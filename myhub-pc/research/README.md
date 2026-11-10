# M-1 技术预研

对应 [`../TODO.md`](../TODO.md) §0.1。目标是把选型风险清零。

| 预研项 | 状态 | 结论 |
| --- | --- | --- |
| **S1 播放基础** | ✅ 通过 | libmpv + mpvqt 可用，硬解生效（nvdec），CPU 1.3~2.6% |
| **S2 控制层叠加** | ✅ 前置已验证 | QML 叠加层正常浮于视频之上，未被遮挡 |
| **S3 mini 实时预览** | ✅ 通过 | **单 mpv 实例 + `ShaderEffectSource`**，零额外解码、0 丢帧、会话不重载 |
| **S4 浏览器能力** | ✅ 通过 | 3 标签保活、off-the-record 隔离、下载接管（SHA-256 校验）、UA 双向覆盖、favicon、`loadProgress` 全通过 |
| **S5 文本排版** | ✅ 通过 | 10 万字 → 113 页 / 2530 行，重排 34ms（预算 200ms）；锚点往返恒等、跨排版重定位全对、emoji 代理对 0 切分 |
| **S6 原生依赖** | ✅ 通过 | libsmb2 / libarchive / 回环 HTTP 全部跑通实链路 |

---

## 复现

```powershell
# S1：播放基础（会自动生成测试素材）
powershell -ExecutionPolicy Bypass -File s1-player\run.ps1
powershell -ExecutionPolicy Bypass -File s1-player\run.ps1 -Backend d3d11   # 对比实验

# S3：mini 实时预览（首次运行自动生成 180s 长素材）
powershell -ExecutionPolicy Bypass -File s3-mini-preview\run.ps1

# S4：浏览器能力（自带本地 TestServer，不依赖外网；跑完自动清理下载与 profile 存储）
powershell -ExecutionPolicy Bypass -File s4-browser\run.ps1

# S5：文本排版（10 万字行级分页 + 锚点往返；纯 QtGui，不建窗口）
powershell -ExecutionPolicy Bypass -File s5-text\run.ps1

# S6：原生依赖
powershell -ExecutionPolicy Bypass -File s6-native\make-archives.ps1
powershell -ExecutionPolicy Bypass -File s6-native\run.ps1 -SkipSmb

# S6 的 SMB 部分需要管理员（创建一次性账户与共享，测完务必 teardown）
powershell -ExecutionPolicy Bypass -File s6-native\smb-setup.ps1
powershell -ExecutionPolicy Bypass -File s6-native\run.ps1
powershell -ExecutionPolicy Bypass -File s6-native\smb-setup.ps1 -Teardown
```

测试素材由 ffmpeg 生成到 `%TEMP%\myhub-s1-media`、`%TEMP%\myhub-s6-archives`。
该 ffmpeg 仅用于**生成本地素材**、不随产品分发，故其 GPL 构建不影响 MyHub 许可状态。

---

## S1 播放基础（实测数据）

测试机：RTX 4060 + Intel UHD 770 / Windows 11 23H2
素材：1080p HEVC Main, 30fps, 30s, 3720kb/s（含 AAC 音轨）

### S1-A 解码能力（`decode_probe`，无 GUI）

```
[OK] seek exact       5.0->5.00 20.0->20.00 12.5->12.50 0.0->0.00 29.0->29.00  (误差全 0.000)
[OK] hevc_1080p.mkv   H.265/HEVC 1920x1080 dur=30.0s frames_advancing=yes
[OK] multitrack.mkv   H.264 1280x720  |  [OK] sample.avi MPEG-4 part2
[OK] sample.ts        H.264 (mpegts)  |  [OK] sample.mp4 H.264
[OK] audio track enum  total=3 audio=2 langs=[jpn chi]
[OK] audio track switch aid 1 -> 2
[OK] external subtitle sub-add ok=1 sid=2
[OK] subtitle encoding UTF-8 中文字节级比对一致（含 BOM / 无 BOM × auto / utf-8 四组）
[OK] speed set/get     0.5x 1.0x 1.5x 2.0x 3.0x
```

> ⚠️ **`vo=null` 下不能判定硬解**：zero-copy 硬解需要 GPU 渲染上下文，
> 无 vo 时必然回退软解（`hwdec-current=no`），且解码帧被立即丢弃，
> **CPU 占用与丢帧数在此模式下无参考价值**。硬解结论一律以 S1-B 为准。

