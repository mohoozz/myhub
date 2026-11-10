import QtQuick
import QtQuick.Controls.Basic as C
import QtQuick.Dialogs
import QtQuick.Shapes
import QtQuick.Window
import MyHub

/*
  全屏播放器（§14.6 / PC-201 / PC-701 / PC-703）。

  纪律：
    - 覆盖整个窗口的沉浸层，强制纯黑，不遮挡启动 Loading（z 低于 1000）
    - 控制层 3s 自动隐藏；鼠标移动 / 点击**立刻**显示（不得延迟），隐藏时鼠标指针一并隐藏
    - 中央播放键与加载圈互斥；播完显示重播；失败显示原因
    - 锁定后屏蔽交互，点击画面重现锁图标，点锁解锁
    - 键盘是移动端手势的等价物：←/→ 快进退（Shift 为精细 5s）、↑/↓ 音量、Shift+↑/↓ 亮度、
      M 静音、A 音轨、S 字幕、[ / ] 倍速、F 全屏、L 锁定

  实现要点：Player（PlayerBridge）是唯一状态源，QML 只做呈现与输入翻译。
*/
Item {
    id: view

    z: 500
    // 呈现位由 PlayerStage 统一决定（full ↔ mini 只搬渲染面，不重建会话）
    visible: PlayerStage.full
    focus: visible

    readonly property bool playing: Player.state === Player.Playing
    readonly property bool loading: Player.state === Player.Loading || Player.buffering
    readonly property bool ended: Player.state === Player.Ended
    readonly property bool failed: Player.state === Player.Error
    readonly property bool fullScreen: view.Window.window
                                      ? view.Window.window.visibility === Window.FullScreen
                                      : false

    property bool controlsVisible: true
    property bool locked: false
    property bool lockHintVisible: false

    // 长按 →（或按住鼠标右键）临时 2x，松开恢复原倍速（§8.5）
    property bool holdBoosting: false
    property real holdSpeedBackup: 1.0

    // 启动即接管键盘；退出时把键盘还给主外壳
    onVisibleChanged: {
        if (visible) {
            locked = false
            lockHintVisible = false
            revealControls()
            forceActiveFocus()
        } else {
            hideTimer.stop()
            locked = false
            endHoldBoost() // 播放器收起时不得残留 2x 倍速
        }
    }

    function revealControls() {
        controlsVisible = true
        if (playing && !locked)
            hideTimer.restart()
        else
            hideTimer.stop()
    }

    function scheduleHide() {
        if (playing && !locked)
            hideTimer.restart()
        else
            hideTimer.stop()
    }

    function flash(icon, text) {
        capsule.flash(icon, text)
    }

    function closePlayer() {
        if (fullScreen)
            WindowController.toggleFullScreen()
        speedMenu.dismiss()
        subtitleMenu.dismiss()
        audioMenu.dismiss()
        moreMenu.dismiss()
        Player.close()
    }

    function setLocked(value) {
        locked = value
        lockHintVisible = false
        controlsVisible = !value
        if (!value) {
            revealControls()
            forceActiveFocus()
        } else {
            hideTimer.stop()
        }
        flash(value ? "lock" : "unlock", value ? qsTr("界面已锁定") : qsTr("界面已解锁"))
    }

    function seekBy(deltaMs) {
        const maxMs = Player.durationMs > 0 ? Player.durationMs : Math.max(0, Player.positionMs + deltaMs)
        const target = Math.max(0, Math.min(maxMs, Player.positionMs + deltaMs))
        Player.seekBy(deltaMs)
        flash(deltaMs < 0 ? "rewind" : "forward", Format.duration(target))
    }

    function setVolume(delta) {
        Player.adjustVolume(delta)
        flash(Player.muted ? "volume-x" : "volume",
              qsTr("音量 %1%").arg(Math.round(Player.volume * 100)))
    }

    function setBrightness(delta) {
        Player.brightness = Player.brightness + delta
        flash("sun", qsTr("亮度 %1%").arg(Math.round(Player.brightness * 100)))
    }

    function formatSpeed(speed) {
        const text = (Math.round(speed * 100) / 100).toFixed(2).replace(/0+$/, "")
        return (text.endsWith(".") ? text + "0" : text) + "×"
    }

    // ---------------------------------------------------------------- 画面

    // 有视频时背景必须透明：渲染面在 PlayerVideoLayer（z 490），本层压在它上面
    Rectangle {
        anchors.fill: parent
        color: Player.hasVideo ? "transparent" : AppTheme.colors.immersiveBg
    }

    // 纯音频 / 无视频轨：显示封面态，mpv 仍在后台出声
    AudioCoverView {
        anchors.fill: parent
        visible: !Player.hasVideo
    }

    // 亮度蒙层：与小说 / 漫画共用 reader.brightness（PC-703）
    Rectangle {
        anchors.fill: parent
        color: "#000000"
        opacity: 1 - Player.brightness
        visible: opacity > 0.001
    }

    // 画面点击 / 双击 / 滚轮
    MouseArea {
        id: surfaceMouse
        anchors.fill: parent
        hoverEnabled: !view.locked
        enabled: !view.locked
        acceptedButtons: Qt.LeftButton | Qt.RightButton
        cursorShape: view.controlsVisible ? Qt.ArrowCursor : Qt.BlankCursor

        onPressed: function(mouse) {
            view.revealControls()
            // 按住右键 = 2x 倍速（§8.5），松开还原
            if (mouse.button === Qt.RightButton)
                view.beginHoldBoost()
        }
        onReleased: function(mouse) {
            if (mouse.button === Qt.RightButton)
                view.endHoldBoost()
        }
        onCanceled: view.endHoldBoost()
        onPositionChanged: view.revealControls()
        onClicked: function(mouse) {
            if (mouse.button !== Qt.LeftButton)
                return
            // 隐藏时第一次点击只负责「立刻唤出控制层」，避免误暂停
            if (!view.controlsVisible) {
                view.revealControls()
                return
            }
            Player.togglePause()
            view.revealControls()
        }
        onDoubleClicked: function(mouse) {
            if (mouse.button === Qt.LeftButton)
                WindowController.toggleFullScreen()
        }
        onWheel: function(wheel) {
            view.setVolume(wheel.angleDelta.y > 0 ? Player.volumeStep : -Player.volumeStep)
            view.revealControls()
        }
    }

    // ---------------------------------------------------------------- 上下渐隐底

    Rectangle {
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        height: 148
        opacity: view.controlsVisible && !view.locked ? 1 : 0
        gradient: Gradient {
            GradientStop { position: 0.0; color: Qt.rgba(0, 0, 0, 0.62) }
            GradientStop { position: 1.0; color: "transparent" }
        }
        Behavior on opacity { NumberAnimation { duration: Motion.normal } }
    }

    Rectangle {
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        height: 188
        opacity: view.controlsVisible && !view.locked ? 1 : 0
        gradient: Gradient {
            GradientStop { position: 0.0; color: "transparent" }
            GradientStop { position: 1.0; color: Qt.rgba(0, 0, 0, 0.72) }
        }
        Behavior on opacity { NumberAnimation { duration: Motion.normal } }
    }

    // ---------------------------------------------------------------- 顶部 / 底部控制层

    PlayerTopBar {
        id: topBar
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.topMargin: AppTheme.spacingXs
        opacity: view.controlsVisible && !view.locked ? 1 : 0
        enabled: opacity > 0
        Behavior on opacity { NumberAnimation { duration: Motion.normal } }

        onCloseRequested: view.closePlayer()
        onMinimizeRequested: PlayerStage.showMini()
        onFloatingRequested: PlayerStage.showFloating()
        onOsdRequested: function(icon, text) { view.flash(icon, text) }
        onMoreMenuRequested: function(anchor) { view.openMenu(moreMenu, anchor) }
    }

    PlayerControlBar {
        id: controlBar
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        anchors.bottomMargin: AppTheme.spacingSm
        fullScreen: view.fullScreen
        opacity: view.controlsVisible && !view.locked ? 1 : 0
        enabled: opacity > 0
        Behavior on opacity { NumberAnimation { duration: Motion.normal } }

        onOsdRequested: function(icon, text) { view.flash(icon, text) }
        onSpeedMenuRequested: function(anchor) { view.openMenu(speedMenu, anchor) }
        onSubtitleMenuRequested: function(anchor) { view.openMenu(subtitleMenu, anchor) }
        onAudioMenuRequested: function(anchor) { view.openMenu(audioMenu, anchor) }
        onLockRequested: view.setLocked(true)
        onFullScreenRequested: WindowController.toggleFullScreen()
    }

    // ---------------------------------------------------------------- 中央状态

    // 加载圈：与中央播放键互斥，绝不重叠
    Item {
        anchors.centerIn: parent
        width: 64
        height: 64
        visible: view.loading && !view.failed

        Shape {
            anchors.fill: parent
            preferredRendererType: Shape.CurveRenderer

            ShapePath {
                strokeColor: Qt.rgba(1, 1, 1, 0.85)
                strokeWidth: 3
                fillColor: "transparent"
                capStyle: ShapePath.RoundCap
                PathAngleArc {
                    centerX: 32
                    centerY: 32
                    radiusX: 28
                    radiusY: 28
                    startAngle: 0
                    sweepAngle: 280
                }
            }

            RotationAnimation on rotation {
                running: view.loading && !view.failed
                from: 0
                to: 360
                duration: 900
                loops: Animation.Infinite
            }
        }
    }

    // 暂停：中央播放键
    Item {
        anchors.centerIn: parent
        width: 96
        height: 96
        visible: Player.state === Player.Paused && !Player.buffering

        Rectangle {
            anchors.fill: parent
            radius: width / 2
            color: Qt.rgba(0, 0, 0, 0.42)
            border.width: AppTheme.borderWidth
            border.color: Qt.rgba(1, 1, 1, 0.20)
        }

        PlayerButton {
            anchors.centerIn: parent
            iconName: "play"
            filled: true
            iconSize: 38
            implicitWidth: 96
            implicitHeight: 96
            color: "#FFFFFF"
            onClicked: {
                Player.togglePause()
                view.revealControls()
            }
        }
    }

    // 播放完成：重播（PC-204，无倒计时、不自动播下一个）
    Column {
        anchors.centerIn: parent
        spacing: AppTheme.spacingMd
        visible: view.ended

        Item {
            anchors.horizontalCenter: parent.horizontalCenter
            width: 96
            height: 96

            PlayerButton {
                anchors.fill: parent
                implicitWidth: 96
                implicitHeight: 96
                iconName: "replay"
                iconSize: 40
                onClicked: {
                    Player.togglePause()
                    view.revealControls()
                }
            }
        }

        Text {
            anchors.horizontalCenter: parent.horizontalCenter
            text: qsTr("播放结束")
            font.family: AppTheme.fontFamily
            font.pixelSize: AppTheme.fontSizeHeading
            font.bold: true
            color: "#FFFFFF"
        }

        Text {
            anchors.horizontalCenter: parent.horizontalCenter
            text: qsTr("点击重播，或拖动进度条回看")
            font.family: AppTheme.fontFamily
            font.pixelSize: AppTheme.fontSizeSmall
            color: Qt.rgba(1, 1, 1, 0.55)
        }
    }

    // 失败：显示原因并允许退出（PC-208）
    Column {
        anchors.centerIn: parent
        spacing: AppTheme.spacingMd
        width: Math.min(view.width - AppTheme.spacingXl * 2, 460)
        visible: view.failed

        AppIcon {
            anchors.horizontalCenter: parent.horizontalCenter
            name: "alert"
            width: 40
            height: 40
            color: AppTheme.colors.danger
        }

        Text {
            width: parent.width
            text: Player.errorText !== "" ? Player.errorText : qsTr("播放失败")
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.Wrap
            font.family: AppTheme.fontFamily
            font.pixelSize: AppTheme.fontSizeBody
            color: "#FFFFFF"
        }

        PlayerButton {
            anchors.horizontalCenter: parent.horizontalCenter
            text: qsTr("返回")
            onClicked: view.closePlayer()
        }
    }

    // ---------------------------------------------------------------- 中央数值胶囊

    PlayerCapsule {
        id: capsule
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.verticalCenter: parent.verticalCenter
        anchors.verticalCenterOffset: 96
    }

    // ---------------------------------------------------------------- 锁定态

    MouseArea {
        anchors.fill: parent
        enabled: view.locked
        acceptedButtons: Qt.LeftButton
        hoverEnabled: true
        cursorShape: Qt.ArrowCursor
        onClicked: {
            view.lockHintVisible = true
            lockHintTimer.restart()
        }
    }

    Item {
        anchors.centerIn: parent
        width: 72
        height: 72
        visible: view.locked && view.lockHintVisible

        PlayerButton {
            anchors.fill: parent
            iconName: "lock"
            iconSize: 30
            onClicked: view.setLocked(false)
        }

        Timer {
            id: lockHintTimer
            interval: Motion.controlsHideDelay
            onTriggered: view.lockHintVisible = false
        }
    }

    // ---------------------------------------------------------------- 字幕拖入

    DropArea {
        anchors.fill: parent
        onDropped: function(drop) {
            if (!drop.hasUrls || drop.urls.length === 0)
                return
            const url = drop.urls[0]
            const path = String(url).toLowerCase()
            if (path.endsWith(".srt") || path.endsWith(".ass") || path.endsWith(".ssa")
                    || path.endsWith(".vtt") || path.endsWith(".sub")) {
                Player.addSubtitle(url)
                view.flash("subtitle", qsTr("字幕已载入"))
            } else {
                view.flash("alert", qsTr("不支持的字幕格式"))
            }
        }
    }

    // ---------------------------------------------------------------- 菜单

    Component { id: actionFactory; C.Action {} }
    Component { id: separatorFactory; C.MenuSeparator {} }

    PopupMenu { id: speedMenu; onClosed: view.scheduleHide() }
    PopupMenu { id: subtitleMenu; onClosed: view.scheduleHide() }
    PopupMenu { id: audioMenu; onClosed: view.scheduleHide() }
    PopupMenu { id: moreMenu; onClosed: view.scheduleHide() }

    FileDialog {
        id: subtitleDialog
        title: qsTr("选择字幕文件")
        nameFilters: [
            qsTr("字幕文件 (*.srt *.ass *.ssa *.vtt *.sub)"),
            qsTr("所有文件 (*)")
        ]
        onAccepted: {
            Player.addSubtitle(selectedFile)
            view.flash("subtitle", qsTr("字幕已载入"))
        }
    }

    function openMenu(menu, anchor) {
        if (!anchor)
            return
        hideTimer.stop()
        refreshMenu(menu)
        const pos = anchor.mapToItem(null, 0, anchor.height + AppTheme.spacingXs)
        menu.popupAt(pos.x, pos.y)
    }

    function refreshMenu(menu) {
        menu.clear()
        if (menu === speedMenu)
            fillSpeedMenu()
        else if (menu === subtitleMenu)
            fillSubtitleMenu()
        else if (menu === audioMenu)
            fillAudioMenu()
        else
            fillMoreMenu()
    }

    function appendAction(menu, label, handler) {
        const action = actionFactory.createObject(menu)
        if (!action)
            return
        action.text = label
        if (handler)
            action.triggered.connect(handler)
        menu.addAction(action)
    }

    function appendSeparator(menu) {
        const item = separatorFactory.createObject(menu)
        if (item)
            menu.addItem(item)
    }

    function fillSpeedMenu() {
        const options = [0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0]
        for (let i = 0; i < options.length; ++i) {
            const value = options[i]
            const checked = Math.abs(Player.speed - value) < 0.001
            appendAction(speedMenu, (checked ? "✓ " : "") + formatSpeed(value), function() {
                Player.speed = value
                view.flash("speed", qsTr("倍速 %1").arg(view.formatSpeed(value)))
            })
        }
    }

    function fillAudioMenu() {
        const tracks = Player.audioTracks
        for (let i = 0; i < tracks.length; ++i) {
            const track = tracks[i]
            appendAction(audioMenu, (track.selected ? "✓ " : "") + track.label, function() {
                Player.selectAudioTrack(track.id)
                view.flash("music", track.label)
            })
        }
    }

    function fillSubtitleMenu() {
        const tracks = Player.subtitleTracks
        if (tracks.length === 0) {
            appendAction(subtitleMenu, qsTr("暂无字幕（可拖入或选择字幕文件）"), null)
        } else {
            appendAction(subtitleMenu, qsTr("关闭字幕"), function() {
                Player.selectSubtitleTrack(-1)
                view.flash("subtitle", qsTr("字幕已关闭"))
            })
            appendSeparator(subtitleMenu)
            for (let i = 0; i < tracks.length; ++i) {
                const track = tracks[i]
                appendAction(subtitleMenu, (track.selected ? "✓ " : "") + track.label, function() {
                    Player.selectSubtitleTrack(track.id)
                    view.flash("subtitle", track.label)
                })
            }
        }
        appendSeparator(subtitleMenu)
        // 延迟调整：同名字幕对不齐多半是片源多了片头，±0.5s 微调比改字幕文件省事
        appendAction(subtitleMenu, qsTr("字幕延迟 %1s（点击归零）").arg(
                         Number(Player.subtitleDelay).toFixed(1)), function() {
            Player.setSubtitleDelay(0)
            view.flash("subtitle", qsTr("字幕延迟 0.0s"))
        })
        appendAction(subtitleMenu, qsTr("字幕提前 0.5s"), function() {
            Player.setSubtitleDelay(Player.subtitleDelay - 0.5)
            view.flash("subtitle", qsTr("字幕延迟 %1s").arg(
                           Number(Player.subtitleDelay).toFixed(1)))
        })
        appendAction(subtitleMenu, qsTr("字幕延后 0.5s"), function() {
            Player.setSubtitleDelay(Player.subtitleDelay + 0.5)
            view.flash("subtitle", qsTr("字幕延迟 %1s").arg(
                           Number(Player.subtitleDelay).toFixed(1)))
        })
        appendSeparator(subtitleMenu)
        appendAction(subtitleMenu, qsTr("打开字幕文件…"), function() {
            subtitleDialog.open()
        })
    }

    function fillMoreMenu() {
        const decode = AppSettings.value("player.decodePreference", "auto")
        const decodeOptions = [
            { key: "auto", label: qsTr("解码：自动（推荐）") },
            { key: "hardware", label: qsTr("解码：硬件优先") },
            { key: "software", label: qsTr("解码：软件") }
        ]
        for (let i = 0; i < decodeOptions.length; ++i) {
            const option = decodeOptions[i]
            appendAction(moreMenu, (decode === option.key ? "✓ " : "") + option.label, function() {
                AppSettings.setValue("player.decodePreference", option.key)
                view.flash("settings", option.label)
            })
        }
        appendSeparator(moreMenu)
        appendAction(moreMenu, qsTr("放大字幕"), function() {
            const size = Math.min(40, Player.subtitleFontSize + 2)
            // 走门面而非直接写设置：当前会话立刻生效，不用等下一集
            Player.setSubtitleFontSize(size)
            view.flash("subtitle", qsTr("字幕字号 %1").arg(size))
        })
        appendAction(moreMenu, qsTr("缩小字幕"), function() {
            const size = Math.max(12, Player.subtitleFontSize - 2)
            Player.setSubtitleFontSize(size)
            view.flash("subtitle", qsTr("字幕字号 %1").arg(size))
        })
        // 截取当前帧（§4.3）：纯音频没有画面，不摆一个点下去只会报错的菜单项
        if (Player.hasVideo) {
            appendSeparator(moreMenu)
            appendAction(moreMenu, qsTr("截取当前帧  Ctrl+S"), function() {
                Player.saveScreenshot()
            })
        }
        appendSeparator(moreMenu)
        appendAction(moreMenu, qsTr("重置亮度"), function() {
            Player.brightness = 1
            view.flash("sun", qsTr("亮度 100%"))
        })
    }

    // ---------------------------------------------------------------- 键盘

    Keys.onPressed: function(event) {
        // Ctrl+M：收进底部 mini 条（§4.4），会话继续、不重载
        if (event.modifiers & Qt.ControlModifier && event.key === Qt.Key_M) {
            PlayerStage.showMini()
            event.accepted = true
            return
        }
        // Ctrl+P：置顶悬浮小窗（§4.4），同样是窗口 / 呈现位切换，不碰会话
        if (event.modifiers & Qt.ControlModifier && event.key === Qt.Key_P) {
            PlayerStage.showFloating()
            event.accepted = true
            return
        }
        // Ctrl+S：截取当前帧（§4.3）。放在锁定判定之前——锁屏状态下截画面正是常见需求
        if (event.modifiers & Qt.ControlModifier && event.key === Qt.Key_S) {
            Player.saveScreenshot()
            event.accepted = true
            return
        }
        if (event.key === Qt.Key_L) {
            view.setLocked(!view.locked)
            event.accepted = true
            return
        }
        if (view.locked) {
            if (event.key === Qt.Key_Escape) {
                view.closePlayer()
                event.accepted = true
            }
            return
        }
        if (event.key === Qt.Key_Escape) {
            if (view.fullScreen)
                WindowController.toggleFullScreen()
            else
                view.closePlayer()
            event.accepted = true
            return
        }

        switch (event.key) {
        case Qt.Key_Space:
        case Qt.Key_K:
            Player.togglePause()
            view.revealControls()
            break
        case Qt.Key_Left:
            // Shift+←/→ 为精细 5s，与设置页的快进步长解耦
            view.seekBy(event.modifiers & Qt.ShiftModifier ? -5000 : -Player.seekStepSeconds * 1000)
            view.revealControls()
            break
        case Qt.Key_Right:
            // 轻按一次 = 快进一个步长；继续按住（自动重复）= 2x 倍速，松开还原
            if (event.isAutoRepeat)
                view.beginHoldBoost()
            else
                view.seekBy(event.modifiers & Qt.ShiftModifier ? 5000 : Player.seekStepSeconds * 1000)
            view.revealControls()
            break
        case Qt.Key_Up:
            if (event.modifiers & Qt.ShiftModifier)
                view.setBrightness(0.05)
            else
                view.setVolume(Player.volumeStep)
            view.revealControls()
            break
        case Qt.Key_Down:
            if (event.modifiers & Qt.ShiftModifier)
                view.setBrightness(-0.05)
            else
                view.setVolume(-Player.volumeStep)
            view.revealControls()
            break
        case Qt.Key_M:
            Player.toggleMute()
            view.flash(Player.muted ? "volume-x" : "volume",
                       Player.muted ? qsTr("静音") : qsTr("音量 %1%").arg(Math.round(Player.volume * 100)))
            view.revealControls()
            break
        case Qt.Key_F:
            WindowController.toggleFullScreen()
            break
        case Qt.Key_A:
            view.cycleAudioTrack()
            break
        case Qt.Key_S:
            view.cycleSubtitle()
            break
        case Qt.Key_BracketLeft:
            view.stepSpeed(-0.25)
            break
        case Qt.Key_BracketRight:
            view.stepSpeed(0.25)
            break
        default:
            return
        }
        event.accepted = true
    }

    // 松开 →（含被窗口抢走焦点时的 cancel）即还原倍速
    Keys.onReleased: function(event) {
        if (event.isAutoRepeat)
            return
        if (event.key === Qt.Key_Right && view.holdBoosting) {
            view.endHoldBoost()
            event.accepted = true
        }
    }

    function cycleAudioTrack() {
        const tracks = Player.audioTracks
        if (tracks.length < 2)
            return
        let index = 0
        for (let i = 0; i < tracks.length; ++i) {
            if (tracks[i].selected) {
                index = i
                break
            }
        }
        const next = tracks[(index + 1) % tracks.length]
        Player.selectAudioTrack(next.id)
        view.flash("music", next.label)
    }

    // S 键：关闭 → 第 1 条 → … → 最后一条 → 关闭
    function cycleSubtitle() {
        const tracks = Player.subtitleTracks
        if (tracks.length === 0) {
            view.flash("subtitle", qsTr("暂无字幕"))
            return
        }
        let index = -1
        for (let i = 0; i < tracks.length; ++i) {
            if (tracks[i].selected) {
                index = i
                break
            }
        }
        if (index + 1 < tracks.length) {
            const next = tracks[index + 1]
            Player.selectSubtitleTrack(next.id)
            view.flash("subtitle", next.label)
        } else {
            Player.selectSubtitleTrack(-1)
            view.flash("subtitle", qsTr("字幕已关闭"))
        }
    }

    // 长按 → / 按住右键：临时 2x 倍速，松开还原（不改用户设置里的默认倍速）
    function beginHoldBoost() {
        if (view.holdBoosting || Player.speed >= 2.0)
            return
        view.holdSpeedBackup = Player.speed
        view.holdBoosting = true
        Player.speed = 2.0
        view.flash("speed", qsTr("倍速 %1").arg(view.formatSpeed(2.0)))
    }

    function endHoldBoost() {
        if (!view.holdBoosting)
            return
        view.holdBoosting = false
        Player.speed = view.holdSpeedBackup
        view.flash("speed", qsTr("倍速 %1").arg(view.formatSpeed(view.holdSpeedBackup)))
    }

    // [ / ] 键：±0.25 倍速，钳制在 0.5~3.0
    function stepSpeed(delta) {
        const next = Math.max(0.5, Math.min(3.0, Math.round((Player.speed + delta) * 100) / 100))
        Player.speed = next
        view.flash("speed", qsTr("倍速 %1").arg(view.formatSpeed(next)))
    }

    Timer {
        id: hideTimer
        interval: Motion.controlsHideDelay
        onTriggered: {
            if (view.playing && !view.locked)
                view.controlsVisible = false
        }
    }

    Connections {
        target: Player
        function onStateChanged() {
            view.revealControls()
        }
        function onErrorTextChanged() {
            view.revealControls()
        }
        // 截图结果（§4.3）：成功只说「已保存」，失败必须把原因摆出来，
        // 否则用户点完不知道是没截成还是截到别处去了
        function onScreenshotSaved(filePath) {
            view.flash("image", qsTr("截图已保存"))
        }
        function onScreenshotFailed(reason) {
            view.flash("image", reason)
        }
    }
}
