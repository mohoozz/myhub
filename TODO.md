# myhub 全栈重写 TODO

> 依据《flutter/需求分析文档.md》v2.0 拆解，按功能模块组织，勾选即完成。
> **架构**：后端 Go Gin + 前端 Flutter（全栈重写，不复用旧代码）
> 里程碑：M0 全栈骨架 → M1 文件管理 → M2 媒体播放 → M3 阅读器 → M4 多端打磨 v1.0 → M5 动态+离线 v1.1 → M6 内置浏览器 v1.2

---

## 0. 项目脚手架与基础设施

### 0.1 Go 后端脚手架

- [x] 初始化 Go module：`go mod init myhub-server`
- [x] 安装核心依赖：Gin、GORM、golang-jwt、Viper、robfig/cron、bcrypt（SQLite 驱动采用纯 Go 的 glebarez/sqlite，免 CGO）
- [x] 搭建目录结构（`cmd/`、`internal/handler/`、`internal/service/`、`internal/repository/`、`internal/model/`、`internal/middleware/`、`internal/adapter/`、`internal/parser/`、`internal/router/`）
- [x] `cmd/server/main.go` 入口：加载配置、初始化数据库、注册路由、启动服务（含优雅关闭）
- [x] 配置管理（`config/config.go`）：Viper 读取 YAML（端口、JWT 密钥、数据库路径、路径源白名单），支持 MYHUB_ 环境变量覆盖
- [x] GORM + SQLite 初始化：自动迁移入口、连接池配置
- [x] 全局中间件：CORS、请求日志（Gin Logger）、异常恢复（Gin Recovery）
- [x] 统一响应格式：`{ code: 0, data: ..., message: "" }`
- [x] 全局错误处理中间件

### 0.2 Flutter 前端脚手架

- [x] `flutter create myhub_flutter`，配置包名/应用名/版本号（PC 优先，仅启用 Windows 平台）
- [x] 配置 `pubspec.yaml`：添加全部依赖（Riverpod、go_router、dio、media_kit、drift、lucide_icons_flutter 等）
- [x] 配置 `analysis_options.yaml`（strict lint 规则）
- [x] 搭建目录结构（`core/`、`data/`、`features/`、`shared/`）
- [x] `main.dart`：ProviderScope + MaterialApp.router 入口（含 MediaKit 初始化）
- [x] `app.dart`：MaterialApp.router 配置（亮/暗主题、路由）
- [x] 环境变量配置（后端 API 地址，通过 `--dart-define=API_BASE_URL=...`）

### 0.3 基础设施

- [x] Go 后端：编写 `Dockerfile`（多阶段构建，最终 Alpine 镜像，含 FFmpeg）
- [x] Flutter 前端：配置各平台入口（PC 优先：Windows 桌面入口已配置；Android/iOS 入口后续里程碑补充）
- [x] `docker-compose.yml`：Go 后端 + Caddy 反向代理（预留 OpenClaw、OpenList）
- [x] `Caddyfile`：反代配置 + 自动 HTTPS
- [x] `Makefile`：`make dev` / `make build` / `make run` 等常用命令
- [x] 编写 `README.md`：快速开始、环境要求、目录结构说明

---

## 1. Go 后端核心模块

### 1.1 数据模型（GORM）

- [x] `model/user.go`：User（id, username, password_hash）
- [x] `model/source.go`：Source（id, name, type, config_json, mount_point, enabled, created_at）
- [x] `model/trash_item.go`：TrashItem（id, source_id, original_path, trash_path, size, deleted_at）
- [x] `model/favorite.go`：Favorite（id, source_id, file_path, media_type, size, created_at），唯一键 (source_id, file_path)
- [x] `model/reading_progress.go`：ReadingProgress（id, source_id, file_path, media_type, title, cover, progress_json, percent, finished, updated_at），唯一键 (source_id, file_path)
- [x] `model/novel_index.go`：NovelIndex（id, source_id, file_path, encoding, chapters_json, file_size），唯一键 (source_id, file_path)
- [x] `model/feed.go`：FeedSubscription、FeedItem（唯一键 platform+content_id）、FeedCursor、WatchLater（唯一键 platform+content_id）、FeedFetchLog
- [x] `model/config.go`：AppConfig（id, key, value），唯一键 key
- [x] GORM AutoMigrate 在启动时自动建表
- [x] 提供 `cmd/cli/` 创建用户命令行工具（`go run cmd/cli/main.go create-user`）

### 1.2 鉴权模块（Auth）

- [x] `POST /api/auth/login`：用户名密码验证，bcrypt 校验，颁发 JWT（24h 过期）
- [x] JWT 中间件：解析 Token、注入用户信息到 Context、401 拦截
- [x] `PUT /api/auth/password`：修改密码（需旧密码验证）
- [x] 内部接口 Token 校验中间件（供 OpenClaw 回传）
- [x] Repository 层：`user.go`（FindByUsername、Create、UpdatePassword）

### 1.3 存储适配器层

- [x] 定义 `IStorageAdapter` 接口：List、Stat、ReadStream、WriteStream、Move、Copy、Delete、Restore、Mkdir
- [x] `LocalAdapter`：基于 `os` 包，挂载点根目录白名单校验防目录穿越，回收站目录 `.trash`
- [x] `WebDavAdapter`：基于 `go-webdav` 库，Range 请求头透传，连接测试
- [x] 适配器工厂：根据 Source.Type 创建对应适配器实例
- [ ] `OpenListAdapter`（可选，二期）：对接 OpenList REST API

### 1.4 路径源管理（Source）

- [x] CRUD API：`GET/POST/PUT/DELETE /api/sources`
- [x] `POST /api/sources/:id/test`：连接测试（调用适配器的 Stat 验证可用性）
- [x] Repository 层：`source.go`（List、GetByID、Create、Update、Delete）
- [x] Service 层：校验、适配器实例化、连接测试

### 1.5 文件管理（File）

- [x] `GET /api/files?source=&path=`：列目录，文件类型识别（扩展名映射）
- [x] `POST /api/files/mkdir`：新建文件夹
- [x] `POST /api/files/upload`：multipart 文件上传
- [x] `POST /api/files/rename`：重命名
- [x] `POST /api/files/move`：同源移动；跨源走流式中转（不落临时文件）
- [x] `POST /api/files/copy`：同源复制；跨源流式中转
- [x] `DELETE /api/files`：删除入回收站（逻辑删除，移入 `.trash/`）
- [x] `GET /api/files/thumbnail?source=&path=`：视频缩略图（FFmpeg 抽帧缓存）
- [x] `GET /api/files/image?source=&path=`：图片原图读取（纯图片预览页使用）
- [x] Service 层：文件操作编排、跨源中转
- [x] 视频缩略图生成：`ffmpeg -ss 10 -i input -vframes 1 -s 320x180 thumb.jpg`

