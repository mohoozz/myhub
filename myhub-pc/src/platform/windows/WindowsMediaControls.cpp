#include "WindowsMediaControls.h"

#include "core/utils/AppLogger.h"

#include <QMetaObject>
#include <QWindow>

#include <windows.h>

#include <roapi.h>
#include <SystemMediaTransportControlsInterop.h>

#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.Media.h>
#include <winrt/Windows.Storage.Streams.h>

#include <chrono>
#include <utility>

namespace myhub {
namespace {

using winrt::Windows::Foundation::TimeSpan;
using winrt::Windows::Media::MediaPlaybackStatus;
using winrt::Windows::Media::MediaPlaybackType;
using winrt::Windows::Media::SystemMediaTransportControls;
using winrt::Windows::Media::SystemMediaTransportControlsButton;
using winrt::Windows::Media::SystemMediaTransportControlsButtonPressedEventArgs;
using winrt::Windows::Media::SystemMediaTransportControlsTimelineProperties;
using winrt::Windows::Storage::Streams::RandomAccessStreamReference;

/// QString → HSTRING（WinRT 一律按 UTF-16 传，不做本地编码转换）
winrt::hstring toHString(const QString &text)
{
    return winrt::hstring{reinterpret_cast<const wchar_t *>(text.utf16()),
                          static_cast<uint32_t>(text.size())};
}

TimeSpan toTimeSpan(qint64 ms)
{
    return TimeSpan{std::chrono::milliseconds{qMax<qint64>(0, ms)}};
}

qint64 fromTimeSpan(TimeSpan span)
{
    return std::chrono::duration_cast<std::chrono::milliseconds>(span).count();
}

} // namespace

struct WindowsMediaControls::Impl
{
    SystemMediaTransportControls smtc{nullptr};
    winrt::event_token buttonToken{};
    winrt::event_token positionToken{};
    winrt::event_token rateToken{};
    HWND hwnd = nullptr;
    bool enabled = false;

    /// 元数据缓存：DisplayUpdater::Update() 会走系统调用，标题没变就不重设
    QString lastTitle;
    QString lastArtist;
    QUrl lastCover;
    bool lastVideo = false;