### S1-B 渲染集成（`render_probe`，GUI + 截帧取像素）

```
actual backend        : OpenGL
[OK] video visible      nonBlack=99.8% colors=521 meanLuma=126.8  (无黑屏)
[OK] playback advancing time-pos=1.10s
[OK] hwdec in render path   hwdec-current=nvdec        ← 真实硬解生效
[OK] realtime playback  advanced 1.17s in 1.2s wall, vf-fps=30.0, drops=0
[OK] CPU usage          2.6% of one core
[OK] seek landed        time-pos=20.000s (err 0.000s)
[OK] QML overlay on top meanLuma 126.8 -> 101.3       ← 叠加层未被遮挡（S2 前置）
```

截帧 `s1-frame-overlay.png` 可见真实彩条画面、mpv 内置时间码 `00:00:20.000`，
以及浮于视频之上的 QML 控制条。

### S1-C 与 QtWebEngine 共存（`compat_probe`）

```
[OK] video renders        left half  nonBlack=50.8%
[OK] web page renders     right half nonBlack=100.0%
[OK] hwdec with WebEngine hwdec-current=nvdec   ← 共存后硬解仍然生效
```

---

## ⚠️ 关键架构发现：mpvqt 强制 OpenGL 后端

`MpvAbstractItem` 继承自 **`QQuickFramebufferObject`**，而非需求文档 §4.1 所写的
`QQuickRhiItem`。前者是 OpenGL 专用的旧路径。

实测对比（同一程序、仅切换 `QQuickWindow::setGraphicsApi`）：

| 后端 | 结果 |
| --- | --- |
| **OpenGL** | ✅ 正常出画，`hwdec=nvdec`，CPU 2.6%，drops=0 |
| **D3D11** | ❌ **100% 黑屏**：nonBlack=0.0%、colors=1、`vf-fps=0.0`、`hwdec-current=(none)`（仅 demux 在推进） |

### 影响与取舍

采用 mpvqt ⇒ **整个应用必须 `setGraphicsApi(OpenGL)`**，而 Qt 6 在 Windows 上默认 D3D11。

好消息是 S1-C 已验证 **OpenGL 后端下 QtWebEngine 与视频可共存且硬解不受影响**，
故该约束当前是可接受的。

两条路线对比：

| 方案 | 工作量 | 后端 | 风险 |
| --- | --- | --- | --- |
| **mpvqt（当前采用）** | 小，已跑通 | 仅 OpenGL | 全局强制 OpenGL；Intel/AMD 旧驱动的 GL 质量参差（需在多机验证） |
| 自写 `QQuickRhiItem` | 大，需自管 `mpv_render_context` 与 RHI 纹理互操作 | D3D11/Vulkan/Metal/GL 全支持 | 实现复杂度高，但与 Qt 6 的 RHI 架构一致，长期更稳 |

**建议**：M2 以 mpvqt 起步（已验证可用），同时把播放器渲染层接口化，
保留后续替换为 `QQuickRhiItem` 的余地；并在 M5 兼容性测试中重点验证
Intel/AMD 显卡的 OpenGL 表现。需求文档 §4.1 应据此修正。

---

## S3 mini 实时预览（实测数据）

需求 §2.4 要求「mini 播放条跨页面保持、点击展开回全屏**复用同一会话不重载**、
显示实时画面预览」。因此要验证的是**单会话双处渲染**，而不是开第二个 mpv 实例。

### 方案

```
PreviewPlayer（唯一的 mpv 实例，常驻）
      │
      ├── 主画面：直接作为 QML Item 显示
      └── mini 预览：ShaderEffectSource { sourceItem: player }  ← 场景图内纹理复制
```

切换「全屏 ↔ mini」靠**改变 Item 的 parent**（`setParentItem`），而非销毁重建。

### 实测结果（13 项判定全通过）

