#include "MacMediaControls.h"

#include "core/utils/AppLogger.h"

#include <QByteArray>
#include <QString>

#import <AppKit/AppKit.h>
#import <MediaPlayer/MediaPlayer.h>

namespace myhub {
namespace {

/// QString → NSString（UTF-8 中转，不依赖 Qt 私有桥接）
NSString *toNSString(const QString &text)
{
    const QByteArray utf8 = text.toUtf8();
    return [NSString stringWithUTF8String:utf8.constData()];
}

} // namespace

struct MacMediaControls::Impl
{
    bool attached = false;
    QString lastCoverPath;
    /// 当前封面对象：nowPlayingInfo 每次整体替换，缓存住才不会每秒丢封面
    MPMediaItemArtwork *artwork = nil;
    /// (command, target) 配对，detach 时逐对摘掉
    NSMutableArray<NSArray *> *registrations = [NSMutableArray array];
};

MacMediaControls::MacMediaControls(QObject *parent)
    : QObject(parent)
    , m_impl(std::make_unique<Impl>())
{}

MacMediaControls::~MacMediaControls()
{
    detach();
}

void MacMediaControls::setCallbacks(MediaControlsCallbacks callbacks)
{
    m_callbacks = std::move(callbacks);
}

bool MacMediaControls::attach(QWindow *window)
{
    // macOS 的控制中心按进程收发，不需要窗口句柄
    Q_UNUSED(window)

    if (m_impl->attached) {
        return true;
    }

    MPRemoteCommandCenter *commands = [MPRemoteCommandCenter sharedCommandCenter];

    // 命令回调可能来自任意线程：一律 dispatch 回主线程，再动播放器
    [m_impl->registrations
        addObject:@[
            commands.playCommand,
            [commands.playCommand addTargetWithHandler:^MPRemoteCommandHandlerStatus(MPRemoteCommandEvent *) {
                const auto callback = this->m_callbacks.play;
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (callback) {
                        callback();
                    }
                });
                return MPRemoteCommandHandlerStatusSuccess;
            }]
        ]];

    [m_impl->registrations
        addObject:@[
            commands.pauseCommand,
            [commands.pauseCommand addTargetWithHandler:^MPRemoteCommandHandlerStatus(MPRemoteCommandEvent *) {
                const auto callback = this->m_callbacks.pause;
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (callback) {
                        callback();
                    }
                });
                return MPRemoteCommandHandlerStatusSuccess;
            }]
        ]];

    [m_impl->registrations
        addObject:@[
            commands.togglePlayPauseCommand,
            [commands.togglePlayPauseCommand
                addTargetWithHandler:^MPRemoteCommandHandlerStatus(MPRemoteCommandEvent *) {
                    const auto callback = this->m_callbacks.togglePlayPause;
                    dispatch_async(dispatch_get_main_queue(), ^{
                        if (callback) {
                            callback();
                        }
                    });
                    return MPRemoteCommandHandlerStatusSuccess;
                }]
        ]];

    [m_impl->registrations
        addObject:@[
            commands.stopCommand,
            [commands.stopCommand addTargetWithHandler:^MPRemoteCommandHandlerStatus(MPRemoteCommandEvent *) {
                const auto callback = this->m_callbacks.stop;
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (callback) {
                        callback();
                    }
                });
                return MPRemoteCommandHandlerStatusSuccess;
            }]
        ]];

    [m_impl->registrations
        addObject:@[
            commands.nextTrackCommand,
            [commands.nextTrackCommand
                addTargetWithHandler:^MPRemoteCommandHandlerStatus(MPRemoteCommandEvent *) {
                    const auto callback = this->m_callbacks.next;
                    dispatch_async(dispatch_get_main_queue(), ^{
                        if (callback) {
                            callback();
                        }
                    });
                    return MPRemoteCommandHandlerStatusSuccess;
                }]
        ]];

    [m_impl->registrations
        addObject:@[
            commands.previousTrackCommand,
            [commands.previousTrackCommand
                addTargetWithHandler:^MPRemoteCommandHandlerStatus(MPRemoteCommandEvent *) {
                    const auto callback = this->m_callbacks.previous;
                    dispatch_async(dispatch_get_main_queue(), ^{
                        if (callback) {
                            callback();
                        }
                    });
                    return MPRemoteCommandHandlerStatusSuccess;
                }]
        ]];

    // 快进/快退：控制中心给的是绝对位置，播放器自己按设置步长走
    [m_impl->registrations
        addObject:@[
            commands.skipForwardCommand,
            [commands.skipForwardCommand
                addTargetWithHandler:^MPRemoteCommandHandlerStatus(MPRemoteCommandEvent *) {
                    const auto callback = this->m_callbacks.fastForward;
                    dispatch_async(dispatch_get_main_queue(), ^{
                        if (callback) {
                            callback();
                        }
                    });
                    return MPRemoteCommandHandlerStatusSuccess;
                }]
        ]];

    [m_impl->registrations
        addObject:@[
            commands.skipBackwardCommand,
            [commands.skipBackwardCommand
                addTargetWithHandler:^MPRemoteCommandHandlerStatus(MPRemoteCommandEvent *) {
                    const auto callback = this->m_callbacks.rewind;
                    dispatch_async(dispatch_get_main_queue(), ^{
                        if (callback) {
                            callback();
                        }
                    });
                    return MPRemoteCommandHandlerStatusSuccess;
                }]
        ]];

    [m_impl->registrations
        addObject:@[
            commands.changePlaybackPositionCommand,
            [commands.changePlaybackPositionCommand
                addTargetWithHandler:^MPRemoteCommandHandlerStatus(MPRemoteCommandEvent *event) {
                    const auto *positionEvent = (MPChangePlaybackPositionCommandEvent *)event;
                    const auto milliseconds = (qint64)(positionEvent.positionTime * 1000.0);
                    const auto callback = this->m_callbacks.seekTo;
                    dispatch_async(dispatch_get_main_queue(), ^{
                        if (callback) {
                            callback(milliseconds);
                        }
                    });
                    return MPRemoteCommandHandlerStatusSuccess;
                }]
        ]];

    [m_impl->registrations
        addObject:@[
            commands.changePlaybackRateCommand,
            [commands.changePlaybackRateCommand
                addTargetWithHandler:^MPRemoteCommandHandlerStatus(MPRemoteCommandEvent *event) {
                    const auto *rateEvent = (MPChangePlaybackRateCommandEvent *)event;
                    const auto rate = rateEvent.playbackRate;
                    const auto callback = this->m_callbacks.setSpeed;
                    dispatch_async(dispatch_get_main_queue(), ^{
                        if (callback) {
                            callback(rate);
                        }
                    });
                    return MPRemoteCommandHandlerStatusSuccess;
                }]
        ]];

    m_impl->attached = true;
    MH_INFO(Player, QStringLiteral("MPNowPlayingInfoCenter 已就绪，系统媒体面板可用"));
    return true;
}

