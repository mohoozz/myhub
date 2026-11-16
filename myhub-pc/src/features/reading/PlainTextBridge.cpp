#include "PlainTextBridge.h"

#include "core/storage/StorageAdapter.h"
#include "core/stream/AdapterRangeSource.h"
#include "core/text/PlainTextDocument.h"
#include "core/utils/AppLogger.h"
#include "features/connections/ConnectionStore.h"

#include <QFileInfo>

#include <utility>

namespace myhub {
namespace {

/// 命中高亮的底色：与阅读器的强调色同一个色系，暖黄不刺眼
constexpr auto kHighlightStyle = "background-color: rgba(255, 196, 0, 0.45);";

/// 富文本里换行必须转成 <br/>：RichText 把 "\n" 当空格，整段会挤成一行
QString fileLineBreaks(const QString &escaped)
{
    QString out = escaped;
    out.replace(QLatin1String("\n"), QLatin1String("<br/>"));
    return out;
}

} // namespace

PlainTextBridge *PlainTextBridge::instance()
{
    static PlainTextBridge *bridge = nullptr;
    if (!bridge) {
        bridge = new PlainTextBridge(nullptr);
    }
    return bridge;
}

PlainTextBridge *PlainTextBridge::create(QQmlEngine *, QJSEngine *)
{
    // 单例工厂会被调用多次，必须幂等（与 NovelBridge 同理）
    return instance();
}

PlainTextBridge::PlainTextBridge(QObject *parent)
    : QAbstractListModel(parent)
{}

PlainTextBridge::~PlainTextBridge() = default;

// ---------------------------------------------------------------- 模型

int PlainTextBridge::rowCount(const QModelIndex &parent) const
{
    return parent.isValid() ? 0 : static_cast<int>(m_chunks.size());
}

QVariant PlainTextBridge::data(const QModelIndex &index, int role) const
{
    if (!index.isValid() || index.row() < 0 || index.row() >= m_chunks.size()) {
        return QVariant();
    }
    switch (role) {
    case TextRole:
        return m_chunks.at(index.row());
    default:
        return QVariant();
    }
}

QHash<int, QByteArray> PlainTextBridge::roleNames() const
{
    return {{TextRole, "text"}};
}

bool PlainTextBridge::canFetchMore(const QModelIndex &parent) const
{
    if (parent.isValid() || !active() || !m_errorText.isEmpty()) {
        return false;
    }
    return !m_atEnd;
}

void PlainTextBridge::fetchMore(const QModelIndex &parent)
{
    if (parent.isValid()) {
        return;
    }
    // 一次多读两块：ListView 每次只补一屏，滚到底时会连续触发，攒一批更顺
    m_fetchAhead = qMax(m_fetchAhead, 2);
    requestChunk();
}

void PlainTextBridge::loadMore()
{
    m_fetchAhead = qMax(m_fetchAhead, 1);
    requestChunk();
}

// ---------------------------------------------------------------- 打开 / 关闭

double PlainTextBridge::percent() const
{
    if (m_fileSize <= 0) {
        return m_atEnd ? 1.0 : 0.0;
    }
    return qBound(0.0, static_cast<double>(m_loadedBytes) / static_cast<double>(m_fileSize), 1.0);
}

void PlainTextBridge::open(const QString &connectionId, const QString &path)
{
    close();

    if (connectionId.isEmpty() || path.isEmpty()) {
        setErrorText(QStringLiteral("缺少连接源或文件路径"));
        return;
    }

    ++m_serial;
    const int serial = m_serial;
    m_connectionId = connectionId;
    m_path = path;
    m_title = QFileInfo(path).fileName();
    if (m_title.isEmpty()) {
        m_title = path;
    }
    emit activeChanged();
    emit bookChanged();
    setLoading(true);

    StorageError error;
    StorageAdapter *adapter = ConnectionStore::instance().adapterFor(connectionId, &error);
    if (!adapter) {
        setLoading(false);
        setErrorText(error.isNull() ? QStringLiteral("连接源不可用") : error.message());
        return;
    }

    adapter->stat(path, [this, adapter, serial](StatResult result) {
        if (serial != m_serial) {
            return; // 上一本书的回调，丢弃
        }
        if (!result.ok()) {
            setLoading(false);
            setErrorText(result.error.message().isEmpty() ? QStringLiteral("读取文件信息失败")
                                                          : result.error.message());
            return;
        }
        if (result.value.isDir) {
            setLoading(false);
            setErrorText(QStringLiteral("这是目录，不是可以阅读的文件"));
            return;
        }

        m_fileSize = result.value.size;
        emit bookChanged();

        auto source = std::make_unique<AdapterRangeSource>(adapter, m_path, m_fileSize);
        m_sourceOwner = std::move(source);
        m_doc = std::make_unique<PlainTextDocument>(m_sourceOwner.get());
        m_doc->probe(m_fileSize, [this, serial](const StorageError &probeError) {
            if (serial != m_serial || !m_doc) {
                return;
            }
            if (!probeError.isNull()) {
                setLoading(false);
                setErrorText(probeError.message().isEmpty() ? QStringLiteral("编码检测失败")
                                                            : probeError.message());
                return;
            }
            m_encodingName = m_doc->encodingName();
            emit bookChanged();
            MH_INFO(App,
                    QStringLiteral("打开纯文本：%1（%2 字节，%3）")
                        .arg(m_path)
                        .arg(m_fileSize)
                        .arg(m_encodingName));

            // 空文件：没有块可读，直接给一个空页
            if (m_fileSize == 0) {
                m_atEnd = true;
                setLoading(false);
                emit progressChanged();
                return;
            }
            m_fetchAhead = 2; // 首屏先铺三块，滚动条不至于一跳一跳
            requestChunk();
        });
    });
}

void PlainTextBridge::close()
{
    reset();
}

void PlainTextBridge::reset()
{
    ++m_serial;
    m_doc.reset();
    m_sourceOwner.reset();

    if (!m_chunks.isEmpty() || active()) {
        beginResetModel();
        m_chunks.clear();
        endResetModel();
    }

    const bool wasActive = active() || !m_errorText.isEmpty();
    m_connectionId.clear();
    m_path.clear();
    m_title.clear();
    m_encodingName.clear();
    m_fileSize = 0;
    m_loadedBytes = 0;
    m_atEnd = false;
    m_inflight = false;
    m_fetchAhead = 0;
    m_needle.clear();
    m_searching = false;
    m_hitRow = -1;
    m_searchBudget = 0;

    setLoading(false);
    setErrorText(QString());
    if (wasActive) {
        emit activeChanged();
        emit bookChanged();
        emit progressChanged();
        emit findTextChanged();
        emit hitRowChanged();
    }
}

// ---------------------------------------------------------------- 分块读取

void PlainTextBridge::requestChunk()
{
    if (m_inflight || !m_doc || !active() || !m_errorText.isEmpty() || m_atEnd) {
        return;
    }
    m_inflight = true;
    const int serial = m_serial;
    m_doc->readNext([this, serial](const PlainTextDocument::Result &result) {
        m_inflight = false;
        if (serial != m_serial) {
            return;
        }
        if (!result.ok()) {
            setLoading(false);
            setErrorText(result.error.message().isEmpty() ? QStringLiteral("读取文件失败")
                                                          : result.error.message());
            return;
        }
        if (!result.text.isEmpty()) {
            appendChunk(result.text);
        }

        const bool end = !m_doc || m_doc->atEnd();
        if (end != m_atEnd) {
            m_atEnd = end;
            emit progressChanged();
        }

        if (m_chunks.size() == 1) {
            setLoading(false); // 第一块上屏即可取消骨架
        }

        // 查找优先：命中就停在这一块，不再预读
        if (m_searching) {
            const int row = locateLoaded(m_hitRow + 1);
            if (row >= 0) {
                finishSearch(true);
                setHit(row);
                return;
            }
            if (!m_atEnd && m_searchBudget > 0) {
                --m_searchBudget;
                requestChunk();
                return;
            }
            finishSearch(false);
            return;
        }

        if (m_fetchAhead > 0 && !m_atEnd) {
            --m_fetchAhead;
            requestChunk();
        }
    });
}

void PlainTextBridge::appendChunk(const QString &text)
{
    const int row = static_cast<int>(m_chunks.size());
    beginInsertRows(QModelIndex(), row, row);
    m_chunks.append(text);
    endInsertRows();

    if (m_doc) {
        m_loadedBytes = m_doc->loadedBytes();
    }
    emit progressChanged();
}

void PlainTextBridge::setLoading(bool loading)
{
    if (m_loading == loading) {
        return;
    }
    m_loading = loading;
    emit loadingChanged();
}

void PlainTextBridge::setErrorText(const QString &text)
{
    if (m_errorText == text) {
        return;
    }
    m_errorText = text;
    emit errorTextChanged();
}

// ---------------------------------------------------------------- 查找

int PlainTextBridge::locateLoaded(int fromRow) const
{
    if (m_needle.isEmpty()) {
        return -1;
    }
    for (int row = qMax(0, fromRow); row < m_chunks.size(); ++row) {
        if (m_chunks.at(row).contains(m_needle, Qt::CaseInsensitive)) {
            return row;
        }
    }
    return -1;
}

void PlainTextBridge::find(const QString &text)
{
    if (text.isEmpty()) {
        clearFind();
        return;
    }
    if (!active()) {
        return;
    }
    m_needle = text;
    m_hitRow = -1;
    emit findTextChanged();
    emit hitRowChanged();

    // 已加载的块先找一遍：绝大多数查找都在已读范围内命中
    const int row = locateLoaded(0);
    if (row >= 0) {
        setHit(row);
        return;
    }
    startSearch();
}

void PlainTextBridge::findNext()
{
    if (m_needle.isEmpty() || !active()) {
        return;
    }
    const int row = locateLoaded(m_hitRow + 1);
    if (row >= 0) {
        setHit(row);
        return;
    }
    startSearch();
}

void PlainTextBridge::clearFind()
{
    if (m_needle.isEmpty() && m_hitRow < 0 && !m_searching) {
        return;
    }
    m_needle.clear();
    m_hitRow = -1;
    m_searching = false;
    m_searchBudget = 0;
    emit findTextChanged();
    emit hitRowChanged();
    emit searchingChanged();
}

void PlainTextBridge::startSearch()
{
    if (m_searching || !active()) {
        return;
    }
    if (m_atEnd) {
        finishSearch(false);
        return;
    }
    m_searching = true;
    // 预算 64 块（默认块 64KB，约 4MB）：再远就让用户自己滚过去，别一次点查找读完整个网盘
    m_searchBudget = 64;
    emit searchingChanged();
    requestChunk();
}

void PlainTextBridge::finishSearch(bool hit)
{
    if (!m_searching) {
        if (!hit) {
            emit findFinished(false);
        }
        return;
    }
    m_searching = false;
    m_searchBudget = 0;
    emit searchingChanged();
    emit findFinished(hit);
}

void PlainTextBridge::setHit(int row)
{
    if (m_hitRow == row) {
        emit found(row); // 同一处再按一次也要滚回去
        return;
    }
    m_hitRow = row;
    emit hitRowChanged();
    emit found(row);
}

QString PlainTextBridge::highlighted(int row) const
{
    if (row != m_hitRow || m_needle.isEmpty() || row < 0 || row >= m_chunks.size()) {
        return QString();
    }
    const QString &text = m_chunks.at(row);
    const int pos = text.indexOf(m_needle, 0, Qt::CaseInsensitive);
    if (pos < 0) {
        return QString();
    }
    const QString head = fileLineBreaks(text.left(pos).toHtmlEscaped());
    const QString hit = fileLineBreaks(text.mid(pos, m_needle.size()).toHtmlEscaped());
    const QString tail = fileLineBreaks(text.mid(pos + m_needle.size()).toHtmlEscaped());
    return head + QLatin1String("<span style=\"") + QLatin1String(kHighlightStyle)
        + QLatin1String("\">") + hit + QLatin1String("</span>") + tail;
}

} // namespace myhub
