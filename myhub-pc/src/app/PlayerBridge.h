#pragma once

#include "core/player/PlaybackTypes.h"

#include <QMetaObject>
#include <QObject>
#include <QPointer>
#include <QQmlEngine>
#include <QQuickItem>
#include <QStringList>
#include <QUrl>
#include <QVariantList>

namespace myhub {

class MpvVideoItem;

/**
 * PlayerCore 的 QML 桥接（QML 侧单例名 `Player`）。
 *
 * 与 SettingsBridge 同样的分层理由：PlayerCore 在 myhub_core、不得依赖 QtQml，
 * 因此由本类（app 层）转发属性/方法，并负责把解码器接上——
 * 这里是**唯一**知道「当前解码后端是 libmpv」的 QML 边界。
 */
class PlayerBridge : public QObject
{
    Q_OBJECT
    QML_NAMED_ELEMENT(Player)
    QML_SINGLETON

    Q_PROPERTY(State state READ state NOTIFY stateChanged)
    Q_PROPERTY(QString title READ title NOTIFY titleChanged)
    /// 从文件名解析出的「作者 / 标题」（§4.3 音频封面、§4.5 系统媒体信息共用）。
    /// 解析规则见 `core/utils/TrackName.h`，无作者时 `mediaArtist` 为空。
    Q_PROPERTY(QString mediaArtist READ mediaArtist NOTIFY currentMediaChanged)
    Q_PROPERTY(QString mediaTitle READ mediaTitle NOTIFY currentMediaChanged)
    /// 当前载入文件的远端路径 / 归属连接源；空表示没有会话。
    /// 浏览页据此给「正在播放」的那一行加均衡器（同一文件在别处被替换时自动更新）
    Q_PROPERTY(QString currentPath READ currentPath NOTIFY currentMediaChanged)
    Q_PROPERTY(QString currentConnectionId READ currentConnectionId NOTIFY currentMediaChanged)
    Q_PROPERTY(qint64 positionMs READ positionMs NOTIFY positionChanged)
    Q_PROPERTY(qint64 durationMs READ durationMs NOTIFY durationChanged)
    Q_PROPERTY(bool buffering READ buffering NOTIFY bufferingChanged)
    Q_PROPERTY(bool hasVideo READ hasVideo NOTIFY mediaChanged)
    Q_PROPERTY(bool audioOnly READ audioOnly WRITE setAudioOnly NOTIFY audioOnlyChanged)
    Q_PROPERTY(bool muted READ muted WRITE setMuted NOTIFY mutedChanged)
    Q_PROPERTY(double volume READ volume WRITE setVolume NOTIFY volumeChanged)
    Q_PROPERTY(double speed READ speed WRITE setSpeed NOTIFY speedChanged)
    Q_PROPERTY(QString errorText READ errorText NOTIFY errorTextChanged)
    Q_PROPERTY(QVariantList audioTracks READ audioTracks NOTIFY audioTracksChanged)
    Q_PROPERTY(QVariantList subtitleTracks READ subtitleTracks NOTIFY subtitleTracksChanged)
    Q_PROPERTY(qreal brightness READ brightness WRITE setBrightness NOTIFY brightnessChanged)
    // 播放行为偏好（只读镜像，写入统一走 AppSettings.setValue，改动即时生效）
    Q_PROPERTY(double volumeStep READ volumeStep NOTIFY preferencesChanged)
    Q_PROPERTY(int seekStepSeconds READ seekStepSeconds NOTIFY preferencesChanged)
    Q_PROPERTY(int subtitleFontSize READ subtitleFontSize NOTIFY preferencesChanged)
    /// 字幕整体延迟（秒，正 = 字幕延后）；运行期可调，即时生效
    Q_PROPERTY(double subtitleDelay READ subtitleDelay NOTIFY preferencesChanged)

public:
    /// 与 core::PlaybackState 一一对应；QML 侧用 `Player.Playing` 这种写法
    enum State
    {
        Idle,
        Loading,
        Playing,
        Paused,
        Ended,
        Error,
    };
    Q_ENUM(State)

