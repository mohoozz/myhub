import QtQuick
import MyHub

/*
  毛玻璃材质（§1.2）—— iOS「液体玻璃」的桌面等价，恒开无开关。

  M0 实现：QML 层的半透明 + 统一描边（降级形态，观感不塌陷）。
  M5 接入平台代码后升级：
    Windows: DwmSetWindowAttribute 的 Acrylic / Mica（Win11）
    macOS:   NSVisualEffectView Vibrancy（.mm）
  平台能力不可用时自动回退到当前实现。
*/
Rectangle {
    id: root

    /// 平台原生材质是否已生效（由 platform 层注入，M5 启用）
    property bool nativeMaterialActive: false
    property real tintOpacity: AppTheme.dark ? 0.72 : 0.78

    radius: AppTheme.radiusCapsule

    // 原生材质生效时自身只保留描边，背景交给平台层
    color: nativeMaterialActive
        ? "transparent"
        : Qt.rgba(AppTheme.colors.cardBg.r,
                  AppTheme.colors.cardBg.g,
                  AppTheme.colors.cardBg.b,
                  tintOpacity)

    // 统一描边色与 1pt 宽度（§2.10：底部播放条 / 工具栏 / 多选操作栏一致）
    border.width: AppTheme.borderWidth
    border.color: AppTheme.colors.cardBorder

    Behavior on color { ColorAnimation { duration: Motion.fast } }
}