### 1.6 回收站（Trash）

- [x] `GET /api/trash`：回收站列表（按 source_id 过滤）
- [x] `POST /api/trash/restore`：还原文件（从 `.trash/` 移回原路径）
- [x] `DELETE /api/trash/:id`：彻底删除单个文件
- [x] `DELETE /api/trash`：清空回收站
- [x] 定时清理任务（robfig/cron，每天执行，删除超过 N 天的回收站条目，默认 30 天）

### 1.7 收藏（Favorite）

- [x] `GET /api/favorites`：收藏列表（支持分页）
- [x] `POST /api/favorites`：添加收藏（source_id + file_path 唯一）
- [x] `DELETE /api/favorites`：取消收藏
- [x] Repository 层：`favorite.go`

### 1.8 流媒体模块（Stream）

- [x] `GET /api/stream/:sourceId/*path`：原始流接口
  - 支持 HTTP Range 请求（解析 `Range` 头，返回 206 Partial Content）
  - 设置正确的 `Content-Type`、`Accept-Ranges: bytes`
  - 视频直通格式：mp4/webm/m4v/mkv/avi/mov
  - 音频直通格式：mp3/m4a/flac/wav/ogg
- [x] FFmpeg HLS 转码（兜底）：
  - `GET /api/stream/hls/:id/playlist.m3u8`：m3u8 播放列表
  - `GET /api/stream/hls/:id/segment/:n.ts`：TS 分片
  - 优先 `-c copy` 仅转封装，不兼容编码时再降码
  - 转码会话管理：按需启动、空闲 5 分钟自动回收
- [x] 字幕转换：srt/ass → webvtt（FFmpeg 或自行解析转换）
- [x] Service 层：Range 解析、流式响应、HLS 会话池

### 1.9 小说阅读模块（Reader - Novel）

- [x] TXT 章节索引：
  - 正则识别"第x章""Chapter x"等标题模式
  - 自动检测编码（UTF-8/GBK/Big5，`golang.org/x/text` + `iconv` 兜底）
  - 索引结果缓存到 `novel_index` 表
  - 大文件后台异步建索引，先按固定分页可读
- [x] `GET /api/reader/novel/chapters?source=&path=`：章节列表
- [x] `GET /api/reader/novel/content?source=&path=&chapter=N`：按章节返回字节区间内容
- [x] EPUB 解包：
  - `GET /api/reader/epub/meta?source=&path=`：元数据（书名、作者、封面、目录）
  - `GET /api/reader/epub/chapter?source=&path=&id=`：章节 HTML 内容
  - `GET /api/reader/epub/resource?source=&path=&id=`：静态资源（图片/CSS）
  - 按 `mimetype` 区分图集型（漫画）与文字型（小说）

### 1.10 漫画阅读模块（Comic）

- [x] 漫画识别策略：
  - 扩展名优先：`.cbz`/`.cbr` → 直接漫画
  - 内容嗅探：ZIP 中央目录解析 → 图片占比 ≥ 90% 且自然序列 → 漫画
  - 目录级约定：路径源可标记为"漫画库"
  - 手动覆盖：`POST /api/reader/comic/override`
- [x] ZIP/CBZ 解析：`archive/zip` 标准库，中央目录读取，natsort 排序
- [x] RAR/CBR 解析：`nwaples/rardecode` 或调用系统 unrar
- [x] `GET /api/reader/comic/pages?source=&path=`：页列表
- [x] `GET /api/reader/comic/page?source=&path=&n=N`：单页图片流式返回
- [x] `GET /api/reader/comic/detect?source=&path=`：内容嗅探判定
- [x] 普通压缩包支持：
  - `GET /api/reader/archive/tree?source=&path=`：文件树
  - `GET /api/reader/archive/file?source=&path=&entry=`：单独解出文件
- [x] EPUB 图集型漫画支持（复用 EPUB 解包逻辑）

### 1.11 阅读进度（Progress）

- [x] `GET /api/progress`：获取所有进度（按 updated_at 降序）
- [x] `PUT /api/progress`：保存/更新进度（upsert）
- [x] `DELETE /api/progress`：标记已读完（设置 finished=true）
- [x] Repository 层：`progress.go`

### 1.12 动态模块（Feed，二期 M5）

- [ ] `GET/POST/DELETE /api/feed/subscriptions`：订阅源 CRUD
- [ ] 抓取调度（robfig/cron）：
  - 按每个订阅源的 cron 表达式触发
  - 增量抓取：基于 last_fetched_at + 已入库 content_id 截断
- [ ] OpenClaw 集成：
  - Gateway API 下发抓取任务
  - `POST /api/internal/feed/ingest`：接收抓取结果，zod 风格校验，去重入库
- [ ] 平台抽取提示词维护（B站/YouTube/抖音各一份 YAML 配置）
- [ ] YouTube RSS 免费兜底通道
- [ ] `GET /api/feed?cursor=&limit=`：动态列表（按发布时间降序）
- [ ] `POST /api/feed/read`：更新已读游标
- [ ] `POST /api/feed/fetch`：手动触发抓取
- [ ] 稍后观看：`GET/POST/DELETE /api/feed/watch-later`
- [ ] 抓取任务日志入库（FeedFetchLog）

### 1.13 系统配置（Config）

- [x] `GET /api/config`：获取所有配置（键值对）
- [x] `PUT /api/config`：批量更新配置
- [x] Repository 层：`config.go`

### 1.14 路由注册

- [x] `router/router.go`：注册所有路由
  - 公开路由组：`/api/auth/*`
  - 需鉴权路由组（JWT 中间件）
  - 内部路由组：`/api/internal/*`（Token 校验中间件）
- [x] 静态文件托管：生产环境托管 Flutter Web 构建产物（可选）

---

## 2. Flutter 前端 - 核心基础设施

### 2.1 主题系统

- [x] `core/theme/colors.dart`：色板常量定义
  - 主色：`#2563eb`（亮）/ `#3b82f6`（暗）
  - 背景：`#eef4fb`（亮）/ `#000000`（暗）
  - 卡片：`#ffffff`（亮）/ `#121212`（暗）
  - 导航背景：`#ffffff`（亮）/ `#0a0a0a`（暗）
  - 文字主：`#1a1a2e`（亮）/ `#e0e0e0`（暗）
  - 文字辅：`#6b7280`（亮）/ `#888888`（暗）
  - 分割线：`#e5e7eb`（亮）/ `#1e1e1e`（暗）
  - 输入框/列表行背景：`#ffffff`（亮）/ `#1a1a1a`（暗）
  - 选中高亮：`#eef4fb` 底 + `#2563eb` 色（亮）/ `#1a2744` 底 + `#3b82f6` 色（暗）
  - 播放器/阅读器沉浸背景：`#000000`（统一纯黑）
