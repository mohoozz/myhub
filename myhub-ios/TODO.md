# myhub-ios 原生应用 TODO

> 依据《myhub-ios/需求分析文档.md》v1.1 拆解，按模块组织，勾选即完成。
> **架构**：纯本地化 iOS 原生应用（无服务器端），Swift + SwiftUI（+ UIKit 桥接）。
> **数据**：全部本地——Core Data / GRDB(SQLite) + UserDefaults + Keychain + 沙盒缓存。
> **网络存储**：客户端原生直连 WebDAV / SMB（可扩展 FTP/SFTP/NFS）。
> **播放内核**：参考 nPlayer——AVPlayer 硬解 + VLC/FFmpeg 软解双引擎 + 边下边播分片缓存。
> 里程碑：M0 骨架+浏览 → M1 文件管理 → M2 播放器 → M3 阅读器 → M4 浏览器 → M5 v1.0 打磨 → M6 v1.1
>
> ⚠️ 已将 Flutter 版「体验优化、bug 修复」经验（原 IOS-701~706）逐条并入下方各功能模块对应条目（标 **加粗** 者为重点验收项），务必对照落地。

---

## 0. 工程脚手架与基础设施

- [x] Xcode 工程 / Swift Package 初始化（Bundle ID `com.myhub.MyHub`、v1.0.0、最低 iOS 16；采用 XcodeGen，`project.yml` 生成 `MyHub.xcodeproj`）
- [x] 目录结构搭建（`App/`、`Core/`、`Player/`、`Readers/`、`Features/`、`Domain/`、`Resources/`）
- [x] 依赖引入（SPM）：AMSMB2、MobileVLCKit（VLCKit 4.x）、ZIPFoundation、UnrarKit、GRDB、Nuke
- [x] `Info.plist` 配置：`NSAppTransportSecurity`（局域网 HTTP + Web 内容）、`NSLocalNetworkUsageDescription`（SMB）、`UIBackgroundModes: audio`、`NSFaceIDUsageDescription`
- [x] 能力开启：后台音频（`UIBackgroundModes: audio`）、后台传输（background `URLSession`，无需额外 entitlement）、Keychain Sharing（entitlements 已配置）
- [x] 应用图标与启动屏（品牌图标 `AppIcon` + `UILaunchScreen`：`BrandLogo` + 亮/暗 `LaunchBackground`）
- [x] `README.md`：环境要求、构建说明、目录结构

---

## 1. 通用框架（IOS-001）

### 1.1 导航与主题

- [x] `RootView`：自适应导航壳（iPhone `TabView` / iPad `NavigationSplitView`）
  - Tab：阅读 / 动态 / 浏览 / 浏览器 / 设置（iPad 侧栏增加 收藏）
- [x] 页面保活：Tab 切换不销毁（iPhone `TabView` 系统保活 / iPad detail ZStack 常驻）；播放器独立全屏路由（`fullScreenCover` + `PlayerPresenter`）；mini 播放器（`MiniPlayer` 顶层悬浮）/ 浏览器标签（`BrowserSessionStore`）全局持有
- [x] `AppTheme` + `Colors`：亮/暗双主题（蓝白 / 纯黑），沉浸场景强制纯黑（`.immersive()`）
- [x] 主题模式（亮/暗/跟随系统）持久化到 `UserDefaults`（`ThemeManager`）
- [x] 选中项浅蓝胶囊高亮（iPad 侧栏 `Capsule`）、按压缩放 0.97（`.pressScale`）、轻量过渡（≤200ms，`Animation.appQuick/appFast`）
- [x] **首启/网络判定期显示 loading 动画（`AppState` + `LaunchLoadingView`，无长白屏）**
- [x] **点击头像/入口直达个人主页（`ProfileEntryButton` → `ProfileView`）**
- [x] **… 菜单 / 长按菜单 / 右键菜单：圆角 + 精致弹出动画（统一 `PopupMenuPresenter` + 圆角卡片层；入口：`PopupMenuButton` / `.popupContextMenu`，iPad·Mac 右键经窗口级 `.secondary` 手势桥接）**

### 1.2 本地存储与凭据（IOS-002）

- [x] `AppDatabase`（GRDB）：`DatabaseMigrator` 建表 + 迁移（唯一约束 / 外键级联 / 常用索引）
  - Connection / Favorite / ReadingProgress / NovelIndex / Bookmark / BrowserHistory / BrowserShortcut / DownloadTask / FeedItem（预留）（`Core/Database/Records/`）
