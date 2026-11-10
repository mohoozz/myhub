# myhub-pc 桌面端 TODO

> 依据《myhub-pc/需求分析文档.md》v1.1 拆解，按模块组织，勾选即完成。
> **平台**：Windows 10 1809+ / macOS 12+，单一代码库双平台。
> **技术栈**：**Qt 6.8+（LGPLv3）+ QML + C++20 + CMake**；选型依据见需求文档 §4.0。
> **架构**：纯本地化桌面应用（无服务器端）。
> **数据**：全部本地——SQLite（sqlite3 C API）+ `QSettings` 偏好 + 系统凭据库（Credential Manager / Keychain）+ 用户缓存目录。
> **网络存储**：客户端原生直连 WebDAV（`QNetworkAccessManager` + 内外网竞速路由）/ SMB2/3（libsmb2）/ 本地磁盘（可扩展 FTP/SFTP/NFS）。
> **播放内核**：libmpv（经 **mpvqt**，硬解优先/软解兜底）+ `QQuickRhiItem` 渲染接入 + libVLC 兜底引擎（接口预留）+ `QTcpServer` 回环代理 + 边下边播分片缓存。
> **浏览器**：QtWebEngine（内置 Chromium）。
> 里程碑：**M-1 预研** → M0 骨架+浏览 → M1 文件管理 → M2 播放器 → M3 阅读器 → M4 浏览器 → M5 v1.0 候选 → M6 v1.0 正式
>
> ⚠️ **移植纪律**：iOS 端 `myhub-ios/TODO.md` 中已勾选的每一条（含末章 130 条体验优化/bug 修复）必须在本列表中有对应条目；
> iOS 平台专有能力按《需求分析文档》§2.12 能力映射表转换为桌面等价实现，**不得静默裁剪**。标 **加粗** 者为重点验收项。
>
> ⚠️ **许可红线**：禁止链接 GPL-only 的 Qt 模块（**Qt HTTP Server / Charts / DataVisualization / Lottie / VirtualKeyboard**）；
> 必须动态链接 Qt 并保持库可替换；发布物须含许可证页。详见需求文档 §4.5 / §7.2。
>
> 📐 **页面原型**：[`prototype/index.html`](prototype/index.html)（7 份主要页面，各章节已标注对应链接）。
> 实现 UI 前先对照原型；原型与《需求分析文档》正文冲突时**以正文为准**；方案变更须同步更新原型。

---

## 0. 技术预研与工程脚手架

### 0.1 技术预研 Spike（M-1，先于编码，产出可运行 Demo + 结论，约 1 周）

> 目标：把选型风险清零。**五条验收标准全部通过才进入 M0**；任一条不通过须回写需求文档 §4 并重新评估。

- [x] **S1 播放基础**：1080p HEVC `.mkv` 经 libmpv + mpvqt 在 QML 中播放 ✅
      （实测详见 [`research/README.md`](research/README.md)）
  - [x] 判定：**硬解生效 `hwdec-current=nvdec`**、CPU **2.6% 单核**、`drops=0`、
        无黑屏（截帧非黑像素 99.8%）、seek 误差 **0.000s**
  - [x] 顺带验证：mkv / avi / ts / mp4 容器，双音轨枚举与切换（jpn/chi），
        外挂字幕 + **UTF-8 中文字节级比对**，倍速 0.5~3.0x
  - [ ] rmvb 容器（需真实素材，ffmpeg 无法生成 RealVideo）
  - [ ] ⚠️ **新发现**：mpvqt 基于 `QQuickFramebufferObject`，**D3D11 后端下 100% 黑屏**，
        全局须强制 OpenGL —— 已回写需求文档 §4.3.1
- [x] **S2 控制层叠加**（前置判定已通过）
  - [x] 判定：**叠加层不被视频遮挡** —— 截帧验证 QML 控制条正常浮于视频之上
        （meanLuma 126.8 → 101.3，合成生效）
  - [ ] 完整交互（`Esc` / 拖动进度 / 滚轮音量 / 点击播放暂停）随 M2 实现一并验证
  - [ ] ASS 字幕浮层与手势反馈胶囊
- [x] **S3 mini 实时预览** ✅（实测详见 [`research/README.md`](research/README.md)）
  - [x] 判定：主画面与 mini 预览同时渲染**不互相干扰**
        —— 等长稳态对照（各 3~5 轮）下双处渲染 **0 丢帧**，与仅主画面持平；
        CPU 差异在噪声内（均 < 3% 单核），`vf-fps=30.0`、`hwdec=nvdec` 稳定
  - [x] 判定：切换全屏/mini **不重载会话**
        —— 两次 reparent 后 `fileLoadedCount` 恒为 1，position 连续（35.07s→37.90s）
  - [x] 同源证据：mini 与主画面亮度直方图相似度 **0.988**（非第二实例、非静态图）
  - [x] 跨页面保持：主画面隐藏后 mini 仍出画（截帧 `s3-frame-mini-only.png`）
  - 方案定稿：**单 mpv 实例 + `ShaderEffectSource` 引用主画面 Item**；
        切换容器用 `setParentItem` 而非销毁重建
- [x] **S4 浏览器能力** ✅（实测详见 [`research/README.md`](research/README.md)）
  - 全部页面由进程内 `TestServer` 提供（`127.0.0.1` 临时端口），**不依赖外网**；20 项判定全通过
  - [x] 判定：切标签不销毁 —— 隐藏 2.4s 后页内计数器仍在增长、`loadStarted` 恒为 1，
        切回后计数器不回零（`ticks 12 -> 25`）
  - [x] 判定：**历史栈不丢** —— tab3 在隐藏状态下 `canGoBack=true`、`history.length=2`
  - [x] 判定：下载可拦截落地 —— `downloadRequested` 接管后 `state=2`，
        落盘 131072 字节且 **SHA-256 与源完全一致**
  - [x] 判定：无痕不写历史 —— OTR 目录未被创建、无隐私文件；普通 profile 有 `History/Cookies/Visited Links/Favicons`
  - [x] UA 覆盖 —— 页面内 `navigator.userAgent` 与服务端实收头**双向一致**
  - [x] favicon / `loadProgress` —— `image://favicon/…` 命中本地 `/fav.png`，三个标签均达 100
  - 关键结论（供 M2）：QML 声明的 `WebEngineProfile` **默认 off-the-record**，
        必须显式 `offTheRecord: false`；后台标签定时器被节流至 **~2Hz**，
        依赖定时器的功能不可假定秒级精度
- [x] **S5 文本排版** ✅（实测详见 [`research/README.md`](research/README.md)）
  - 语料由固定种子 LCG 生成：100000 个 UTF-16 单元 / 535 段 /
    CJK 69447 + ASCII 22703 + 1438 个 emoji 代理对，逐字节可复现；18 项判定全通过
  - [x] 判定：**不截断行** —— 2530 个行区间**精确铺满**全部段文本（无空洞/无重叠/无丢字），
        2530 个行边界对 1438 个 emoji 代理对**0 切分**，0 行横向溢出列宽
  - [x] 判定：**重排 < 200ms** —— 10 万字全量重排中位 **34ms**/最坏 39ms；
        改 24px + 1.9x 行距后 225 页、**36ms**
  - [x] 判定：**锚点往返一致** —— 3600 个锚点（段首/段尾/每个行首）`偏移 → 行 → 偏移` 恒等；
        2000 个随机偏移全部落回本行；落进代理对中间时归一化到字符起点（1438 个位置 0 异常）
  - [x] 判定：**跨排版有效** —— 612 个锚点在 15/20px、1.6~2.0x 行距、560/760px 列宽下
        全部定位到含该偏移的行（其中 1193 次落在**不同页**，偏移与片段不变）
  - [x] 一步定位 —— 锚点直接算出页码（二分，平均 **0.11 µs**），无需「先跳章节再找偏移」
  - [x] 极端边界 —— 整章无换行（单块 10 万字 `QTextLayout`）2272 行、同样 34ms
  - 关键结论（供 M3）：档只存 `{段序, 段内偏移, 片段}`，**页码/行号一律不进持久化**；
        `offscreen` 平台插件无字体库（会造成「全绿但数据是假」），排版类探针必须用真实平台插件
- [x] **S6 原生依赖构建** ✅（实测详见 [`research/README.md`](research/README.md)）
  - [x] libsmb2 在 Windows（MSVC）编译与链接，跑通 SMB 目录列举 + Range 读
        —— vcpkg `libsmb2 6.2`；连接/列举/stat/**Range 字节级校验**/EOF 全通过
  - [ ] libsmb2 在 macOS 的编译与链接（跨平台时验证）
  - [x] libarchive 编译，跑通 rar/cbr 解页
        —— cbz(zip) / 7z / **RAR4** / **RAR5** 均可枚举并读出内容，页序自然排序正确
  - [x] `QTcpServer` 回环 HTTP（Range/206）拦截概率评估与规避方案
        —— 回环临时端口无需管理员权限与防火墙放行；libmpv 经回环成功解码 HEVC，
        **请求全部携带 Range 头**；规避方案见需求文档 §7.1
- [ ] 预研结论汇总，回写需求文档 §4 / §7；确认 §6 里程碑工期
  - [x] S1 / S2(前置) / S3 / S4 / S5 / S6 结论已汇总至 `research/README.md`
        并回写 §2.3、§2.7、§4.2、§4.3.1、§4.3、§7.1
  - [ ] 待多显卡（Intel/AMD）验证后补齐最终结论与工期确认

### 0.2 工程脚手架（M0）

- [x] CMake 工程初始化（应用名 `MyHub`、AppID `com.myhub.desktop`、v1.0.0、C++20）
- [x] `CMakePresets.json`：Windows（MSVC 2022 + Ninja）/ macOS（Xcode Clang，arm64 + x86_64 通用二进制）预设
- [x] 目录结构搭建（`src/app`、`src/core`、`src/features`、`src/platform`、`qml/`、`third_party/`、`resources/`、`tests/`、`scripts/`）
  - [ ] 待后续里程碑创建：`src/player`（M2）、`src/readers`（M3）、`src/domain`、`packaging/`（M6）
- [x] Qt 模块引入：`Core` / `Gui` / `Quick` / `QuickControls2` / `Network` / `Concurrent` / `WebEngineQuick` / `Svg`
  - [x] **CI 检查：禁止链接 GPL-only 模块**（HttpServer / Charts / DataVisualization / Lottie / VirtualKeyboard）
        —— `cmake/LicenseGuard.cmake`，configure 期拦截 + 链接期校验
- [x] 原生依赖 vendor 进 `third_party/` 并锁定版本：libmpv、mpvqt、libsmb2、libarchive、zlib、sqlite3
      （vcpkg baseline `44ccfd8` + `fetch-libmpv.ps1` SHA256 锁定；见 `third_party/README.md`）
  - [ ] ⚠️ **libmpv 当前为 GPL 构建，发布前须换 LGPL 版或改用 libVLC**
- [x] `cmake/` 模块：`FindLibmpv.cmake` / `FindLibsmb2.cmake` / `Deploy.cmake` / `LicenseGuard.cmake` / `RuntimeLibs.cmake` / `QmlModule.cmake`
      （libarchive 用 CMake 内置 `FindLibArchive`，无需自写）
- [x] **分层约束落地**：`myhub_core` 只链接 QtCore/QtNetwork/QtConcurrent，
      **编译期强制**（误 include QtQuick/QtGui 即编译失败），无需额外静态检查
- [x] QML 模块注册（`qt_add_qml_module`）与资源打包
- [x] 启动 Loading 窗 + 应用图标（SVG）
  - [ ] Windows `.ico` / macOS `.icns` 多尺寸图标（M6 打包时补齐）
- [x] 代码规范与 CI：`clang-format` / `clang-tidy`、QML lint、构建流水线
  - [x] **`clang-format` 基线**（`.clang-format`，clang-format 19）：68 个文件全量格式化后
        `--dry-run -Werror` **零 diff**；`SortIncludes: Never` + `ReflowComments: false`
        保证 diff 只含空白、可逐行评审
  - [x] **`clang-tidy`**（`.clang-tidy` + `compile_commands.json`）：37 个 TU、**0 findings**；
        顺带修 3 处真实问题（`QJsonArray` 迭代绑定临时值、返回值未 move、`qint64` 乘加溢出），
        另 2 处平台层 `const_cast` / `int → 指针` 按规则加 `NOLINT` 与理由
  - [x] **`qmllint`**（`.qmllint.ini`）：30 个 QML 文件干净；6 个委托文件加
        `pragma ComponentBehavior: Bound`（真修，非抑制）
  - [x] 统一入口 `scripts/lint.ps1`（`-Fix` / `-SkipTidy`）+ `scripts/ci.ps1`
        （构建 → 单测 → 规范校验，与 CI 同一份脚本）；工具缺失直接失败，不静默跳过
  - [x] QTest 单测接入（6 个用例集，`ctest` 全绿）
  - [ ] 双平台流水线：Windows 已落地 `.github/workflows/ci.yml`（只装环境，执行体复用 `ci.ps1`；
        **首次推送后需按日志校准 runner 自带的 LLVM / Qt 版本**）；macOS 流水线待跨平台阶段
        （与 §0.1 的 libsmb2 macOS 构建一并验证）
