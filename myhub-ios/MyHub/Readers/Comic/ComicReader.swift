import Foundation

/// 漫画阅读模块（TODO §6 / IOS-207 / IOS-208）组成：
/// - `ArchiveDecoder`：zip/cbz/epub（RangeZipReader 按需解页）+ rar/cbr（UnrarKit）页数据源；
/// - `ComicDetector`：扩展名优先 + 图片占比 ≥90% 嗅探 + 手动覆盖；
/// - `ComicReaderViewModel`：状态机 / 页码进度直接恢复 / ±3 预加载 / 翻完推荐下一本；
/// - `ComicReaderView`：单页 / 双页（RTL/LTR 持久化）/ 条漫 + 双指缩放；
/// - `ComicReaderPresenter`：全局全屏路由 + 点击防抖；
/// - `ComicProgressStore`（Domain/Services）：页码锚点 + 文件指纹落库。
enum ComicReaderModule {}