- [x] `CredentialStore`（Keychain）：WebDAV/SMB 账号密码安全存取（`conn.<id>` key 约定 + 便捷方法；生物识别保护预留 SecAccessControl）
- [x] `UserDefaults` 封装：主题/阅读器/播放器/浏览器偏好（`AppSettings` + `@UserDefault` 属性包装，含音量步进 5%、回收站 30 天等默认值）
- [x] 缓存目录管理（沙盒 Caches 分区：`CacheManager` 分区目录 + 占用统计 + 清理）
- [x] 配置导入/导出（`ConfigTransfer`：连接源 + 偏好 JSON 快照，不含明文密码；按挂载点 upsert）

---

## 2. 存储适配器层（IOS-101）

- [x] `StorageAdapter` 协议：list / stat / readStream(range) / writeStream / move / copy / delete / mkdir（+ `testConnection`、`StorageError`、`StoragePath` 虚拟路径归一化）
- [x] `LocalAdapter`：沙盒 Documents + 文件 App 共享目录（Security-Scoped Bookmark，`fileImporter` 选择）
- [x] `WebDAVAdapter`：`URLSession` + PROPFIND/GET，**支持 HTTP Range** 串流；HTTPS + Basic 认证；PROPFIND 连接测试
- [x] `SMBAdapter`：AMSMB2（SMB2/3），账号/访客/域，**原生分块 `AsyncThrowingStream` 读取**；echo 连接测试
- [x] 适配器工厂：按 `Connection.type` 实例化（Keychain 自动取凭据，`passwordOverride` 支持表单未保存测试）
- [x] （预留）FTP / SFTP / NFS 适配器接口：`ConnectionType` 已留 case，工厂抛 `unsupportedProtocol`，协议即扩展点
- [x] 连接源管理 UI：`ConnectionListView`（类型图标/挂载点/开关）+ `ConnectionFormView`（分类型表单）+ 删除确认（已挂入设置页）
  - [x] **连接测试状态：正常绿点 / 异常红点**（列表行出现即自动测试，测试中转圈）
  - [x] **测试成功提示区分内网 / 外网可达**（`NetworkHeuristics` 私有 IP / .local / 无点主机名判定）

---

## 3. 文件浏览与管理

### 3.1 文件浏览（IOS-102）

- [x] 浏览页：连接源选择器 + 面包屑 + 搜索 + 视图切换 + 上传（`BrowseHomeView` 连接源卡片 + `BrowseDirectoryView` 面包屑/`.searchable`/工具栏切换/`.fileImporter` 上传带进度横幅）
- [x] 网格视图：封面/图标、文件名、文件夹子项数、视频时长角标、漫画徽标（`FileGridCell` + `DurationBadge`/`ComicBadge` + 子项数懒加载限并发）
- [x] **列表视图**（新增，与网格切换）（`FileListRow`，工具栏一键切换）
- [x] 排序（名称/大小/时间，升降序），**排序与路径显示偏好缓存**（`AppSettings.Browse`：sortKey/sortAscending/viewMode/lastPaths，进入连接源恢复上次路径）
- [x] 下拉刷新 + 空/加载/错误状态（`.refreshable` + loading/empty/failed 三态 + 搜索无结果态）
- [x] 目录结果本地缓存，二次进入加速（`DirectoryCache`：Caches/DirectoryListings，stale-while-revalidate 先出缓存再后台刷新）
- [x] **封面缩略图**：音视频/漫画/图片封面显示（`CoverService` + 通用组件 `RemoteCoverImage`，正在阅读页 M3 复用同一组件保证一致）
  - [x] 视频抽帧首帧本地生成缩略图并缓存（本地直读 / 远程前缀 8MB 临时文件抽帧，AVAssetImageGenerator，顺带探测时长；内存 + 磁盘双缓存 Caches/Thumbnails）
  - [x] **封面异步加载 + 失败占位 + 缓存；封面加载不阻塞点击进入播放/阅读**（cell `.task` 后台加载、占位图标先行、点击与封面解耦；in-flight 去重 + 全局并发限 4）
- [x] **选中/交互效果**：iPad/PC hover 高亮；iOS 点击/长按选中态高亮（`SelectableCellStyle` 按压浅蓝 + `onHover`/`hoverEffect`）
- [x] **iOS 左侧边缘滑动返回上一级目录**（NavigationStack 系统交互式 pop：当前目录右滑露出上一级，与系统手势天然无冲突）
- [x] **「定位到原路径」高亮改呼吸灯，仅提示约 10s**（`BrowseLocator` 全局触发 + `.breathingHighlight`，10s 后自动淡出）

### 3.2 文件操作（IOS-103 ~ 105）