- [x] 部署脚本骨架：`qt_generate_deploy_qml_app_script` + 运行库随包拷贝
  - [ ] 完整验证 `windeployqt` 产出可运行包（含 QtWebEngine 资源与 Helper 进程）（M6）
- [x] `README.md`：环境要求、构建说明、目录结构、原生依赖准备步骤、**LGPL 合规说明**
- [x] **QML 设计令牌落地**：`qml/theme/Colors.qml` + `AppTheme.qml` + `Motion.qml` + `Icons.qml`
      （颜色 / 圆角 / 描边 / 阴影 / 动效时长单一来源，图标 path 移植自原型 `_icons.js`）
- [x] 原型维护约定写入 `README.md`：原型为正文的可视化补充，**冲突以《需求分析文档》为准**

---

## 1. 通用框架（PC-001 / PC-003 / PC-004）

> 📐 原型：[`prototype/01-shell-navigation.html`](prototype/01-shell-navigation.html)

### 1.1 窗口与导航

- [x] `RootShell`：左侧侧边栏 + 内容区（播放器全屏覆盖层已接入；底部播放条待 M2.4）
  - [x] 导航项：阅读 / 收藏 / 动态 / 浏览 / 浏览器 / 设置
  - [x] 宽度断点自适应：≥1100 展开 / 760~1100 折叠图标栏（hover 浮出）/ <760 抽屉式
  - [x] 侧边栏选中项浅蓝胶囊高亮；可手动固定折叠状态并持久化
- [x] **页面保活**：切换导航不销毁，保留滚动位置 / 搜索词 / 选择态
- [ ] 四条独立全屏路由：播放器（已接入 `PlayerView`）/ 小说阅读器 / 漫画阅读器 / 纯文本阅读器（M2/M3）
- [x] **重复点击当前导航项回到该模块起始页**（浏览页回连接源选择列表）
- [x] 窗口管理：尺寸/位置/最大化状态记忆、最小尺寸限制、`F11` 全屏
      （含跨显示器失效几何的回退处理）
- [x] **单实例运行**：再次启动激活已有窗口（`QLocalServer`，已支持携带参数传递）
- [ ] 系统托盘图标 + 菜单（显示/隐藏主窗、播放控制、退出）；macOS Dock 菜单
- [ ] macOS 原生菜单栏（文件/编辑/视图/播放/窗口/帮助）
- [ ] 多显示器与 HiDPI 适配（跨屏移动 DPI 自适应不模糊）

### 1.2 主题与视觉基线

- [x] `Colors` + `AppTheme`：亮（白底蓝调）/ 暗（纯黑）双主题，令牌严格对齐 `prototype/_shared.css`
  - [x] 沉浸场景强制纯黑（令牌 `immersiveBg`；播放器已用，阅读器 M3 接入）
- [x] 主题模式（亮/暗/跟随系统）持久化（`app.themeMode`）；跟随系统时监听系统外观变化实时切换
      （`QStyleHints::colorSchemeChanged`，跨平台）
- [x] 设计令牌统一：圆角、**统一描边色与 1pt 宽度**、阴影、间距、动效 ≤200ms
- [x] 按压反馈（缩放 0.975 + 淡填充）、hover 高亮
  - [ ] 焦点环（键盘可访问性，M5）
- [x] **确认框统一为居中 + 完全圆角矩形**（`ConfirmDialog.qml`，不使用锚点气泡）
- [x] **启动期 Loading 动画，无长白屏**（`LaunchLoading.qml`，就绪后淡入主界面）
- [x] **点击头像入口跳转**（当前指向设置，个人主页待实现）
- [x] 统一菜单体系：右键上下文菜单 + ⋯ 菜单（圆角 + 弹出动画 + **在鼠标位置精确定位** + 边缘自动翻转留白）
- [x] **毛玻璃材质**组件骨架：`GlassPanel.qml`（半透明 + 统一描边的降级形态，观感不塌陷）
  - [x] Windows：`DwmSetWindowAttribute` Mica（Win11）/ Acrylic 的平台层实现已就绪
  - [ ] 接入根窗口并联动主题（M5）
  - [ ] macOS：`NSVisualEffectView` Vibrancy（`.mm`）
- [x] 可复用视觉组件：`CellPressHighlight`（浮起抬升）、`ConfirmDialog`（居中圆角）、
      `PopupMenu`、`StatusDot`、`SearchField`、`EmptyState`、`ToolbarButton`、`AppIcon`
  - [x] `RevealHalo`（呼吸灯，PC-109 定位高亮）、`FilePropertiesDialog`（属性面板，PC-110）
  - [ ] `RemoteCoverImage`（远程封面，PC-702）
- [x] HiDPI：`PassThrough` 缩放策略 + SVG 矢量图标（跨屏移动不模糊）

### 1.3 键鼠交互与快捷键（PC-003）

- [x] 全局快捷键：`Ctrl+1..6` 切换模块、`Ctrl+,` 设置、`F11` 全屏
  - [ ] 完整分发器 + macOS `Cmd` 自动映射（跨平台时补）
- [x] 浏览页：hover、单击选中、双击打开（可配单击打开）、`Ctrl/Shift+单击` 多选
  - [ ] 框选（橡皮筋）、多选操作栏（M1）
- [ ] 键盘完全可操作：Tab 焦点环、方向键移动、`Enter` 打开、`Delete` 删除、`F2` 重命名（M1/M5）
- [x] `Alt+←` / `Backspace` 返回上一级；`F5`/`Ctrl+R` 刷新；`Ctrl+F` 目录内搜索；`Ctrl+A` 全选
  - [ ] 鼠标侧键返回
- [ ] 拖拽：文件拖入窗口上传；页面内拖拽移动（M1）；字幕拖入播放器（M2）
- [ ] **快捷键速查面板**（`F1` / `?`），与《需求分析文档》§8.5 总表一致（M5）

### 1.4 本地存储与凭据（PC-002）

- [x] `AppDatabase`（sqlite3 C API，不用 Qt SQL）：版本化迁移器建表（`v1_initial`、`v2_reading_fingerprint`）
  - [x] 9 张表与 iOS 同构：connection / favorite / readingProgress / novelIndex / bookmark / browserHistory / browserShortcut / downloadTask / feedItem（预留）
  - [x] 唯一约束 / 外键级联 / 常用索引与 iOS 完全一致（单测 `tst_e2e_browse` 验证）
  - [x] `ready()` 信号：依赖数据库的 Store 必须等待后再装载（避免冷启动空列表）
- [x] `CredentialStore`：Windows Credential Manager，key 约定 `conn.<id>`
  - [ ] macOS Keychain 实现（`.mm`，跨平台时补）
- [x] `AppSettings`：偏好封装，**键名与 iOS 对齐**（见需求文档 §5.4），含桌面新增键
- [x] 数据与缓存目录管理（`%APPDATA%\MyHub` / `%LOCALAPPDATA%\MyHub\Cache`），设置中可「打开所在文件夹」
- [x] 缓存分区目录创建（6 分区）
  - [ ] `CacheManager`：分区配额 + 占用统计 + LRU 清理（M5）
- [x] **数据库定期自动备份**到 `backup/`（每日一份，保留 7 份，用 SQLite 在线备份 API）
- [ ] `ConfigTransfer`：配置导入/导出 JSON 快照（连接源 + 全部偏好，不含明文密码；按挂载点 upsert，返回新增/更新计数）
  - [ ] **与 iOS 导出文件互导兼容**（formatVersion 兼容，缺失字段不覆盖）

### 1.5 日志、崩溃与诊断（PC-707）

- [x] `AppLogger`：按天滚动文件日志、保留 7 份、单文件超限截断、新构建首启归档旧日志
      （框架 debug 输出不入文件，避免淹没业务日志）
- [x] 分模块 tag：`app / lifecycle / network-route / stream / player / player-audio / novel-index / comic-reader / browser / database / storage`
- [x] 崩溃捕获：`qInstallMessageHandler` + `std::set_terminate` + 原生信号
      （SIGSEGV/SIGABRT/SIGFPE/SIGILL/SIGBUS）→ `crash.log`，自写 async-signal-safe 处理
- [x] 设置 → 关于：日志查看 / 清空 / 打开日志文件夹 + 上次崩溃提示
  - [ ] 日志导出（M5）
- [ ] 关键链路埋点：数据源解析耗时、引擎加载耗时、地址锁定快照、代理健康快照、网络路径变化、失败全量快照

---

## 2. 存储适配器层（PC-101 / PC-708）

> 📐 原型（连接源 UI）：[`prototype/02-browse.html`](prototype/02-browse.html) §1 · [`prototype/07-settings.html`](prototype/07-settings.html) §2

- [x] `StorageAdapter` 接口：list / stat / readRange / testConnection / writeFile / move / copy / remove / mkdir
      （回调式 `Result<T>` 替代文档示例的 `QFuture`，以便按错误种类精确分支，见 `StorageAdapter.h` 注释）
  - [ ] `RangeStream` 增量流式接口（M2 边下边播时实现）
- [x] 配套类型：`FileEntry`（含 fingerprint）、`StorageError`（含 **InvalidResponse** / **Offline**）、`StoragePath`
- [x] `LocalAdapter`：本机任意目录（阻塞 IO 走线程池，GUI 线程零阻塞）
  - [ ] macOS 沙盒分发时的 Security-Scoped Bookmark
- [x] `WebDAVAdapter`：PROPFIND / GET(Range) / PUT / MOVE / COPY / DELETE / MKCOL；HTTPS + Basic 认证；自签证书信任开关
  - [ ] **真正增量流式下载**（M2 边下边播时实现，当前为整块 Range 读）
  - [x] **PROPFIND 严格校验**：解析不到合法 `multistatus` 即抛错并记录状态码/Content-Type/响应体前缀，
        **严禁把异常响应当空目录**（`tst_webdavparse` 7 个用例覆盖）
  - [x] 独立 Session（禁用 HTTP 缓存、预置 Authorization 避免 401 往返）
- [x] `RoutedWebDAVAdapter`：内外网双地址路由装饰器
  - [x] **Happy Eyeballs 竞速**：内网先发、外网延迟 ~700ms 并发兜底，先成功者锁定
  - [x] 锁定状态 + `lockSnapshot()` 诊断快照
  - [x] **失败自愈**：仅连接类/网关类错误才回退或清锁（8s 冷却）；404/409/鉴权不触发
        （判定逻辑由 `tst_storageerror` 12 个用例覆盖）
  - [x] **流式读写先解析路由再选址**（流不可中途换址）
  - [x] `testConnection` 清锁重判
- [x] `SMBAdapter`：libsmb2（SMB2/3），账号 / 访客 / 域，**原生分块读取**（64KB/块）；连接测试
  - [ ] 降级备选：引导用户映射网络驱动器后按本地路径访问
- [x] 适配器工厂：按 `Connection.type` 实例化，自动取凭据；表单未保存时支持 `passwordOverride` 测试
- [x] （预留）FTP / SFTP / NFS：枚举保留，工厂抛「暂不支持」（单测覆盖）
- [ ] `NetworkPathMonitor`：监听网络接口变化（断网 / 切换 / 计费受限）并记录（M5）
- [ ] `NetworkRecovery`：系统休眠唤醒、网络切换、窗口恢复时 → 清除地址锁定 + 回环代理探活重建（M5）
- [x] 连接源管理 UI：`ConnectionListView`（类型图标/挂载点/状态）+ `ConnectionFormView`（分类型表单 + 内网地址）+ 删除确认
  - [x] **连接测试状态：正常绿点 / 异常红点，状态持久化缓存**
  - [x] **仅手动点击「测试连接」或重启应用才重新判定**（不得每次进入页面重测）
  - [x] **测试成功提示区分「内网可达 / 外网可达」**（私有 IP / localhost / .local / .lan / 无点主机名启发式，
        `tst_networkheuristics` 覆盖边界段 172.15/172.32）
  - [x] **浏览页连接源卡片与设置页连接源列表状态实时一致**（`ConnectionStore` 为全局唯一数据源 + 变更广播）
  - [x] **凭据/连接配置持久保存，不因会话过期被清空**（仅删除连接源才清凭据）
  - [ ] 启用/禁用开关 UI（后端 `setEnabled` 已就绪）

---

## 3. 文件浏览与管理（M1）

> 📐 原型：[`prototype/02-browse.html`](prototype/02-browse.html)（网格/列表、搜索框、右键菜单、多选、拖拽上传、四态）

### 3.1 文件浏览（PC-102）

- [x] 浏览首页：连接源卡片列表（类型图标 + 挂载点 + 连接状态绿/红点 + 内外网文案）
- [x] 目录页：顶部操作栏显示**当前目录名**（根目录显示连接名）+ 返回 + 刷新 + 视图切换 + 排序 + ⋯ 菜单
  - [x] 上传按钮（M1）—— 已落地（工具栏按钮 + `Ctrl+U` + 右键/多选栏/整页拖拽，见 §3.2 上传条目）