- [x] `core/theme/app_theme.dart`：亮色/暗色 ThemeData
  - 亮色：ColorScheme.light，卡片 Elevation 1-2
  - 暗色：ColorScheme.dark（纯黑背景 `#000000`），**无阴影，用 `#1e1e1e` 边框区分卡片**
  - 全局圆角 12px、按钮 20px 胶囊、输入框 8px
  - 进度条 4px 高
  - 字体：正文系统默认，阅读器思源宋体
- [x] `shared/providers/theme_provider.dart`：主题状态管理（实现于 `core/theme/theme_mode_provider.dart`）
  - 亮/暗切换
  - 跟随系统（`PlatformDispatcher` 监听）
  - 持久化到 `SharedPreferences`
  - 沉浸式场景自动强制暗色
- [x] 导航栏样式：
  - `NavigationBar`（手机）：选中项蓝色高亮
  - `NavigationRail`（平板/桌面）：选中项蓝色胶囊高亮，暗色模式 `#0a0a0a` 背景

### 2.2 路由系统

- [x] `core/router/app_router.dart`：go_router 配置
  - 路由表：`/login`、`/reading`、`/favorites`、`/feed`、`/browse`、`/trash`、`/settings`、`/profile`
  - 路由守卫：未登录 → 重定向 `/login`；已登录访问 `/login` → 重定向 `/reading`
  - 嵌套路由：`ShellRoute` + 自适应导航壳
  - 深层链接支持

### 2.3 导航壳

- [x] `shared/widgets/app_navigation.dart`：自适应导航壳
  - `LayoutBuilder` 判断宽度：
    - `<600px`：底部 `NavigationBar`（阅读/动态/浏览 3 项）+ 顶栏 `AppBar` 右侧头像按钮
    - `600~840px`：左侧 `NavigationRail`（仅图标，阅读/收藏/动态/浏览/设置）+ 顶栏右侧头像
    - `>840px`：左侧 `NavigationRail`（展开标签，同项）+ 左下角设置/主题切换按钮
  - 选中项蓝色胶囊高亮动画
  - 头像菜单（`PopupMenuButton`）：个人中心、我的收藏、设置、深色模式开关、退出登录

### 2.4 页面保活

- [x] `IndexedStack` 包裹 Tab 页面，保持切换不销毁
- [x] 播放器使用独立全屏路由（`Navigator.push`），不随 Tab 切换影响
- [x] 迷你播放器使用全局 `Overlay`，跨页面保持

### 2.5 API 层封装

- [x] `core/api/dio_client.dart`：dio 单例
  - `BaseOptions`：baseUrl、超时 30s、JSON 默认 Content-Type
  - 请求拦截器：注入 JWT Token（从 `flutter_secure_storage` 读取）
  - 响应拦截器：统一错误处理、401 跳转登录
  - 日志拦截器（Debug 模式）
- [x] `core/api/auth_api.dart`：`login()`、`changePassword()`
- [x] `core/api/source_api.dart`：CRUD + `testConnection()`
- [x] `core/api/file_api.dart`：`listFiles()`、`uploadFiles()`（进度回调）、`mkdir()`、`rename()`、`moveFiles()`、`copyFiles()`、`deleteFiles()`、`thumbnailUrl()`
- [x] `core/api/trash_api.dart`：列表、还原、删除、清空
- [x] `core/api/favorite_api.dart`：列表、添加、移除
- [x] `core/api/stream_api.dart`：`streamUrl()`、`hlsPlaylistUrl()`、`subtitleUrl()`
- [x] `core/api/reader_api.dart`：TXT 章节/内容、EPUB 元数据/章节/资源
- [x] `core/api/comic_api.dart`：页列表、单页图片、识别、覆盖、压缩包文件树/单文件
- [x] `core/api/progress_api.dart`：获取所有、保存、标记已读完
- [x] `core/api/feed_api.dart`：列表、已读、订阅 CRUD、手动抓取、稍后观看 CRUD
- [x] `core/api/config_api.dart`：获取、更新

### 2.6 数据模型

- [x] 用 `freezed` 生成全部数据模型（User、Source、FileItem、TrashItem、Favorite、ReadingProgress、NovelIndex、FeedItem、FeedSubscription、WatchLater、AppConfig 等）
- [x] `json_serializable` 配置 JSON 序列化

### 2.7 本地存储

- [x] `flutter_secure_storage`：JWT Token 读写
- [x] `shared_preferences`：主题偏好、阅读器设置、播放设置
- [x] `drift` 本地数据库（`data/database/`）：
  - `local_progress.dart`：LocalProgress 表（离线进度缓存 + synced 标记）
  - `download_task.dart`：DownloadTask 表（离线下载队列，二期）
  - `build_runner` 生成代码

---

## 3. Flutter 前端 - 鉴权模块（Auth）

- [x] `features/auth/screens/login_screen.dart`：登录页 UI（实现于 `features/auth/login_screen.dart`）
  - Logo + 标题
  - 用户名输入框
  - 密码输入框（可切换明文/密文）
  - 登录按钮（胶囊形，蓝色）
  - 错误提示（SnackBar）
  - 加载状态（按钮内转圈）
- [x] `features/auth/providers/auth_provider.dart`：登录状态管理
  - `login()` → dio POST → 存储 Token → 更新状态
  - `logout()` → 清除 Token → 跳转登录页
  - `changePassword()` → PUT 请求
- [x] `shared/providers/auth_state_provider.dart`：全局认证状态（Riverpod）
  - 是否已登录
  - 当前用户名
  - Token 有效性检查
- [x] 路由守卫：go_router `redirect` 逻辑
- [x] 设置页修改密码 UI

---

## 4. Flutter 前端 - 浏览模块（文件管理）

### 4.1 路径源管理（F-101）

- [x] `shared/widgets/source_manager.dart`：路径源管理组件
  - 列表展示：类型图标、名称、挂载点、开关
  - 添加/编辑弹窗：类型下拉（本地/WebDAV）、配置表单、连接测试按钮
  - 删除确认弹窗
- [x] 路径源选择器（浏览页顶部）：`DropdownButton` 切换当前路径源
- [x] 对接 `source_api.dart` 全部接口

### 4.2 文件浏览（F-102）