    /// WinRT 调用失败只记一次，避免每秒刷屏
    bool reportedFailure = false;
};

WindowsMediaControls::WindowsMediaControls(QObject *parent)
    : QObject(parent)
    , m_impl(std::make_unique<Impl>())
{}

WindowsMediaControls::~WindowsMediaControls()
{
    detach();
}

void WindowsMediaControls::setCallbacks(MediaControlsCallbacks callbacks)
{
    m_callbacks = std::move(callbacks);
}

bool WindowsMediaControls::attach(QWindow *window)
{
    if (m_impl->smtc) {
        return true;
    }
    if (!window) {
        return false;
    }

    // QWindow::winId() 在 Windows 上就是 HWND（与 WindowsIntegration 同一约定）
    const HWND hwnd = reinterpret_cast<HWND>(window->winId()); // NOLINT(performance-no-int-to-ptr)
    if (!hwnd) {
        return false;
    }

    // Qt 已通过 OleInitialize 把 GUI 线程设为 STA。这里再初始化一次只是兜底：
    // 同模式返回 S_FALSE，模式不同（RPC_E_CHANGED_MODE）也不影响 SMTC 的同步调用，
    // 因此失败不阻断绑定。
    try {
        winrt::init_apartment(winrt::apartment_type::single_threaded);
    } catch (const winrt::hresult_error &error) {
        // 失败只说明线程模型与请求的不一致（Qt 已初始化过 COM），
        // 不清理也不中断：SMTC 的同步调用不依赖这次初始化是否成功。
        Q_UNUSED(error)
    }

    try {
        winrt::com_ptr<ISystemMediaTransportControlsInterop> interop;
        const winrt::hstring className{L"Windows.Media.SystemMediaTransportControls"};
        winrt::check_hresult(RoGetActivationFactory(
            reinterpret_cast<HSTRING>(winrt::get_abi(className)),
            __uuidof(ISystemMediaTransportControlsInterop), interop.put_void()));

        // GetForWindow 输出的是 default interface（ISystemMediaTransportControls）指针。
        // 该接口的 IID 取自 cppwinrt 的 guid_v 特化（SDK 的 ABI 头不带 windows.media.h）
        const winrt::guid iid =
            winrt::guid_of<winrt::Windows::Media::ISystemMediaTransportControls>();
        void *raw = nullptr;
        winrt::check_hresult(interop->GetForWindow(hwnd, iid, &raw));
        m_impl->smtc = SystemMediaTransportControls{raw, winrt::take_ownership_from_abi};
    } catch (const winrt::hresult_error &error) {
        MH_WARN(Player,
                QStringLiteral("SMTC 绑定窗口失败：%1")
                    .arg(QString::fromWCharArray(error.message().c_str())));
        m_impl->smtc = nullptr;
        return false;
    }

    m_impl->hwnd = hwnd;

    // 事件回调由系统在后台线程触发，统一排队回 GUI 线程再动播放器
    m_impl->buttonToken = m_impl->smtc.ButtonPressed(
        [this](const SystemMediaTransportControls &,
               const SystemMediaTransportControlsButtonPressedEventArgs &args) {
            const int button = static_cast<int>(args.Button());
            QMetaObject::invokeMethod(
                this, [this, button]() { handleButton(button); }, Qt::QueuedConnection);
        });

    m_impl->positionToken = m_impl->smtc.PlaybackPositionChangeRequested(
        [this](const SystemMediaTransportControls &,
               const winrt::Windows::Media::PlaybackPositionChangeRequestedEventArgs &args) {
            const qint64 position = fromTimeSpan(args.RequestedPlaybackPosition());
            QMetaObject::invokeMethod(
                this, [this, position]() { handlePositionRequest(position); },
                Qt::QueuedConnection);
        });

    m_impl->rateToken = m_impl->smtc.PlaybackRateChangeRequested(
        [this](const SystemMediaTransportControls &,
               const winrt::Windows::Media::PlaybackRateChangeRequestedEventArgs &args) {
            const double rate = args.RequestedPlaybackRate();
            QMetaObject::invokeMethod(
                this, [this, rate]() { handleRateRequest(rate); }, Qt::QueuedConnection);
        });

    MH_INFO(Player, QStringLiteral("SMTC 已绑定窗口，系统媒体面板可用"));
    return true;
}

void WindowsMediaControls::apply(const MediaSnapshot &snapshot)
{
    if (!m_impl->smtc) {
        return;
    }

    // 系统媒体面板是增强项：任何一次 WinRT 激活/调用失败都不能冒泡到 Qt 事件循环，
    // 否则一次元数据设置失败就会把整个播放器带走（§14.16）
    try {
        applySnapshot(snapshot);
    } catch (const winrt::hresult_error &error) {
        if (!m_impl->reportedFailure) {
            m_impl->reportedFailure = true;
            MH_WARN(Player,
                    QStringLiteral("SMTC 更新失败：%1")
                        .arg(QString::fromWCharArray(error.message().c_str())));
        }
    }
}

void WindowsMediaControls::applySnapshot(const MediaSnapshot &snapshot)
{
    if (!m_impl->smtc) {
        return;
    }

    if (!snapshot.active) {
        // 会话结束：收起面板，别留一条点不动的「幽灵」媒体
        if (m_impl->enabled) {
            m_impl->smtc.IsEnabled(false);
            m_impl->smtc.DisplayUpdater().ClearAll();
            m_impl->enabled = false;
            m_impl->lastTitle.clear();
            m_impl->lastArtist.clear();
            m_impl->lastCover.clear();
            m_impl->lastVideo = false;
        }
        return;
    }

    if (!m_impl->enabled) {
        m_impl->smtc.IsEnabled(true);
        m_impl->enabled = true;
    }

    m_impl->smtc.IsPlayEnabled(true);
    m_impl->smtc.IsPauseEnabled(true);
    m_impl->smtc.IsStopEnabled(true);
    m_impl->smtc.IsFastForwardEnabled(true);
    m_impl->smtc.IsRewindEnabled(true);
    // §4.6「连续播放推荐」尚未落地，没有上/下一个目标就先禁用，避免点了没反应
    m_impl->smtc.IsNextEnabled(snapshot.canNext);
    m_impl->smtc.IsPreviousEnabled(snapshot.canPrevious);

    // 加载中 / 已播完都按暂停展示，播放态只由 mpv 的事实决定
    m_impl->smtc.PlaybackStatus(snapshot.playing ? MediaPlaybackStatus::Playing
                                                 : MediaPlaybackStatus::Paused);

    if (m_impl->lastTitle != snapshot.title || m_impl->lastArtist != snapshot.artist
        || m_impl->lastCover != snapshot.coverUrl || m_impl->lastVideo != snapshot.video) {
        auto updater = m_impl->smtc.DisplayUpdater();
        updater.Type(snapshot.video ? MediaPlaybackType::Video : MediaPlaybackType::Music);
        if (snapshot.video) {
            auto properties = updater.VideoProperties();
            properties.Title(toHString(snapshot.title));
            properties.Subtitle(toHString(snapshot.artist));
        } else {
            auto properties = updater.MusicProperties();
            properties.Title(toHString(snapshot.title));
            properties.Artist(toHString(snapshot.artist));
        }

        if (snapshot.coverUrl.isValid() && !snapshot.coverUrl.isEmpty()) {
            // CreateFromUri 是懒加载，不需要异步拿 StorageFile
            updater.Thumbnail(RandomAccessStreamReference::CreateFromUri(
                winrt::Windows::Foundation::Uri{toHString(snapshot.coverUrl.toString())}));
        } else {
            updater.Thumbnail(nullptr);
        }
        updater.Update();

        m_impl->lastTitle = snapshot.title;
        m_impl->lastArtist = snapshot.artist;
        m_impl->lastCover = snapshot.coverUrl;
        m_impl->lastVideo = snapshot.video;
    }

    SystemMediaTransportControlsTimelineProperties timeline;
    timeline.StartTime(toTimeSpan(0));
    timeline.MinSeekTime(toTimeSpan(0));
    timeline.EndTime(toTimeSpan(snapshot.durationMs));
    timeline.MaxSeekTime(toTimeSpan(snapshot.durationMs));
    timeline.Position(toTimeSpan(snapshot.positionMs));
    m_impl->smtc.UpdateTimelineProperties(timeline);
}

void WindowsMediaControls::detach()
{
    if (!m_impl || !m_impl->smtc) {
        return;
    }

    // 先摘事件再关会话：排队中的回调可能还在路上，handleXxx 里对空 smtc 是安全的
    m_impl->smtc.ButtonPressed(m_impl->buttonToken);
    m_impl->smtc.PlaybackPositionChangeRequested(m_impl->positionToken);
    m_impl->smtc.PlaybackRateChangeRequested(m_impl->rateToken);
    m_impl->smtc.IsEnabled(false);
    m_impl->smtc.DisplayUpdater().ClearAll();
    m_impl->smtc = nullptr;
    m_impl->enabled = false;
    m_impl->hwnd = nullptr;
}

void WindowsMediaControls::handleButton(int button)
{
    const auto value = static_cast<SystemMediaTransportControlsButton>(button);
    switch (value) {
    case SystemMediaTransportControlsButton::Play:
    case SystemMediaTransportControlsButton::Pause:
        // 媒体键是「翻转」语义：系统按当前 PlaybackStatus 决定发 Play 还是 Pause
        if (m_callbacks.togglePlayPause) {
            m_callbacks.togglePlayPause();
        }
        break;
    case SystemMediaTransportControlsButton::Stop:
        if (m_callbacks.stop) {
            m_callbacks.stop();
        }
        break;
    case SystemMediaTransportControlsButton::Next:
        if (m_callbacks.next) {
            m_callbacks.next();
        }
        break;
    case SystemMediaTransportControlsButton::Previous:
        if (m_callbacks.previous) {
            m_callbacks.previous();
        }
        break;
    case SystemMediaTransportControlsButton::FastForward:
        if (m_callbacks.fastForward) {
            m_callbacks.fastForward();
        }
        break;
    case SystemMediaTransportControlsButton::Rewind:
        if (m_callbacks.rewind) {
            m_callbacks.rewind();
        }
        break;
    default:
        break;
    }
}

void WindowsMediaControls::handlePositionRequest(qint64 positionMs)
{
    if (m_callbacks.seekTo) {
        m_callbacks.seekTo(positionMs);
    }
}

void WindowsMediaControls::handleRateRequest(double rate)
{
    if (m_callbacks.setSpeed) {
        m_callbacks.setSpeed(rate);
    }
}

std::unique_ptr<MediaControls> createMediaControls()
{
    return std::make_unique<WindowsMediaControls>();
}

} // namespace myhub