    static PlayerBridge *create(QQmlEngine *, QJSEngine *);

    /**
     * 退出应用前把播放进度落盘（PC-209）。
     *
     * 必须由 `main()` 在 `AppState::shutdown()` **之前**调用：shutdown 会关闭数据库，
     * 而 `aboutToQuit` 的处理顺序是按连接先后执行的，本类的连接晚于 shutdown，
     * 靠自己去抢顺序必然写不进去。没有播放过（单例未创建）时是空操作。
     */
    static void flushPendingProgress();

    /**
     * 构造函数刻意**不留默认参数**：
     * QML 判断单例走哪种构造方式时先看 `is_default_constructible`，只有不可默认构造
     * 才会调用 `create()`（见 QQmlPrivate::singletonConstructionMode）。
     * 留默认参数会让 `create()` 变成死代码，mpv 引擎就永远装不上。
     */
    explicit PlayerBridge(QObject *parent);

    State state() const;
    QString title() const;
    QString mediaArtist() const;
    QString mediaTitle() const;
    QString currentPath() const;
    QString currentConnectionId() const;
    qint64 positionMs() const;
    qint64 durationMs() const;
    bool buffering() const;
    bool hasVideo() const;
    bool audioOnly() const;
    bool muted() const;
    double volume() const;
    double speed() const;
    QString errorText() const;
    QVariantList audioTracks() const;
    QVariantList subtitleTracks() const;
    qreal brightness() const;
    double volumeStep() const;
    int seekStepSeconds() const;
    int subtitleFontSize() const;
    double subtitleDelay() const;

    void setAudioOnly(bool audioOnly);
    void setMuted(bool muted);
    void setVolume(double volume);
    void setSpeed(double speed);
    void setBrightness(qreal brightness);

    /**
     * 打开媒体。
     *
     * @param startMs `< 0` 表示按历史进度**精准续播**（查不到记录则从头）；
     *                `>= 0` 表示显式指定起点（0 即从头，供「从头播放」用）。
     * @param connectionId 归属连接源；空则记为本地（`local`），
     *                与进度记录的键一致，跨调用点不会分裂成两条记录。
     *
     * 续播位置在 loadfile 之前写进 mpv 的 `start` 选项，
     * 因此不会出现「先 0 后跳」（PC-209）。
     */
    Q_INVOKABLE void open(const QUrl &url, const QString &title, qint64 startMs = -1,
                          const QString &connectionId = QString());
    Q_INVOKABLE void openLocalFile(const QString &path, const QString &title, qint64 startMs = -1,
                                   const QString &connectionId = QString());
    /**
     * 打开远程条目（§4.2 边下边播）。
     *
     * 走 127.0.0.1 回环代流：浏览页/收藏/在读三处共用同一个入口，
     * 调用方只需给「连接源 + 路径」，`size` / `fingerprint` 是可选快路
     * （目录模型已有这两个角色，传进来可省一次 stat 往返）。
     *
     * 失败时发 `remoteOpenFailed`，由页面决定提示文案——不在门面里弹窗，
     * 门面不知道当前是哪个页面在起播。
     */
    Q_INVOKABLE void openRemote(const QString &connectionId, const QString &path,
                                const QString &title, qint64 size = 0,
                                const QString &fingerprint = QString(), qint64 startMs = -1);
    Q_INVOKABLE void close();
    Q_INVOKABLE void togglePause();
    Q_INVOKABLE void toggleMute();
    Q_INVOKABLE void adjustVolume(double delta);
    Q_INVOKABLE void seekTo(qint64 positionMs);
    Q_INVOKABLE void seekBy(qint64 deltaMs);
    Q_INVOKABLE void selectAudioTrack(int id);
    Q_INVOKABLE void selectSubtitleTrack(int id);
    Q_INVOKABLE void addSubtitle(const QUrl &url);
    /// 字幕字号 / 延迟：写设置并立刻下发给引擎（不用等下一集）
    Q_INVOKABLE void setSubtitleFontSize(int fontSize);
    Q_INVOKABLE void setSubtitleDelay(double seconds);
    Q_INVOKABLE void toggleAudioOnly();
    /// 截取当前帧（§4.3）：结果走 screenshotSaved / screenshotFailed，UI 无需等待
    Q_INVOKABLE void saveScreenshot();
    /**
     * 认领视频渲染面：创建全进程唯一的渲染面，挂进 `container`（PlayerVideoLayer）。
     *
     * **只认领一次**。全屏 ↔ mini 切换不重挂载、不销毁重建，只改宿主的几何，
     * 因此不会重新起播（§4.4）。重挂载会让场景图销毁重建 mpv 渲染节点，
     * 实测导致「切回全屏黑屏」与渲染线程死锁。
     *
     * 这样 QML 侧不直接声明 MpvVideoItem——该类型继承自 mpvqt 的第三方基类，
     * QML 类型系统无法解析其继承链，会拒绝把实例放进子元素列表。
     */
    Q_INVOKABLE void claimSurface(QQuickItem *container);