- [x] 网格视图：类型图标、文件名（居中）、漫画徽标；**目录不显示子项数**；时长位占位（M2 填充）
  - [x] 封面缩略图（PC-702 统一 `CoverImage`；视频抽帧仍待 M2，暂无帧时回落类型图标占位）
- [x] 列表视图：类型图标、文件名、类型/大小；**行间无分割线**；行高较紧凑模式 +1/4
- [x] 排序（名称/大小/时间 + 升降序，目录恒在文件前）
  - [x] **每个目录独立记忆排序偏好**（按「连接 + 目录路径」，上限 500 条 LRU，无记录回落全局默认）
- [x] 搜索框：位于内容区顶部，**仅滚动在顶部时显示**，向下滚动超过搜索框高度才隐藏
      （**迟滞判定防抖动**：隐藏阈值 = 框高、显示阈值 = 8px），带动画；**上下无分割线**
- [x] 刷新：`F5`/`Ctrl+R`/按钮；刷新中旋转指示；**刷新失败保留旧缓存内容并给轻提示**，不得清空列表
- [x] 四态：加载 / 空目录 / 搜索无结果 / 错误
- [x] `DirectoryCache`：目录列表本地缓存，**stale-while-revalidate**（先出缓存秒开，后台刷新覆盖）
  - [x] **刷新前不预删缓存**；**并发刷新改为登记补刷**（不得静默吞掉）
  - [x] **异常响应严禁写入「空目录」缓存**（`verifiedEmpty` 显式标志，单测覆盖）
- [x] **封面缩略图**（PC-702）：`CoverImage.qml` + `CoverService`，浏览页与「正在阅读」页**同组件同缓存**
  - [x] 图片文件直出；MP4 `covr`、ID3v2.2 PIC / v2.3–2.4 APIC、FLAC `PICTURE` 内嵌封面直取
        （`EmbeddedCoverExtractor`，按 head/tail **Range 只读首尾片段**，整文件不下载）
  - [x] 音频无内嵌时回落同目录封面图：同名 > `cover` > `folder` > `front`（大小写不敏感）
  - [x] **异步加载 + 占位先行 + 失败占位 + 内存 LRU(512)/磁盘双缓存 + in-flight 去重 + 全局并发上限 4 + 失败 30s 冷却重试**
  - [x] **封面加载不阻塞点击进入播放/阅读**（读盘/解码/缩放全在 worker 线程，主线程只收信号）
  - [x] 稳定键 `connectionId|normalizedPath` → SHA1 → `thumbnails/<hash>.jpg` + 旁挂 meta（size/modTime 指纹校验）
  - [x] 已缓存封面**同步命中直显**（`cachedCover()`），跨启动有效
  - [ ] 视频抽帧首帧生成缩略图并缓存（本地直读 / 远程经回环代理 Range 抽帧，顺带探测时长）→ M2 解码器就绪后
  - [ ] epub / 漫画（zip）封面提取 → 随阅读器（M3）
- [x] **文件状态指示**：
  - [x] 有阅读记录 → 环形进度（网格角标 / 列表行尾）；目录不显示
        —— `ProgressRepository::briefs(connectionId)` 一次取全源摘要（不逐行 SQL），
        `BrowseDirectoryModel` 新增 `progressPercent` / `progressFinished` 角色，
        网格画在封面右下（左上留收藏星标、右上留类型徽标），列表画在行尾
  - [x] 正在播放 → 文件名主色加粗 + 三竖条均衡器动画
        —— `PlayingBars.qml`（2.5pt 竖条、三根相位错开、暂停即静止）；
        播放器侧新增 `Player.currentPath` / `currentConnectionId`，换文件/关会话即时刷新
  - [x] 优先级：正在播放 > 进度环 > 无标识（`showRing` 与 `playing` 互斥）
  - [x] **多选态下进度环/播放动画与勾选标记并列可见**（不得被顶掉）
        —— 新增 `SelectionTick.qml`（18px，选中主色实心 + 白勾）；网格里勾选标记占右上，
        此时让类型徽标让位，进度环/均衡器分居右下、左下，三者同时可见；
        列表里勾选标记排在行尾角标之后
- [x] **选中/hover 交互**：hover 高亮；选中为「浮起抬升」（内缩圆角高亮 + 轻微放大 + 主色软阴影 + 1pt 细描边，填充 ≤8%），
      **不得贴边直角色块** —— 统一由 `CellPressHighlight.qml` 渲染，各页面不得各写一套
- [x] **文件名行数设置（1~5）即时生效** —— 浏览网格/列表已生效；收藏（M1）与阅读（M3）页接入后即六处齐全
- [x] 类型图标与目录图标**去白底、放大**，仅用图标展示（网格与列表均调整）
- [x] 大目录虚拟化（GridView/ListView 按需渲染 + cacheBuffer）
  - [ ] 万级条目 60fps 实测验证（M5 性能验收）
- [x] 进入连接源恢复上次路径；**重复点击「浏览」导航回到连接源选择页**

### 3.2 文件操作（PC-103 ~ PC-105）

- [x] 上传：系统文件对话框 + **拖拽文件/文件夹进窗口**；多文件顺序队列 + 字节级进度横幅 + 取消
  - 实现：`src/core/transfer/TransferManager`（队列 / 流式分块 / 进度节流 / 取消 / 重试）
        + 适配器 `uploadFile`（Local 1MB 分块读写、WebDAV `put + uploadProgress`）
        + `src/features/transfer/TransferListModel`（`Transfers` 单例，角色快照）
        + `qml/components/TransferBanner.qml`（跨页面常驻的进度 / 取消 / 重试 / 队列展开）
  - 入口：工具栏上传按钮 / 「更多」菜单（文件·文件夹）/ `Ctrl+U` / 右键与多选栏 / 整页拖拽
  - 同名顺延 `name (n).ext` 不覆盖；文件夹递归展开（单批上限 500 个）
  - 验证：`tests/tst_transfer`（10 例）+ `tests/tst_transfermodel`（4 例）
- [x] 新建文件夹（`Ctrl+Shift+N` 或「更多」菜单）/ 重命名（`F2` 或右键菜单）
  - 实现：`src/core/files/FileOperations`（服务）+ `TrashStore`（回收站布局）+ `src/app/FileBridge`（QML 门面）+ `qml/components/InputDialog.qml`
  - 名称就地校验（非法字符 / 同名）失败不关闭对话框
- [x] 移动 / 复制：同源走适配器；**跨源流式中转**（目录递归、边读边写、不落大临时文件）；目标目录选择器（可切连接源 + 新建文件夹）
  - 实现：`src/core/files/FileOperations::moveOrCopy`（顺序队列 / 同名顺延 / 递归 / 取消）
        + `src/core/transfer/RelayStream`（跨源顺序管道：1MB 分块 + 4MB 高水位背压，生产者按需拉取）
        + `StorageAdapter::writeFrom`（Local 分块写、WebDAV `put(QIODevice)` + 显式 Content-Length）
        + `.myhub-part` 中转落盘，完成后 `move` 到最终名（取消/失败即清理，不留半截）
  - 入口：多选栏「移动 / 复制」+ 右键「移动到… / 复制到…」；`qml/components/FolderPickerDialog.qml`（目标源 + 逐级目录 + 新建文件夹 + 进度与取消）
  - 拒绝：移到自身内部；同目录移动=无操作（UI 直接禁用确认）；目标同名绝不覆盖
  - 移动成功后改写阅读记录路径并失效两侧目录缓存
  - 验证：`tests/tst_movecopy`（13 例：管道背压/abort、同源 move/copy/顺延/递归/无操作/自身内部、跨源多分块与目录、无 `.myhub-part` 残留、记录改写、取消无痕）
- [x] **页面内拖拽移动**（按 `Ctrl`/`Option` 复制）
  - 实现：`FileGridCell` / `FileListRow` 在既有 MouseArea 上接管拖拽（`drag.target` 指向页面占位项，
        保住 `keepMouseGrab` 不被 GridView/ListView 当成滚动手势抢走；阈值 8px，未越阈值仍算点击）
  - 命中判定：窗口坐标回传页面 → 委托矩形逐个 `mapFromItem` 比对（不依赖 `indexAt` 的坐标系约定）；
        文件 / 自身 / 自身子目录 / 当前目录一律不算可落点
  - 反馈：跟随光标的胶囊（「移动 3 项到「xxx」」/「复制…」，无落点时转灰）+ 目标文件夹主色细环；
        拖未选中项先把它变成唯一选中，拖已选中项则整组一起走
  - 落地：同一连接源直接调 `FileOperations::moveOrCopy`（不走选择器），成功后源侧就地移除、目标侧按 `transferred` 校正
- [x] 下载：下载到默认下载目录 / 另存为；完成后「在资源管理器·访达中显示」
  - 默认落点 `<下载>/MyHub/<连接名>/<远端路径>`；另存为走系统保存对话框
  - `.myhub-part` 断点续传（失败保留半截文件、取消则清理）；失败可原地重试
  - 文件夹暂不支持直接下载（需进入目录后选择文件），横幅与对话框都给明确中文原因；
    「在文件夹中显示」由 `FileBridge::revealInFolder` 打开所在目录
- [x] **txt 在线编辑并保存回源**（沿用原编码，不可表示时回退 UTF-8）
  - 编码：`src/core/text/TextCodec` 检测 BOM / 无 BOM UTF-16 / UTF-8 / GB18030 / Big5（严格 UTF-8 优先，
    双字节族按解码成功性 + 常用字命中率 + 尾随 ASCII 比例择优）；Qt 未带 ICU，故 Windows 走
    `WideCharToMultiByte`（CP54936 / 950）、macOS 走 CoreFoundation 转码
  - **回写纪律**：保存沿用打开时的编码；原编码表示不了新字符 → 回退 UTF-8 并如实告知（`fellBackToUtf8`），
    绝不写问号、不静默丢字；判断用「编码后回读比对」（Windows 的 `lpUsedDefaultChar` 对 CP54936 不可靠）
  - 体积：读/写上限 8MB，超过**直接报失败**而不是截断
  - 落地：`FileOperations::loadText/saveText` → `FileBridge::loadText/saveText`；双击纯文本或右键「编辑文本」进
    `qml/components/TextEditorDialog.qml`（加载态 / 编码徽标 / 脏标记 / Ctrl+S / Esc 与关闭时未保存确认 / 保存后刷新行元信息）
  - 验证：`tests/tst_textcodec`（各编码检测、BOM 保留、GB18030/Big5 往返、不可表示回退 UTF-8、空文件）
- [x] 多选操作栏：移动 / 复制 / 下载 / 收藏 / 重命名 / 删除（全量落地：已选计数 / 移动 / 复制 / 下载 / 收藏·取消收藏 / 重命名 / 删除 / 取消）
  - [x] **按钮不超出窗口；图标与文字对齐（固定槽高，图标视觉体量一致）**
        —— 合计 7 个按钮后窄窗会溢出，故加了 `compactBar`（<820 收成纯图标 + ToolTip）
  - [x] 批量收藏：**全部已收藏**时按钮变「取消收藏」，混合态按「收藏」补齐未收藏项（不做逐条 toggle）
  - [ ] **进入多选模式时隐藏底部播放条与导航，操作栏落到底部**；退出多选恢复（已接 `PlayerStage.selectionActive`，待随播放条一起验收）
- [ ] 右键上下文菜单（**「多选」置于首位**）：打开 / 以小说阅读器打开 / 以漫画阅读器打开 / 纯文本查看 / 属性 / 收藏 / 重命名 / 移动 / 复制 / 下载 / 定位到原路径 / 删除（已落地：多选 / 打开 / 编辑文本 / 以纯文本查看 / 收藏·取消收藏 / 下载 / 另存为 / 属性 / 重命名 / 移动到… / 复制到… / 删除；「以小说/漫画阅读器打开」待 M3）
- [x] **操作成功后本地立即更新列表并同步目录缓存**（不依赖网络刷新，弱网下界面依然正确；`applyCreated/applyRenamed/applyRemoved`，移动/复制经 `transferred` 源侧就地移除）
- [x] **文件操作联动阅读记录**：删除 → 记录同步删除；重命名/同源移动 → 记录同步改写（跨连接源移动的记录迁移待补）

### 3.3 回收站与收藏（PC-106 / PC-107）

- [x] 删除入回收站：挂载点下 `.trash` + `<name>.meta.json`（原路径 + 删除时间 + 连接源）；同名冲突顺延 `name (n).ext`；并入 `TrashStore`（`/.trash` 布局唯一来源）
- [x] 回收站页：列表、还原（冲突自动追加序号）、彻底删除、清空、过期自动清理（默认 30 天，进页即静默清理）
  - 实现：`src/features/trash/TrashModel`（跨连接源聚合的三层异步扫描 + 信号驱动就地增删）+ `qml/settings/TrashSection.qml`（列表 / 保留期滑块 / 彻底删除·清空·错误三个确认框）
  - **元数据丢失的条目不可还原**（不猜原路径，只允许彻底删除）；原目录已不存在时还原前自动重建
  - 验证：`tests/tst_trash`（6 例：还原、同名顺延不覆盖、重建父目录、拒绝无 meta、单条彻底删除、清空全部）