- [x] `features/browse/screens/browse_screen.dart`：浏览页主界面（实现于 `features/browse/browse_screen.dart`）
  - 顶部：路径源选择器 + 面包屑导航 + 搜索按钮 + 视图切换 + 上传按钮
  - 内容区：`IndexedStack` 切换网格/列表视图
- [x] `features/browse/widgets/file_grid.dart`：文件网格视图
  - `GridView.builder` + 文件卡片
  - 卡片内容：类型图标/缩略图、文件名（单行省略）、文件夹子项数、视频时长角标
  - 漫画文件显示"漫画"徽标（蓝色胶囊）
  - 卡片整体可点击，hover 浮起（亮色）/ 边框高亮（暗色）
- [x] `features/browse/widgets/file_list.dart`：文件列表视图
  - `ListView.builder` + `ListTile`
  - 行内容：类型图标、文件名、大小、修改时间
- [x] `features/browse/widgets/breadcrumb_bar.dart`：面包屑导航
  - 水平滚动 `Chip` 列表
  - 点击跳转到对应层级
- [x] 搜索当前目录：`TextField` + 前端过滤
- [x] 排序选择器：底部弹出菜单（名称/大小/时间，升序/降序）
- [x] 下拉刷新（`RefreshIndicator`）
- [x] 空状态：文件夹图标 + "此目录为空"
- [x] 加载状态：`CircularProgressIndicator`
- [x] 错误状态：错误信息 + 重试按钮

### 4.3 文件操作（F-103 ~ F-105）

- [x] 文件上传：
  - 点击上传按钮 → `file_picker` 选择文件
  - 上传进度 `BottomSheet`：文件名 + `LinearProgressIndicator` + 百分比
  - 多文件队列上传
  - 桌面端：`desktop_drop` 拖拽上传
- [x] 新建文件夹：`AlertDialog` 输入名称 → `POST /api/files/mkdir`
- [x] 重命名：`AlertDialog` 输入新名称 → `POST /api/files/rename`
- [x] 移动/复制：`MoveTargetPicker`（`BottomSheet` 文件树选择目标目录）
- [x] 长按进入多选模式：
  - 卡片显示复选框
  - 底部浮现操作栏：移动/复制/重命名/删除/收藏（`SnackBar` 风格或固定 `BottomAppBar`）

### 4.4 删除与回收站（F-106）

- [x] 删除确认 `AlertDialog`："确定删除 xxx？将移入回收站"
- [x] `features/trash/screens/trash_screen.dart`：回收站页（实现于 `features/trash/trash_screen.dart`）
  - 列表展示：文件名、原始路径、大小、删除时间
  - 滑动操作（`Dismissible`）：左滑还原、右滑彻底删除
  - 顶栏：清空按钮（二次确认）
  - 空状态："回收站为空"
- [x] 浏览页回收站入口（顶栏或导航栏按钮）

### 4.5 文件收藏（F-107）

- [x] 浏览页文件/文件夹星标按钮（卡片右上角或长按菜单）
- [x] `features/favorites/screens/favorites_screen.dart`：收藏页（实现于 `features/favorites/favorites_screen.dart`）
  - 网格/列表视图切换
  - 类型图标、文件名、大小
  - 右上角实心星标（点击取消收藏，即时移除）
  - 卡片整体可点击 → 按类型进入播放器/阅读器
  - 空状态：星形图标 + "暂无收藏，去浏览页添加吧"
- [x] 收藏页与浏览页星标状态双向同步

---

## 5. Flutter 前端 - 媒体播放模块（F-201 / F-206 / F-207）

### 5.1 播放器核心

- [x] `shared/widgets/media_player/media_player.dart`：播放器主 Widget
  - 集成 `media_kit`：`Player` + `VideoController`
  - 初始化：平台特定配置（Android/iOS/桌面）
  - 播放源构建：直接 URL（直通格式）+ HLS URL（转码兜底，失败自动互换重试一次）
  - 视频/音频自动识别（根据 mediaType 或扩展名）
  - 全屏播放使用 `Navigator.push` 独立路由
  - 暗色沉浸背景（纯黑 `#000000`）
- [x] 加载状态：中央 `CircularProgressIndicator` + "加载中..."
- [x] 缓冲指示器：控制栏进度条显示缓冲区间
- [x] 错误状态：错误信息 + 重试按钮

### 5.2 播放控制

- [x] `shared/widgets/media_player/player_controls.dart`：自定义控制栏（Overlay）
  - 播放/暂停按钮（中央大按钮，轻触画面切换控制栏显隐）
  - 进度条：可拖拽 + 缓冲进度叠加
  - 当前时间 / 总时长（`Text` 格式 `mm:ss`）
  - 倍速选择：`BottomSheet` 列表（0.5x/0.75x/1.0x/1.25x/1.5x/2.0x）
  - 音量滑块：水平 `Slider`（宽屏内嵌）+ 静音按钮
  - 全屏切换按钮（桌面端系统级全屏）
  - 控制栏 3 秒无操作自动隐藏（暂停时常显，桌面端鼠标移动唤醒）
- [x] 锁定屏幕方向（移动端视频全屏时横屏锁定，退出恢复竖屏）

### 5.3 音频唱片封面模式

- [x] `shared/widgets/media_player/audio_cover_mode.dart`：音频播放 UI
  - 封面图片：`RotationTransition` 旋转动效（播放时旋转，暂停时停止）
  - 封面来源：同目录同名图片 / cover / folder / front（无封面时显示音乐图标占位）
  - 标题 + 作者信息（居中显示，按 "作者 - 标题" 文件名解析）
  - 控制栏与视频完全一致
- [x] 视频/音频模式自动切换（按实际媒体轨校正，albumart 内嵌封面不算视频轨）

### 5.4 手势控制

- [x] `shared/widgets/media_player/gesture_handler.dart`：手势识别层
  - 水平滑动：调节进度（±10s 起，随滑动距离增加，满幅约 ±120s）
  - 右侧 1/3 竖滑：调节音量
  - 左侧 1/3 竖滑：调节亮度（软件调光遮罩，跨平台一致）
  - 双击左半区：快退 10s
  - 双击右半区：快进 10s
  - 调节时屏幕中央悬浮胶囊实时反馈（进度时间 / 音量% / 亮度% 图标 + 数值）

### 5.5 键盘控制（桌面端）

- [x] `CallbackShortcuts` + `Focus` 全局键盘监听（页面级，加载/错误状态下 Esc 可用）
  - `←`/`→`：快退/快进 5s
  - `↑`/`↓`：调节音量 5%
  - `空格`：播放/暂停
  - `Esc`：退出全屏播放器
  - `F`：全屏切换
  - `M`：静音切换（记住静音前音量）