```
[OK] main stage renders        nonBlack=90.0%
[OK] mini preview renders      nonBlack=89.5% colors=343
[OK] main still renders        mini 不会让主画面变黑
[OK] mini mirrors main         luma-hist similarity=0.988     ← 同源证据
[OK] single mpv session        fileLoadedCount 全程 =1        ← 无第二实例
[OK] mini adds no drops        optimized=0 vs main-only=0
[OK] mini survives hidden main nonBlack=90.1%                 ← 跨页面保持
[OK] playback continues        time-pos=33.67s while main hidden
[OK] renders after reparent    nonBlack=99.4%
[OK] session NOT reloaded      fileLoadedCount 1 -> 1         ← 核心判定
[OK] position continuous       35.07s -> 37.90s（不回 0）
[OK] restored to full          nonBlack=90.0%
[OK] still same session        fileLoadedCount=1 across 2 reparents
```

截帧 `s3-frame-mini-only.png` 是最有力的证据：**主画面区域全黑（已隐藏），
底部 mini 条仍显示彩条实时画面且 `pos` 持续推进**。

### 性能（3~5 轮等长稳态对照，窗口内不做 grab）

| 模式 | 丢帧 | CPU |
| --- | --- | --- |
| 仅主画面 | 0 | 1.7% 单核 |
| 主画面 + mini（纹理全分辨率） | **0** | 2.6~3.0% |
| 主画面 + mini（`textureSize` 限制为 114×64） | **0** | 2.6% |

`hwdec=nvdec`、`vf-fps=30.0` 全程稳定。三组 CPU 差异在测量噪声内（均 < 3%），
说明 **mini 预览基本零成本**——纹理复制发生在 GPU 侧，不触碰解码路径。

### 实现要点（供 M2）

1. **只能有一个 mpv 实例**。mini 预览必须用 `ShaderEffectSource` 引用主画面 Item，
   绝不能为 mini 另开一个 mpv —— 那会双倍解码且进度不同步。
2. **切换容器用 reparent，不要销毁重建**。实测两次 reparent 后
   `fileLoadedCount` 仍为 1、position 连续，完全满足「复用同一会话不重载」。
3. **`layer.enabled` 不是必需的**（实测对照：关掉后主画面隐藏时 mini 照常出画，
   `ShaderEffectSource` 自身会驱动源项渲染）。
4. `textureSize` 建议仍设为 mini 的实际尺寸 —— 虽然实测不设也不丢帧，
   但可避免为 114×64 的预览分配 1920×1080 的纹理，省显存与带宽。

### 测量方法上的两个教训

| 坑 | 后果 | 对策 |
| --- | --- | --- |
| 用 `grabWindow()` 取证 | 该调用阻塞渲染线程强制同步，**本身就制造丢帧**。初版把它混进"稳态"窗口，测出 5/0/4 的假丢帧，差点得出「mini 会掉帧」的错误结论 | 丢帧只在**无 grab 的窗口**内测；并与**等长的单处基线**对照 |
| 素材只有 30s + `loop=inf` | 测试时长超过 30s 后视频回绕，mpv 在回绕时**重置 `frame-drop-count`**，导致出现 `-23` 的负增量、分项和大于总数 | 改用 180s 素材；并在采样器中检测回绕（position 变小或 drops 变小）自动丢弃该轮 |

> 补充：初版还有一个 phase 跳转 bug（轮次循环的落点少了 1），导致带判定和 grab 的
> 阶段被重复执行、最终超时。这正是上面那批假丢帧的来源。

---

## S4 浏览器能力（实测数据）

需求 §2.6 / §4.2 要求内置浏览器具备：多标签保活（不销毁、历史栈不丢）、
off-the-record 无痕 profile、下载接管、UA 覆盖、favicon、`loadProgress`。

### 方案

3 个 `WebEngineView` 叠放在 1000×700 容器内，靠 `visible: activeTab === n` 切换
（与真实切标签等价），右侧再挂一个 `offTheRecord: true` 的独立视图。
所有页面由进程内 `TestServer`（`127.0.0.1` 临时端口）提供，**不依赖外网**：

| 路由 | 用途 |
| --- | --- |
| `/tab1` `/tab2` `/tab3` | 蓝/绿/橙底页，内嵌 16×16 favicon，页内 `setInterval(100ms)` 自增 `window.__ticks` |
| `/ua` | 把 `navigator.userAgent` 写进 `<title>`，供页面内取证 |
| `/download` | 128 KiB 附件（`Content-Disposition: attachment`），内容为确定性伪随机字节 |
| `/fav.png` | 16×16 PNG |

判定全部落到可量化证据上：`.png` 截帧取区域像素主色、「隐藏」期页内计数器增量、
`loadStarted` 计数、cookie 内容、服务端实际收到的 `User-Agent`、落盘文件的 **SHA-256**。