- [ ] 不支持回收站时降级真实删除（二次确认 + **展示移动失败的具体原因**）（已先落地：适配器不支持回收站时明确报「该连接源暂不支持回收站」并中止，不做静默真删）
- [ ] **占用处理**：删除前若待删项正在播放/阅读，先停播并等待串流会话注销（最长 1s）；彻底删除前兜底再释放一次
- [x] **占用/瞬时错误自动退避重试 2 次**（0.6s / 1.2s）
- [x] **失败提示携带具体原因**（首错原因 + 未完成项清单，避免部分成功后重复删）／「稍后重试」文案建议待补
- [ ] **回收站降级真删只针对未成功的剩余项**（不得对已移走文件重复删除而误报失败）
- [x] 收藏：星标/取消；收藏页（网格/列表切换，封面与浏览页一致）；点击进入对应播放器/阅读器，文件夹跳浏览页定位
  - 实现：`src/core/favorites/FavoriteRepository`（`favorite` 表唯一数据源，`(connectionID, filePath)` 唯一；重复收藏只刷新类型/大小、不刷新收藏时间）+ `src/features/favorites/FavoriteListModel`（收藏页行数据，监听信号就地增删）+ `qml/favorites/FavoritesHome.qml`（网格/列表 / 空态 / 右键打开·定位·取消收藏·属性）
  - 打开：目录 → 浏览页定位到该目录；影音（本地源）→ 播放器续播；远程源流播与阅读器（M3）暂未接入时统一「去浏览页定位」，连接源已删除的条目明确提示而非静默丢
  - 联动：删除/移动/重命名文件时收藏同步清理与改写（与阅读进度同一套纪律）；连接源删除时数据库外键 CASCADE 清掉其收藏
  - 验证：`tests/tst_favorite`（9 例：落库查回、重复收藏唯一性与时间保持、切换、单条删除、缺失键无副作用、子树清理、目录/文件改名改写、键集、徽标反查）
- [x] **收藏与浏览页星标双向实时同步**（全局唯一数据源 + 变更广播，启动预载）
  - `Favorites` 单例缓存「是否收藏」键集（委托逐格判定不打 SQL），任何写入都经仓库信号回到单例 → `revision` 自增 → 浏览页星标（网格左上角/列表行内）与收藏页同时重算
  - 启动预载挂在 `AppState` 数据库就绪之后（冷启动首屏星标即正确）；连接源变动后重建键集（对齐外键级联删除）
  - 浏览页「收藏/取消收藏」在右键菜单，按当前状态显示文案

### 3.4 纯文本 / 图片 / 属性 / 定位（PC-108 ~ PC-110）

- [ ] **纯文本查看器**（独立界面，区别于小说阅读器）
  - [ ] 编码检测 UTF-8 / GBK·GB18030 / Big5 / UTF-16 LE·BE
  - [ ] **大文件懒加载分段渲染**（不卡死、不 CPU 飙高）
  - [ ] 文本可选中复制、`Ctrl+F` 查找、字号调节；**内容不与标题栏重叠**
  - [ ] **不计入阅读记录、不建索引**
- [x] **文本编辑器**：编辑并保存回源（已在 §3.2 落地 `TextEditorDialog`，此处为重复条目）
- [x] **不支持预览的文件**：双击弹出菜单提供「以纯文本查看」入口（菜单在鼠标位置，不偏移）
  - 实现：单元格双击把 `mapToGlobal` 的窗口坐标带给页面（`openItem(index, wx, wy)`），
    不支持的类型不再只弹「暂未实现」，就地弹 `PopupMenu`：以纯文本查看 / 属性
  - 「以纯文本查看」走 `TextEditorDialog` 的**只读模式**（`openFor(..., readOnly=true)`：不显示保存、Ctrl+S 失效、
    不回写源文件），编码检测与 8MB 上限复用既有实现
  - 右键菜单同步补了「以纯文本查看」（对任意文件可用）
  - 注：`纯文本查看器`（上一项，独立界面 / 大文件分段 / Ctrl+F / 字号）仍未做，届时该入口改为切页而非弹窗
- [ ] **图片预览器**（独立于漫画阅读器）：`←/→`、滚轮、浮动按钮、点击左右分区切换；`Ctrl+滚轮`/双击缩放；旋转；拖拽平移；复制 / 另存为
  - [ ] **仅加载当前页与相邻页，翻页离开即取消下载，取消不得误报加载失败**
- [x] **文件属性面板**：标题 / 连接源 / 完整路径 / 类型 / 现场 stat 大小与修改时间 / 阅读进度 / 复制路径
  - 实现：`FileOperations::inspect`（现场 `stat` + 阅读进度 + 徽标，发 `inspected`/`inspectFailed`）→
    `FileBridge::requestProperties`（补齐连接源名称/类型，`copyToClipboard`）→
    `qml/components/FilePropertiesDialog.qml`（加载态 / 读取失败态 / 行式字段 / 复制路径反馈 / 收藏状态 / 定位入口）
  - **不复用目录缓存的行数据**：大小与修改时间必须是此刻的真实值；条目已被删除时明确报错，不显示「看起来正常」的旧值
  - 三处共用同一实现：浏览页右键「属性」、收藏页、正在阅读页（原来各写一套确认框文案，已统一）
  - 验证：`tests/tst_fileoperations::inspectReportsLiveStatAndProgress`（现场大小、进度字段、未读不伪造进度、缺条目失败）
- [x] **定位到原路径**（PC-109）：切模块 → 重建导航栈直达父目录 → **滚动定位居中** → **呼吸灯高亮约 10s 后淡出**
  - [x] 目标被搜索过滤时先清空搜索；目录加载中分阶段重试定位；同一文件重复定位可重新触发（唯一 token）
  - 实现：`BrowseController::reveal(connectionId, filePath, isDir)`（目录定位自身 / 文件定位父目录，`token` 自增，
  `revealRequest` 广播 + `clearReveal`）→ `BrowseDirectory` 收到后切模块、清搜索、`indexOfPath` 找行、
  `positionViewAtIndex(…, Center)` 居中、`RevealHalo.qml` 呼吸 10s 后淡出；加载中按状态信号续试，行未到齐短延迟重试（≤6 次）后给轻提示
  - 入口：收藏页右键「在浏览页中定位」、正在阅读页右键「在浏览页中定位」、属性面板「定位」按钮

---

## 4. 播放内核（PC-201 / 202 / 203，M2）

> 📐 原型：[`prototype/03-player.html`](prototype/03-player.html)（控制层、键鼠反馈、锁定、纯音频、mini 条、悬浮小窗、系统媒体集成）

### 4.1 引擎与路由

- [x] `PlayerCore` 统一门面：播放/暂停/seek/倍速 0.5~3.0x/音量/亮度/音轨/字幕/纯音频/状态与时间发布
  - [x] 进度上报：播放中节流 5s + 暂停/seek/结束/退出强制上报
        —— `PlaybackProgressTracker` 是**唯一写入点**（随门面存活），退出顺序被固化在 `main.cpp`：
        先 `PlayerBridge::flushPendingProgress()` 再 `AppState::shutdown()`，顺序颠倒即丢最后一次进度
  - [x] `PlaybackRequest.startAt` 引擎层一次性精准 seek
  - [x] **播放完成后再次点击播放从头重播**（`state == ended` 时先 seek 0 并复位 finished）
- [x] `PlaybackEngine` 接口 + `MpvEngine`（libmpv 主引擎，硬解优先/软解兜底）+ `VlcEngine`（兜底引擎，接口预留，可二期实现）
- [x] **视频渲染接入**：`MpvVideoItem`（mpvqt 的 `QQuickFramebufferObject` 派生），视频作为普通 Item 参与场景图
  - [x] 渲染后端固定 **OpenGL**（S1 实测：mpvqt 仅支持 OpenGL，Windows 默认 D3D11 下 100% 黑屏）
  - [ ] **多实例共存**：全屏主画面 + mini 条预览 + 悬浮小窗，同一会话不重载
  - [x] 渲染线程与 GUI 线程分离，不阻塞 UI（画面在场景图渲染线程出帧）
  - [x] **mpvqt 必须与构建配置同源**：Debug 应用要用 `mpvqt-install-debug`（`build-mpvqt.ps1 -Config Debug`），
        否则 Release 版 `MpvQt.dll` 把第二套 Qt 运行时（`Qt6Core/Qt6Quick`）拉进进程，
        首次 `new MpvVideoItem` 即在 `QQuickFramebufferObject` 基类构造中 SIGSEGV（无任何日志）
- [x] `DecodeRouter`（硬解/软解路由）：用户偏好强制 > 扩展名集合 > 本地魔数探测（200 字节一次同步读）
  - [x] 强制语义：`software` → `hwdec=no`、`hardware` → `hwdec=auto`，**运行期不得自动改判**
  - [x] 已知无硬解/硬解不可靠的容器起播即软解（rm·rmvb / avi / flv / wmv·asf / vob·mpg / ogg / 3gp），省掉一次重载
  - [x] 本地魔数识别 mkv·webm / mp4·mov / avi / flv / ts / ps / rm / asf / ogg；远程源只按扩展名（不引入网络探测）
- [ ] 主引擎起播失败 → **自动回退兜底引擎**（`VlcEngine` 二期实现）；当前兜底为 mpv 自身软解
- [x] **「有视频轨但无音频轨」异常组合检测 → 自动回退软解**（修复 DTS/TrueHD/E-AC-3 等「有画面无声」）
  - [x] 强制硬解时不自动改判，但记录可操作提示（设置 → 播放器 → 自动）
- [x] **缓冲恢复后状态切回播放中**（不得残留加载菊花）
- [x] 设置可强制硬解/软解（`player.decodePreference`）

### 4.2 边下边播缓存

- [x] `LocalStreamProxy`：127.0.0.1 HTTP 回环服务，`/stream/<id>/<fileName>`，GET/HEAD + Range/206，随机端口
  - [x] **健康探活**（非阻塞 connect + poll，超时 300ms）与僵尸监听重建换端口
        —— `setHealthTimeoutMs()` 供测试收紧；换端口后 `listenerRebuilt(old,new)` 逐会话重签 URL
  - [x] `healthSnapshot()` 诊断
- [x] `AdapterRangeDataSource`：WebDAV Range / SMB 分块统一为可 Range 数据源
  - [x] **停滞超时看门狗**（15s 内持续收到数据就不超时）
  - [x] **断点续传**（超时/中断保留已下载字节、从断点续拉，**严禁整块作废重下**）
  - [x] 连续零进展才退避重试，并触发地址锁定失效（`invalidateRoute`）
- [x] `SegmentCache`：1MB 分片磁盘缓存 + LRU + 总容量上限 + 单文件上限（总量 1/4，淘汰最远分片）
  - [x] 缓存键含**文件指纹**（size+modTime 变更自动失效）；断点续播复用已持久化分片
  - [x] `cachedIdentity` 离线反查（stat 失败时以缓存身份起播）
        —— 正常起播即写 `meta.json`（connectionId/path/name/size/fingerprint）；
        `PlaybackStreamService::prepareOffline()` 凭它重建会话，只放行**缓存完整**的文件
        （`segmentCount()` 与 `ceil(size/segmentBytes)` 对齐），半截缓存起播前明确报错；
        `PlayerBridge::openRemote()` 在 stat 失败 / 适配器缺失时兜底走这条路
- [x] `CachedRangeReader`：分片装配 + in-flight 去重 + **低优先级预读窗口**（由 `preloadSeconds` 换算）+ 并发信号量
  - [x] **会话注销时置取消标记**，阻断排队中的预取任务与去重器后续请求（避免连续切换视频后残留请求拖慢新视频）
  - [x] `offlineMode`：未命中区间快速失败不重试不预取
        —— 离线会话以 `CachedRangeReader(nullptr, cache, key)` + `setDeclaredSize()` 装配，
        `read()` 未命中整段区间直接回 `Offline` 错误，`ensureJob()` 在离线态不排任务
- [x] 解码器侧前向缓冲时长配置（抗抖动）
      —— `MpvEngine::configureForLoad()` 按 `player.preloadSeconds` 同源下发
      `cache-secs` / `demuxer-readahead-secs` / `demuxer-max-bytes`（4MB/s 估算，夹 32~512MiB）
- [x] **精准续播：历史进度直接从历史位置起播，无「先 0 后跳」**
      —— `openLocalFile(startMs < 0)` 查 `readingProgress` 取 `resumePositionMs()`，
      起播点经 mpv `start` 属性下发（本地文件已实测：60s → 起播即 60s）