- [x] 上传：`UIDocumentPicker`/相册选择 → 进度显示 → 多文件队列（工具栏 ＋ 菜单：`.fileImporter` 文件 / `.photosPicker` 相册 `PhotoImport` Transferable；顺序队列 + 字节级进度横幅）
- [x] 新建文件夹 / 重命名 / 移动 / 复制（同源走适配器；跨源 `streamingCopy` 设备端流式中转、目录递归、边读边写不落大临时文件；`DestinationPickerView` 选目标，含新建文件夹）
- [x] **长按进入多选模式**（非仅弹菜单）；多选操作栏：移动/复制/重命名/下载/收藏/删除（`selection` 状态机，右键经 `.popupSecondaryMenu` 保留完整操作菜单）
  - [x] **操作栏含删除，且按钮不超出手机屏幕**（6 按钮等分 `maxWidth: .infinity` 布局）
- [x] **下载文件到本地/「文件」App/相册**（下载至沙盒 `Documents/Downloads`；`ActivityView` 分享表存储到「文件」；图片/视频经 `PHPhotoLibrary` 保存相册）
- [x] **txt 在线编辑并保存回源**（`TextFileEditorView`：编码检测加载 → 编辑 → 原编码优先保存回源）
- [x] **不支持预览的文件**：底部菜单 → 「纯文本」查看（`TextFileViewer` 独立界面 + `TextEncodingDetector` 编码检测 UTF-8/GBK/Big5/UTF-16 LE/BE，区分小说阅读器）
- [x] **纯图片预览界面**（独立于漫画阅读器，`ImagePreviewView`）：左右滑动（page TabView）/ 分区点击（`SpatialTapGesture` 不拦拖拽）/ 键盘 ← →（UIKeyCommand 桥接）/ 浮动按钮切换上下张

### 3.3 回收站与收藏（IOS-106 / 107）

- [x] 删除入回收站（记录原路径），远端 `.trash`（`TrashService`：`<name>.meta.json` 记录原路径/删除时间；不支持时降级真删确认——见 §3.2 双确认弹窗）
- [x] 回收站页：列表、滑动还原/彻底删除、清空、自动清理（默认 30 天）（`TrashConnectionListView` + `TrashView`，设置页「存储」入口；还原冲突自动追加序号；过期项进入页面即静默清理）
- [x] 收藏：星标/取消，收藏页（网格/列表切换），点击进入播放器/阅读器（`FavoritesView`：封面复用 `RemoteCoverImage` 与浏览页一致；视频/音频→播放器、图片→预览、文件夹/其他→`AppRouter`+`BrowseLocator` 跳浏览页呼吸灯定位）
- [x] 收藏与浏览页星标双向同步（`FavoritesStore` 全局唯一数据源 + `favoritesDidChange` 通知；浏览页星标实时跟随，启动预载）

---

## 4. 播放内核（IOS-201/202/203，参考 nPlayer）

### 4.1 双引擎解码

- [x] `PlayerCore` 统一门面（播放/暂停/seek/倍速 0.5~3.0x/音轨/字幕/进度上报——播放中 5s 节流 + 暂停/seek/结束/退出强制上报 `onProgressReport`；`@Published` 状态/时间/时长/轨道列表供 UI 订阅；`PlaybackRequest.startAt` 引擎层一次性精准 seek 为 §4.2 精准续播打底）
- [x] `AVPlayerEngine`（硬解）：H.264/HEVC 等，`allowsExternalPlayback`（AirPlay）、暴露 `AVPlayer` 供 §4.3 渲染层启用 PiP；KVO 状态/缓冲/播终事件、内嵌音轨/字幕轨选择（`AVMediaSelectionGroup`）
- [x] `VLCEngine`（软解）：MobileVLCKit，mkv/rmvb/avi/flv/wmv/ts；delegate 状态/时间回报、音轨/字幕轨选择（字幕 -1 关闭）
- [x] 格式探测与引擎自动路由（`EngineRouter`：原生/软解扩展名集合 + `AVURLAsset.isPlayable` 5s 超时探测 webm 等未知容器 + 自动模式硬解起播失败回退软解）；设置可强制硬解/软解（`AppSettings.Player.decodePreference`）

### 4.2 边下边播缓存