### 实测结果（20 项判定全通过）

```
[OK] loadProgress reaches 100     tab1=100 tab2=100 tab3=100
[OK] favicon from page            tab1=image://favicon/http://127.0.0.1:11763/fav.png
[OK] tab renders                  nonBlack=100.0% avgRGB=(31,59,138)
[OK] tab1 shows blue page         avgRGB=(31,59,138) expected dominant blue
[OK] hidden tab keeps running     tab1 ticks 6 -> 12 (delta=6 over ~2.4s hidden, ~2Hz throttled)
                                  lifecycle=Active recommended=Frozen
[OK] hidden tab not reloaded      tab1 loadStarted count stayed 1
[OK] visible tab2 runs            tab2 ticks=27
[OK] switched to tab2             avgRGB=(23,101,53) expected dominant green
[OK] tab1 alive after return      ticks 12 -> 25 (no reset => page was kept alive)
[OK] no reload on switch back     tab1 loadStarted count still 1
[OK] UA override (in page)        navigator.userAgent=MyHubS4Probe/2.0 (dynamic)
[OK] UA override (on wire)        server saw User-Agent=MyHubS4Probe/2.0 (dynamic)
[OK] cookie set in normal profile document.cookie='mh_s4=1'
[OK] incognito isolated           OTR document.cookie='' (same origin, must be empty)
[OK] offTheRecord flags           incognitoProfile.offTheRecord=1, normal=0
[OK] hidden tab keeps history     tab3 canGoBack=true history.length=2 while hidden (/tab3 -> /ua)
[OK] downloadRequested fired      1 request(s) intercepted
[OK] download accepted+completed  state=2 bytes=131072/131072
[OK] downloaded file size         131072 bytes (expected 131072)
[OK] downloaded bytes intact      sha256=2af5d3dffc8442da... matches
[OK] incognito leaves no disk trace  otr dir exists=no privacy files=[]
                                     normal privacy files=[History,Cookies,Visited Links,Favicons]
```

截帧 `s4-frame-tab1.png` / `s4-frame-tab2.png`：左侧底色由蓝转绿，说明切标签
真的在换渲染内容（不是叠了一层不透明矩形）；右侧无痕视图与左侧**同步计时器**
却读不到 cookie，是 profile 隔离的直观证据。

### 实现要点（供 M2）

1. **`WebEngineProfile` 在 QML 里声明时默认就是 `offTheRecord: true`**。
   只设 `storageName` 不翻转该标志——cookie / HTTP 缓存会全留在内存里，
   用户每次重启都掉登录态。必须显式写 `offTheRecord: false`。
   （首次运行就是被这条坑成 `[FAIL] offTheRecord flags … normal=1`。）
2. **后台标签的 `setInterval` 会被节流到约 2Hz**（实测 2.4s 只涨 5~7 次），
   但 `lifecycleState` 仍是 `Active`、`recommendedState` 变成 `Frozen`。
   所以「保活」的可测口径是**页面未被销毁/未重载 + 计数器仍在推进**，
   而不是「后台不受节流」。M2 的阅读进度自动保存、在线状态轮询等
   依赖定时器准确性的功能，必须假定后台是 ~2Hz，不可依赖秒级精度。
3. **切换瞬间采样会拿到旧值**。初版切回前台后只在切换那一刻发了一次
   `runJavaScript`，下一拍（400ms 后）就去读属性，测出 `ticks 12 -> 12` 的假失败。
   正确做法是**连续采样并留观察窗口**（本探针给 ~1.6s），否则会把「采样时机」误读成
   「页面被杀」。这类「用异步采样结果做判定」的地方都要注意回调落地时间。
4. **`renderProcessPid` 在 Qt 6.8 恒为 0**（QML 属性未填充）。
   进程级内存/崩溃归因没有现成接口，M2 若要按标签做资源治理需另找途径
   （`QWebEnginePage` 未暴露 renderer pid）。本次不把它计入判定。
5. **下载接管**：`profile.onDownloadRequested(download)` 里改
   `downloadDirectory` / `downloadFileName` 后调 `download.accept()` 即可无对话框落盘；
   `state` 枚举 0=Requested、1=InProgress、2=Completed，进度靠 `stateChanged` 推。