- [x] ⚠️ **mpv `start` 下发纪律（已踩坑，勿回退）**：必须 `set_property "start" <字符串秒>`
      且**在 `loadfile` 之前**；写 double 会静默返回 `-11 PROPERTY_ERROR`（表现为从 0 起播），
      用 `loadfile <url> replace start=60` 文件局部选项会返回 `-4 INVALID_PARAMETER`（文件根本不加载）
- [x] 播放失败若为「回环连接被拒」→ **换端口重试一次**再考虑回退引擎
      —— `PlayerBridge::openRemote` 起播报错且挂着远程会话时调一次 `verifyHealth()`，
      监听僵死 → 换端口 → `streamUrlRebuilt` 按新 URL + 当前进度重开；只重试一次
- [x] `PlaybackSourceResolver`：条目 → 播放请求（本地 file / 远程注册代理 / 离线缓存兜底 / 历史 startAt）
      —— 未拆独立类，职责落在 `PlayerBridge::openRemote(connectionId, path, title, size, fingerprint, startMs)`：
      缺 `size` 时补一次 `stat`，再向 `PlaybackStreamService` 注册会话拿到回环 URL，
      进度与历史 `startAt` 沿用 §4.1 的 `beginRequest()` 单一路径

### 4.3 播放 UI 与键鼠控制

- [x] `PlayerView` + `PlayerControls`：沉浸纯黑、顶栏（退出 / 悬浮小窗 / 音量 / 音轨 / 更多：纯音频·解码方式·截取当前帧）、底栏（进度条含缓冲段 / 倍速 / 时间 / 快退快进 / 播放暂停 / 字幕）
  - [x] 控制层 3s 自动隐藏（播放中），**鼠标移动或点击立刻显示**（不得延迟）
  - [x] **中央加载圈与大播放键互斥不重叠**；**暂停/播放图标方向正确**
  - [ ] **不同分辨率（含竖屏）视频正确适配显示比例**
  - [x] **点击进度条任意位置立即跳到目标位置**；未缓冲时播放按钮显示加载指示（不得回退原位置、不得显示暂停图标）
  - [x] 播放完成时中央显示**「重播」按钮**
- [ ] 键鼠控制层（按《需求分析文档》§8.5）：
  - [x] `Space/K` 播放暂停、`←/→` 快退快进（步长可配）、`Shift+←/→` 精细 5s
  - [x] `↑/↓` 与滚轮调音量（步进可配）、`M` 静音
  - [x] `Shift+↑/↓` 或控制栏滑杆调**窗口内亮度蒙层**（与小说/漫画共用同一偏好）
  - [x] `[`/`]` 步进倍速（±0.25x，夹在 0.5~3.0x）
  - [x] **按住 `→` 或按住右键 2x 倍速，松开恢复**（不改用户默认倍速；播放器收起时强制还原）
  - [x] `F` / 双击全屏、`Esc` 退出、`S` 字幕、`A` 音轨、`L` 锁定
  - [x] `Ctrl+M` 在完整播放与 mini 条之间切换
  - [x] `Ctrl+P` 悬浮小窗（见 §4.4）
  - [x] **调节时中央悬浮胶囊显示数值**（目标时间/总时长、音量%、亮度%、倍速、±秒），0.8s 自动隐去
- [x] **界面锁定**：锁定后屏蔽交互；中央显示锁图标并自动消失；点击画面重新显示锁图标，点击锁图标解锁
- [x] `AudioCoverView`：唱片封面旋转（播放转/暂停冻结）、封面来源（同目录同名图/cover/folder/front → ID3 内嵌 → 占位）、「作者 - 标题」文件名解析
  - [x] 封面走 `CoverImage` → `CoverService`（优先级已在其内部实现，含 mp3/flac/m4a 内嵌），圆形裁切 + 中心轴孔
  - [x] 旋转用 `RotationAnimator`（16s/圈），`running` 绑 `Player.state === Playing`，暂停保留当前角度继续
  - [x] 「作者 - 标题」解析抽成 `core/utils/TrackName`（半角/en dash/em dash/全角、音轨号、`AC-DC` 不误切），
        经 `Player.mediaArtist` / `Player.mediaTitle` 暴露；解析不出作者时副标题退回「纯音频模式」
  - [x] mini 条音频位改用同一个 `CoverImage`（§4.4 同源同缓存那条一并解掉），描边由外层补
- [x] **纯音频播放模式**（视频可切仅音频：关闭画面解码；音频文件与 `audioOnlyByDefault` 自动进入；控制栏一键切换）
  - [x] **纯音频模式下仍可访问窗口/全屏控制**（不得因切音频而丢失控制入口）
- [x] `SubtitleManager`：内嵌轨选择 + 外挂 srt/ass/ssa **同目录同名自动匹配**（含 `name.zh.srt` 语言后缀，精确同名优先，启动自动加载）+ 字号/延迟可调 + 双引擎统一渲染
  - [x] **手动加载外部字幕文件**（菜单选择 + 拖拽字幕进播放窗口）
  - [x] **同目录同名自动匹配**：`core/player/SubtitleMatcher`（纯逻辑，有单测）——
        `影片.srt` 100 分 > `影片.zh.srt` 90 > `影片.en.srt` 80；
        `影片2.srt` / `影片-加长版.srt` **明确不认**（错配比不配更糟）；
        起播后 `PlayerBridge::autoAttachSubtitle()` 在 `subtitleTracksChanged`（文件已加载）时触发，
        本地走 `QDir`、远程走适配器 `list` + **回环代流**（mpv 不认 smb://），
        字幕会话随主会话在 `releaseStreamSession()` 一并注销；
        已有 external 轨则跳过，不叠加、换端口重开不重复
  - [x] **字号 / 延迟可调且即时生效**：`PlaybackEngine::setSubtitleStyle(fontSize, delaySeconds)`
        → `MpvEngine` 直接 set `sub-font-size`（夹 8~64）/ `sub-delay`（夹 ±30s）；
        `Player.setSubtitleFontSize()` / `Player.setSubtitleDelay()` 写设置并立刻下发，
        字幕菜单里 ±0.5s 微调 + 点击归零，设置页滑杆同样即时
  - [x] **统一渲染**：内嵌与外挂都交给 mpv 的 `sid` / `sub-add` 走同一条渲染管线；
        `PlaybackEngine` 接口已抽象，将来接 libVLC 兜底时字幕不用改调用方
- [x] 多音轨切换（菜单 + `A` 键循环；≤1 轨时隐藏音轨入口）
- [x] 截图 / 截取当前帧（P2）
  - [x] 入口：「更多」菜单「截取当前帧」+ `Ctrl+S`（放在锁定态判定之前，锁屏时也能截）
  - [x] `PlayerCore::saveScreenshot()` 只做**策略**：无会话 / 纯音频 / 无视频轨直接回
        `screenshotFailed`，不惊动引擎；有画面才生成路径下发
  - [x] 落盘路径 `core/utils/ScreenshotPath`：`图片/MyHub/<标题>_yyyy-MM-dd_HH-mm-ss.png`，
        净化 Windows 九个非法字符 + 裁剪尾随点/空格 + 同秒重名自动 `-2`/`-3`；
        系统取不到「图片」目录时退回 `AppData/MyHub/screenshots`
  - [x] 引擎侧 `screenshot-to-file <path> subtitles`：选 `subtitles` 而非 `window` ——
        `window` 要读窗口像素，libmpv 渲染 API 下不可用；`subtitles` 从解码帧出发，
        原生分辨率、带字幕不带 OSD。同时固定 `screenshot-format=png`（与扩展名一致）、
        `screenshot-sw=yes`（硬解帧不在 mpv 可读位置时由它把帧取回来）
  - [x] 结果回执：`screenshotSaved(path)` / `screenshotFailed(reason)` 一路透传到
        `Player` 门面，QML 用中央胶囊提示（成功「截图已保存」，失败显示具体原因）
  - [x] 实测（临时探针 + 真实片源，验证后已移除）：`sample.mp4` → 1280×720(302KB)、
        `hevc_1080p.mkv` → 1920×1080(765KB)，平均亮度 125.8（非黑帧）✅
  - 单测 `tst_screenshotpath`：非法字符 / 连续字符折叠 / 尾随点空格 / 空标题兜底 /
        时间戳命名 / 同秒去重 / 不擅自建目录 / 默认目录落在 Pictures
- [x] 进度自动上报 + 打开自动恢复（已在 §4.1 落地：`PlaybackProgressTracker` 定时落库 + 起播跳转续播位；此处为重复条目）

### 4.4 mini 播放条与悬浮小窗（PC-603）

- [x] `MiniPlayer`：主窗口底部常驻播放条，跨页面保持；封面/实时画面预览 + 标题 + 进度细条 + 播放暂停 + 关闭
  - [x] **深/浅色均加细边框**，与底部装饰统一描边色
  - [x] **音频无封面占位块必须不透明**（不得透出边框/背景）
  - [x] **mini 音频封面与全屏、系统媒体信息同源同缓存**（mini 与全屏都用 `CoverImage` → `CoverService`；
        系统媒体信息在 §4.5 接 SMTC 时复用同一 `TrackName` 解析与封面路径）
  - [x] 点击展开全屏（**复用同一会话不重载**）；关闭按钮停止播放
  - [x] **从浏览页/收藏页/阅读页再次点击正在 mini 播放的同一文件 → 回到完整播放**（新起会话即回 full；已播完从头重播待 §4.6 一起收）
  - [x] **进入多选模式时与底部导航一起隐藏**，退出多选恢复
- [x] **置顶悬浮小窗**（替代画中画）：always-on-top，无边框圆角，可拖动/缩放/记忆尺寸
  - [x] **实现方式是「主窗口变身」而非另开窗口** —— 见下方渲染面纪律：全进程只有一个
        `MpvVideoItem`，搬进第二个窗口必然销毁重建渲染节点。所以
        `WindowController::enterFloating()` 把主窗口改成
        `Window | FramelessWindowHint | WindowStaysOnTopHint`、缩到小窗尺寸并记住还原点
        （几何 / 最大化 / 原 flags），`exitFloating()` 原样还原；位置默认贴屏右下角 24px，
        尺寸记忆在 `window.floatingSize`（下限 320x180）—— mpvqt 的 `MpvRenderer` 析构会
        `freeContext()`、新场景图里重建 context，因此会话不中断（实测进入/还原窗口矩形正确、
        `Player.state` 全程保持 Playing、无 vo 报错）
  - [x] 小窗内控制集：播放暂停 / 进度（复用 `PlayerProgressBar`）/ 音量（点击静音 + 滚轮）/
        关闭 / 还原（`FloatingPlayerOverlay`）；单击画面暂停、双击或 `Esc` 还原、`空格` 暂停
  - [x] **复用同一播放会话，不重载不丢进度**（只切窗口形态与 `PlayerStage.mode`）
  - [x] 控制带显隐：鼠标进入小窗即显示、移出即收起，暂停时保持常显
        （`HoverHandler` 驱动，**不要改回 QML `Timer` 延时隐去** —— 改过窗口 flags 之后
        QML 侧 `Timer` 在本机实测不再回调，C++ `QTimer` 正常，用 Timer 会让控制条永不隐）
  - [x] 无边框窗口自己实现系统交互：顶部 30px 拖动条 → `startSystemMove()`，
        四边 5px 热区 → `startSystemResize()`；小窗时窗口底色强制纯黑（比例不符时露黑边）
  - [x] 设置项「最小化主窗口时进入悬浮小窗」**默认关闭**、**运行期立即生效**
        （`Main.qml` 在 `visibilityChanged` 时读 `WindowController.minimizeToFloating` 当前值）；
        顶栏 `pip` 按钮与 `Ctrl+P` 不受开关影响
  - [x] 小窗时退出播放（改为 Idle）自动还原主窗口，不留一个空白小窗
  - [x] 修掉小窗状态退出应用会把 480x270 当成主窗口尺寸存进 `window.bounds` 的坑
- [x] 退出按钮为**直接退出播放器**（不进 mini）；单独提供「进入 mini」按钮（顶部栏 minimize + `Ctrl+M`）
- [x] 底部装饰间距统一：播放条 / 工具栏 / 多选操作栏互不遮挡、不相贴

> ⚠️ **渲染面纪律（已踩坑，勿回退）**：全进程只有一个 `MpvVideoItem`，由 `PlayerVideoLayer`
> （`qml/player/PlayerVideoLayer.qml`，z 490）**一次性**认领后就不再动 —— 不 `setParentItem`、
> 不翻 `visible`、不缩到 0 尺寸。mpv 的 render context 绑在场景图渲染节点上，重挂载/隐藏都会销毁
> 重建它，实测导致「切回全屏黑屏」与渲染线程死锁；0 尺寸会让 mpv 渲染到 FBO 0（糊满窗口）。
> 全屏 ↔ mini 只改这一层的几何。另外 `AppState` 的构造函数**不得可默认构造**（否则 Qt 6.8 的
> `singletonConstructionMode()` 会绕过 `create()` 工厂直接 `new`，QML 与 `main()` 拿到两个实例，
> 表现为启动 Loading 永不消失）。