- [x] 本地 HTTP 代理 `LocalStreamProxy`（NWListener 回环服务，`http://127.0.0.1/stream/<id>/<文件名>`，支持 GET/HEAD + Range/206；双引擎通用——AVPlayer 走 NSURLSession 协议栈、VLC 走 libvlc 网络栈；seek 时解码器 Range 请求直达目标分片）
- [x] `RangeDataSource`：WebDAV Range / SMB 分块统一为可 Range 读取（`AdapterRangeDataSource` 收集 `readStream(range:)` 流式块）
- [x] `SegmentCache`：1MB 分片磁盘缓存（Caches/MediaSegments）+ LRU 淘汰 + 总容量上限（`cache.totalLimitMB`）+ 单文件上限（1/4，淘汰最远分片）；缓存键含文件指纹（size+modTime 变更自动失效）；断点续播复用已持久化分片
- [x] 预读窗口（`CachedRangeReader`：读完后按 `player.preloadSeconds`×0.5MB/s 向后预取，可配）+ in-flight 分片去重；弱网自适应——超时递增 10/20/30s + 3 次重试 + 退避
- [x] **精准续播：历史进度直接从历史位置起播，无「先 0 后跳」**（`PlaybackSourceResolver` 查 ReadingProgress 生成 `startAt` → 引擎首帧就绪后一次性零容差 seek；`PlaybackProgressStore` 上报落库 + 广播刷新通知；浏览/收藏点击经 `PlayerPresenter.play(connection:entry:)` 全链路接通）

### 4.3 播放 UI 与控制

- [x] `PlayerView` + `PlayerControls`：播放/暂停（图标方向正确）、自定义进度条（轨道/缓冲段/已播放/拖钮，点击定位+拖动）、时间、倍速菜单(0.5~3.0x)、音量（手势层系统联动）、沉浸纯黑；顶栏退出直接退出 + 独立「进入 mini」按钮 + 引擎徽标；控制层 3s 自动隐藏（播放中）点击切换；**中央加载圈与大播放键互斥不重叠**
- [x] `GestureHandler`：水平调进度（松手 seek）/ 右竖滑音量（**系统音量联动 MPVolumeView，步进 5%**）/ 左竖滑亮度 / 双击左右快退快进（`seekStepSeconds`，中央双击播放暂停）/ 长按 2x 松开恢复
  - [x] **调节时中央悬浮胶囊显示数值（`GestureFeedbackCapsule`：目标时间/总时长、音量%、亮度%、倍速、±秒数，0.8s 自动隐去）**
- [x] `AudioCoverView`：唱片封面旋转（30fps 计时器，播放转/暂停冻结）、封面来源（同目录同名图/cover/folder/front 复用 `CoverService` 约定 → ID3 内嵌 albumart 兜底，占位图标）、「作者 - 标题」文件名解析
- [x] **纯音频播放模式**（视频可切仅音频：`PlayerCore.setAudioOnly`；软解断开视频轨节电、硬解隐藏画面；音频文件与 `audioOnlyByDefault` 自动进入；控制栏一键切换）
- [x] `SubtitleManager`：内嵌轨选择（控制栏菜单，与外挂互斥）+ 外挂 srt/ass/ssa 自动匹配同目录同名文件（含 `name.zh.srt` 语言后缀，精确同名优先，启动自动加载）+ SwiftUI 浮层渲染（双引擎统一，二分查找 cue）+ 样式（`subtitleFontSize`）/延迟（`subtitleDelay`）
- [x] 多音轨切换（内嵌轨菜单，AVMediaSelectionGroup / VLC trackIndexes，≤1 轨时置灰）
- [x] `NowPlaying`：后台音频（`AVAudioSession(.playback)` 起播激活/退出释放）+ 锁屏/控制中心（`MPNowPlayingInfoCenter` 标题/作者/时长/进度/倍率 + `MPRemoteCommandCenter` 播放暂停/快进快退/拖动定位）
- [x] 画中画（PiP）：`AVPictureInPictureController` 挂 AVPlayerLayer（硬解路径），控制栏入口（软解/纯音频自动隐藏）
- [x] 进度自动上报（节流，§4.1/4.2 已完成）+ 打开自动恢复（`startAt` 精准续播，§4.2 已完成）

### 4.4 mini 播放器

- [x] `MiniPlayer`：**悬浮式（灵动岛 / QQ 音乐风格）**，全局持有跨页面保持（RootView 顶层悬浮，圆角卡片 + 阴影 + 底部播放进度细条；播放/暂停键随状态切换）
- [x] **深/浅色均加细边框**，避免与黑背景融为一体（0.5pt `separator` 描边）
- [x] 退出按钮直接退出（不进 mini，`PlayerPresenter.close()` 联动停止内核）；功能栏单独「进入 mini」按钮（§4.3 顶栏 `chevron.down`）
- [x] **移动端从画面中央下拉进入 mini（过渡动画）**（手势层竖滑三分区：左亮度/中下拉/右音量；下拉跟随手指偏移 + 渐隐，松手 >120pt 进入 mini，否则回弹）
- [x] 点击 mini 展开全屏（复用会话不重载，`PlayerPresenter.expand()`）；下拉拖拽 >60pt 关闭
- [x] **从浏览页再次点击正在 mini 播放的同一文件 → 回到完整播放**（`PlayerPresenter.play(_:)` 命中 mini 同项即 expand）

