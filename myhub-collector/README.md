# myhub-collector

每天定时拉取关注列表，把**前一天**发布的内容（视频 / 图文 / 文字动态）下载到本地，并生成一份 Markdown + HTML 总结。

当前进度：**M1 = B 站单平台闭环**（关注列表 → 动态流 → 过滤前一天 → yt-dlp 下载 → 日报）。

## 快速开始

```powershell
cd d:\Code\myhub\myhub-collector

# 1) 配置登录态
copy .env.example .env
#    编辑 .env，把浏览器里整段 Cookie 填到 BILI_COOKIE

# 2) 校验登录态 + 同步关注列表
python -m app sync

# 3) 试跑（只抓取不下载）
python -m app collect --day 2026-11-22 --no-download

# 4) 正式跑（抓取 + 下载 + 日报）
python -m app collect
```

报告输出在 `data/reports/YYYY-MM-DD.md` 与 `.html`（浏览器直接打开看卡片图墙）。

## 命令

| 命令 | 说明 |
| --- | --- |
| `python -m app collect [--day YYYY-MM-DD] [--limit N] [--no-download] [--no-sync] [--mid MID]` | 采集指定日期（默认昨天）并下载、生成总结 |
| `python -m app sync` | 仅同步关注列表为订阅源 |
| `python -m app list [--day YYYY-MM-DD]` | 查看某天已入库内容 |
| `python -m app report [--day YYYY-MM-DD]` | 重新生成某天报告 |

### 每天自动跑

```powershell
powershell -ExecutionPolicy Bypass -File scripts\register-task.ps1
```

注册 Windows 计划任务「MyHubCollector」，每天 06:00 跑一次，日志在 `data/logs/collect.log`。

## 目录结构

```
app/
  config.py          # 配置（.env）
  models.py          # subscriptions / contents / downloads / run_logs
  cookies.py         # 登录态：.env → 本地缓存 → 读浏览器
  sources/           # 抓取源（目前 bilibili）
  downloader/        # yt-dlp 视频 / httpx 图片
  summarize.py       # 日报 Markdown + HTML
  pipeline.py        # 编排：同步 → 抓取 → 下载 → 报告
  __main__.py        # CLI
data/
  collector.db       # SQLite
  cookies_bili.txt   # Cookie 缓存（同时给 yt-dlp 当 cookiefile）
  media/2026-11-22/bilibili/作者名/标题 [BV号].mp4
  reports/2026-11-22.md|html
```

## 配置项（.env）

| 键 | 默认 | 说明 |
| --- | --- | --- |
| `BILI_COOKIE` | 空 | 浏览器整段 Cookie，**必填** |
| `BILI_BROWSER` | chrome | Cookie 兜底来源（Chrome 127+ 常失败，可用 firefox） |
| `DATA_DIR` | data | 数据库 / 缓存 / 报告 / 媒体根目录 |
| `OUT_DIR` | 空 | 媒体单独放盘，留空 = `data/media` |
| `REQUEST_INTERVAL` | 1.2 | 请求间隔（秒），防风控 |
| `MAX_PAGES` | 5 | 单个作者最多翻几页动态（一页约 20 条） |
| `PROXY` | direct | `direct` 直连 / `system` 跟随系统代理 / 填代理地址 |
| `QUALITY` | 1080 | `best` / `1080` / `720` / `audio` |
| `MAX_DOWNLOADS_PER_RUN` | 40 | 单次下载条数上限（磁盘保护） |
| `MAX_DOWNLOADS_PER_AUTHOR` | 8 | 单作者上限 |
| `DOWNLOAD_IMAGES` | true | 是否下载图文动态的图片 |
| `KEEP_DAYS` | 30 | 媒体保留天数（清理脚本尚未实现） |

## 设计要点

- **抓取用动态流，不用投稿列表**：`x/polymer/web-dynamic/v1/feed/space` 免 wbi 签名，一次请求即含视频 / 图文 / 纯文本；投稿列表接口 `x/space/wbi/arc/search` 风控严格（-403）。
- **去重键**：视频 `platform + bvid`，动态 `platform + dynamic_id`，重复运行不会重复下载。
- **幂等文件名**：`标题 [ID].mp4` 固定命名，`find_file` 命中即跳过，不怕中断。
- **失败可重试**：`downloads.status = failed` 的任务下次运行会被重新挑中。
- **Cookie 三级回落**：`.env` → `data/cookies_bili.txt` → 读浏览器；Chrome 127+ 的 app-bound 加密会让第三条路失效，属正常现象。

## 已知限制

- 只填 `SESSDATA` 容易被 `-352` 风控拦截，务必粘贴浏览器整段 Cookie。
- 匿名访问动态流也会 `-352`，因此登录态是硬性前提。
- B 站 CDN 有多个镜像节点，个别节点不通会导致单条下载失败（会记为 failed，下次重试）。
- 转发类动态（`DYNAMIC_TYPE_FORWARD`）一期跳过，避免与原作者的原创内容重复。

## 后续计划

- M2 YouTube：订阅列表（InnerTube `FEchannels`）+ 频道 RSS 视频
- M3 Web UI：FastAPI + 静态页（任务进度 / 内容浏览 / 报告查看）
- M4 抖音：Playwright 主页拦截（关注列表标为实验性）
- M5 总结升级：字幕 / ASR + LLM 摘要
