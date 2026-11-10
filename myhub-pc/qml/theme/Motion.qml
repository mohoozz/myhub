pragma Singleton
import QtQuick

/*
  动效令牌 —— 《需求分析文档》§2.10：轻量过渡，一律 ≤ 200ms
*/
QtObject {
    // ---- 时长 ----
    readonly property int fast:   120
    readonly property int normal: 180
    readonly property int slow:   200

    // 搜索框显隐、菜单弹出等
    readonly property int reveal: 160

    // 呼吸灯高亮持续时间（定位到原路径，约 10s 后淡出）
    readonly property int breathingDuration: 10000

    // 中央数值反馈胶囊自动隐去
    readonly property int capsuleHideDelay: 800

    // 控制层自动隐藏（播放中 3s）
    readonly property int controlsHideDelay: 3000

    // ---- 缓动 ----
    readonly property int easeOut:   Easing.OutCubic
    readonly property int easeInOut: Easing.InOutQuad
    readonly property int easeOutBack: Easing.OutBack
}