### 4.5 连续播放推荐（IOS-204）

- [x] `NextMediaTip`：播完查同目录同类型下一个（`NextMediaFinder` 按浏览排序偏好 sortKey/升降序定位），底部弹出提示 + 倒计时环 5s 自动播放，点击立即播放，可取消；切新项/复播自动撤销

---

## 5. 小说阅读（IOS-205 / 206）

- [x] `TxtReader`：流式读取 + 本地章节索引（正则识别标题）（`TxtNovelIndexer` + `TxtChapterLoader`：按章 Range 加载不整本读入；**字节级行扫描**记录章节标题全局字节偏移，精确无漂移；索引存 `NovelIndex` 表可重建；「第 x 章/节/回/卷」「Chapter n」「楔子/序章/尾声/番外」多模式正则）
- [x] **编码检测**：UTF-8 / GBK / Big5 / **UTF-16 LE/BE**（BOM + 启发式 + 码元对齐 + 缓存自愈），避免乱码（纯文本查看 & 小说阅读器均适用）（复用 `TextEncodingDetector` + `CodeUnitAligner` 切块边界对齐 + 旧缓存抽样复核替换符占比，异常自动重建）
- [x] `EpubReader`：解包 + 目录/章节/资源按需渲染（`EpubBook`：`RangeZipReader` Range 解包不整包下载；container.xml → OPF manifest/spine → NAV(EPUB3)/NCX(EPUB2) 目录；章节 XHTML 按需解析为段落流 `EpubHTMLParser`；封面提取缓存供「正在阅读」）
- [x] **epub 图集型（漫画）判断**：命中则提示/一键转漫画阅读器（抽样 spine 前 5 个 XHTML：文本 <120 字且含插图占比 ≥80% 判定；弹窗提示，`NovelReaderPresenter.onOpenComic` 回调预留待 §6 接管）
- [x] 翻页模式（`TextPainter` 行边界分页）/ 滚动模式（`TextPaginator`：CTFramesetter 逐行 origin 切页不截断行，标题放大加粗、插图 NSTextAttachment 等比嵌入；滚动模式为同分页结果的连续页块 + ScrollViewReader 程序滚动联动）
- [x] 章节预加载（当前 ±1）（`chapterCache` LRU 保留 ±1，切章即调度）
- [x] 阅读器设置：字号、行距、主题（日间/夜间/护眼）、翻页/滚动、亮度、思源宋体（`ReaderSettingsPanel` 实时生效并持久化 `AppSettings.Reader`；亮度联动 `UIScreen.brightness` 退出恢复；思源宋体未打包时回退系统宋体）
- [x] 目录抽屉（当前章高亮跳转）（`.sheet` 半屏列表，当前章 ✓ 高亮）
- [x] 进度实时显示 + 上下章（底栏页码/全书百分比进度条 + 上一章/下一章；3s 节流 + 切章/退出强制上报 `NovelProgressStore`，广播驱动「正在阅读」自动刷新）
- [x] **进度恢复：排版无关锚点一步定位**（需求 v1.2 已废除「先跳章节再定位偏移」两步时序：txt 存全局字节偏移 Int64，恢复直接 seek → 章节索引二分反查，一步完成；epub 存 spine+段落+段内字符偏移；进度记录附 fileSize+modTime 文件指纹，文件被替换提示并归零防错乱；`NovelReaderPresenter` 全屏路由接入浏览页/收藏页）

---

## 6. 漫画阅读（IOS-207 / 208）