### 5.6 字幕支持

- [x] 外挂字幕自动检测：同目录同名 srt/ass/ssa/vtt 文件（含 `name.zh.srt` 语言后缀约定）
- [x] 字幕加载与显示（media_kit 内置 subtitle 支持，srt/ass/ssa 经后端转 WebVTT，vtt 透传）
- [x] 字幕轨切换按钮（存在字幕轨时显示，BottomSheet 列表含"关闭字幕"）

### 5.7 播放进度与迷你播放器

- [x] 播放进度自动上报：每 5 秒节流 → `PUT /api/progress`（暂停/停止/播完即时补报）
- [x] 打开已播放文件自动恢复进度（seek 到上次位置，已完成或过短则从头播放）
- [x] `shared/widgets/media_player/mini_player.dart`：迷你播放器
  - 底部迷你条：文件名、细进度条、播放/暂停圆形按钮、关闭按钮
  - 使用全局 `Overlay` 实现，跨页面保持（播放会话由全局 `mediaPlayerProvider` 持有）
  - 点击迷你条展开全屏播放器（复用同一会话，不重新加载）
  - 关闭按钮停止播放并移除 Overlay
  - 拖拽到底部可关闭

### 5.8 连续播放推荐（F-207，新增）

- [x] `shared/widgets/media_player/next_media_tip.dart`：下一个推荐提示
  - 播放结束后，查询同目录同类型文件列表
  - 按当前排序找下一个文件（排序缓存 > 名称升序）
  - 底部弹出"下一个：xxx"提示条（`SnackBar` 风格或自定义 Widget）
  - 点击立即播放、点击空白区域关闭

---

## 6. Flutter 前端 - 小说阅读模块（F-202 / F-203）

### 6.1 TXT 阅读器

- [x] `shared/widgets/novel_reader/novel_reader.dart`：阅读器主 Widget
- [x] 章节列表加载：`GET /api/reader/novel/chapters`（大文件索引构建中 2s 轮询，60s 超时）
- [x] 章节内容按需加载：`GET /api/reader/novel/content?chapter=N`（内存缓存）
- [x] `shared/widgets/novel_reader/page_mode.dart`：翻页模式
  - `PageView.builder` 左右滑动翻页
  - 每页计算可容纳字数，按屏幕高度切分（`TextPainter` 行边界对齐，不出半行）
  - 翻页动画（`PageView` 默认滑动效果）；左/右 30% 轻触翻页，末页越界自动切章
- [x] `shared/widgets/novel_reader/scroll_mode.dart`：滚动模式
  - `CustomScrollView` + `center` 键双向无限列表，上下连续滚动
  - 章节间平滑衔接（接近边缘且内容就绪时逐章延伸）
- [x] 章节预加载：当前章节 ± 1

### 6.2 EPUB 阅读器

- [x] EPUB 元数据加载：书名、作者、封面、目录（封面/信息页 + 开始阅读）
- [x] 章节 HTML 渲染：自建轻量富文本渲染（`epub_html.dart` 标签栈解析 → 富文本原子，可用 TextPainter 分页；flutter_widget_from_html 无法分页故自建）
- [x] 静态资源加载（图片经 resource 接口按 href 加载，字节缓存；后端 `ReadItem` 补 href 兜底）
- [x] 翻页/滚动模式（与 TXT 共用阅读器壳交互；图集型 EPUB 提示转漫画阅读器）

### 6.3 阅读器设置

- [x] `shared/widgets/novel_reader/reader_settings.dart`：设置面板
  - `ModalBottomSheet` 弹出（阅读器顶栏设置按钮触发，TXT/EPUB 共用）
  - 字号调节：`Slider`（12~24px，0.5 步进）
  - 行距调节：`Slider`（1.2~2.5，0.1 步进）
  - 三种主题切换：日间（白底 `#ffffff` 黑字）、夜间（黑底 `#000000` 白字）、护眼（暖纸 `#f5f0e8` 底 + 深棕 `#4a3728` 字）
  - 翻页模式切换（翻页/滚动，`SegmentedButton`）
  - 设置持久化到 `SharedPreferences`（滑动结束才落盘）
- [x] 思源宋体（`Noto Serif SC`）应用于正文（`GoogleFonts.notoSerifSc`，加载失败回退系统字体）
- [x] 亮色模式阅读器也使用独立背景色（`Scaffold` 背景始终取主题色，不受全局主题影响；EPUB 原子缓存随样式签名失效重解析）

### 6.4 目录与进度

- [x] `shared/widgets/novel_reader/chapter_drawer.dart`：目录抽屉
  - `Drawer` 从右侧滑出（顶栏按钮开启，禁用边缘拖出避免与翻页手势冲突）
  - 章节列表，当前章节高亮
  - 点击跳转到对应章节
- [x] 阅读进度实时显示：底部进度条 + 百分比文字（翻页模式按 章+页内进度 折算，滚动模式按滚动比例）
- [x] 上/下一章按钮（底部栏，与进度条同行）
- [x] 进度自动上报后端（退出阅读器时保存 `progress_json={chapter,page}` + percent；打开时自动恢复章节，EPUB 有进度则跳过封面页直接续读）

---

## 7. Flutter 前端 - 漫画阅读模块（F-204 / F-208）

### 7.1 漫画数据加载

- [x] `shared/widgets/comic_reader/comic_reader.dart`：漫画阅读器主 Widget
- [x] 漫画页列表加载：`GET /api/reader/comic/pages`
- [x] 单页图片加载：`GET /api/reader/comic/page?n=N` + `cached_network_image`（JWT 请求头，`ComicApi.pageUrl()` 构建完整 URL）
- [x] 漫画识别策略复用后端判定，前端根据返回类型路由到对应阅读器（cbz/cbr 直开；zip/rar 经 detect 嗅探路由；图集型 EPUB 一键转交漫画阅读器）

### 7.2 阅读模式

- [x] `shared/widgets/comic_reader/single_page.dart`：单页模式
  - `PageView.builder` 左右滑动翻页
  - `InteractiveViewer` 包裹每张图片，支持双指缩放/拖拽
  - 点击切换控制栏显隐
- [x] `shared/widgets/comic_reader/double_page.dart`：双页模式
  - 横屏/平板自动启用（未手动选择模式时，横屏或宽度 ≥840 自动双页）
  - `PageView` 每页显示两张图（`Row` 左右排列，整组共用一个 InteractiveViewer 同步缩放）
  - 从右向左阅读（日漫方向，默认）或从左向右（顶栏按钮切换，持久化）
