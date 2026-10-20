本目录字体由 XcodeGen 自动纳入 target 资源（平铺进 bundle 根目录），并在 `Info.plist` 的 `UIAppFonts` 中声明。

已内置（均为 Noto CJK 单语言子集，SIL OFL 1.1，来源 github.com/notofonts/noto-cjk）：

- `NotoSansSC-Regular.otf`（思源黑体简体，族名 `Noto Sans SC`，8.0MB）
  —— 内嵌 ASS 字幕的字体兜底，解决「部分动漫内嵌字幕显示为方框 □」（TODO 412；
  VLC 在 Apple 平台不自带字幕字体，经 `SubtitleFontRegistry` 下发给 libass）。
- `NotoSerifSC-Regular.otf`（思源宋体简体，PostScript 名 `NotoSerifSC-Regular`，11.1MB）
  —— 小说 / 文本阅读器正文衬线字体（`UIFont(name: "NotoSerifSC-Regular")`）。

替换或增减字体后需同步更新 `project.yml` 的 `UIAppFonts` 与 `MyHub/Info.plist`，并重新 `xcodegen generate`。
用户也可不依赖打包字体：运行时把字体放进「文件」App 的 MyHub → Fonts 目录即可（`SubtitleFontRegistry` 自动接管，优先级高于打包字体）。