- [x] `ArchiveDecoder`：zip/cbz/epub 按需解页（`ArchiveDecoder`：复用 `RangeZipReader` Range 解包不整包下载，仅拉中央目录 + 目标条目；rar/cbr 经 UnrarKit——本地直读（security-scoped 逐次进入访问作用域），远程源流式落地临时文件带下载进度；页名自然排序）
- [x] `ComicDetector`：扩展名优先（cbz/cbr 直接放行）+ 图片占比≥90%且自然序列命名嗅探（zip/rar/epub 打开时校验，非漫画报「不是漫画文件」）+ 手动覆盖（浏览页右键/长按菜单「以漫画阅读打开」支持 zip/rar/epub）
- [x] 单页 / 双页（横屏·iPad 自动启用，RTL/LTR 切换持久化 `AppSettings.Reader.comicDirection`，auto 默认日漫 RTL；TabView 整体翻转实现 RTL 翻页方向）/ 条漫模式（纵向连续滚动 `LazyVStack`）
- [x] 双指缩放（`ZoomableScrollView`：UIScrollView 桥接 1x~4x 捏合 + 双击放大/还原；1x 时平移手势让位外层翻页）
- [x] 预加载 ±3 页（正向前向优先/反向后向优先，最多并发 3；内存 LRU 保留当前 ±6 页；ImageIO 下采样 2200px 防大图集爆内存）
- [x] **进度记录 + 恢复：直接恢复到上次页码（首次构建即定位，不从第一页开始）**，条漫恢复页码显示（`ComicProgressStore`：页码 + fileSize/modTime 文件指纹，文件替换提示归零；恢复页在 load 完成即定位；条漫经 ScrollViewReader 程序滚动 + PreferenceKey 可见页回写页码）
- [x] **弱网点击漫画：先展示 UI 进入加载界面 + 点击防抖去重**（Presenter `open` 同项去重；打开即 fullScreenCover 进加载态——解析归档转圈 / 远程 rar 下载百分比进度条）
- [x] 翻完推荐下一本（底部提示 + 5s 倒计时自动打开，点击立即打开可取消；复用 `NextMediaTip` UI + 同目录按浏览排序偏好找下一本漫画）

---

## 7. 正在阅读首页与进度（IOS-209）

- [x] 「正在阅读」列表：封面、标题、类型徽标、进度条、最后阅读时间（`ReadingHomeView` + `ReadingHistoryStore`：封面优先复用阅读时提取的缩略图缓存（epub/漫画，Caches/Thumbnails 零网络秒出），否则 `RemoteCoverImage` 与浏览页一致；按 updatedAt 降序；类型徽标 视频/音频/小说/漫画；相对时间「n 分钟前/昨天」）
- [x] 网格 / **列表两种视图**；**长按进入多选模式**（视图偏好持久化 `AppSettings.Reading.viewMode`；iOS 长按进多选、iPad/PC 右键弹圆角菜单，与浏览页一致）
- [x] 点击恢复进度进入对应阅读器/播放器（stat 解析最新 FileEntry 保证文件指纹校验准确——失败落兜底条目防反复重试；视频/音频→`PlayerPresenter.play` 精准续播、小说→`NovelReaderPresenter` 锚点一步定位、漫画→`ComicReaderPresenter` 恢复页码）
- [x] **已读完记录保留至手动删除**；文案区分：视频「已看完」/ 音频「已听完」/ 漫画·小说「已读完」（默认「已读完」，主色高亮 + 进度条满格）
- [x] **将「标记已读完」改为「删除阅读记录」**（右键菜单单条删 / 多选操作栏批量删，确认弹窗注明不影响源文件）
- [x] **进度上报后自动刷新列表**（`ReadingHistoryStore` 订阅 `playbackProgressDidChange` 广播——播放/小说/漫画进度落库共用通道，无需手动下拉）
- [x] 空状态提示（图标 + 引导文案）

---

## 8. 内置浏览器（IOS-401 ~ 404）

### 8.1 核心与多标签

- [x] `BrowserView`：`WKWebView` 封装（配置、KVO 进度、favicon/标题）
- [x] `AddressBar`：URL 智能识别、域名 + HTTPS 图标、聚焦全选
- [x] 2px 加载进度条；错误页（失败/SSL）+ 重试
- [x] `TabManager`：Safari 卡片网格标签，新建/关闭/切换、无痕开关、全局保活
- [x] `target=_blank`/`window.open` → 新标签
- [x] **标签会话持久化**：退出保存标签列表 + 激活标签，启动恢复；保持导航历史栈不因 URL 重建丢失

### 8.2 iOS 交互

- [x] **操作栏放到底部**（后退/前进/刷新/标签/菜单）
- [x] **进入新网页后后退按钮可用；侧滑返回上一页生效**（历史栈空退出页签）
- [x] **滚动收起操作栏（收为 0 高），点击页面展开（动画），切标签重置展开**

### 8.3 起始页 / 书签 / 历史 / 设置

- [x] `StartPage`：搜索框 + 快捷入口网格（增删改 + 拖拽排序 + 首启预置），本地持久化
- [x] 书签：地址栏星标收藏，管理页列表/搜索/编辑/删除
- [x] 历史：自动记录、按日分组、搜索、单条删除、清空；无痕不记录
- [x] 浏览器设置：默认搜索引擎、默认 UA、清除缓存/Cookie/历史

---

## 9. 动态模块（IOS-301，预留）