- [x] `shared/widgets/comic_reader/webtoon_mode.dart`：条漫模式
  - `ListView.builder` 纵向连续滚动
  - 每张图全宽显示
  - `InteractiveViewer`（panEnabled: false）支持双指缩放，单指滚动归 ListView
- [x] 模式切换按钮：底部悬浮 `SegmentedButton`（单页/双页/条漫，随控制栏显隐，选择持久化到 SharedPreferences）

### 7.3 预加载

- [x] 当前页 ± 3 页预加载（`preloader.dart`：`ComicPreloader`，页列表就绪与翻页回调驱动）
  - `cached_network_image` 的 `precacheImage` 方法（与 ComicPageImage 同一 headers 实例，缓存命中）
  - 正向翻页时前向优先（+1/+2/+3 先于 -1/-2/-3）
  - 反向翻页时后向优先
- [x] 预加载队列管理：最多同时预加载 3 张（完成一张补一张，翻页时重排等待队列，失败静默）

### 7.4 控制栏与进度

- [x] 顶部悬浮控制栏（Overlay，点击显示/隐藏）：
  - 页码指示器：`当前页 / 总页数`
  - 返回按钮
  - 模式切换按钮（底部悬浮 `SegmentedButton`，见 7.2；顶栏另含双页方向切换）
- [x] 阅读页码进度自动上报（退出阅读器时 `PUT /api/progress`，`progress_json={page}`，mediaType=comic）
- [x] 下次打开恢复上次页码（与页列表并行加载，首次构建即定位；已读完则从头；条漫模式恢复页码显示，滚动位置受列表高度限制无法精确定位）

### 7.5 翻完推荐下一本（F-208，新增）

- [ ] `shared/widgets/comic_reader/next_comic_tip.dart`：下一本推荐提示
  - 翻到最后一页时，底部弹出"下一本：xxx"提示
  - 同目录查找下一个漫画文件
  - 5 秒倒计时自动打开（`CircularProgressIndicator` 倒计时环）
  - 点击立即打开、点击空白区域关闭

---

## 8. Flutter 前端 - 阅读进度与"正在阅读"（F-205）

- [x] `features/reading/providers/reading_provider.dart`：进度数据管理
  - 加载全部进度列表
  - 按 updated_at 降序排列
  - 下拉刷新
- [x] `features/reading/screens/reading_screen.dart`："正在阅读"首页（实现于 `features/reading/reading_screen.dart`）
  - `GridView` 卡片网格（2 列自适应）
  - `shared/widgets/reading_card.dart`：进度卡片
    - 封面/类型图标（cover 字段优先，视频回退 FFmpeg 缩略图，其余类型渐变+图标）
    - 类型徽标（小说/漫画/视频/音频，蓝色胶囊小标）
    - 标题（单行省略）
    - 细进度条（4px，蓝色）
    - 最后阅读时间（相对时间，如"3 小时前"）
  - 卡片整体可点击 → 进入对应阅读器/播放器并恢复进度（打开逻辑提取为 `shared/utils/open_media.dart`，与收藏页共用）
  - 长按卡片 → "标记为已读完"选项
- [x] 空状态：书本图标 + "还没有阅读记录，去浏览页看看吧"

---

## 9. Flutter 前端 - 动态模块（F-301 ~ F-304，二期 M5）

> 动态模块为后端主导功能，Flutter 端主要负责 UI 展示。

- [ ] `features/feed/providers/feed_provider.dart`：动态数据管理
- [ ] `features/feed/screens/feed_screen.dart`：动态流 UI
  - 时间序卡片列表：`ListView.builder` + 无限滚动（`ScrollController` 触底加载更多）
  - 卡片内容：平台徽标、作者、封面缩略图、标题、发布时间（相对时间）、类型徽标
  - 视频/音频动态点击内嵌播放（复用统一播放器）或跳转原站
  - "已看到此处"进度锚点
  - 下拉刷新加载最新
  - "全部标为已读"按钮
- [ ] 稍后观看（F-304）：
  - 动态卡片书签按钮（点击收录/取消，实心高亮）
  - 顶栏书签图标 + 数量角标
  - 点击角标展开稍后观看列表（`BottomSheet`）
  - 列表支持单条移除、内嵌播放
- [ ] 订阅源管理：设置页添加/编辑/删除/启停
- [ ] 手动触发抓取按钮

---

## 10. Flutter 前端 - 设置模块（F-401 ~ F-403）

- [x] `features/settings/screens/settings_screen.dart`：设置页 UI（实现于 `features/settings/settings_screen.dart`）
  - 分组卡片列表：`ListView` + `Card` + `ListTile`
  - 每组：标题 + 列表行（行尾 chevron 或 Switch）
- [x] 路径源管理：条目列表 + iOS 风格开关（`Switch.adaptive`）+ 添加按钮
- [x] 阅读器偏好：字号、行距、主题、翻页模式（复用阅读器 provider）、漫画模式/方向（复用漫画 provider，新增"自动"恢复）
- [x] 播放设置：默认倍速、转码质量偏好（`playerSettingsProvider`，播放器打开时应用倍速、转码偏好决定直链/HLS 优先级）
- [x] 动态设置：抓取频率、保留条数上限（经 `/api/config` 持久化，M5 消费）；平台凭据（订阅时扫码获取，文案提示）
- [x] 账号安全：修改密码行
- [x] 系统信息：存储用量（图片缓存大小 + 清理按钮）；任务日志待 M5 动态模块落地
- [x] 设置持久化：`GET/PUT /api/config`（`appConfigProvider`；回收站保留天数后端定时任务已改读 DB 配置）
- [x] Flutter 专属设置：
  - 离线缓存管理（显示缓存大小 + 清理按钮）
  - 主题跟随系统开关（关闭后可手动选亮/暗）
  - 关于（版本号 `package_info_plus`、开源许可 `showLicensePage`）

---

## 11. Flutter 前端 - 多平台适配（F-501）

> 前置：`flutter create --platforms=android,ios` 已补充 Android/iOS 平台入口。

### 11.1 Android

- [x] 边缘到边缘（Edge-to-Edge）：`SystemUiMode.edgeToEdge` + 透明状态栏/导航栏（`AnnotatedRegion<SystemUiOverlayStyle>`）
- [x] 状态栏图标颜色跟随主题（按 effectiveThemeMode 推导明暗）
- [x] 系统返回手势兼容（浏览页 `PopScope`：多选中先退出多选，子目录先回上级）
- [x] Material 3 动态取色（`dynamic_color`，Android 12+ 生效，其余回退品牌色）

### 11.2 iOS