void MacMediaControls::apply(const MediaSnapshot &snapshot)
{
    if (!m_impl->attached) {
        return;
    }

    MPNowPlayingInfoCenter *center = [MPNowPlayingInfoCenter defaultCenter];
    MPRemoteCommandCenter *commands = [MPRemoteCommandCenter sharedCommandCenter];

    commands.playCommand.enabled = snapshot.active;
    commands.pauseCommand.enabled = snapshot.active;
    commands.togglePlayPauseCommand.enabled = snapshot.active;
    commands.stopCommand.enabled = snapshot.active;
    commands.nextTrackCommand.enabled = snapshot.active && snapshot.canNext;
    commands.previousTrackCommand.enabled = snapshot.active && snapshot.canPrevious;
    commands.changePlaybackPositionCommand.enabled = snapshot.active;
    commands.changePlaybackRateCommand.enabled = snapshot.active;
    commands.skipForwardCommand.enabled = snapshot.active;
    commands.skipBackwardCommand.enabled = snapshot.active;

    if (!snapshot.active) {
        center.nowPlayingInfo = nil;
        if (@available(macOS 10.12.2, *)) {
            center.playbackState = MPNowPlayingPlaybackStateStopped;
        }
        m_impl->lastCoverPath.clear();
        m_impl->artwork = nil;
        return;
    }

    NSMutableDictionary<NSString *, id> *info = [NSMutableDictionary dictionary];
    info[MPMediaItemPropertyTitle] = toNSString(snapshot.title);
    if (!snapshot.artist.isEmpty()) {
        info[MPMediaItemPropertyArtist] = toNSString(snapshot.artist);
    }
    info[MPMediaItemPropertyPlaybackDuration] = @(snapshot.durationMs / 1000.0);
    info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = @(snapshot.positionMs / 1000.0);
    info[MPNowPlayingInfoPropertyPlaybackRate] = @(snapshot.playing ? 1.0 : 0.0);
    info[MPNowPlayingInfoPropertyDefaultPlaybackRate] = @(snapshot.speed);
    info[MPNowPlayingInfoPropertyMediaType] =
        @(snapshot.video ? MPNowPlayingInfoMediaTypeVideo : MPNowPlayingInfoMediaTypeAudio);

    // 封面：只在文件变化时读盘（每秒读一次图片会把主线程拖死）
    const QString coverPath =
        snapshot.coverUrl.isLocalFile() ? snapshot.coverUrl.toLocalFile() : QString();
    if (coverPath != m_impl->lastCoverPath) {
        m_impl->lastCoverPath = coverPath;
        m_impl->artwork = nil;
        if (!coverPath.isEmpty()) {
            NSImage *image = [[NSImage alloc] initWithContentsOfFile:toNSString(coverPath)];
            if (image) {
                m_impl->artwork =
                    [[MPMediaItemArtwork alloc] initWithBoundsSize:image.size
                                                    requestHandler:^NSImage *(CGSize size) {
                                                        Q_UNUSED(size)
                                                        return image;
                                                    }];
            }
        }
    }
    if (m_impl->artwork) {
        info[MPMediaItemPropertyArtwork] = m_impl->artwork;
    }

    center.nowPlayingInfo = info;
    if (@available(macOS 10.12.2, *)) {
        center.playbackState = snapshot.playing ? MPNowPlayingPlaybackStatePlaying
                                                : MPNowPlayingPlaybackStatePaused;
    }
}

void MacMediaControls::detach()
{
    if (!m_impl || !m_impl->attached) {
        return;
    }

    for (NSArray *registration in m_impl->registrations) {
        [(MPRemoteCommand *)registration[0] removeTarget:registration[1]];
    }
    [m_impl->registrations removeAllObjects];

    MPNowPlayingInfoCenter *center = [MPNowPlayingInfoCenter defaultCenter];
    center.nowPlayingInfo = nil;
    if (@available(macOS 10.12.2, *)) {
        center.playbackState = MPNowPlayingPlaybackStateStopped;
    }

    m_impl->artwork = nil;
    m_impl->lastCoverPath.clear();
    m_impl->attached = false;
}

std::unique_ptr<MediaControls> createMediaControls()
{
    return std::make_unique<MacMediaControls>();
}

} // namespace myhub