6. **历史栈**：`canGoBack` 是同步属性，页面隐藏时依然准确；
   `history.length` 需 `runJavaScript` 取（隐藏页只能读、不能靠它驱动 UI）。
   实测 tab3 在隐藏状态下 `canGoBack=true` / `history.length=2`，切标签不丢。
7. **UA 覆盖**：改 `profile.httpUserAgent` 后**下一次导航**立即生效，
   页内 `navigator.userAgent` 与服务端实际收到的头**双向一致**；
   已加载页面不会因改 UA 而重新加载（符合预期，也意味着 UA 变更要提示用户刷新）。
8. **判定无痕不能看 `persistentStoragePath`**：OTR profile 的该属性**并不为空**，
   而是指向 `…/QtWebEngine/OffTheRecord`。必须落到磁盘侧：
   实测该目录**根本不会被创建**，而普通 profile 下有
   `History / Cookies / Visited Links / Favicons`。所以判据是
   「无痕目录无隐私文件，且普通 profile 确实有」——后者保证判定有牙齿。
9. **profile 存储的真实根目录是 `%APPDATA%\<exe名>`**（`storageName` 只是子目录），
   缓存则在 `%LOCALAPPDATA%\<exe名>\cache`。清理脚本一开始按 `%LOCALAPPDATA%\MyHubS4Probe`
   去删，一直在删空气；已按这两条路径修正。

---

## S5 文本排版（实测数据）

需求 §2.3 / §4.3 要求小说阅读器做到：10 万字章节行级分页、字号/行距变更后重排 < 200ms、
锚点（段序 + 段内偏移）跨排版往返一致，且**不切断 emoji 代理对**。

### 方案

纯 `QtGui`（不建窗口、不用 QML）：`QTextLayout` + `QTextLine` 负责**行切分**，
页码由自己按行高累加切分——**页边界只能落在行边界上**，所以不可能出现「半个字被切到下一页」。
语料由固定种子 LCG 生成，100000 个 UTF-16 单元 / 535 段 /
CJK 69447 + ASCII 22703 + 1438 个 emoji 代理对，逐字节可复现。

锚点结构对齐需求 §2.3：`{段落序, 段内 UTF-16 偏移, 片段快照}`，**不含页码与行号**。
页码由偏移现算（二分一次，0.11 µs），所以换字号后同一锚点自然落到新排版下的正确行。

判定全部落到可量化证据上：行区间**精确铺满**段文本（无空洞/无重叠/无丢字）、
行首行尾不落在代理对中间、行宽不溢出列宽、页首尾相接且不超页高、
锚点 `偏移 → 行 → 偏移` 恒等、同一锚点在 3 组排版下都落在含该偏移的行上。

### 实测结果（18 项判定全通过）

```
font db          : 227 families available
corpus           : 100000 UTF-16 units, 535 paragraphs, max paragraph 250 units
mix              : CJK 69447 / ASCII 22703 / emoji pairs 1438
font             : Microsoft YaHei 18 px, lineSpacing 1.6
viewport         : 760x980, padding 24
[OK] font really resolved           'Microsoft YaHei' -> 'Microsoft YaHei', height 23.77 px, ascent 19.05 px
     emoji glyph : U+1F600 present in 'Microsoft YaHei'

--- phase 1: paginate 100k chars ---
     pages=113 lines=2530 layout=34 ms (median of 3; worst 39 ms)
[OK] corpus is 100k units           100000 UTF-16 units in 535 paragraphs
[OK] pagination produced            113 pages / 2530 lines
[OK] full relayout < 200ms          100000 units: median 34 ms, worst of 3 39 ms (budget 200 ms)
[OK] lines tile paragraphs exactly  535 paragraphs split into 2530 lines: no gap / no overlap / no dropped char
[OK] no emoji split at line edge    2530 line boundaries vs 1438 emoji pairs: 0 split
[OK] no line overflows column       0 of 2530 lines exceed 712.0 px
[OK] pages contiguous, no overflow  113 pages, max page height 929.0 / 932.0 px
[OK] giant paragraph < 200ms        100000 units in ONE paragraph -> 2272 lines, median 34 ms / worst 34 ms
[OK] relayout on typography < 200ms 24 px / 1.9x -> 225 pages in 36 ms (18 px gave 113 pages)

--- phase 2: anchor round-trip ---
[OK] anchor round-trip identity     3600 anchors (paragraph head/tail + every line head): offset -> line -> offset is identity
[OK] one-step locate                anchor yields page directly, avg 0.11 us over 3600 lookups
[OK] random offsets stay in line    2000 random offsets: all normalise into their own line
[OK] emoji mid-pair offset safe     1438 emoji positions (incl. offset+1 inside the pair): 0 anomalies
[OK] anchor survives relayout       612 anchors re-located under 15/20 px, 1.6~2.0x spacing, 560/760 px width:
                                    all on the line containing the offset (1193 hit a different page, offset unchanged)
[OK] chapter head -> page 0         page=0 line=0
[OK] chapter tail -> last page      page=112 of 112
[OK] percent fallback monotonic     last paragraph starts at 99%, so a percent fallback never claims 100% early
checks           : 18 passed, 0 failed
RESULT: S5 PASSED
```