- [x] `SafeArea` 适配：导航壳内容区 SafeArea（刘海屏、Dynamic Island）
- [x] 状态栏样式跟随主题（同一 `AnnotatedRegion` 覆盖）
- [x] 系统侧滑返回手势兼容（go_router/Material 默认支持，无需改动）
- [x] 橡皮筋滚动效果（`AppScrollBehavior`：iOS/macOS `BouncingScrollPhysics`）

### 11.3 平板/折叠屏

- [x] NavigationRail 自适应（600px 断点，2.3 已落地）
- [x] 双页漫画模式（横屏自动启用，7.2 已落地；设置页可选"自动"）
- [x] 设置页双栏布局（>=1080px：左侧分组导航 + 右侧内容）

### 11.4 桌面端

- [x] 键盘快捷键全局（`CallbackShortcuts`：Ctrl+1..5 切换主 Tab；播放器页内快捷键 5.5 已落地）
- [x] 窗口最小尺寸限制（480×320，`window_manager.setMinimumSize`）
- [x] 文件拖拽上传（`desktop_drop`，4.3 已落地）
- [x] 右键上下文菜单（文件网格/列表行：打开/收藏/重命名/移动/复制/删除）
- [x] 窗口标题栏自定义（`WindowTitleBar`，0.3 已落地）

### 11.5 横竖屏适配

- [x] 横竖屏切换处理（漫画阅读器自动模式按 MediaQuery 宽高比判定，等效 OrientationBuilder）
- [x] 视频播放器：竖屏正常/横屏全屏（移动端全屏横屏锁定，5.2 已落地）
- [x] 漫画阅读器：竖屏单页/横屏双页（7.2 已落地）
- [x] 浏览页：横屏增加列数（`maxCrossAxisExtent` 自适应宽度）

---

## 12. Flutter 前端 - 新增功能

### 12.1 离线进度缓存与同步（F-502）

- [x] drift 数据库 `local_progress` 表：本地进度存储
- [x] 阅读器/播放器退出时：同时保存到本地 drift 和后端 API（`data/repositories/progress_repository.dart`：本地优先写入，随后尝试上报）
- [x] 网络不可用时：仅保存到本地 drift，设置 `synced = false`
- [x] 网络恢复时：批量上传未同步的进度（`shared/providers/progress_sync_provider.dart`：connectivity_plus 监听，恢复时 `syncPending()` 批量上传）
- [x] 冲突处理：后端时间戳更新 → 以最新为准（`syncPending`/`get`/`listMerged` 均比较 updated_at，后端较新则回写本地并跳过上传）

### 12.2 离线下载（F-503，二期）

- [ ] drift 数据库 `download_task` 表：下载队列
- [ ] 下载管理页：下载中/已完成/已暂停列表
- [ ] dio `download()` 方法：支持暂停/恢复/取消
- [ ] 下载进度通知
- [ ] 后台下载（`workmanager` 或 `flutter_background_service`）
- [ ] 离线播放/阅读：从本地文件路径加载
- [ ] 下载存储空间管理：显示占用空间 + 清理按钮

### 12.3 系统通知（F-504，二期）

- [ ] `flutter_local_notifications` 初始化 + 权限申请
- [ ] 动态抓取完成通知
- [ ] 离线下载完成通知
- [ ] 通知点击跳转对应页面（go_router 深层链接）

---

## 13. Flutter 前端 - 浏览器模块（F-601 ~ F-605，M6）

> PC（Windows）+ iOS 双端内置浏览器页签，基于 `flutter_inappwebview`（Windows → WebView2，iOS → WKWebView）。
> 仅 PC / iOS 平台显示"浏览器"页签，其余平台隐藏。

### 13.1 后端数据模型与 API

- [x] `model/browser.go`：Bookmark（id, title, url 唯一键, favicon, created_at）
- [x] `model/browser.go`：BrowserHistory（id, title, url, favicon, visited_at 索引）
- [x] `model/browser.go`：BrowserShortcut（id, title, url 唯一键, sort_order）
- [x] `GET/POST/DELETE /api/browser/bookmarks`：书签 CRUD（url 唯一，重复添加幂等）
- [x] `GET /api/browser/history?cursor=&limit=`：历史分页（visited_at 降序，按日分组由前端处理）
- [x] `POST /api/browser/history`：访问记录上报（前端节流批量上报）
- [x] `DELETE /api/browser/history`：清空历史（`?id=` 单条删除）
- [x] `GET/POST/PUT/DELETE /api/browser/shortcuts`：起始页快捷入口 CRUD + 排序
- [x] Handler/Service/Repository 层：`browser.go`

### 13.2 页签与导航接入

- [x] `features/browser/browser_screen.dart`：浏览器页主界面（顶栏 + WebView 区）
- [x] 路由新增 `/browser` 分支（`AppBranches.browser`）
- [x] PC 侧边栏新增"浏览器"项（`globe` 图标，浏览之后）
- [x] iOS 底部 Tab 新增"浏览器"项（浏览之后，共 5 Tab）
- [x] PC 快捷键更新：Ctrl+1..5 切换主 Tab（浏览器占一个键位）
- [x] 非 PC / iOS 平台隐藏页签（WebView 不可用时降级）

### 13.3 网页浏览核心（F-601）

- [x] `features/browser/widgets/browser_view.dart`：InAppWebView 封装
  - 平台初始化：Windows（WebView2 userDataFolder、Runtime 缺失检测并引导安装）、iOS（WKWebView 配置）
  - 标签页 keepAlive：后台标签保持会话不销毁
- [x] `features/browser/widgets/address_bar.dart`：地址栏
  - URL 智能识别：合法 URL 直接导航，非 URL 输入走默认搜索引擎
  - 显示当前页域名 + 安全图标（HTTPS 锁 / 警示）
  - 聚焦全选编辑、Enter 提交、Esc 取消恢复
- [x] 导航控制：后退 / 前进 / 刷新 / 停止（按历史栈状态禁用）
- [x] 加载进度条：地址栏下方 2px 蓝色进度条
- [x] 页面标题 + favicon 显示
- [x] 错误页：加载失败 / SSL 错误提示 + 重试按钮
- [x] `target=_blank` / `window.open` → 新标签页打开
- [x] iOS 侧滑返回上一页（历史栈空则退出页签，与系统返回手势协调）
- [x] 键盘快捷键（PC）：`Ctrl+T` 新标签、`Ctrl+W` 关标签、`Ctrl+L` 聚焦地址栏、`Ctrl+R` 刷新、`Alt+←/→` 后退/前进
- [x] 下载链接拦截：一期引导系统浏览器打开（不做下载管理）
- [x] 历史自动记录：页面加载完成节流上报（无痕标签跳过）