### 4.5 系统媒体集成（PC-602）

- [x] Windows SMTC：标题/作者/封面/时长/进度/速率，播放暂停、上/下一个、快进快退、拖动定位
  - [x] 平台中立层 `platform/media/MediaControls.h`：`MediaSnapshot`（会话态快照）+ `MediaCallbacks`
        （播放语义，不是按键枚举）+ `createMediaControls()` 工厂；app 层 `app/MediaSession` 单例
        把 `PlayerCore` / `CoverService` 的状态聚合成快照下发，两个后端共用同一份驱动逻辑
  - [x] `SystemMediaTransportControlsInterop::GetForWindow` 绑根窗口 HWND —— 必须**等窗口建好**
        再 attach（`main.cpp` 里 `show()` 之后），否则拿不到 interop 工厂
  - [x] 接口 IID 用 `winrt::guid_of<winrt::Windows::Media::ISystemMediaTransportControls>()`，
        **不能用 `__uuidof`**：SDK 10.0.26100 的 ABI 头不带 `windows.media.h`，`__uuidof` 直接编不过
  - [x] `ButtonPressed` / `PlaybackPositionChangeRequested` / `PlaybackRateChangeRequested` 三个事件
        全部 `QMetaObject::invokeMethod(..., Qt::QueuedConnection)` 排回 GUI 线程再动播放器
        （回调由系统后台线程触发，直接调 `PlayerCore` 会跨线程碰 mpv）
  - [x] `apply()` 外裹 `try/catch (winrt::hresult_error)` 且只告警一次：系统面板是增强项，
        一次元数据设置失败不得冒泡到 Qt 事件循环把播放器带走
  - [x] 标题/作者复用 `TrackName::parse`、封面复用 `CoverService`（与 mini 条、全屏同一份缓存，不额外请求）
  - [x] 时间轴 1s 节流（位置事件 250ms 一次，全推会把面板刷成幻灯）；状态变化不节流
  - [x] 会话结束（Idle）时 `IsEnabled(false)` + `DisplayUpdater().ClearAll()`，不留点不动的幽灵条目
  - [x] 实测（PowerShell 侧 `GlobalSystemMediaTransportControlsSessionManager` 读取）：
        `APPID: MyHub.exe`、`TITLE` 为音轨名、`STATUS: Playing`、`TIME: 22.7/40` ✅
  - [ ] 上/下一个：SMTC 侧按钮已注册但**禁用**，等 §4.6 的「推荐上/下一个」落地后再接语义
- [ ] macOS MPNowPlayingInfoCenter + 远程命令
  - 代码已落地 `platform/macos/MacMediaControls.mm`（`MPNowPlayingInfoCenter` 元数据 + 时间轴、
    `MPRemoteCommandCenter` 的 play/pause/toggle/next/prev/seek 命令、`MPNowPlayingInfoPropertyPlaybackRate`
    同步速率；CMake 单独加 `-fobjc-arc`、链 `-framework MediaPlayer`）
  - **未在 macOS 实机编译验证**（本机是 Windows），保留未勾选直到 CI/Mac 上跑通
- [x] 媒体键（Play/Pause/Next/Prev）全局响应
  - 走 SMTC 的 `ButtonPressed` 统一入口（系统媒体键就是路由到会话的 ButtonPressed），未额外注册全局热键
  - ⚠️ **自动化验证未成功**：`keybd_event(VK_MEDIA_PLAY_PAUSE, 0x45, KEYEVENTF_EXTENDEDKEY)`
    未观察到 Pause（日志 status 一直是 Playing），合成按键疑似不被 shell 转发给 SMTC。
    需要**真人按键 / 点系统面板**复验；代码路径本身与面板点击同一条
- [ ] 最小化/托盘常驻时继续播放音频
  - 音频续播本身没问题（§4.4 的悬浮小窗即最小化后继续播），但**托盘图标/托盘常驻**还没做，
    该项与托盘功能一起收
- [ ] 音频输出设备变化（拔耳机/切设备）时的播放状态处理
  - **结论：不做主动兜底**。实测 mpv 的 `audio-out-detected-device` 在 `onFileLoaded()` 时刻
    返回空串（`detected-device='' audio-tracks=1`），据此判断「音频输出丢失」会把正常播放误判成故障、
    触发无谓的 seek 重载；mpv 的 ao 自身会跟随系统默认设备切换。已回滚整套观察 + 延时重载代码
  - 若日后要补，判据必须换成「`audio-tracks > 0` 且 `ao` 已建立后 `detected-device` 变空」，
    不能在文件加载早期采样

### 4.6 连续播放推荐（PC-204）

- [ ] 播完查同目录同类型下一个（**按该目录的排序偏好**），底部弹出提示条
- [ ] **无倒计时、不自动播放**，需用户点击；可取消；切新项/重播自动撤销

---

## 5. 小说阅读（PC-205 / PC-206 / PC-210，M3）

> 📐 原型：[`prototype/04-readers.html`](prototype/04-readers.html) §1 §2 §4（翻页/滚动、目录抽屉、设置面板、纯文本阅读器）

- [ ] `TxtIndexer`：流式读取 + **字节级行扫描**分章（记录章节标题全局字节偏移，精确无漂移），按章 Range 加载不整本读入
- [ ] `ChapterRuleTable` 分章规则引擎：数据驱动多规则（「第 x 章/节/回/卷」「Chapter n」「楔子/序章/尾声/番外」）+ 首字符预筛 + **「选最优规则而非并集」校验**（条数/间隔/章长/重复度）+ 命中 ruleID 写入索引
  - [ ] **必须能正确识别第一章**（不得从第二章开始）
- [ ] **编码检测**：BOM + 启发式，覆盖 UTF-8 / GBK·GB18030 / Big5 / **UTF-16 LE·BE**；Range 切块**码元对齐**；旧缓存编码复核自愈（替换符占比异常则重建）
- [ ] 索引存库（`novelIndex`，可重建缓存）+ **文件指纹校验**（size + modTime）
- [ ] `EpubBook`：**Range 解包不整包下载**；container.xml → OPF manifest/spine → NAV(EPUB3)/NCX(EPUB2) 目录；章节 XHTML → 段落流；封面提取缓存
- [ ] **epub 图集型（漫画）判定** → 提示并一键转交漫画阅读器
- [ ] 排版：**`QTextLayout` 行级分页**（`createLine()` 按行边界切页不截断行，对应 iOS CoreText `CTLine` 方案）+ 标题放大加粗 + 插图等比嵌入；滚动模式为同分页结果的连续页块 + **页内行映射**（`QTextLine::textStart()/textLength()`）供精确锚点
  - [ ] **调整字号/行距不得卡死或 CPU 飙高**（增量重排 + 页缓存 + 排版放 worker 线程）
- [ ] 章节 ±1 预加载（LRU）
- [ ] 阅读器设置面板：字号 / 行距 / 主题（跟随系统·日间·夜间·护眼）/ 翻页·滚动模式 / **亮度（窗口蒙层）** / 衬线字体（思源宋体，未内置回退系统宋体）；实时生效并持久化
- [ ] 目录抽屉（当前章高亮跳转）
- [ ] 底栏：页码 / 全书百分比进度条 / 上一章 / 下一章；3s 节流 + 切章/退出强制上报并广播
- [ ] **进度恢复：排版无关锚点一步定位**
  - [ ] 锚点结构：章序 + 章标题 + 段落序 + 段内字符偏移（UTF-16 计数）+ 章内偏移 + **后续文本片段重定位兜底** + 百分比兜底 + 文件指纹
  - [ ] **禁止「先跳章节再定位偏移」两步时序**
  - [ ] 兼容 iOS 旧版纯字节偏移锚点
  - [ ] 文件指纹不匹配时提示并重建索引/归零
  - [ ] **锚点正反向换算统一计数单位，含 emoji/代理对不得越界崩溃**
- [ ] `NovelChapterCache`：章节解码产物落盘（txt 含行字节范围表；epub 含内容块/插图/元数据快照），命中免网络、支持离线
- [ ] **`Esc` 退出阅读器**（替代 iOS 左滑退出）；`←/→`、`PgUp/PgDn` 翻页；`Ctrl+←/→` 切章；`Ctrl+D` 目录；`Ctrl+±` 字号
- [ ] 「下一本」推荐（底部提示条，无倒计时，需点击）
- [ ] **纯 txt 阅读器**（PC-210，第 4 条阅读路由）：txt 默认用它打开，右键可「以小说阅读器打开」

---

## 6. 漫画阅读（PC-207 / PC-208）

> 📐 原型：[`prototype/04-readers.html`](prototype/04-readers.html) §3（双页/条漫、缩略图面板、弱网加载态、下一本提示）

- [ ] `RangeZipReader`（移植）：EOCD → 中央目录 → 目标条目，**支持 ZIP64 + deflate/stored**，`firstImageEntry()`
- [ ] `ArchiveDecoder`：zip/cbz/epub 走 RangeZipReader **按需解页不整包下载**；rar/cbr 走 libarchive（本地直读 / 远程流式落地临时文件带下载进度）；页名自然排序
- [ ] `ComicDetector`：① 扩展名优先（cbz/cbr）② 内容嗅探（图片占比 ≥90% 且自然序列）③ **epub 图集目录层预判并缓存**（列目录即显示漫画徽标）④ 右键手动「以漫画阅读打开」⑤ 目录级「漫画库」标记
  - [ ] 非漫画文件报「不是漫画文件」
- [ ] 阅读模式：单页 / 双页（RTL·LTR 切换持久化，默认日漫 RTL）/ 条漫（纵向连续滚动）
- [ ] 缩放：`Ctrl+滚轮` 1x~4x、双击放大/还原、拖拽平移；1x 时让位翻页
- [ ] 预加载 ±3 页（正向前向优先/反向后向优先，最多并发 3）；内存 LRU 保留 ±6 页；**大图下采样防爆内存**
- [ ] **进度记录 + 恢复：直接恢复到上次页码**（首次构建即定位，不从第一页开始）；条漫恢复页码显示；文件指纹校验
- [ ] **弱网点击漫画：先展示 UI 进入加载界面**（解析转圈 / 远程 rar 下载百分比进度条）+ **点击防抖去重**
- [ ] 控制层：顶栏（关闭 + 书名 + ⋯ 菜单：模式切换 / 双页方向 / 亮度）+ 底部毛玻璃胶囊（上一页 / 可拖进度轨 / 页码 / 目录 / 下一页）
  - [ ] **拖动中只改本地值、松手才跳页**，拖动时气泡跟随（出界夹紧）
  - [ ] 胶囊上方细字「第 x / N 页 · y% · 模式」；下方快捷 chip：缩略图 / 下一本 / 亮度
  - [ ] **底栏毛玻璃样式与小说阅读器统一**
- [ ] **缩略图面板**：缩略图网格点击跳页，按需小尺寸解码 + LRU，**不占用阅读解压并发**
- [ ] 亮度面板（与小说共用 `reader.brightness`，退出恢复）
- [ ] 翻完推荐下一本（底部提示条，**无倒计时**，需点击；按该目录排序偏好查找）
- [ ] `ComicPageCache`：解压页按「指纹 + 页名」落盘 + 页名清单持久化；**缓存优先源秒开 + 后台归档补齐**；远程 rar 整包落缓存分区复用；离线源
- [ ] 打开全链路日志埋点（`comic-reader` 模块）
- [ ] 退出时清理远程临时文件（正常路径与异常路径均覆盖）

---

## 7. 「正在阅读」首页与进度（PC-209）

> 📐 原型：[`prototype/05-reading-home.html`](prototype/05-reading-home.html)（饼状进度、类型徽标、已读完文案、多选、确认框、空态、收藏页）

- [x] 列表项：标题 / 类型徽标（视频·音频·小说·漫画）/ **饼状进度图 + 下方百分比文字（间距适中）** / 最后阅读相对时间（「n 分钟前 / 昨天」）
  - [x] 封面缩略图（复用 PC-702 `CoverImage`，与浏览页同一份磁盘缓存）
- [x] 封面优先复用阅读时提取的缩略图缓存（epub/漫画零网络秒出），否则走统一封面组件
      （阅读器自身的缩略图缓存待 M3 提取逻辑落地后接入，键已统一）
- [ ] **借助进度记录中的文件指纹免 stat 直接命中磁盘缓存秒出**，后台再静默校正；**stat 失败不永久放弃，30s 冷却后重试**
- [x] 网格 / 列表两种视图切换（偏好持久化）
- [x] 多选（`Ctrl`/`Shift`）+ 右键菜单
  - [ ] 框选（rubber band 拖动）
- [x] 点击条目恢复进度进入对应阅读器/播放器（视频·音频精准续播）
  - [ ] 小说锚点一步定位 / 漫画恢复页码（依赖阅读器，M3）
- [x] **已读完记录保留至手动删除**；文案区分：视频「已看完」/ 音频「已听完」/ 漫画·小说「已读完」（主色高亮 + 进度满格）
- [x] 菜单项：**删除阅读记录**（确认框注明不影响源文件）/ 属性
  - [ ] **删除源文件**
  - [x] 定位到原路径（右键「在浏览页中定位」，滚动居中 + 呼吸灯 10s）
