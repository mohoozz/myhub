#include "ConnectionStore.h"

#include "core/cache/DirectoryCache.h"
#include "core/credentials/CredentialStore.h"
#include "core/database/AppDatabase.h"
#include "core/network/NetworkHeuristics.h"
#include "core/preferences/AppSettings.h"
#include "core/storage/RoutedWebDAVAdapter.h"
#include "core/utils/AppLogger.h"

#include <QDateTime>
#include <QJsonDocument>
#include <QJsonObject>
#include <QUuid>

namespace myhub {

ConnectionStore::ConnectionStore(QObject *parent)
    : QObject(parent)
{}

ConnectionStore::~ConnectionStore() = default;

ConnectionStore &ConnectionStore::instance()
{
    static ConnectionStore s_instance;
    return s_instance;
}

ConnectionStore *ConnectionStore::create(QQmlEngine *, QJSEngine *)
{
    // 单例生命周期由 C++ 持有，QML 不得接管
    QJSEngine::setObjectOwnership(&instance(), QJSEngine::CppOwnership);
    return &instance();
}

QString ConnectionStore::upsertFromQml(const QString &id, const QString &name, const QString &type,
                                       const QVariantMap &config, const QString &mountPoint,
                                       bool enabled, const QString &password)
{
    ConnectionRecord r;
    r.id = id;
    r.name = name;
    r.type = StorageAdapterFactory::typeFromString(type);
    r.config = QJsonObject::fromVariantMap(config);
    r.mountPoint = mountPoint;
    r.enabled = enabled;

    if (!id.isEmpty()) {
        // 保留原始创建时间
        const ConnectionRecord existing = byId(id);
        if (existing.isValid())
            r.createdAt = existing.createdAt;
    }

    if (!upsert(r, password))
        return {};

    // upsert 内部可能生成了新 id，从末尾取回
    m_lastUpsertedId = id.isEmpty() ? (m_records.isEmpty() ? QString() : m_records.last().id) : id;
    return m_lastUpsertedId;
}

void ConnectionStore::load()
{
    auto &db = AppDatabase::instance();
    if (!db.isOpen()) {
        MH_WARN(App, QStringLiteral("ConnectionStore::load called before database is open"));
        return;
    }

    m_records.clear();

    const auto rows =
        db.query(QStringLiteral("SELECT id, name, type, configJSON, mountPoint, enabled, createdAt "
                                "FROM connection ORDER BY createdAt ASC"));

    for (const QVariantMap &row : rows) {
        ConnectionRecord r;
        r.id = row.value(QStringLiteral("id")).toString();
        r.name = row.value(QStringLiteral("name")).toString();
        r.type =
            StorageAdapterFactory::typeFromString(row.value(QStringLiteral("type")).toString());
        r.mountPoint = row.value(QStringLiteral("mountPoint")).toString();
        r.enabled = row.value(QStringLiteral("enabled")).toLongLong() != 0;
        r.createdAt =
            QDateTime::fromSecsSinceEpoch(row.value(QStringLiteral("createdAt")).toLongLong());

        const QByteArray json = row.value(QStringLiteral("configJSON")).toString().toUtf8();
        r.config = QJsonDocument::fromJson(json).object();

        m_records.append(r);
    }

    m_loaded = true;
    MH_INFO(App, QStringLiteral("loaded %1 connection(s)").arg(m_records.size()));
    emit loadedChanged();
    emit connectionsChanged();
}

ConnectionRecord ConnectionStore::byId(const QString &id) const
{
    for (const ConnectionRecord &r : m_records) {
        if (r.id == id)
            return r;
    }
    return {};
}

int ConnectionStore::indexOf(const QString &id) const
{
    for (int i = 0; i < m_records.size(); ++i) {
        if (m_records.at(i).id == id)
            return i;
    }
    return -1;
}

bool ConnectionStore::upsert(const ConnectionRecord &record, const QString &password)
{
    auto &db = AppDatabase::instance();
    if (!db.isOpen())
        return false;

    ConnectionRecord r = record;
    if (r.id.isEmpty())
        r.id = QUuid::createUuid().toString(QUuid::WithoutBraces);
    if (!r.createdAt.isValid())
        r.createdAt = QDateTime::currentDateTime();
    if (r.mountPoint.isEmpty())
        r.mountPoint = QStringLiteral("/") + r.name;

    const QString configJson =
        QString::fromUtf8(QJsonDocument(r.config).toJson(QJsonDocument::Compact));

    const bool ok = db.execute(
        QStringLiteral(
            "INSERT INTO connection (id, name, type, configJSON, mountPoint, enabled, createdAt) "
            "VALUES (?, ?, ?, ?, ?, ?, ?) "
            "ON CONFLICT(id) DO UPDATE SET "
            "  name=excluded.name, type=excluded.type, configJSON=excluded.configJSON, "
            "  mountPoint=excluded.mountPoint, enabled=excluded.enabled"),
        {r.id, r.name, StorageAdapterFactory::typeToString(r.type), configJson, r.mountPoint,
         r.enabled ? 1 : 0, r.createdAt.toSecsSinceEpoch()});

    if (!ok) {
        MH_ERROR(App, QStringLiteral("upsert connection failed: %1").arg(db.lastError()));
        return false;
    }

    // 凭据写入系统凭据库（密码不入库）
    if (!password.isEmpty())
        CredentialStore::save(CredentialStore::connectionKey(r.id), password);

    // 配置已变 → 旧适配器作废
    invalidateAdapter(r.id);

    const int idx = indexOf(r.id);
    if (idx >= 0)
        m_records[idx] = r;
    else
        m_records.append(r);

    // 新增后浏览页立即可见（§14.10）
    emit connectionsChanged();
    return true;
}

bool ConnectionStore::remove(const QString &id)
{
    auto &db = AppDatabase::instance();
    if (!db.isOpen())
        return false;

    if (!db.execute(QStringLiteral("DELETE FROM connection WHERE id = ?"), {id})) {
        MH_ERROR(App, QStringLiteral("delete connection failed: %1").arg(db.lastError()));
        return false;
    }

    // 仅在删除连接源时才清除凭据（§2.4 PC-101）
    CredentialStore::remove(CredentialStore::connectionKey(id));
    AppSettings::instance().clearConnectionTestState(id);
    DirectoryCache::instance().invalidateConnection(id);
    invalidateAdapter(id);

    const int idx = indexOf(id);
    if (idx >= 0)
        m_records.removeAt(idx);

    emit connectionsChanged();
    return true;
}

bool ConnectionStore::setEnabled(const QString &id, bool enabled)
{
    auto &db = AppDatabase::instance();
    if (!db.execute(QStringLiteral("UPDATE connection SET enabled = ? WHERE id = ?"),
                    {enabled ? 1 : 0, id})) {
        return false;
    }
    const int idx = indexOf(id);
    if (idx >= 0)
        m_records[idx].enabled = enabled;
    emit connectionsChanged();
    return true;
}

StorageAdapter *ConnectionStore::adapterFor(const QString &id, StorageError *error)
{
    if (auto it = m_adapters.constFind(id); it != m_adapters.constEnd())
        return it.value();

    const ConnectionRecord r = byId(id);
    if (!r.isValid()) {
        if (error)
            *error = StorageError(StorageError::InvalidConfig, tr("连接源不存在"));
        return nullptr;
    }

    StorageAdapter *adapter = StorageAdapterFactory::create(r, QString(), error, this);
    if (!adapter)
        return nullptr;

    // 竞速路由锁定后同步刷新 UI 的「内网/外网」文案
    if (auto *routed = qobject_cast<RoutedWebDAVAdapter *>(adapter)) {
        connect(routed, &RoutedWebDAVAdapter::routeLocked, this,
                [this, id](const QString &, bool isInternal) {
                    const QVariantMap st = testState(id);
                    AppSettings::instance().setConnectionTestState(
                        id, true,
                        isInternal ? NetworkHeuristics::scopeName(NetworkHeuristics::Internal)
                                   : NetworkHeuristics::scopeName(NetworkHeuristics::External),
                        st.value(QStringLiteral("message")).toString());
                    emit testStateChanged(id);
                });
    }

    m_adapters.insert(id, adapter);
    return adapter;
}

void ConnectionStore::invalidateAdapter(const QString &id)
{
    if (auto it = m_adapters.find(id); it != m_adapters.end()) {
        it.value()->deleteLater();
        m_adapters.erase(it);
    }
}

void ConnectionStore::applyTestResult(const QString &id, const StorageError &error,
                                      const ConnectionRecord &record)
{
    m_testing.remove(id);

    NetworkHeuristics::Scope scope = NetworkHeuristics::Unknown;
    if (error.isNull()) {
        // 区分「内网可达 / 外网可达」：优先看竞速锁定结果，否则按地址启发式判断
        if (auto *routed = qobject_cast<RoutedWebDAVAdapter *>(m_adapters.value(id))) {
            if (!routed->lockedBaseURL().isEmpty()) {
                scope = routed->lockedIsInternal() ? NetworkHeuristics::Internal
                                                   : NetworkHeuristics::External;
            }
        }
        if (scope == NetworkHeuristics::Unknown) {
            QString probe;
            switch (record.type) {
            case ConnectionType::WebDAV:
                probe = record.config.value(QStringLiteral("internalBaseURL")).toString();
                if (probe.isEmpty())
                    probe = record.config.value(QStringLiteral("baseURL")).toString();
                break;
            case ConnectionType::SMB:
                probe = record.config.value(QStringLiteral("host")).toString();
                break;
            case ConnectionType::Local:
                scope = NetworkHeuristics::Internal;
                break;
            default:
                break;
            }
            if (scope == NetworkHeuristics::Unknown && !probe.isEmpty())
                scope = NetworkHeuristics::scopeOf(probe);
        }
    }

    const QString message =
        error.isNull() ? NetworkHeuristics::scopeDisplayText(scope) : error.userMessage();

    AppSettings::instance().setConnectionTestState(id, error.isNull(),
                                                   NetworkHeuristics::scopeName(scope), message);

    MH_INFO(NetworkRoute,
            QStringLiteral("test %1: %2 (%3)")
                .arg(record.name, error.isNull() ? QStringLiteral("OK") : QStringLiteral("FAIL"),
                     message));

    emit testStateChanged(id);
}

void ConnectionStore::testConnection(const QString &id, const QString &passwordOverride)
{
    const ConnectionRecord r = byId(id);
    if (!r.isValid())
        return;

    if (m_testing.value(id, false))
        return; // 已在测试中，避免重复发起

    m_testing.insert(id, true);
    emit testStarted(id);
    emit testStateChanged(id);

    // 手动测试需清锁重判：丢弃缓存适配器以重新竞速
    if (!passwordOverride.isEmpty())
        invalidateAdapter(id);

    StorageError createError;
    StorageAdapter *adapter = nullptr;

    if (!passwordOverride.isEmpty()) {
        // 表单未保存：用临时适配器测试，不污染缓存
        adapter = StorageAdapterFactory::create(r, passwordOverride, &createError, this);
        if (!adapter) {
            applyTestResult(id, createError, r);
            return;
        }
        adapter->testConnection([this, id, r, adapter](StorageError err) {
            adapter->deleteLater();
            applyTestResult(id, err, r);
        });
        return;
    }

    adapter = adapterFor(id, &createError);
    if (!adapter) {
        applyTestResult(id, createError, r);
        return;
    }

    adapter->testConnection([this, id, r](StorageError err) { applyTestResult(id, err, r); });
}

void ConnectionStore::probeAllOnStartup()
{
    // 启动时探测一次并锁定地址；此后不再每次进入页面重测（PC-101）
    for (const ConnectionRecord &r : m_records) {
        if (!r.enabled)
            continue;
        testConnection(r.id);
    }
}

QVariantMap ConnectionStore::testState(const QString &id) const
{
    QVariantMap st = AppSettings::instance().connectionTestState(id);
    st.insert(QStringLiteral("testing"), m_testing.value(id, false));
    if (!st.contains(QStringLiteral("reachable")))
        st.insert(QStringLiteral("reachable"), QVariant()); // 未知状态
    return st;
}

bool ConnectionStore::isTesting(const QString &id) const
{
    return m_testing.value(id, false);
}

} // namespace myhub