    /// 读取某条目的进度（§7 首页/后续「从头播放」菜单用）；无记录返回空 map
    Q_INVOKABLE QVariantMap progressFor(const QString &connectionId, const QString &path) const;

signals:
    void stateChanged();
    void titleChanged();
    /// 当前载入的媒体换了（新建会话 / 关闭会话）
    void currentMediaChanged();
    void positionChanged();
    void durationChanged();
    void bufferingChanged();
    void mediaChanged();
    void audioOnlyChanged();
    void mutedChanged();
    void volumeChanged();
    void speedChanged();
    void errorTextChanged();
    void audioTracksChanged();
    void subtitleTracksChanged();
    void brightnessChanged();
    void preferencesChanged();
    /// 远程起播失败（连接不可用 / 长度未知 / 代流服务起不来）
    void remoteOpenFailed(const QString &reason);
    /// 截图结果（§4.3）：failed 的 reason 已是可读文案
    void screenshotSaved(const QString &filePath);
    void screenshotFailed(const QString &reason);

private:
    /// 统一的起播实现：`path` 是进度记录用的远端路径（不是回环 URL）
    void beginRequest(const QUrl &url, const QString &path, const QString &title, qint64 startMs,
                      const QString &connectionId);
    void releaseStreamSession();
    /// 把字幕字号 / 延迟下发给引擎（运行期即时生效）
    void applySubtitleStyle();
    /**
     * 外挂字幕自动匹配（§4.3）：起播后在同目录里找「同名 / 同名.语言」字幕并挂上。
     * 已经有外挂轨（用户手动加过 / 换端口重开后已恢复）就直接返回，不重复叠加。
     */
    void autoAttachSubtitle();

    /// 当前远程会话 id；空表示本地/直链播放
    QString m_streamId;
    /// 自动挂载的外挂字幕会占用独立的代流会话，随主会话一起注销
    QStringList m_subtitleStreams;
    /// 回环监听换端口后只重试一次，避免坏文件无限重开
    bool m_remoteRetried = false;

    /// 唯一的视频渲染面（由 claimSurface 创建，随宿主容器一起销毁）
    MpvVideoItem *m_surface = nullptr;
    /// 渲染面唯一的宿主容器（PlayerVideoLayer 里的 PlayerSurface）
    QPointer<QQuickItem> m_host;
    QMetaObject::Connection m_hostWidthConn;
    QMetaObject::Connection m_hostHeightConn;
    QVariantList m_audioTracks;
    QVariantList m_subtitleTracks;
    qreal m_brightness = 1.0;
};

} // namespace myhub