### 13.4 多标签页管理（F-601）

- [x] PC 端 `features/browser/widgets/tab_strip.dart`：Chrome 风格标签栏
  - 标签项：favicon / 加载转圈 + 标题 + 关闭按钮
  - 新建（+）/ 关闭 / 切换，中键关闭
- [x] iOS 端标签管理页：卡片网格（域名 / 标题），Safari 风格
  - 底部工具栏：标签数切换、新建、无痕开关
- [x] 标签会话 Riverpod 全局持有（`browserProvider`），切页签不销毁
- [x] 右键 / 长按标签：关闭其他、关闭全部

### 13.5 起始页与快捷入口（F-602）

- [x] `features/browser/widgets/start_page.dart`：新标签页
  - 默认搜索引擎大搜索框
  - 常用站点快捷入口网格（favicon + 标题）
- [x] 快捷入口管理：空位"+"添加（标题 + URL 对话框）、编辑、删除、拖拽排序
- [x] 快捷入口经 `/api/browser/shortcuts` 持久化（跨端同步）
- [x] 首次启动预置默认入口

### 13.6 书签与历史（F-603）

- [x] 地址栏星标：一键收藏 / 取消（已收藏高亮）
- [x] 书签管理页：列表 + 搜索 + 编辑（标题/URL）+ 删除
- [x] 历史管理页：按日分组、搜索、单条删除、清空
- [x] 无痕模式：不记录历史（iOS 标签管理页开关 / PC 菜单入口）

### 13.7 与 myhub 内容联动（F-604，二期）

- [ ] 菜单"收录到稍后观看"：当前页标题 + URL → `/api/feed/watch-later`（依赖 M5 动态模块）
- [ ] UA 切换：菜单"桌面版/移动版"（会话级）+ 设置页默认 UA
- [ ] 动态模块"跳转原站"改走内置浏览器（M5 落地后）

### 13.8 浏览器设置（F-605）

- [x] 设置页新增"浏览器"分组（经 `/api/config` 持久化）：
  - 默认搜索引擎（Google / Bing / 百度 / 自定义 URL 模板）
  - 默认 UA（跟随平台 / 桌面 / 移动）
- [x] 清除浏览数据：缓存 / Cookie / 历史（WebView API + 后端历史清空）

---

## 体验优化、bug修复
---

- [x] 缓存PC的打开窗口大小和位置，每次重新打开按照上次的大小和位置打开
- [x] mini播放器条，做成一个悬浮式的，类似灵动岛那样子
- [x] 播放器播放起始时，屏幕中央，开始按钮和旋转圈动画重叠了
- [x] 播放器快进、音量、亮度等等调节时，目前没有数字显示，需要有一个数值的显示
- [x] 点击头像框，直接跳到个人主页
- [x] 路径源，测试链接正常时候，给一个绿点提示，异常时候，给一个红点提示，点击连接测试，连接成功时，提示词里面加一下连接成功内外还是外网
- [x] 路径显示设置的缓存
- [x] 目前音视频、漫画文件的封面都没有显示（包括阅读页面，浏览界面）
- [x] 漫画文件没有阅读的进度显示和缓存：阅读界面没有显示；每次打开还是从第一页开始
- [x] 网络不好的情况下，webdav路径源，点击漫画文件没有反应，需要等待一段时间才进入阅读界面，期间可以频繁点击，优化下，点击后先展示ui，进入加载界面
- [x] 视频播放，没有按照播放历史进度，播放到历史记录
- [x] 音视频播放现在的退出按钮，改为直接退出，不进入mini播放器模式，单独在下方的功能栏，增加一个按钮进入mini模式。
- [x] 移动端模式，播放音视频时候，可以从中间向下拖动，进入mini模式，需要有过渡动画
- [x] mini播放条，暗黑模式和白天模式，和背景黑色融为一体了，增加一点点边框
- [x] 应用图标更新
- [x] 浏览界面，点击了不支持预览的文件时候，底部拉起一个菜单栏，里面有`纯文本`显示，点击后显示一个纯文本的界面，和小说阅读界面区分开来
- [x] 阅读界面，文件增加以列表的方式显示；目前长按文件是显示菜单，改为进入多选模式
- [x] 点击纯图片文件，进入独立图片预览界面（与漫画阅读器区分），支持左右滑动/点击分区/键盘/浮动按钮手动切换上一张、下一张
- [x] 阅读界面，阅读完成的记录也显示在阅读界面上，直到用户手动删除，把目前的标记以读完，改为删除阅读记录
- [x] 浏览界面，各个平台操作总结优化下
- [x] ios音量调节不是和系统音量一起调节的
- [x] epub缺少漫画判断
- [x] 小说阅读器。历史记录，章节跳转有问题，需要先跳转到对应章节，才能跳到历史记录
- [x] 播放界面。暂停和播放的提示，图标是反的
- [x] 浏览界面，当处于mini模式播放时，再次单击相同的文件，切换到完整播放模式
- [x] mini播放参考qq音乐的ui
- [x] 阅读界面，菜单栏没有删除文件的选项，多选模式，删除文件的按钮，超出手机屏幕了
- [x] 不同分辨率的视频，显示有问题，比如竖屏视频显示
- [x] 连续播放推荐
- [x] ios的收藏界面缺少
- [x] ios端的浏览界面，增加手指从左侧滑动时候的返回上一级的功能，需要有一个过渡动画，手指滑动时候，当前目录界面滑到右侧，被划过的地方显示上一级目录的内容
- [x] 正在阅读界面，如果文件已经读完，现在默认都是显示已读完，优化下，当文件是视频类型时候，显示已看完，当文件是音频类型时候，显示已听完，当文件是漫画、小说等类型时候，显示已看完，默认显示已读完
- [x] PC端，侧边栏，浏览界面，鼠标移动到上面，没有对应的选中效果，参考正在阅读界面列表模式的选中效果。
- [x] ios端，浏览界面在点击长按某一项文件时候，也没有对应的选中效果
- [x] ios端，正在阅读和浏览界面右上角的 ... 按钮，点击后的菜单栏，动画效果和项目不太配，美化一下（例如菜单栏改成圆角、显示动画美化等等）。PC端同样也美化下，包括 ...按钮，右键菜单。
- [x] ios端，第一次打开，会在白屏界面停留一段时间，看上去是在等待判断内网还是外网，优化下这里等待的白屏，有一个loading动画
- [ ] 视频播放增加一个纯音频播放模式
- [ ] 加一个内置的浏览器（需求已拆解至第 13 章浏览器模块，F-601~F-605）