- [ ] `FeedItem` 本地表 + `FeedService` 协议（`fetch(since:)`）预留
- [ ] 动态页占位 UI（时间降序无限滚动 / 稍后观看 / 进度锚点占位）
- [ ] 显示「功能开发中 / 待接入外部 API」
- [ ] 预留统一播放器内嵌 / 内置浏览器跳转接口

---

## 10. 设置模块（IOS-501 ~ 504）

- [x] 连接源设置（增删改查 + 测试 + 绿/红点 + 内外网提示）（§2 已完成，设置页「连接源管理」入口）
- [x] 阅读器偏好：字号/行距/主题/翻页模式/漫画方向（含自动）（`ReaderPreferencesView` 实时持久化 `AppSettings.Reader`，阅读器内面板仍可临时调整）
- [x] 播放器偏好：默认倍速/解码偏好/预读窗口/字幕样式/纯音频默认/**iOS 音量步进默认 5%**（`PlayerPreferencesView`，含双击快进步长与字幕延迟）
- [x] 缓存与存储：分类占用查看 + 清理 + 容量上限 + **内容缓存本地化开关**（`CacheSettingsView` + `CacheManager` 分区统计/单项与全部清理；回收站保留天数 1~90）
- [x] 安全：应用锁（Face ID/Touch ID，无生物识别回退设备密码；后台上锁返回验证，开关需先验证身份）（`AppLockManager` + `AppLockView` 全屏遮罩）、**凭据/连接配置持久保存不被清空**（Keychain `AfterFirstUnlockThisDeviceOnly`，删除连接源才清除凭据）
- [x] 关于：版本、开源许可、存储用量、日志、应用图标（`AboutView` + `AppLogger` 文件日志：查看/分享/清空，512KB 自动截断）
- [x] 附：外观（主题模式）快捷切换 + 配置导入/导出 UI（`SettingsHomeView`，导出 JSON 快照不含明文密码，导入按挂载点 upsert）

---

## 11. 内容缓存本地化（IOS-605）

- [x] 视频/音频分片缓存本地化（复用 §4.2 SegmentCache）：命中分片零网络直出；`FileIdentity` 存缓存索引 + `cachedIdentity` 反查，stat 失败（无网络）以缓存身份起播，`CachedRangeReader.offlineMode` 未命中区间快速失败不重试不预取
- [x] 漫画解压页缓存本地化（`ComicPageCache` + `FingerprintDiskCache`：解压页按指纹+页名落盘，命中免解压；远程 rar/cbr 整包落缓存分区复用；页名列表持久化 → `DiskCachedComicSource` 离线打开）
- [x] 小说章节缓存本地化（`NovelChapterCache`：txt 缓存章解码产物含行字节范围表、epub 缓存内容块+插图数据+`CachedEpubMeta` 元数据快照 → 离线重建 `EpubBook`；`loadChapter` 命中免网络）
- [x] 封面缩略图缓存本地化（`CoverService`/`ComicProgressStore`/`EpubBook` 写 Caches/Thumbnails；epub 封面键改稳定 SHA256 修复 `path.hashValue` 跨启动失效；命中刷新访问时间）
- [x] 统一容量上限 + LRU；设置页分类查看/清理（`CacheManager.limitBytes(for:)` 分区配额派生自 `totalLimitMB`；`FingerprintDiskCache` 目录粒度 LRU、封面/目录分区文件粒度 LRU、`enforceGlobalLimit` 跨分区兜底；`CacheSettingsView` 6 分区查看/清理，受「内容缓存本地化」开关约束，启动预热触发兜底淘汰）
- [x] 已完整缓存内容支持无网络播放/阅读（视频分片 / 漫画页 / 小说章节命中即离线可用；缺失内容以 `StorageError.offline` 明确提示，点击先展示 UI 不阻塞）

---

## 12. iOS 平台特性（IOS-601 ~ 604）

- [ ] iPhone/iPad 自适应；SafeArea、Dynamic Island、刘海适配
- [ ] iPad 分屏（Split View / Slide Over）、双页漫画、外接键盘快捷键
- [ ] 后台音频 + 锁屏/控制中心 + PiP（§4.3）
- [ ] 横竖屏：视频竖屏正常/横屏全屏；不同分辨率（含竖屏视频）正确适配
- [ ] 离线下载（二期）：`URLSession` background 队列（暂停/恢复/取消）+ 离线播放/阅读
- [ ] 本地通知（二期）：`UNUserNotificationCenter`（下载完成等）

---

## 13. 非功能与质量

- [ ] 起播 < 3s（局域网）；文件列表 < 1s；漫画翻页无白屏
- [ ] 内存常态 < 250MB；软解及时释放解码资源
- [ ] 网络中断自动重连；上传/下载断点续传
- [ ] 本地数据库定期自动备份到沙盒
- [ ] 隐私合规：数据全本地、不上传用户内容、符合 ATS 与 App Store 隐私政策

---

## 体验优化、bug修复
- [x] 纯txt浏览器，无法打开
- [x] 以纯txt浏览器打开的，不计入阅读记录
- [x] 长按文件，无法弹出菜单栏，阅读界面和浏览界面都无法弹出菜单栏（根因：SwiftUI Button 内部手势吞掉长按；已改为 cellPressableMenu/cellPressable 手势组合）
- [x] 从阅读界面打开的小说（包括txt、epub等等文件），默认以小说阅读器打开，漫画默认以漫画阅读器打开
- [x] 漫画打开后直接闪退了，并且在阅读界面上，显示的还是小说标签
- [x] 阅读界面，封面有时候显示，有时候不显示，看看是不是bug，封面应该是会缓存的，直接读取就行
- [x] 目前底部的页签栏，按钮太大了，调小一点
- [x] 视频播放内部音量，和系统音量不同步，需要进入播放页时，使用系统音量，并且在内部音量变化时，系统音量同步变化，同时检查下亮度是否同步
- [x] 参考flutter的视频播放页面UI，在屏幕左中的地方，增加一个按钮用于切换横竖屏
- [x] 视频播放界面锁屏的时候，目前是在屏幕的上方点击解锁，参考flutter的视频播放页面UI，改为在屏幕正中央显示一个锁，这个锁会自动消失，用户点击其他地方会显示锁的图标，点击锁的图标会解锁，并且长按锁定时候，触发一次震动
- [x] 参考 Flutter 浏览界面，为文件浏览列表（`Features/Browse/FileCellViews.swift` 的 `FileGridCell` / `FileListRow`）增加「阅读进度」与「正在播放」两种状态指示，逻辑与 Flutter 端 `file_status_indicator.dart` 对齐。实现：新增 `Features/Browse/FileStatusIndicator.swift`（`FileStatusIndicator` / `ReadingProgressRing` / `PlayingBarsIndicator`）；`BrowseDirectoryView` 注入 `ReadingHistoryStore` + `PlayerCore` 提供进度字典与播放判断。
  - [x] 进度环：文件在 `readingProgress` 表有记录时，右上角(网格)/尾部(列表)显示 18pt 环形进度（`ReadingProgressRing`，`percent` 0~1，从 12 点顺时针，100% 满环）；无记录不显示；目录不显示。
  - [x] 正在播放：`player.current.connectionID == connection.id && current.path == entry.path && PlayerCore.isPlaying` 时，文件名变主色+加粗，并显示三竖条均衡器动画（`PlayingBarsIndicator`）。
  - [x] 优先级：正在播放 > 进度环 >（无标识），与 Flutter 端一致。
- [x] 添加了路径源后，无法在浏览界面看到，需求重新进app
- [x] 设置里面的行数，选择其他行数后，数字没有变化，要切换主题才会更新，并且实际没有生效
- [x] 浏览界面无法滑动
- [x] 浏览界面的搜索框，现在是默认常驻显示，改成用户向上滑动到最顶部，才用动画显示搜索框，再上滑，才触发刷新
- [x] 浏览界面，每次重新进入，不会进入第一级目录，看上去是进入上一次的目录
- [x] 浏览界面，列表模式，视频的时间长度，把封面挡住了，并且还换行了，把时间放到标题栏下面，把修改时间去掉，显示时长，列表和卡片模式都改
- [ ] 内置浏览器，有多个输入网址的输入框，并且点击输入框，弹出输入法后，点击空白部分，无法退出输入法
- [ ] 浏览界面，每次左滑返回上一级目录，进入下一级目录，右上角的图标就会像被点击一样触发动画
- [ ] 路径源设置，没有内外外网的逻辑
- [ ] 部分封面一直没有加载成功
- [ ] txt文件还是无法以纯文本阅读
- [ ] 小说分章有问题
- [ ] 视频播放的画中画和音量按钮去掉，把倍速按钮放到右下角，注意移动倍速按钮后进度条的长度比例也要调整
- [ ] mini播放器预览界面，播放视频时候没有实时画面，同时样式也和fultter的不同，预览界面没有突出的部分
- [ ] 漫画文件还是无法打开
- [ ] 阅读界面和浏览界面，右上角的还是毛玻璃的样式，优化下和整体主题风格相同
- [ ] 视频左右拖动进度时候，跨度太大了，2小时视频，拖一下就40min了，改成固定的一段时间
- [ ] 视频锁定的长按，要手指拉起来才触发，改成按住一段时间后触发，并且触发时候有震动
