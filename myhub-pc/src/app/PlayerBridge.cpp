#include "PlayerBridge.h"

#include "core/history/ProgressRepository.h"
#include "core/player/PlaybackProgressTracker.h"
#include "core/player/PlayerCore.h"
#include "core/player/SubtitleMatcher.h"
#include "core/preferences/AppSettings.h"
#include "core/storage/StorageAdapter.h"
#include "core/utils/AppLogger.h"
#include "core/utils/TrackName.h"
#include "features/connections/ConnectionStore.h"
#include "features/player/MpvEngine.h"
#include "features/player/MpvVideoItem.h"
#include "features/player/PlaybackStreamService.h"

#include <QDir>
#include <QFileInfo>
#include <QHash>
#include <QQuickItem>
#include <QVariantMap>
#include <QtGlobal>

#include <utility>

namespace myhub {
namespace {

constexpr auto kBrightnessKey = "reader.brightness";
constexpr auto kAudioOnlyDefaultKey = "player.audioOnlyByDefault";
constexpr auto kDecodePreferenceKey = "player.decodePreference";
/// 无连接源归属时的保留 id（与 QML 传入的连接 id 同域，避免同一文件写出两条记录）
constexpr auto kLocalConnectionId = "local";

/// 进度上报器随门面存活，退出时需要它在数据库关闭前落盘
PlaybackProgressTracker *s_tracker = nullptr;

PlayerBridge::State toBridgeState(PlaybackState state)
{
    switch (state) {
    case PlaybackState::Idle:
        return PlayerBridge::Idle;
    case PlaybackState::Loading:
        return PlayerBridge::Loading;
    case PlaybackState::Playing:
        return PlayerBridge::Playing;
    case PlaybackState::Paused:
        return PlayerBridge::Paused;
    case PlaybackState::Ended:
        return PlayerBridge::Ended;
    case PlaybackState::Error:
        return PlayerBridge::Error;
    }
    return PlayerBridge::Idle;
}

QString trackLabel(const PlaybackTrack &track, const QString &prefix, int index)
{
    if (!track.title.isEmpty()) {
        return track.title;
    }
    if (!track.lang.isEmpty()) {
        return track.lang.toUpper();
    }
    return QStringLiteral("%1 %2").arg(prefix).arg(index + 1);
}

QVariantList toVariantList(const QList<PlaybackTrack> &tracks, const QString &prefix)
{
    QVariantList list;
    list.reserve(tracks.size());
    for (int i = 0; i < tracks.size(); ++i) {
        const auto &track = tracks.at(i);
        QVariantMap item;
        item.insert(QStringLiteral("id"), track.id);
        item.insert(QStringLiteral("label"), trackLabel(track, prefix, i));
        item.insert(QStringLiteral("lang"), track.lang);
        item.insert(QStringLiteral("codec"), track.codec);
        item.insert(QStringLiteral("external"), track.external);
        item.insert(QStringLiteral("selected"), track.selected);
        list.append(item);
    }
    return list;
}

} // namespace

PlayerBridge *PlayerBridge::create(QQmlEngine *qmlEngine, QJSEngine *)
{
    // 单例工厂必须幂等：QML 引擎实测会调用两次 create()。
    // 返回不同实例会让「QML 持有的门面」与「PlayerCore 装配的引擎」错位；
    // 且未设 C++ 所有权的对象会被 JS GC 回收，连带销毁渲染面（播一会儿黑屏 / 卡死）。
    static PlayerBridge *instance = nullptr;
    if (!instance) {
        instance = new PlayerBridge(nullptr);
        // 唯一的引擎装配点：门面不知道具体解码器，UI 不知道 mpv 存在
        PlayerCore &core = PlayerCore::instance();
        core.setEngine(new MpvEngine(instance));
        // 进度的唯一写入点：跟着门面走，QML 与后续模块都不必各自上报
        s_tracker = new PlaybackProgressTracker(&core, &ProgressRepository::instance(), instance);
    }
    qmlEngine->setObjectOwnership(instance, QQmlEngine::CppOwnership);

    return instance;
}

PlayerBridge::PlayerBridge(QObject *parent)
    : QObject(parent)
{
    const auto &settings = AppSettings::instance();
    const double storedBrightness =
        settings.value(QString::fromLatin1(kBrightnessKey), -1.0).toDouble();
    m_brightness = storedBrightness < 0 ? 1.0 : qBound(0.2, storedBrightness, 1.0);

    auto &core = PlayerCore::instance();
    connect(&core, &PlayerCore::stateChanged, this, &PlayerBridge::stateChanged);
    connect(&core, &PlayerCore::titleChanged, this, &PlayerBridge::titleChanged);
    // 会话建立（open → Loading/Title）与会话关闭（close → Idle）都会经过这两个信号；
    // 路径属性据此通知，浏览页的「正在播放」角标不必自己猜时机
    connect(&core, &PlayerCore::stateChanged, this, &PlayerBridge::currentMediaChanged);
    connect(&core, &PlayerCore::titleChanged, this, &PlayerBridge::currentMediaChanged);
    connect(&core, &PlayerCore::mediaChanged, this, &PlayerBridge::currentMediaChanged);
    connect(&core, &PlayerCore::positionChanged, this, &PlayerBridge::positionChanged);
    connect(&core, &PlayerCore::durationChanged, this, &PlayerBridge::durationChanged);
    connect(&core, &PlayerCore::bufferingChanged, this, &PlayerBridge::bufferingChanged);
    connect(&core, &PlayerCore::mediaChanged, this, &PlayerBridge::mediaChanged);
    connect(&core, &PlayerCore::errorTextChanged, this, &PlayerBridge::errorTextChanged);
    connect(&core, &PlayerCore::audioOnlyChanged, this, &PlayerBridge::audioOnlyChanged);
    connect(&core, &PlayerCore::mutedChanged, this, &PlayerBridge::mutedChanged);
    connect(&core, &PlayerCore::volumeChanged, this, &PlayerBridge::volumeChanged);
    connect(&core, &PlayerCore::speedChanged, this, &PlayerBridge::speedChanged);
    connect(&core, &PlayerCore::audioTracksChanged, this,
            [this](const QList<PlaybackTrack> &tracks) {
                m_audioTracks = toVariantList(tracks, tr("音轨"));
                emit audioTracksChanged();
            });
    connect(&core, &PlayerCore::subtitleTracksChanged, this,
            [this](const QList<PlaybackTrack> &tracks) {
                m_subtitleTracks = toVariantList(tracks, tr("字幕"));
                emit subtitleTracksChanged();
                // 轨道列表就位 = 文件已加载完成，这时才谈得上挂外挂字幕
                autoAttachSubtitle();
            });
    connect(&core, &PlayerCore::screenshotSaved, this, &PlayerBridge::screenshotSaved);
    connect(&core, &PlayerCore::screenshotFailed, this, &PlayerBridge::screenshotFailed);

    // 设置项改动即时生效（§14.16）：解码方式当下就下发，其余属性由 QML 重新绑定
    connect(&settings, &AppSettings::settingChanged, this, [this](const QString &key) {
        if (key == QString::fromLatin1(kDecodePreferenceKey)) {
            if (auto *engine = PlayerCore::instance().engine()) {
                engine->setDecodePreference(
                    AppSettings::instance().value(key, QStringLiteral("auto")).toString());
            }
        }
        if (key.startsWith(QStringLiteral("player."))
            || key == QString::fromLatin1(kBrightnessKey)) {
            emit preferencesChanged();
        }
    });

    // §4.2：回环代流换端口后，正在播的远程会话按新 URL 重开一次
    connect(&PlaybackStreamService::instance(), &PlaybackStreamService::streamUrlRebuilt, this,
            [this](const QString &streamId, const QUrl &url) {
                if (streamId != m_streamId)
                    return;
                const PlaybackRequest request = PlayerCore::instance().currentRequest();
                const qint64 position = PlayerCore::instance().positionMs();
                beginRequest(url, request.path, request.title, position, request.connectionId);
            });

    // 起播即报错且处于远程会话时，探一次活：监听僵死 → 换端口 → 上面的信号把播放接上。
    // 只重试一次，坏文件（编码不支持）不会无限重开。
    connect(&core, &PlayerCore::stateChanged, this, [this]() {
        if (m_streamId.isEmpty() || m_remoteRetried)
            return;
        if (PlayerCore::instance().state() != PlaybackState::Error)
            return;
        m_remoteRetried = true;
        PlaybackStreamService::instance().verifyHealth();
    });
}

// ---------------------------------------------------------------- 属性

PlayerBridge::State PlayerBridge::state() const
{
    return toBridgeState(PlayerCore::instance().state());
}

QString PlayerBridge::title() const
{
    return PlayerCore::instance().title();
}

QString PlayerBridge::mediaArtist() const
{
    return TrackName::parse(PlayerCore::instance().currentRequest().title).artist;
}

QString PlayerBridge::mediaTitle() const
{
    return TrackName::parse(PlayerCore::instance().currentRequest().title).title;
}

QString PlayerBridge::currentPath() const
{
    return PlayerCore::instance().currentRequest().path;
}

QString PlayerBridge::currentConnectionId() const
{
    return PlayerCore::instance().currentRequest().connectionId;
}

qint64 PlayerBridge::positionMs() const
{
    return PlayerCore::instance().positionMs();
}

qint64 PlayerBridge::durationMs() const
{
    return PlayerCore::instance().durationMs();
}

bool PlayerBridge::buffering() const
{
    return PlayerCore::instance().buffering();
}

bool PlayerBridge::hasVideo() const
{
    return PlayerCore::instance().hasVideo();
}

bool PlayerBridge::audioOnly() const
{
    return PlayerCore::instance().audioOnly();
}

bool PlayerBridge::muted() const
{
    return PlayerCore::instance().muted();
}

double PlayerBridge::volume() const
{
    return PlayerCore::instance().volume();
}

double PlayerBridge::speed() const
{
    return PlayerCore::instance().speed();
}

QString PlayerBridge::errorText() const
{
    return PlayerCore::instance().errorText();
}

QVariantList PlayerBridge::audioTracks() const
{
    return m_audioTracks;
}

QVariantList PlayerBridge::subtitleTracks() const
{
    return m_subtitleTracks;
}

qreal PlayerBridge::brightness() const
{
    return m_brightness;
}

double PlayerBridge::volumeStep() const
{
    return AppSettings::instance().value(QStringLiteral("player.volumeStep"), 0.05).toDouble();
}

int PlayerBridge::seekStepSeconds() const
{
    return AppSettings::instance().value(QStringLiteral("player.seekStepSeconds"), 10).toInt();
}

int PlayerBridge::subtitleFontSize() const
{
    return AppSettings::instance().value(QStringLiteral("player.subtitleFontSize"), 16).toInt();
}

double PlayerBridge::subtitleDelay() const
{
    return AppSettings::instance().value(QStringLiteral("player.subtitleDelay"), 0.0).toDouble();
}

void PlayerBridge::setAudioOnly(bool audioOnly)
{
    PlayerCore::instance().setAudioOnly(audioOnly);
}

void PlayerBridge::setMuted(bool muted)
{
    PlayerCore::instance().setMuted(muted);
}

void PlayerBridge::setVolume(double volume)
{
    PlayerCore::instance().setVolume(volume);
}

void PlayerBridge::setSpeed(double speed)
{
    PlayerCore::instance().setSpeed(speed);
}

void PlayerBridge::setBrightness(qreal brightness)
{
    const qreal clamped = qBound<qreal>(0.2, brightness, 1.0);
    if (qFuzzyCompare(clamped, m_brightness)) {
        return;
    }
    m_brightness = clamped;
    AppSettings::instance().setValue(QString::fromLatin1(kBrightnessKey), m_brightness);
    emit brightnessChanged();
}

// ---------------------------------------------------------------- 控制

void PlayerBridge::open(const QUrl &url, const QString &title, qint64 startMs,
                        const QString &connectionId)
{
    // 本地/直链起播：先注销可能还在跑的远程会话，避免两条管线并存
    releaseStreamSession();
    beginRequest(url, url.isLocalFile() ? url.toLocalFile() : url.toString(), title, startMs,
                 connectionId);
}

void PlayerBridge::beginRequest(const QUrl &url, const QString &path, const QString &title,
                                qint64 startMs, const QString &connectionId)
{
    const auto &settings = AppSettings::instance();
    auto &core = PlayerCore::instance();

    PlaybackRequest request;
    request.url = url;
    request.title = title;
    request.path = path;
    request.connectionId =
        connectionId.isEmpty() ? QString::fromLatin1(kLocalConnectionId) : connectionId;

    // 续播起点：负数表示「按历史进度」。位置直接交给 mpv 的 start 选项，
    // 起播即落在该点，不出现「先 0 后跳」（PC-209）。
    qint64 resume = qMax<qint64>(0, startMs);
    if (startMs < 0) {
        ProgressRecord record;
        if (ProgressRepository::instance().find(request.connectionId, request.path, &record)) {
            resume = ProgressRepository::resumePositionMs(record);
        }
    }
    request.startPositionMs = resume;

    // 会话内保持当前的纯音频选择；首次起播取全局默认（PC-206）
    request.audioOnly = core.active()
        ? core.audioOnly()
        : settings.value(QString::fromLatin1(kAudioOnlyDefaultKey), false).toBool();

    if (auto *engine = core.engine()) {
        engine->setDecodePreference(
            settings.value(QString::fromLatin1(kDecodePreferenceKey), QStringLiteral("auto"))
                .toString());
    }
    core.open(request);
}

void PlayerBridge::openLocalFile(const QString &path, const QString &title, qint64 startMs,
                                 const QString &connectionId)
{
    open(QUrl::fromLocalFile(path), title, startMs, connectionId);
}

void PlayerBridge::openRemote(const QString &connectionId, const QString &path,
                              const QString &title, qint64 size, const QString &fingerprint,
                              qint64 startMs)
{
    const QString id =
        connectionId.isEmpty() ? QString::fromLatin1(kLocalConnectionId) : connectionId;
    if (id == QString::fromLatin1(kLocalConnectionId)) {
        // 没有连接源归属的「远程」路径没有意义，按本地文件处理
        openLocalFile(path, title, startMs, id);
        return;
    }

    // 断网兜底：整份缓存已在本地时，凭缓存身份离线起播（§4.2 cachedIdentity）
    auto startOffline = [this, id, path, title, startMs](const QString &reason) {
        const auto offline =
            PlaybackStreamService::instance().prepareOffline(id, path, title, reason);
        if (!offline.ok()) {
            emit remoteOpenFailed(offline.error);
            return;
        }
        releaseStreamSession();
        m_streamId = offline.streamId;
        m_remoteRetried = false;
        beginRequest(offline.url, path, title, startMs, id);
    };

    if (size <= 0) {
        // 收藏 / 在读页拿不到目录模型的大小与指纹，补一次 stat 再起播
        StorageError error;
        StorageAdapter *adapter = ConnectionStore::instance().adapterFor(id, &error);
        if (!adapter) {
            startOffline(error.message().isEmpty() ? tr("连接源当前不可用") : error.message());
            return;
        }
        adapter->stat(path, [this, id, path, title, startMs, startOffline](StatResult result) {
            if (!result.ok()) {
                startOffline(result.error.message().isEmpty() ? tr("无法读取该文件的信息")
                                                              : result.error.message());
                return;
            }
            openRemote(id, path, title, result.value.size, result.value.fingerprint(), startMs);
        });
        return;
    }

    const auto prepared =
        PlaybackStreamService::instance().prepare(id, path, title, size, fingerprint);
    if (!prepared.ok()) {
        emit remoteOpenFailed(prepared.error);
        return;
    }

    releaseStreamSession();
    m_streamId = prepared.streamId;
    m_remoteRetried = false;
    beginRequest(prepared.url, path, title, startMs, id);
}

void PlayerBridge::releaseStreamSession()
{
    // 外挂字幕的代流会话永远从属当前片子：换片 / 关闭时一并注销
    for (const QString &id : std::as_const(m_subtitleStreams))
        PlaybackStreamService::instance().release(id);
    m_subtitleStreams.clear();

    if (m_streamId.isEmpty())
        return;
    PlaybackStreamService::instance().release(m_streamId);
    m_streamId.clear();
    m_remoteRetried = false;
}

void PlayerBridge::flushPendingProgress()
{
    if (s_tracker) {
        s_tracker->flush();
    }
}

QVariantMap PlayerBridge::progressFor(const QString &connectionId, const QString &path) const
{
    const QString id =
        connectionId.isEmpty() ? QString::fromLatin1(kLocalConnectionId) : connectionId;
    ProgressRecord record;
    if (!ProgressRepository::instance().find(id, path, &record)) {
        return {};
    }

    QVariantMap info = record.progress;
    info.insert(QStringLiteral("mediaType"), record.mediaType);
    info.insert(QStringLiteral("title"), record.title);
    info.insert(QStringLiteral("cover"), record.cover);
    info.insert(QStringLiteral("percent"), record.percent);
    info.insert(QStringLiteral("finished"), record.finished);
    info.insert(QStringLiteral("updatedAt"), record.updatedAt);
    info.insert(QStringLiteral("resumeMs"), ProgressRepository::resumePositionMs(record));
    return info;
}

void PlayerBridge::close()
{
    PlayerCore::instance().close();
    // 会话注销：排队中的预读立即作废，不留后台请求
    releaseStreamSession();
}

void PlayerBridge::togglePause()
{
    PlayerCore::instance().togglePause();
}

void PlayerBridge::toggleMute()
{
    PlayerCore::instance().toggleMute();
}

void PlayerBridge::adjustVolume(double delta)
{
    PlayerCore::instance().adjustVolume(delta);
}

void PlayerBridge::seekTo(qint64 positionMs)
{
    PlayerCore::instance().seekTo(positionMs);
}

void PlayerBridge::seekBy(qint64 deltaMs)
{
    PlayerCore::instance().seekBy(deltaMs);
}

void PlayerBridge::selectAudioTrack(int id)
{
    PlayerCore::instance().selectAudioTrack(id);
}

void PlayerBridge::selectSubtitleTrack(int id)
{
    PlayerCore::instance().selectSubtitleTrack(id);
}

void PlayerBridge::addSubtitle(const QUrl &url)
{
    PlayerCore::instance().addSubtitleFile(url);
}

void PlayerBridge::setSubtitleFontSize(int fontSize)
{
    AppSettings::instance().setValue(QStringLiteral("player.subtitleFontSize"),
                                     qBound(8, fontSize, 64));
    applySubtitleStyle();
}

void PlayerBridge::setSubtitleDelay(double seconds)
{
    AppSettings::instance().setValue(QStringLiteral("player.subtitleDelay"),
                                     qBound(-30.0, seconds, 30.0));
    applySubtitleStyle();
}

void PlayerBridge::applySubtitleStyle()
{
    PlayerCore::instance().setSubtitleStyle(subtitleFontSize(), subtitleDelay());
}

void PlayerBridge::autoAttachSubtitle()
{
    PlayerCore &core = PlayerCore::instance();
    const PlaybackRequest request = core.currentRequest();
    if (request.path.isEmpty())
        return;

    // 已经有外挂轨：用户手动加的、或换端口重开后恢复的，都不再重复叠加
    for (const PlaybackTrack &track : core.subtitleTracks()) {
        if (track.external)
            return;
    }

    const QFileInfo info(request.path);
    const QString base = info.completeBaseName();
    if (base.isEmpty())
        return;
    const QString dir = info.path();

    const bool local = request.connectionId == QString::fromLatin1(kLocalConnectionId)
        || request.url.isLocalFile();
    if (local) {
        const QDir folder(dir);
        const QString hit = SubtitleMatcher::pick(base, folder.entryList(QDir::Files, QDir::Name));
        if (hit.isEmpty())
            return;
        MH_INFO(Player, QStringLiteral("自动加载外挂字幕：%1").arg(hit));
        core.addSubtitleFile(QUrl::fromLocalFile(folder.absoluteFilePath(hit)));
        return;
    }

    StorageError error;
    StorageAdapter *adapter = ConnectionStore::instance().adapterFor(request.connectionId, &error);
    if (!adapter)
        return;

    // 远程目录列举是异步的：回来时若已换片，直接丢弃，别给新视频挂上旧字幕
    const QPointer<PlayerBridge> guard(this);
    const QString mediaPath = request.path;
    adapter->list(dir, [this, guard, base, mediaPath](ListResult result) {
        if (!guard || !result.ok())
            return;
        const PlaybackRequest current = PlayerCore::instance().currentRequest();
        if (current.path != mediaPath || current.connectionId.isEmpty())
            return;

        QStringList names;
        QHash<QString, FileEntry> byName;
        for (const FileEntry &entry : std::as_const(result.value)) {
            if (entry.isDir)
                continue;
            names.append(entry.name);
            byName.insert(entry.name, entry);
        }

        const QString hit = SubtitleMatcher::pick(base, names);
        if (hit.isEmpty())
            return;
        const FileEntry entry = byName.value(hit);

        // 远程字幕不能直接把私有路径交给 mpv（它只认 http/file），统一走回环代流
        const auto prepared = PlaybackStreamService::instance().prepare(
            current.connectionId, entry.path, entry.name, entry.size, entry.fingerprint());
        if (!prepared.ok()) {
            MH_WARN(Player,
                    QStringLiteral("外挂字幕代流建立失败：%1（%2）").arg(hit, prepared.error));
            return;
        }

        for (const QString &id : std::as_const(m_subtitleStreams))
            PlaybackStreamService::instance().release(id);
        m_subtitleStreams = QStringList{prepared.streamId};

        MH_INFO(Player, QStringLiteral("自动加载外挂字幕：%1").arg(hit));
        PlayerCore::instance().addSubtitleFile(prepared.url);
    });
}

void PlayerBridge::toggleAudioOnly()
{
    PlayerCore::instance().toggleAudioOnly();
}

void PlayerBridge::saveScreenshot()
{
    PlayerCore::instance().saveScreenshot();
}

void PlayerBridge::claimSurface(QQuickItem *container)
{
    auto *engine = PlayerCore::instance().engine();
    if (!engine || !container) {
        return;
    }

    if (m_surface) {
        // 单宿主架构：渲染面自创建起就固定在 PlayerVideoLayer 里，
        // 全屏 ↔ mini 只改那一层的几何。这里若真换了容器，说明 QML 侧
        // 又出现了第二个宿主 —— 重挂载会让场景图销毁并重建 mpv 渲染节点
        // （表现为切换后黑屏 / 渲染线程死锁），所以宁可不搬只报错。
        if (m_surface->parentItem() != container) {
            qWarning("PlayerBridge: video surface already hosted, refusing to reparent");
        }
        return;
    }

    auto *surface = new MpvVideoItem(container);
    m_surface = surface;
    surface->setSize(QSizeF(container->width(), container->height()));

    // 尺寸始终跟随宿主容器（QML 只决定容器多大，不直接碰渲染面）
    m_host = container;
    m_hostWidthConn =
        QObject::connect(container, &QQuickItem::widthChanged, surface,
                         [container, surface]() { surface->setWidth(container->width()); });
    m_hostHeightConn =
        QObject::connect(container, &QQuickItem::heightChanged, surface,
                         [container, surface]() { surface->setHeight(container->height()); });

    // 注意：**不要**按 hasVideo 翻 visible。渲染节点一旦隐藏会被场景图销毁，
    // mpv 的 render context 随之释放；再显示时重建，起播时机就错位了
    // （视频轨被丢弃 → 有声音没画面）。呈现与否由 PlayerVideoLayer 的几何决定。
    QObject::connect(surface, &QObject::destroyed, this, [this]() {
        m_surface = nullptr;
        m_host = nullptr;
    });

    engine->attachSurface(surface);
}

} // namespace myhub