- [ ] 多选操作栏：批量删记录 / 批量删源文件
- [x] **进度上报后自动刷新列表**（`ProgressRepository::progressChanged` 广播 → 就地更新对应行，不重整列表）
- [x] 空状态提示（图标 + 引导文案）
- [x] **长按/右键菜单与浏览页风格一致**；选中高亮为「浮起抬升」样式

---

## 8. 内置浏览器（PC-401 ~ PC-404，M4）

> 📐 原型：[`prototype/06-browser.html`](prototype/06-browser.html)（标签条、工具栏胶囊、起始页、标签网格、历史书签、错误页、下载接管、设置）

### 8.1 核心与多标签

- [ ] `BrowserView`：QtWebEngine `WebEngineView` 封装（`QWebEngineProfile` 配置、`loadProgress`、`iconUrl`、标题、安全态、`certificateError`）
- [ ] `AddressBar`：URL 智能识别（否则走搜索引擎）、域名 + HTTPS 图标、聚焦全选
  - [ ] **输入框宽度受控**（不得撑满窗口导致看不到光标）；**只保留一个输入框**（起始页与地址栏不重复）
- [ ] 2px 主色加载进度条；错误页（加载失败 / SSL）+ 重试
- [ ] `TabManager` / `BrowserSessionStore`：多标签卡片网格，新建 / 关闭 / 切换 / **拖拽排序** / 无痕开关
  - [ ] 每标签独立 `WebEngineView` 实例 **常驻保活**，切标签不销毁、**历史栈不丢**；无痕标签用 off-the-record `QWebEngineProfile`
- [ ] `target=_blank` / `window.open` → 新标签
- [ ] **标签会话持久化**：URL 变化即落盘，退出前兜底落盘；启动恢复标签列表 + 激活标签（无痕不保存）
- [ ] **起始页作为可回退的虚拟第一页**：从起始页导航后后退按钮可用并能回到起始页
- [ ] **回退到最后一页时不得关闭标签**
- [ ] 下载接管：下载到应用下载目录 + 完成提示 + 在文件管理器中显示

### 8.2 桌面交互

- [ ] 工具栏（后退 / 前进 / 刷新·停止 / 地址栏 / 标签数 / 菜单），按历史栈状态启用禁用，**按压动画**
- [ ] 快捷键：`Ctrl+T`/`Ctrl+W`/`Ctrl+Shift+T`/`Ctrl+Tab`/`Ctrl+L`/`Alt+←→`/`F5`/`Ctrl+F`/`Ctrl+±`
- [ ] 鼠标侧键后退前进
- [ ] 工具栏收起：窗口高度不足或沉浸阅读时收为小胶囊（**始终可见可点击**），点击恢复
- [ ] 工具栏与底部播放条、导航之间保持统一间距，互不相贴
- [ ] 点击空白处可收起地址栏输入焦点

### 8.3 起始页 / 书签 / 历史 / 设置

- [ ] `StartPage`：大搜索框 + 快捷入口网格（增删改 + 拖拽排序 + 首启预置），本地持久化
  - [ ] **预置逻辑必须在数据库就绪之后执行**；数据库未就绪时不得写入「已预置」标记
- [ ] 书签：一键收藏 / 取消；管理页列表 / 搜索 / 编辑 / 删除
- [ ] 历史：自动记录（标题 + URL + favicon）、按日分组、搜索、单条删除、清空；无痕不记录
  - [ ] **`BrowserDataStore` 必须在数据库初始化完成后再装载**（否则冷启动读到空列表）
- [ ] 浏览器设置：默认搜索引擎 / 默认 UA / 清除缓存·Cookie·历史

---

## 9. 动态模块（PC-301，预留）

- [ ] `FeedItem` 本地表 + `FeedService` 接口（`fetch(since)`）预留
- [ ] 动态页占位 UI（时间降序无限滚动 / 稍后观看 / 进度锚点占位）
- [ ] 显示「功能开发中 / 待接入外部 API」
- [ ] 预留统一播放器内嵌 / 内置浏览器跳转接口
- [ ] 设置中预留外部 API 配置入口（候选：仓库内 `myhub-feed` FastAPI 服务）

---

## 10. 设置模块（PC-501 ~ PC-507，M5）

> 📐 原型：[`prototype/07-settings.html`](prototype/07-settings.html)（设置双栏、连接源表单、缓存分区、回收站、安全与数据、关于与日志）

- [x] 连接源设置（增删改查 + 测试 + 绿/红点 + 内外网提示 + 内网地址配置）—— 已落地（`qml/settings/ConnectionListView.qml` / `ConnectionFormView.qml`，见 §2），此处为重复条目
- [ ] 阅读器偏好：字号 / 行距 / 主题 / 翻页模式 / 漫画方向（含自动）/ 漫画默认模式 / 衬线字体 / 亮度
- [x] 播放器偏好（已落地：默认纯音频 / 解码偏好 / 字幕字号 / 快进步长 / 音量步进；待补：默认倍速、预读窗口、字幕延迟、**音量联动系统开关**、**最小化自动悬浮小窗**、全屏启动偏好）
- [ ] 显示设置：**文件名行数（1~5，六处生效且即时生效）** / 默认视图 / 单击或双击打开 / 主题模式
- [ ] 缓存与存储：6 分区占用查看 + 单项与全部清理 + 总容量上限 + **内容缓存本地化开关** + 回收站保留天数（1~90）+ 下载目录设置 + 打开数据/缓存目录
- [ ] 安全：应用锁（Windows Hello / macOS Touch ID，回退本地 PIN；最小化/锁屏后上锁，返回需验证；**开关需先验证身份**）
- [ ] 数据：配置导出 / 导入（JSON 快照不含明文密码，**与 iOS 互导兼容**）
- [ ] 关于：版本 / 开源许可 / 存储用量 / **日志查看·导出·清空·打开日志文件夹** / **检查更新** / 应用图标
- [ ] **所有设置项改动即时生效**，不得需要重启应用或切换主题才刷新

---

## 11. 内容缓存本地化与离线（PC-605）

- [ ] 视频/音频分片缓存本地化（复用 §4.2 SegmentCache）：命中分片零网络直出
  - [ ] 文件指纹存缓存索引 + 反查；stat 失败（无网络）以缓存身份起播；离线模式未命中快速失败
- [ ] 漫画解压页缓存本地化（指纹 + 页名落盘、页名清单持久化、离线源打开）
- [ ] 小说章节缓存本地化（txt 章解码产物含行字节范围表；epub 内容块 + 插图 + 元数据快照 → 离线重建）
- [ ] 封面缩略图缓存本地化（稳定哈希键，跨启动有效；命中刷新访问时间）
- [ ] 目录列表缓存本地化
- [ ] **统一容量上限 + 分区配额 + 文件/目录粒度 LRU + 跨分区全局兜底淘汰**（启动预热触发一次）
- [ ] 设置页 6 分区查看/清理，受「内容缓存本地化」开关约束
- [ ] **已完整缓存内容支持无网络播放/阅读**；缺失内容明确提示「离线且未缓存」，点击先展示 UI 不阻塞

---

## 12. 桌面平台特性（PC-601 ~ PC-607，M6）

- [ ] Windows 适配：自绘/系统标题栏、托盘、SMTC、Toast 通知、Credential Manager、Windows Hello、在资源管理器中显示
- [ ] macOS 适配：原生菜单栏、交通灯与全屏 Space、Dock 菜单、NowPlaying、通知中心、Keychain、Touch ID、在访达中显示
- [ ] 快捷键修饰键自动映射（`Ctrl` ↔ `Cmd`，`Alt` ↔ `Option`）
- [ ] **离线下载队列**（PC-606）：右键「离线下载」→ 队列管理（暂停/恢复/取消/重试）→ 持久化 `downloadTask` → 完成通知 → 无网可播放/阅读
- [ ] **桌面通知**（PC-604）：下载完成 / 缓存完成 / 动态更新；点击跳转；可在设置关闭
- [ ] 多显示器 / HiDPI / 跨屏 DPI 自适应
- [ ] 独立窗口打开播放器/阅读器（P2）
- [ ] 文件关联（可选）：双击媒体/漫画/小说文件用 MyHub 打开；单实例携参启动
- [ ] 自动更新：检查更新 + 下载 + 安装引导（Win：MSIX/NSIS；mac：DMG/Sparkle）
- [ ] 部署产物：`windeployqt` / `macdeployqt`（含 QtWebEngine 资源与 Helper 进程）；**macOS 需对 QtWebEngine Helper 一并签名**
- [ ] 打包与签名：Windows 代码签名 + 安装包；macOS 通用二进制（arm64 + x86_64）+ Developer ID 签名 + 公证
- [ ] **LGPL 合规产物校验**（发布前检查清单）：
  - [ ] Qt 全部动态链接，安装目录内动态库可替换（满足重链接义务），不做签名绑定校验
  - [ ] 「设置 → 关于 → 开源许可」页含 Qt(LGPLv3)、libmpv(LGPL)、FFmpeg(LGPL)、libsmb2(LGPL)、libarchive(BSD)、SQLite(Public Domain)、mpvqt(LGPL) 许可证全文并明示使用 Qt
  - [ ] CI 确认未链接任何 GPL-only Qt 模块
  - [ ] 未修改 Qt 源码（如有修改则公开该部分）

---

## 13. 非功能与质量

- [ ] 起播 < 2s（局域网）；文件列表首屏 < 1s（命中缓存 < 200ms）；万级条目滚动 60fps；漫画翻页无白屏
- [ ] 小说调字号重排 < 200ms 且不卡 UI
- [ ] 内存常态 < 400MB；软解及时释放解码资源；图片缓存受控
- [ ] 冷启动到可交互 < 2s，无白屏
- [ ] 网络中断自动重连与自愈；上传/下载断点续传
- [ ] 数据库定期自动备份
- [ ] 可访问性：全键盘可操作、焦点可见、系统字体缩放 ≥125% 不破版
- [ ] 隐私合规：数据全本地、不上传用户内容、无遥测（如需崩溃上报须显式开关且默认关闭）
- [ ] 双端对照回归清单（同一用例在 Windows 与 macOS 各跑一遍）
- [ ] **线程纪律**：网络 IO / 解析 / 缓存写盘 / 排版一律在 worker 线程，**GUI 线程零阻塞**；跨线程通信统一 `Qt::QueuedConnection`
- [ ] **内存纪律**：`QImage` / 解码页 / 分片缓冲及时释放；大图集下采样；worker 线程池有上限
- [ ] QTest 单测覆盖纯逻辑层：`RangeZipReader`、`TextEncodingDetector`、`ChapterRuleTable`、锚点正反向换算、`SegmentCache` LRU、内外网竞速路由、`StoragePath` 归一化

### 13.1 技术栈监测（每半年复核一次，见需求文档 §7.3）

- [ ] Qt 许可政策公告与常规版本发布节奏
- [ ] `mpvqt` 最近提交 ≤ 12 个月（超期则 fork 进 `third_party/` 自维护）
- [ ] QtWebEngine 的 Chromium 基线落后上游代数（影响使用则评估 CEF 替换）
- [ ] libsmb2 / libarchive 最近提交 ≤ 18 个月（超期则锁定 vendor 版本）

---

## 14. iOS 实战经验逐条验收清单

> 来源：`myhub-ios/TODO.md` 末章「体验优化、bug 修复」130 条。**每一组都必须在 PC 端验收**；
> 标「不适用」的已在《需求分析文档》§2.12 说明原因，无需实现但需在验收时确认已有桌面等价物。

### 14.1 打开方式与阅读器分发

- [ ] txt 默认用**纯文本阅读器**打开，右键可改「以小说阅读器打开」
- [ ] epub 按**图集判定**分发：图集 → 漫画阅读器，普通 → 小说阅读器；可手动覆盖
- [ ] 漫画文件（zip/cbz/rar/cbr）默认漫画阅读器，**打开不得崩溃**
- [ ] 阅读页（正在阅读列表）打开沿用同一分发规则
- [ ] **类型徽标须正确**（漫画不得显示小说标签）
- [ ] 以纯文本打开的文件**不计入阅读记录**

### 14.2 封面

- [x] 浏览 / 阅读两处封面**同组件同缓存**（`CoverImage` + `CoverService`）；收藏、mini 播放条待各自页面/组件接入
- [x] 占位先行、异步加载、失败占位、**失败 30s 冷却后重试**（不得永久放弃）
- [x] 冷启动首次加载不阻塞交互；已缓存的下次直接秒出（`cachedCover()` 同步命中）
- [x] 封面键使用**稳定哈希**（`connectionId|normalizedPath` → SHA1，跨启动有效，不含进程内 hash）
- [ ] mini 播放条音频封面与全屏、系统媒体信息同源
- [ ] 视频首帧缩略图（M2 解码器）、epub/漫画封面（M3 阅读器）