### 实现要点（供 M3）

1. **`offscreen` 平台插件下字体库是空的**。首版用 `QT_QPA_PLATFORM=offscreen` 跑，
   `QFontDatabase::families()` 为空、`QFontInfo::family()` 返回空串，
   量出的行高/行数/耗时全是假数据，而判定却「全绿」——这是最危险的一种通过。
   改回默认平台插件（探针不建窗口，不会弹窗）后才有 23.77 px 的真实行高，
   并加了一条 `font really resolved` 把这种**静默空跑变成硬失败**。
2. **段间距必须计入页高预算**。首版只在行后累加 `paragraphSpacing`，结果某页 937 > 932 直接溢出。
   正确做法是把段间距当作「下一段首行」的预算一起算，且**页面顶部不画段间距**（间距不跨页）。
3. **`QTextLayout` 只管行，不管页**。`createLine()` + `setLineWidth()` 出的是行，
   页码要按行高自己累加切——这同时也是「不截断行」的实现保证。
4. **整章无换行（单个 10 万字 `QTextLayout`）同样 34ms**，与 535 段的常规语料同量级；
   txt 里「整章挤一行」的脏数据不需要预切分。
5. **页码/行号绝不能进持久化**。612 个锚点在 3 组排版下有 1193 次落在**不同页**，
   但偏移与片段不变。存档只写 `{段序, 偏移, 片段}`，读档时现算页码。
6. **代理对安全**：`QTextLayout` 自己不会把 emoji 切到两行（2530 个边界 0 越界），
   但外部传进来的偏移可能落在代理对中间，`anchorAt()` 必须向下归一化到字符起点，
   否则会切出半个 emoji。
7. **`QString::size()` 是 UTF-16 单元数，不是字数**。400 个 emoji 记 800 个单元；
   「10 万字」的口径、字数统计、进度百分比都要先声明用哪个（本探针按 UTF-16 单元）。
8. **`QTextStream(stdout)` 在 GBK 控制台会把中文打成乱码**；`run.ps1` 读报告必须
   `Get-Content -Encoding UTF8`（PowerShell 5.1 默认按 ANSI 读无 BOM 文件）。

---

## S6 原生依赖（实测数据）

### S6-A libarchive 漫画解页

```
libarchive 3.8.9
[OK] volume01.cbz    entries=5 regular=5 readable=5   (zip)
[OK]   natural page order  page1 page2 page10 page11 page20
[OK]   page decodable      5/5 entries have JPEG magic (FF D8 FF)
[OK] volume02.7z     entries=5 regular=5 readable=5   (7z，同上)
[OK] volume03.cbr    entries=3 regular=2 readable=2 nonRegular=1   (RAR4)
[OK] volume04_rar5.cbr entries=1 regular=1 readable=1              (RAR5)
```

rar 素材取自 libarchive 官方测试仓库（仓库内以 uuencode 存储，
用 `uudecode.py` 还原；7-Zip 无法创建 rar）。
RAR4 中的 `testlink` 为符号链接，无数据体属正常，判定时只要求**常规文件**可读。

### S6-B libsmb2（MSVC / SMB2/3 实链路）

```
[OK] connect share   connected
[OK] list root       dirs=2 files=2 [readme.txt ramp.bin media/ docs/]
[OK] list subdir     media/ entries=1
[OK] stat ramp.bin   size=256 type=0
[OK] range read      [0,+16)=ok [64,+32)=ok [200,+56)=ok [255,+1)=ok
[OK] read past EOF   pread(offset=1000) returned 0
[OK] disconnect      clean
```

