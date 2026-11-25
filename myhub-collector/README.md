# myhub-collector

每天定时拉取关注列表，把**前一天**发布的内容（视频 / 图文 / 文字动态）下载到本地，并生成一份 Markdown + HTML 总结。

当前进度：**B 站 + YouTube + 抖音 三平台闭环**（订阅 → 当天内容 → 按发布顺序下载 → 日报）。B 站走关注列表动态流，YouTube 走频道 RSS（免登录），抖音用 Playwright 复用已登录的浏览器抓关注列表和作品。

## 快速开始

装好依赖后，**不想碰命令行就双击 `start-web.bat`**：浏览器会打开本地门户（`http://127.0.0.1:8765`），登录、看下载进度、改配置都在页面上点，不用记任何命令。见下方「[本地门户](#本地门户)」。

想用命令行，第一次走初始化脚本（建虚拟环境、装依赖和浏览器、生成 `.env`、自检）：

```powershell
cd c:\Code\myhub\myhub-collector
powershell -ExecutionPolicy Bypass -File scripts\setup.ps1
# 也可以直接双击 scripts\setup.cmd
```

之后三个平台都是**弹窗手动登录**，一次搞定：

```powershell
python -m app login all     # 依次弹出浏览器，各自登录后自动导出 Cookie
python -m app status        # 随时查看三个平台登录态
```

再同步关注 / 频道并采集：

```powershell
python -m app sync                              # 关注列表 → 订阅源
python -m app collect --day 2026-11-22 --no-download   # 试跑，只抓不下载
python -m app collect                           # 抓取 + 下载 + 日报
```

已有环境（依赖装好了）可以跳过安装，只做自检：`scripts\setup.ps1 -NoVenv -SkipDeps -SkipBrowser`；
平时只查状态用 `python -m app init`。

报告默认输出 `data/reports/YYYY-MM-DD.html`（可用 `REPORT_DIR` 改到别的盘），内容即文字总结：先「总览」（各平台 UP 主数 / 内容数 / 类型构成），再「详细」清单——失败的全部排在前面并带失败原因，其后是成功与其他状态。

## 本地门户

双击 `start-web.bat`（等价于 `python -m app serve`），浏览器自动打开 `http://127.0.0.1:8765`：

| 页面 | 能做什么 |
| --- | --- |
| 概览 | 三平台登录态、环境自检、同步订阅、选日期与平台直接采集；任务运行时抽屉顶部有进度条，显示当前第几个、已下 / 总量、下载速度与剩余时间，日志实时滚动，关掉页面也不影响后台 |
| 平台登录 | 点「登录」弹出浏览器窗口，完成后自动保存并关闭；支持一键依次登录三个平台，等待时长可选 |
| 链接下载 | 直接粘贴链接下载，不用等采集：抖音单视频、B 站单视频（`?p=N` 只下该 P）/ 稍后再看、YouTube 单视频 / 播放列表 / 稍后观看；一次多条，分享文案里夹着链接也能识别；解析结果逐条列出状态、大小与失败原因，落盘命名和采集完全一致 |
| 下载进度 | 按内容发布日归档：完成 / 失败 / 待下载 / 占用空间、进度条、失败原因、「重新采集这一天」（重抓再下）、「只重新下载 N 条」（沿用已入库清单，只补失败 / 待下载，不重抓）、打开当天日报 |
| 环境配置 | 表单化编辑 `.env`，保存前校验类型和枚举；自动备份 `.env.bak`；`DATA_DIR` 等改动会提示重启；目录项点「选择…」可浏览本机目录后回填（`DATA_DIR` / `DOWNLOAD_DIR` / `REPORT_DIR` / ffmpeg 目录 / 抖音浏览器目录） |

服务只绑 `127.0.0.1`，且所有 `/api/*` 需页面内注入的随机令牌，外部网页无法调用。同一时间只允许一个任务（登录 / 采集互斥），避免 Playwright 抢 profile、B 站风控和 SQLite 并发写。

## 命令

| 命令 | 说明 |
| --- | --- |
| `python -m app serve [--port 8765] [--no-browser]` | 启动本地门户（只监听本机，端口占用自动顺延） |
| --- | --- |
| `python -m app collect [--day YYYY-MM-DD] [--platform bilibili\|youtube\|douyin\|all] [--no-download] [--no-sync] [--no-collect] [--mid MID] [--id 内容号 ...]` | 采集指定日期（默认昨天）并下载、生成总结 |
| `python -m app sync [--platform bilibili\|youtube\|douyin\|all]` | 仅同步订阅源（B 站关注列表 / YouTube 频道清单 / 抖音关注列表） |
| `python -m app login all\|bilibili\|youtube\|douyin [--wait 秒] [--profile 目录]` | 弹窗手动登录（`all` 依次跑三个平台），Cookie 统一导出到 `data/credentials/<平台>.txt`；中途关窗口即取消 |
| `python -m app status` | 查看三个平台登录态（是否有效、过期时间、来源） |
| `python -m app init` | 首次自检：Python / 依赖 / 浏览器 / ffmpeg / Deno / 配置 / 登录态，不改数据（缺 Deno 会自动下载） |
| `python -m app deps` | 检查并按需下载 Deno（YouTube 解 JS 挑战用；启动脚本会先跑一次） |
| `python -m app list [--day YYYY-MM-DD]` | 查看某天已入库内容 |
| `python -m app report [--day YYYY-MM-DD]` | 重新生成某天报告 |
| `python -m app clean [--keep-days N] [--dry-run]` | 删除早于保留天数的下载文件，并清理对应下载记录（`--dry-run` 只统计） |
| `python -m app fixtime [--day YYYY-MM-DD] [--dry-run]` | 把已下载文件的修改时间对齐到内容发布时间，回填历史文件用 |

`--no-collect` 跳过抓取，只按库里 `pending/failed` 的记录重下；`--id` 可指定单个内容号重跑（例如重生成某个动态的 HTML）。

### 每天自动跑

```powershell
powershell -ExecutionPolicy Bypass -File scripts\register-task.ps1
```

注册 Windows 计划任务「MyHubCollector」，每天 06:00 跑一次，日志在 `data/logs/collect.log`。
媒体清理需要另外执行一次 `python -m app clean`（可再加一条月度计划任务，或用 `--keep-days` 临时指定）。

## 目录结构

```
app/
  config.py          # 配置（.env）
  models.py          # subscriptions / contents / downloads / run_logs
  credentials.py     # 登录态统一层：路径、Netscape 读写、cookiefile/cookie_header/status
  browser.py         # Playwright 公共封装：持久化上下文 / 登录判定 / profile 占用
  login.py           # python -m app login <platform> 的统一实现
  cookies.py         # 兼容层：旧 B 站 / YouTube 接口，内部转发 credentials
  sources/           # 抓取源：bilibili（动态流）/ youtube（频道 RSS）/ douyin（浏览器抓取）
  downloader/        # yt-dlp 视频 / 直链 mp4（抖音）/ httpx 图片
  summarize.py       # 日报 HTML（总览 + 失败优先明细）
  cleanup.py         # 按 KEEP_DAYS 清理过期媒体与下载记录
  linkdl.py          # 按链接下载：链接识别 → B 站接口 / yt-dlp / 抖音浏览器解析 → 入库 → 复用下载器
  pipeline.py        # 编排：同步 → 抓取 → 下载 → 报告
  jobs.py            # 门户后台任务：线程、日志/stdout 捕获、任务互斥
  envfile.py         # .env 的表单结构、校验与写回（带 .env.bak 备份）
  webapp.py          # 本地 HTTP 服务 + JSON API（只用标准库）
  webui.py           # 门户单页 HTML（内嵌 CSS/JS，无前端构建）
  __main__.py        # CLI（collect / sync / login / status / init / serve …）
start-web.bat        # 双击启动本地门户
scripts/
  setup.ps1          # 首次初始化：venv + 依赖 + 浏览器 + .env + 自检
  setup.cmd          # 双击即可运行的 setup 入口
  register-task.ps1  # 注册每日计划任务
data/
  collector.db       # SQLite
  credentials/               # 三个平台登录态的唯一位置（Netscape cookies.txt）
    bilibili.txt             # login 自动写入；也可手工替换
    youtube.txt
    douyin.txt               # 抖音登录后自动导出（给 yt-dlp 兜底）
  browser/                   # 登录/抓取用的独立浏览器 profile
    douyin/                  # 抖音必须靠它（接口要真实浏览器环境）
    bilibili/  youtube/      # 由 login 命令创建
  tools/deno/deno.exe        # YouTube 解 JS 挑战用的 Deno（首次运行自动下载，40MB 包 / 90MB 文件）
  reports/2026-11-22.html
downloads/           # 下载根目录 = DOWNLOAD_DIR，平铺、不建作者/日期子目录
  Bili-UP主-视频标题-BV1xx411c7mD.mp4                  # 单 P 视频
  Bili-UP主-合集标题-BV1xx411c7mD-[P3].mp4             # 多 P 视频，分 P 号放最后
  Bili-UP主-文字动态-1273917639684521990.html          # 纯文本 / 专栏动态
  Bili-UP主-图文动态-1273917639684521990.html          # 图文动态：正文 + 图片（base64 内嵌），单文件
  DouYin-作者-作品文案-7400000000000000001.mp4           # 抖音视频（直链 mp4）
  DouYin-作者-作品文案-7400000000000000002.html          # 抖音图文（图片 base64 内嵌）
```

命名规则：`平台-作者-文件名称-发布号-[Pn]`
平台前缀 `Bili` / `DouYin` / `Youtube`；发布号是 bvid 或动态 id；`[Pn]` 只在多 P 视频里出现，且固定放在最后。

## 配置项（.env）

登录态不在 `.env` 里配——三个平台都用 `python -m app login` 弹窗登录，文件落在 `data/credentials/`。

| 键 | 默认 | 说明 |
| --- | --- | --- |
| `BROWSER_CHANNEL` | chrome | 三平台登录 + 抖音抓取共用的浏览器通道：`chrome` / `msedge` / `chromium`，留空用 Playwright 自带 Chromium |
| `DATA_DIR` | data | 数据库 / 登录态根目录 |
| `DOWNLOAD_DIR` | 空 | **下载根目录**（平铺存放所有成品文件），留空 = `data/downloads`；也可写绝对路径如 `D:\Media\Bili` |
| `REPORT_DIR` | 空 | **报告输出目录**（每日 HTML 汇总），留空 = `data/reports`；也可写绝对路径如 `D:\Media\Reports` |
| `OUT_DIR` | 空 | 旧配置，`DOWNLOAD_DIR` 未设置时才生效 |
| `REQUEST_INTERVAL` | 1.2 | 请求间隔（秒），防风控 |
| `MAX_PAGES` | 5 | 单个作者最多翻几页动态（一页约 20 条） |
| `FILE_MTIME_FROM_PUBLISH` | `true` | 下载完成后把文件修改时间设为内容发布时间，资源管理器按「修改日期」排序即发布顺序 |
| `YOUTUBE_CHANNELS` | 空 | 手动追加的 YouTube 频道：频道 ID（`UCxxx`）/ `@handle` / 频道主页链接，逗号或换行分隔；留空就只用自动同步的订阅列表 |
| `YOUTUBE_SUBSCRIPTIONS` | `true` | 自动并入登录账号的订阅列表（读 `youtube.com/feed/channels`，需要 Cookie）；设 `false` 就只用 `YOUTUBE_CHANNELS` |
| `YOUTUBE_COOKIEFILE` | 空 | 兼容项：指向任意 cookies.txt 时会自动收编到 `data/credentials/youtube.txt`（仅一次性迁移，之后用 `login` 刷新） |
| `YOUTUBE_PROXY` | 空 | 给 YouTube 单独指定代理，留空跟随 `PROXY` |
| `DOUYIN_HEADLESS` | `false` | 抖音抓取是否无头运行；无头更容易撞验证码，默认开窗口 |
| `DOUYIN_MAX_SCROLLS` | 30 | 关注列表 / 作者主页最多滚几次（每次约 20 条） |
| `DOUYIN_PROXY` | 空 | 给抖音单独指定代理，留空跟随 `PROXY` |
| `PROXY` | direct | `direct` 直连 / `system` 跟随系统代理 / 填代理地址 |
| `QUALITY` | 1080 | `best` / `1080` / `720` / `audio` |
| `DOWNLOAD_IMAGES` | true | 是否下载图文动态的图片 |
| `MAX_DURATION_MINUTES` | 0 | 单条视频最长时长（分钟），0 = 不限制；B 站多分 P 按总时长算，超长的只存一张含标题和封面的 HTML 预览，不下载视频本体 |
| `KEEP_DAYS` | 30 | 保留天数，`python -m app clean` 按下载记录的完成时间删文件 |
| `FFMPEG_LOCATION` | 空 | ffmpeg 所在目录（如 `C:\Code\ffmpeg...\bin`），留空则只找 PATH；没有 ffmpeg 会退化成单文件流 |

## 设计要点

- **抓取用动态流，不用投稿列表**：`x/polymer/web-dynamic/v1/feed/space` 免 wbi 签名，一次请求即含视频 / 图文 / 纯文本；投稿列表接口 `x/space/wbi/arc/search` 风控严格（-403）。
- **去重键**：视频 `platform + bvid`，动态 `platform + dynamic_id`，重复运行不会重复下载。
- **幂等文件名**：`平台-作者-标题-发布号-[Pn]` 固定命名，`find_files` 前缀匹配命中即跳过，不怕中断（文件名含 `[]`，不能用 `glob` 匹配）。
- **失败可重试**：`downloads.status = failed` 的任务下次运行会被重新挑中。
- **下载顺序**：当天候选按 `published_at` **正序**串行下载——先发布的先下、最新的排在最后，失败会中断在末尾方便继续。
- **YouTube 下载三件套**：① 登录态 `data/credentials/youtube.txt`（`login` 写入），过「Confirm you're not a bot」；② Deno（优先 `data/tools/deno/deno.exe`，其次 PATH），解 nsig / n 挑战；③ `yt-dlp-ejs` 提供挑战求解脚本（已在 pyproject 依赖里）。缺 Deno 只剩 storyboard 预览图，缺 Cookie 会报 bot 校验，两种情况都会翻译成配置提示写进 `downloads.error`。
- **登录态统一层**：三个平台都只认 `data/credentials/<平台>.txt`（Netscape 格式），唯一来源是 `python -m app login <平台>`。旧文件（`data/cookies_*.txt`、`YOUTUBE_COOKIEFILE` 指向的文件）首次访问自动迁移过来，之后不再看 `.env`。Chrome 扩展常把 `.youtube.com` 行的 includeSubdomains 写成 `FALSE` 导致整份被拒，读取时按「域名带点 → TRUE」在内存里修正。
- **画质按短边限制**：格式选择器用 `res` 而不是 `height`，否则 1080x1920 的竖屏 Shorts 会被判成超高而降质到 608x1080。
- **YouTube 用频道 RSS**：`https://www.youtube.com/feeds/videos.xml?channel_id=UC...` 免登录，一次给最近 15 条视频（标题 / 发布时间 / 封面 / 简介）；RSS 的 UTC 时间入库前转本地朴素时间。`@handle` / 频道链接会抓主页取 `channelId`。
- **订阅列表自动同步**：YouTube 没有「我的订阅」公开接口（官方 `subscriptions.list?mine=true` 要 OAuth + Google Cloud 项目），所以借 yt-dlp 现有的 tab 提取器打开 `https://www.youtube.com/feed/channels`（yt-dlp 源码里专门处理 `feed/channels` 的 channel renderer，会自动翻页），带 Cookie 就能拿到全部订阅的 `channel_id` + 频道名。结果与 `YOUTUBE_CHANNELS` 合并去重，取关的走 `enabled=false` 软停用，和 B 站口径一致。
- **视频存视频、动态存网页**：视频用 yt-dlp 落 mp4/mkv；纯文本 / 专栏动态 / 图文动态都落**单个自包含 HTML**——图文动态的图片下载到临时目录后转成 base64 内嵌，最终不留文件夹（离线可读，报告卡片直接链到本地文件）。
- **文件名不带时间、时间靠 mtime**：下载目录平铺、文件按「平台-作者-标题-发布号」命名，按名称排序是作者聚合顺序；所以下载成功后统一 `os.utime` 把 atime/mtime 写成 `published_at`，资源管理器按「修改日期」排序就是发布顺序（B 站 / YouTube / 抖音混排也对）。创建时间（NTFS creation time）改不了，但排序只看修改时间。`clean` 按 `downloads.finished_at` 判断过期，不受影响；历史文件用 `python -m app fixtime` 回填。
- **正文来源**：新版 opus 动态的正文在 `module_dynamic.major.opus.summary.text`（`desc` 常为空），解析时做兜底；重新抓取到同一条内容会刷新标题 / 正文 / 图片清单。落盘前若动态正文仍为空，还会用详情接口补一次（历史数据自愈）。
- **正文表情**：正文里的 `[doge_金箍]` / `[UPOWER_xxx_开饭]` 这类是表情文字，图标 URL 在 `rich_text_nodes[].emoji.icon_url`，解析时存进 `contents.emotes_json`；生成 HTML 时下载图标并以 base64 内嵌（离线也能显示），渲染成 24px 行内图片。
- **抖音不走纯 HTTP**：web 接口要 `a_bogus` / `X-Bogus` 签名，算法随前端发版变，纯 Python 复刻必失效。改用 Playwright 驱动一个**已登录的浏览器 profile**，页面自己算签名，我们只拦 `/following/list` 与 `/aweme/v1/web/aweme/post/` 的响应拿原始 JSON；滚动触发分页，置顶作品不参与判停。
- **抖音下载走直链**：作品 JSON 里的 `video.play_addr` 就是现成 mp4，用 httpx 带 `Referer: douyin.com` 直下（存 `contents.media_url`），比 yt-dlp 的抖音提取器稳（后者要求「新鲜 cookie」，一撞验证页就报错）；直链失效才退回 yt-dlp。图文作品没有直链，按 image 类型走自包含 HTML。
- **抖音登录一次**：`python -m app login douyin`（旧命令 `douyin-login` 仍可用）打开有头浏览器扫码，Cookie 写进 `data/browser/douyin` 独立 profile（不动系统 Chrome），同时导出 `data/credentials/douyin.txt` 给 yt-dlp 兜底；失效时同步会报错并提示重跑。
- **统一登录命令**：`login` 对三个平台是同一套流程（打开有头浏览器 → 轮询登录态 → 导出 Netscape cookies.txt），不用再手工 F12 复制或装导出扩展。`status` 可离线查看三平台登录态与过期时间。
- **没有 .env 登录态**：不再支持用 `BILI_COOKIE` 之类的手工 Cookie 兜底，三个平台都只有一条路——`login` 弹窗。好处是 B 站也能像抖音那样一次登录长期复用，不必再为 Chrome 127+ / Edge 136+ 的 app-bound 加密发愁。

## 已知限制

- 只填 `SESSDATA` 容易被 `-352` 风控拦截，务必粘贴浏览器整段 Cookie。
- 匿名访问动态流也会 `-352`，因此登录态是硬性前提。
- B 站 CDN 有多个镜像节点，个别节点不通会导致单条下载失败（会记为 failed，下次重试）。
- 转发类动态（`DYNAMIC_TYPE_FORWARD`）一期跳过，避免与原作者的原创内容重复。
- YouTube 下载需要 Cookie + Deno 两样都齐：只配 Cookie 会卡在 nsig 挑战（只剩预览图格式），只配 Deno 会卡在 bot 校验；两者都缺时抓取仍正常，只下载失败并在日报里写明原因。
- Deno 放在 `data/tools/deno/` 下，`data/` 被 gitignore，所以没有跟着仓库走。`start-web.bat` 和 `scripts\setup.ps1` 启动前会跑 `python -m app deps`，缺失就从 GitHub Release 自动下载解压（压缩包约 40MB，解压后约 90MB，单文件无需安装）；网络不通时先在 `.env` 设 `PROXY` 再重试。已装 Node 也没用：yt-dlp 对 Node < 23.5 会加 `--experimental-permission` 但没给读权限，EJS 必然失败。
- YouTube 频道 RSS 只有最近 15 条，单个频道一天发超过 15 条会漏（正常频道不会发生）。

## 后续计划

- ~~M2 YouTube：频道 RSS 视频~~（已完成：频道清单 + RSS + yt-dlp 下载）
- M3 Web UI：FastAPI + 静态页（任务进度 / 内容浏览 / 报告查看）
- M4 抖音：Playwright 主页拦截（关注列表标为实验性）
- M5 总结升级：字幕 / ASR + LLM 摘要