### 14.3 列表与卡片视觉

- [ ] 列表行高 +1/4；**行间无分割线**
- [ ] 网格卡片标题**居中**
- [ ] 视频时长放在**标题下方**（不遮封面、不换行）；**不显示修改时间**
- [ ] 类型图标与目录图标**去白底、放大**（网格与列表均调整）
- [ ] **目录不显示子项数**（并移除对应的额外列举请求）
- [ ] **文件名行数设置六处生效**（浏览网格/列表、收藏网格/列表、阅读网格/列表）且即时生效
- [ ] 选中高亮为「浮起抬升」（内缩圆角 + 放大 + 软阴影 + 细描边），**不得贴边直角色块**
- [ ] hover 高亮由统一修饰器渲染（各页面不得各写一套）
- [ ] **多选态下进度环/播放动画与勾选标记并列可见**

### 14.4 菜单与弹窗

- [ ] 右键菜单 **在鼠标位置精确弹出**（不得偏移到上方）
- [ ] 菜单圆角 + 弹出动画；菜单底部与窗口边缘保持足够间距
- [ ] **确认框居中 + 完全圆角矩形**（删除确认等全部统一）
- [ ] 各页签 ⋯ 菜单收纳次要按钮
- [ ] 右键菜单**「多选」置于首位**
- [ ] 右键菜单含：定位到原路径、属性、删除源文件

### 14.5 搜索框与导航

- [ ] 搜索框**仅滚动在顶部时显示**，向下滚动超过其高度才隐藏（**迟滞判定防抖动**），带动画
- [ ] 搜索框**上下无分割线**，高度观感对齐
- [ ] **移除面包屑**，改由顶部操作栏显示当前目录名
- [ ] 返回上一级（`Alt+←` / 侧键 / 按钮）带过渡动画；多选态隐藏返回
- [ ] **重复点击「浏览」导航回连接源选择页**
- [ ] 进入连接源恢复上次路径；首次进入进第一级目录

### 14.6 播放器交互

- [ ] 点击画面**立刻显示控制层**（不得延迟）
- [ ] 点击画面不得误触发锁定；锁定为长按（带反馈），中央锁图标自动消失、点击画面重现、点击锁图标解锁
- [ ] 进度拖动跨度随拖动距离分级（5s~60s 量级），**不得一拖 40 分钟**
- [ ] **弱网点击进度条立即跳到目标位置**，未缓冲时显示加载指示
- [ ] 音量与系统音量关系明确（内部音量为主 + 可选联动）；亮度为窗口蒙层
- [ ] **调节时中央胶囊显示数值**
- [ ] 全屏/窗口切换按钮常驻可见（**纯音频模式下同样可见**）；**窗口/全屏偏好缓存**
- [ ] 播放器与音频播放器的控制入口一致
- [ ] 画中画（悬浮小窗）与音量按钮**必须有实际功能**，不得是空按钮

### 14.7 mini 播放条

- [x] 宽度/高度合理，预览不遮挡进度条；标题下**不显示路径**
- [x] 播放视频时显示**实时画面**；播放音频时显示封面
- [x] 音频无封面占位**不透明**
- [x] 深浅色均带细边框，描边色与底部装饰统一
- [x] **多选态与底部导航一起隐藏**
- [ ] 再次点击 mini 中同一文件回到全屏；**已播完则从头重播**（回全屏已生效，播完重播待补）

### 14.8 播放稳定性

- [ ] **弱网不卡死**：增量流式下载 + 停滞超时 + 断点续传 + 足够前向缓冲（对标 nPlayer 流畅度）
- [ ] 缓冲恢复后**不得残留加载菊花**
- [ ] **连续切换视频无残留请求**拖慢新视频起播
- [ ] 多音轨容器硬解无音轨时**自动回退软解**（修复「有画面无声」）
- [ ] 「部分视频无法打开」具备日志可定位（引擎探测、HTTP 状态、错误详情）
- [ ] **休眠/挂起唤醒后仍可播放**（地址锁定清除 + 回环代理探活重建 + 换端口重试），不得只能重启应用
- [ ] 最小化/托盘常驻继续播放，不得自动暂停
- [ ] 播放中/播放后**可立即删除源文件**（占用等待 + 退避重试 + 具体原因提示）
- [ ] 播放发热/CPU 异常排查（打开 txt 与播放视频同时进行时）

### 14.9 网络与路由

- [ ] 内外网**竞速判定 ~700ms 完成**，不得等待数秒
- [ ] 判定结果**锁定复用**，仅手动「测试连接」或重启才重判
- [ ] **浏览页与设置页连接状态实时一致**
- [ ] 连接失败后重测成功须**立即变绿**（无需重启应用）
- [ ] 外网环境下进入下级目录不得每次长时间加载
- [ ] 刚启动即点击媒体文件也能正常播放（**未锁定时先竞速再选址**，不得盲走内网）
- [ ] 路由失败自愈仅对连接类/网关类错误触发
- [ ] **目录列举严格校验**，异常响应不得当作「空目录」返回并写缓存

### 14.10 文件操作

- [ ] 删除源文件后**目录不得整体无法显示**；刷新失败保留旧缓存
- [ ] 删除/移动成功后**本地立即更新列表并同步缓存**
- [ ] 并发刷新**登记补刷**，不得静默吞掉
- [ ] 回收站降级真删只处理未成功项
- [ ] **新增连接源后浏览页立即可见**（无需重启应用）
- [ ] 删除/移动/重命名**联动阅读记录**
- [ ] 多选操作栏含删除源文件；阅读页右键菜单含属性与删除源文件
- [ ] 下载文件（图片、txt 等）到本地并可在文件管理器中显示

### 14.11 小说阅读器

- [ ] **大 txt 懒加载可读**（不得卡死）
- [ ] **分章识别第一章**
- [ ] **调字号不卡死、不发热**
- [ ] 锚点换算**不越界崩溃**（emoji / 代理对 / 段落分隔符边界）
- [ ] `Esc` 可退出阅读器
- [ ] 滚动时**内容不与标题栏重叠**；文本**可选中复制**
- [ ] 阅读主题支持跟随系统

### 14.12 漫画阅读器

- [ ] 打开成功率（含日志埋点可定位失败原因）
- [ ] 弱网**先进加载界面**（不得点了没反应）
- [ ] **ZIP64 支持**
- [ ] 缓存优先源秒开 + 后台补齐
- [ ] 控制层：顶栏裸显示 + 底部毛玻璃胶囊 + 缩略图/下一本/亮度 chip
- [ ] 进度轨**拖动中只改本地值、松手才跳页**，气泡跟随
- [ ] 底栏毛玻璃样式与小说阅读器统一

### 14.13 浏览器

- [ ] **地址栏居中、宽度受控**，不得撑满窗口
- [ ] **只保留一个 URL 输入框**；点击空白可收起输入焦点
- [ ] 工具栏收起后**保留可见可点击的小胶囊**，不得完全隐藏无法唤回
- [ ] **起始页可回退**（从起始页导航后后退按钮可用）
- [ ] **回退到最后一页不得关闭标签**
- [ ] **标签会话持久化**（导航后直接退出也能恢复）
- [ ] **历史记录与快捷入口在数据库就绪后装载**（冷启动不得显示空）
- [ ] 快捷入口预置标记仅在写入成功后设置
- [ ] 刷新能力（`F5` / 按钮 / 可选下拉）+ 动画
- [ ] 工具栏按钮按压动画
- [ ] 工具栏与底部播放条、导航间距合理不相贴
- [ ] 标签拖拽排序

### 14.14 进度与记录

- [x] 进度上报后**自动刷新**正在阅读列表
- [x] 已读完文案区分「已看完 / 已听完 / 已读完」并保留至手动删除
- [x] 「标记已读完」改为「删除阅读记录」
- [x] 进度显示为**饼状图 + 下方百分比**（间距适中）
- [x] 定位到原路径**滚动定位 + 呼吸灯 10s**

### 14.15 全局视觉

- [ ] 主界面背景改为**白色**；底部装饰以描边与主界面分割
- [ ] 底部播放条 / 工具栏 / 多选操作栏 / 卡片**统一描边色与 1pt 宽度**
- [ ] **进入多选模式隐藏底部导航与播放条**，操作栏落到底部；退出恢复
- [ ] 多选操作栏按钮**图标与文字对齐**（固定槽高，图标视觉体量一致）
- [ ] iOS「液体玻璃」材质 → 桌面用**亚克力 / 毛玻璃**等价（Windows Acrylic / macOS Vibrancy），作为全局标准不设开关
- [ ] 底部页签栏 → 桌面侧边栏；悬浮圆角语言沿用于底部播放条与工具栏

### 14.16 设置生效

- [ ] 文件名行数、显示设置、播放器偏好、阅读器偏好等**改动即时生效**，不得需重启或切主题才刷新
- [ ] 「最小化自动悬浮小窗」开关运行期修改即时生效（含兜底拒绝自动触发）

### 14.17 iOS 专有（不适用，验收时确认已有桌面等价物）

- [ ] ~~保存到相册~~ → 保存到文件 / 在文件管理器中显示
- [ ] ~~AirPlay~~ → 不实现（可选 DLNA，P3）
- [ ] ~~Dynamic Island / Live Activity / Widget / 推送~~ → iOS 代码中本就未实现，不移植
- [ ] ~~横竖屏方向与方向缓存~~ → 窗口全屏/还原 + 尺寸位置记忆
- [ ] ~~系统侧滑返回~~ → `Alt+←` / 鼠标侧键 / 返回按钮
- [ ] ~~Security-Scoped Bookmark~~ → 直接存绝对路径（macOS 沙盒分发时保留）
- [ ] ~~液体玻璃开关~~ → 桌面毛玻璃恒开，无开关

---

## 体验优化、bug 修复

> 开发过程中新增的问题与优化，按 iOS 端的维护纪律逐条追加到此处（描述 + 根因 + 修复方案），并同步回《需求分析文档》对应小节。

- [x] **CMake 预设的 `environment` 会覆盖父进程环境变量**，导致 README 原来「用 `$env:MYHUB_QT_DIR` 覆盖预设路径」的说法不成立（`$env{}` 取的是预设自己的 environment）。
      根因：configurePreset 的 `environment` 优先级高于继承环境。修复：README 改为用 `-D` 覆盖；
      CI 反过来把 Qt / vcpkg 装到预设写死的位置（见 README §3 / §9.2）。
- [x] **`.clang-tidy` 的 `Checks:` 折叠标量里写 `#` 注释会让禁用项静默失效**——注释被当成通配模式
      混入 `Checks`，症状是「明明写了 `-bugprone-xxx` 还在报」。修复：`Checks` 内保持纯列表，理由移到文件头注释。
- [x] **续播完全无效（每次从 0 起播，无任何报错）**：`start` 用 double 经 `set_property` 下发返回
      `-11 PROPERTY_ERROR` 被静默忽略；改用 `loadfile <url> replace start=60` 文件局部选项又返回
      `-4 INVALID_PARAMETER`，**文件根本不加载**（状态卡 Loading、时长为 0）。
      根因：该 libmpv 构建只接受**字符串**形式的 `start`，且必须在 `loadfile` **之前**单独下发。
      修复：`MpvEngine::configureForLoad()` 末尾 `set_property("start", "60.000")`。实测 60s → 起播 60s。
- [x] **退出时最后一次进度丢失**：`aboutToQuit` 里 `AppState::shutdown()` 先关了数据库，
      进度上报器的落盘成为空操作。
      根因：两个 `aboutToQuit` 连接的执行顺序不可控。修复：`main.cpp` 里合并成**同一个 lambda**，
      显式先 `PlayerBridge::flushPendingProgress()` 再 `shutdown()`。
- [x] **进入连接源「恢复上次路径」永不生效，总是回到根目录**：`BrowseController::setConnectionId` 先
      `emit connectionIdChanged()`（目录页收到后重置到根目录、并把 `"/"` 回写为 lastPath），之后才去读
      `lastPath(id)`，读到的自然只有 `"/"`。
      根因：信号副作用发生在读取之前。修复：先取 `restorePath` 再 emit。实测重启/切换回浏览均能回到原目录。
- [x] **浏览页委托取不到部分 model 角色（封面等依赖项为 undefined）**：委托直接用 `model.xxx` 引用角色，
      与组件模板内同名属性互相遮蔽，表现为部分角色静默拿到空值。
      修复：网格/列表委托统一改为「外层 `Item` + `required property` 声明角色」，再显式传给 `FileGridCell` /
      `FileListRow`（Qt 6 推荐写法，角色注入不再依赖 `model.` 前缀）。
- [x] **MP4 内嵌封面永远解析为空**：`findChildBox` 从 `moov` 偏移 0 开始扫子盒，而 `moov` 自身是完整盒子
      （前 8 字节是 size + type），必然扫不到 `udta`。修复：子盒扫描从偏移 8 起，`covr` 正常提取。
- [ ] （待补充）
</content>
<parameter name="explanation">创建 PC 端 TODO 列表，逐条映射 iOS 功能与实战经验