Range 读做了**字节级校验**（测试文件内容为 0..255，offset N 处的字节必须等于 N），
确认 `smb2_pread` 的偏移语义正确——这是边下边播的基础。

### S6-C 回环 HTTP（Range/206）

```
[OK] bind 127.0.0.1       port=8230 (ephemeral, 无需管理员权限)
[OK] Range -> 206         status206=1 contentRange=1 bodyLen=100
[OK] libmpv over loopback loaded=1 time-pos=0.53s codec=H.265/HEVC httpReqs=2 rangeReqs=2
[OK] mpv issues Range     2 of 2 requests carried Range header
```

**结论**：回环方案可行。绑定 `127.0.0.1` 的临时端口无需管理员权限、无需防火墙放行
（Windows 防火墙默认不拦截回环流量）；且 **libmpv 发出的请求全部携带 Range 头**，
说明 seek 能按需取片段，不会整file 下载。

> 残留风险：少数主动防御型安全软件会对"进程监听端口"行为告警。
> 缓解措施（M2 落实）：只绑 `127.0.0.1`（不绑 `0.0.0.0`）、使用临时端口、
> 进程退出即关闭监听、并在设置中提供"诊断"入口说明用途。

---

## 集成踩坑（已修复，供后续参考）

| 问题 | 现象 | 原因与对策 |
| --- | --- | --- |
| `MpvQt/MpvAbstractItem` 找不到 | C1083 | MpvQt 的 include 目录已指向 `include/MpvQt`，**不带前缀**直接 `#include <MpvAbstractItem>` |
| `QML_ELEMENT` 类放在 .cpp | LNK2005 多重定义（含 `main`） | 类型注册代码会 include 声明头；必须把该类拆到**独立头文件**（`ProbePlayer.h`） |
| smb2.h 报一片 C3646「未知重写说明符」 | 看似语法错 | 实为 `uint32_t` 未定义——smb2.h **不自带 `<stdint.h>`**，须先行引入 |
| 回环 HTTP 收不到任何请求 | `httpReqs=0`，自测也超时 | `waitForReadyRead()` 只泵自身 socket 事件；服务端 accept 得不到处理。必须用 `QEventLoop`，且 **mpv 事件要非阻塞轮询**（`mpv_wait_event(h, 0)` + `QTimer`），不能阻塞主线程 |
| 中文字幕乱码 | `瀛樼簵娴嬭瘯` | **PowerShell 5.1 读取无 BOM 的 UTF-8 脚本时按 GBK 解析**，脚本内中文字面量在载入阶段即损坏。改用显式 UTF-8 字节写入。**mpv 本身无问题**（字节级比对四组全通过） |
| `New-LocalUser` 静默失败 | 账户未创建却显示成功 | `-Description` 超 48 字符上限；且 `Out-Null` 吞掉了错误。另 `-UserMayNotChangePassword` 在部分版本会导致失败 |
| `New-SmbShare -FullAccess` 失败 | "No mapping between account names and security IDs" | 该参数只接受**账户名**（`计算机名\用户`），不接受 SID 字符串；而 `FileSystemAccessRule` 则推荐用 SID 对象 |
| QML 里声明的 `WebEngineProfile` | cookie 重启即失，登录态全掉 | QML 声明**默认就是 off-the-record**；只给 `storageName` 不会翻转，必须显式 `offTheRecord: false` |
| 切标签后 400ms 采样 | 测出 `ticks 12 -> 12`，误判「页面被销毁」 | 那次采样是在切换瞬间发出的，读到的还是旧值。异步采样做判定必须留观察窗口并多次采样 |
| `QT_QPA_PLATFORM=offscreen` | 排版耗时 13ms、行数偏少，判定全绿但数据是假的 | offscreen 插件**没有字体库**（`families()` 为空、`QFontInfo::family()` 空串），`QFontMetricsF` 用的是兜底度量。改默认平台插件 + 断言 `family` 非空 |
| 分页后某页 937 > 932 px | 内容溢出页底，最后一行被裁 | 段间距在行后累加却没进预算。把间距算进「下一段首行」的换页预算，且页顶丢弃 |

---

## 尚待完成

- 多显卡验证：当前仅在 NVIDIA 上测得 `nvdec`，需补 Intel 核显（`d3d11va`）与 AMD
