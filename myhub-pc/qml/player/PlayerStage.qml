pragma Singleton
import QtQuick
import MyHub

/*
  播放呈现位（§4.4）。

  整个进程只有**一个播放会话**，三个呈现位互斥：
    full     —— 覆盖全窗口的沉浸播放层（PlayerView）
    mini     —— 主窗口底部常驻播放条（MiniPlayerBar）
    floating —— 主窗口变身为置顶无边框小窗（FloatingPlayerOverlay）

  切换呈现位只改渲染层的几何（见 PlayerVideoLayer），不重建会话，
  因此进度不回到 0、也不会重新起播。

  规则集中在这里，避免各页面各判各的：
    · 新打开 / 重播（Loading）→ full，点文件就该看到完整播放
    · 用户在 full 里点「进入 mini」或按 Ctrl+M → mini
    · 点「悬浮小窗」/ Ctrl+P → floating（窗口形态由 WindowController 负责）
    · 会话结束（Idle）→ 三个呈现位一起收起，小窗也要还原回普通窗口
    · 浏览页多选态 → mini 条让位（与底部操作栏一致），会话继续播
*/
QtObject {
    id: stage

    /// "hidden" | "full" | "mini" | "floating"
    property string mode: "hidden"

    readonly property bool full: mode === "full"
    readonly property bool mini: mode === "mini"
    readonly property bool floating: mode === "floating"

    /// 浏览页多选态（由 BrowseDirectory 写入）
    property bool selectionActive: false

    /// mini 条的画面预览块（由 MiniPlayerBar 注册）。
    /// 渲染面不搬进 mini 条，只在几何上贴到这个矩形上（见 PlayerVideoLayer）
    property Item previewTarget: null

    /// mini 条是否可见：多选时让位；Idle 时不等 mode 归位也不闪一下
    readonly property bool miniVisible: mini && !selectionActive && Player.state !== Player.Idle

    function showFull() {
        if (Player.state !== Player.Idle) {
            if (floating)
                WindowController.exitFloating()
            mode = "full"
        }
    }

    function showMini() {
        if (Player.state !== Player.Idle) {
            if (floating)
                WindowController.exitFloating()
            mode = "mini"
        }
    }

    /// 进入置顶悬浮小窗（窗口形态与呈现位一起切）
    function showFloating() {
        if (Player.state === Player.Idle)
            return
        WindowController.enterFloating()
        mode = "floating"
    }

    /// 从小窗还原回完整播放（窗口恢复原尺寸 / 位置 / 最大化状态）
    function restoreFromFloating() {
        WindowController.exitFloating()
        if (mode === "floating")
            mode = "full"
    }

    /// Ctrl+M：在两种呈现位之间来回切
    function toggle() {
        if (mini || floating)
            showFull()
        else if (full)
            showMini()
    }

    function hide() {
        if (floating)
            WindowController.exitFloating()
        mode = "hidden"
    }

    // 会话生命周期 → 呈现位
    property Connections playerWatcher: Connections {
        target: Player
        function onStateChanged() {
            if (Player.state === Player.Idle) {
                stage.hide()
            } else if (Player.state === Player.Loading) {
                // 新打开或播完后重播同一文件：回到完整播放（§4.4）。
                // 小窗里重播不弹回大窗，否则会打断「边看边干别的」
                if (!stage.floating)
                    stage.mode = "full"
            }
        }
    }
}
