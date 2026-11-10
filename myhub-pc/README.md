# MyHub 桌面端

个人内容中心的桌面形态（Windows + macOS），纯本地运行、无服务器端。
客户端直连 WebDAV / SMB / 本地磁盘，内置全格式播放器、小说与漫画阅读器、内置浏览器。

- 需求与设计：[`需求分析文档.md`](需求分析文档.md)
- 任务清单：[`TODO.md`](TODO.md)
- 页面原型：[`prototype/index.html`](prototype/index.html)
- 原生依赖：[`third_party/README.md`](third_party/README.md)

当前进度：**M0（工程脚手架 + 导航外壳 + 连接源管理 + 文件浏览）已完成**。

---

## 1. 环境要求

| 项 | 要求 | 本机验证版本 |
| --- | --- | --- |
| Qt | 6.8 LTS 或更新（`QQuickRhiItem` 需 ≥ 6.7） | 6.8.3 msvc2022_64 |
| 编译器 | Windows：MSVC 2022；macOS：Xcode 15+ | MSVC 19.44（BuildTools 17.14） |
| 构建系统 | CMake 3.21+ + Ninja | CMake 4.4.4 / Ninja 1.13 |
| C++ 标准 | C++20 | — |
| 包管理 | vcpkg（zlib / sqlite3 / libarchive / libsmb2） | baseline `44ccfd8` |

> Qt 模块：`Core` / `Gui` / `Quick` / `QuickControls2` / `Network` / `Concurrent` /
> `WebEngineQuick` / `Svg`。
>
> ⚠️ **许可红线**：禁止链接 GPL-only 的 Qt 模块
> （HttpServer / Charts / DataVisualization / Lottie / VirtualKeyboard）。
> `cmake/LicenseGuard.cmake` 在 configure 阶段即拦截，详见需求文档 §4.5。

---

## 2. 准备依赖

```powershell
# 1) vcpkg 依赖（按 vcpkg.json 锁定版本）
C:\vcpkg\vcpkg.exe install --triplet x64-windows
C:\vcpkg\vcpkg.exe install ecm:x64-windows          # 仅 mpvqt 构建期需要

# 2) libmpv（下载 + SHA256 校验 + 生成 MSVC 导入库）
powershell -ExecutionPolicy Bypass -File third_party\fetch-libmpv.ps1

# 3) mpvqt（克隆 v1.2.0 + 打 Qt6.8 兼容补丁 + 构建）
powershell -ExecutionPolicy Bypass -File third_party\build-mpvqt.ps1
#    要跑 windows-debug 预设时，还需构建 Debug 版（见下方注意）
powershell -ExecutionPolicy Bypass -File third_party\build-mpvqt.ps1 -Config Debug

# 4) 依赖自检（逐库真实 API 调用）
powershell -ExecutionPolicy Bypass -File third_party\deps-check\run.ps1
```

依赖来源、许可状态与集成踩坑详见 [`third_party/README.md`](third_party/README.md)。

> **mpvqt 必须与构建配置一致**。MSVC 下 Debug 应用依赖 `Qt6Cored.dll` / `Qt6Quickd.dll`，
> 而 Release 版 `MpvQt.dll` 依赖 `Qt6Core.dll` / `Qt6Quick.dll`；混用会把两套 Qt 运行时
> 载入同一进程，`new MpvVideoItem(...)` 在 `QQuickFramebufferObject` 基类构造里直接
> SIGSEGV（日志停在 `attach` 前，没有任何 Qt 报错）。
> - Release 版 → `third_party/mpvqt-install`（默认）
> - Debug 版 → `third_party/mpvqt-install-debug`，由 `build-mpvqt.ps1 -Config Debug` 生成
>
> 顶层 `CMakeLists.txt` 会按 `CMAKE_BUILD_TYPE` 强制 `MpvQt_DIR`，缺失时直接 configure
> 失败并提示该跑哪条命令。

---

## 3. 构建与运行

### 便捷脚本（推荐）

`scripts/build.ps1` 会自动导入 MSVC 环境（`vcvars64.bat`）后配置、构建：

```powershell
powershell -ExecutionPolicy Bypass -File scripts\build.ps1                    # Debug 构建
powershell -ExecutionPolicy Bypass -File scripts\build.ps1 -Test              # 构建 + 跑单测
powershell -ExecutionPolicy Bypass -File scripts\build.ps1 -Run               # 构建 + 运行
powershell -ExecutionPolicy Bypass -File scripts\build.ps1 -Preset windows-release -Clean
```

辅助脚本：

| 脚本 | 用途 |
| --- | --- |
| `scripts/smoke-run.ps1` | 启动数秒并捕获 QML 运行期错误与应用日志 |
| `scripts/diag.ps1` | 输出完整构建错误（排查编译问题用） |

### 手动构建

CMake 预设需要 MSVC 环境已就绪（Ninja 生成器不会自己调用 vcvars）：

```powershell
cmd /c '"C:\BuildTools\VC\Auxiliary\Build\vcvars64.bat" && powershell'
cmake --preset windows-debug
cmake --build --preset windows-debug --parallel
ctest --preset windows-debug
```

预设中的 Qt 与 vcpkg 路径**不能用环境变量覆盖**：`windows-base` 的 `environment`
会覆盖父进程同名变量（`$env{}` 取的是预设自己的 environment，已实测验证），
`build.ps1 -QtRoot` 只影响 `-Run` 时的 `PATH`。换路径请用 `-D` 显式传入：

```powershell
cmake --preset windows-debug `
  -DCMAKE_PREFIX_PATH="D:/Qt/6.8.3/msvc2022_64;C:/vcpkg/installed/x64-windows;$PWD/third_party/mpvqt-install" `
  -DQt6_DIR="D:/Qt/6.8.3/msvc2022_64/lib/cmake/Qt6"
```

或直接改 `CMakePresets.json` 中的 `environment`（CI 采用前者思路的反向做法：把依赖装到预设写死的位置）。

---

## 4. 目录结构

```
myhub-pc/
├── CMakeLists.txt          # 顶层：依赖查找 + MyHub 目标 + QML 模块 + 部署
├── CMakePresets.json       # Windows / macOS 构建预设
├── vcpkg.json              # 原生依赖版本锁定
├── .clang-format           # 排版基线（只改空白，见 §9）
├── .clang-tidy             # 语义 / 性能静态检查
├── .qmllint.ini            # QML 静态检查
├── cmake/
│   ├── LicenseGuard.cmake  # GPL-only 模块拦截（§4.5）
│   ├── FindLibmpv.cmake    # vendor 的 libmpv
│   ├── FindLibsmb2.cmake   # vcpkg 的 libsmb2
│   ├── QmlModule.cmake     # QML 模块定义
│   ├── RuntimeLibs.cmake   # 随包分发的运行库
│   └── Deploy.cmake        # 安装与 windeployqt/macdeployqt
├── src/
│   ├── main.cpp            # 入口：单实例 + 日志 + 崩溃捕获 + QML 装配
│   ├── core/               # 【纯逻辑层】仅 QtCore/QtNetwork，禁止 QtQuick/QtGui
│   │   ├── storage/        #   适配器：Local / WebDAV / RoutedWebDAV / SMB + 工厂
│   │   ├── database/       #   AppDatabase（sqlite3 C API）+ 版本化迁移
│   │   ├── preferences/    #   AppSettings（键名与 iOS 对齐）
│   │   ├── credentials/    #   系统凭据库
│   │   ├── cache/          #   DirectoryCache
│   │   ├── network/        #   内外网判定启发式
│   │   └── utils/          #   日志 / 崩溃 / 类型识别 / 自然排序 / 格式化
│   ├── app/                # 启动编排 / 路由 / 窗口 / 主题 / 设置桥接
│   ├── features/           # 连接源 / 浏览（QAbstractListModel + 控制器）
│   └── platform/windows/   # 平台分叉点（Mica/Acrylic、深色标题栏）
├── qml/
│   ├── Main.qml            # 根窗口（启动 Loading → 主外壳）
│   ├── theme/              # 设计令牌：Colors / AppTheme / Motion / Icons
│   ├── components/         # 可复用组件（高亮 / 菜单 / 确认框 / 搜索框 …）
│   ├── shell/              # RootShell + 侧边栏（三断点自适应）
│   ├── browse/             # 浏览首页 + 目录页 + 网格/列表单元
│   └── settings/           # 设置双栏 + 连接源列表与表单
├── third_party/            # libmpv / mpvqt（vendor，见其 README）
├── resources/              # 图标等资源
├── tests/                  # QTest 单测与集成测试
└── scripts/                # 构建 / 诊断 / 规范校验 / CI 脚本
```

### 分层约定（需求文档 §5.2）

- **QML 只做展示与交互**，状态经 C++ 的 `Q_PROPERTY` / 信号槽 / `QAbstractListModel` 暴露。
- **`src/core` 不得依赖 QtQuick/QtGui** —— 该约束由「`myhub_core` 不链接这些模块」
  从**编译期强制**：一旦误 include 即编译失败。逻辑层因此可被 QTest 直接覆盖。
- 因此 `AppSettings` 这类核心类通过 `src/app/SettingsBridge` 薄包装暴露给 QML。
- **`src/platform` 是唯一的平台分叉点**。

---

## 5. 测试

```powershell
powershell -ExecutionPolicy Bypass -File scripts\build.ps1 -Test
```

当前覆盖（6 个用例集，全部通过）：

| 测试 | 覆盖内容 |
| --- | --- |
| `tst_storagepath` | 虚拟路径归一化 / join / 扩展名 / 父目录 / 子路径判定 / 百分号编码 |
| `tst_storageerror` | **路由自愈分类**（仅连接类/网关类可回退）、瞬时错误重试判定 |
| `tst_webdavparse` | PROPFIND 解析；**异常响应不得当作空目录**（HTML 错误页 / 截断 XML） |
| `tst_naturalsort` | 自然排序（含前导零、超 64 位数字串、漫画页名） |
| `tst_networkheuristics` | 内外网判定（私有段边界 172.15/172.32、`.local`、无点主机名） |
| `tst_e2e_browse` | 集成：9 表迁移 + 外键级联 + 本地适配器列举/stat/Range 读 + 目录缓存 |

---

## 6. 数据位置

| 类别 | Windows | macOS |
| --- | --- | --- |
| 结构化数据 | `%APPDATA%\MyHub\myhub.sqlite` | `~/Library/Application Support/MyHub/` |
| 偏好 | `%APPDATA%\MyHub\settings.ini` | 同上 |
| 自动备份 | `%APPDATA%\MyHub\backup\`（保留 7 份） | 同上 |
| 日志 / 崩溃 | `%APPDATA%\MyHub\Logs\` | `~/Library/Logs/MyHub/` |
| 可重建缓存 | `%LOCALAPPDATA%\MyHub\Cache\` | `~/Library/Caches/MyHub/` |
| 凭据 | Windows Credential Manager（key `conn.<id>`） | Keychain |

设置 → 关于中可直接「打开数据目录 / 日志文件夹」。

---

## 7. LGPL 合规

本项目使用 Qt 开源版（LGPLv3），合规要点见需求文档 §4.5：

- Qt 与 libmpv / libsmb2 / mpvqt **一律动态链接**，安装目录内动态库可替换。
- 「设置 → 关于」页列出各依赖许可证。
- 对 mpvqt 的修改以补丁形式公开（`third_party/patches/`）。
- CI/configure 期拦截 GPL-only Qt 模块。

> ⚠️ **待处理**：当前 vendor 的 libmpv 预编译包为 **GPL 构建**（内含 x264/x265）。
> 发布前必须替换为自编译的 LGPL 版，或改用 libVLC。
> 详见 [`third_party/README.md`](third_party/README.md)「许可状态」。

---

## 8. 原型维护约定

`prototype/` 是正文的**可视化补充，不是独立规范**：

- 原型与《需求分析文档》正文冲突时**以正文为准**。
- 实施中方案变更须**同步更新原型与正文**。

---

## 9. 代码规范与 CI

三件工具各管一段、互不重叠，统一入口 `scripts/lint.ps1`：

| 工具 | 管什么 | 配置 | 当前基线 |
| --- | --- | --- | --- |
| `clang-format` | 排版（**只动空白**） | `.clang-format`（clang-format 19） | 68 个文件零 diff |
| `clang-tidy` | 语义 / 性能 | `.clang-tidy`（需 `compile_commands.json`） | 37 个 TU、0 findings |
| `qmllint` | QML 静态检查 | `.qmllint.ini` | 30 个 QML 文件干净 |

```powershell
powershell -ExecutionPolicy Bypass -File scripts\lint.ps1            # 校验（退出码 0/1）
powershell -ExecutionPolicy Bypass -File scripts\lint.ps1 -Fix       # 就地格式化
powershell -ExecutionPolicy Bypass -File scripts\lint.ps1 -SkipTidy  # 跳过最慢的一段
```

一条命令跑完整流水线（构建 → 单测 → 规范校验），与 CI 执行体是**同一份脚本**：

```powershell
powershell -ExecutionPolicy Bypass -File scripts\ci.ps1
powershell -ExecutionPolicy Bypass -File scripts\ci.ps1 -Preset windows-release -SkipTidy
```

`build.ps1` / `lint.ps1` / `ci.ps1` / `third_party/build-mpvqt.ps1` 的参数命名统一
（各自只接受用得上的那几项），默认值即本机开发环境：
`-QtRoot` / `-VcVars` / `-SkipVsEnv` / `-LlvmBin` / `-VcpkgInstalled`，
`build-mpvqt.ps1` 另有 `-Config Debug|Release`（必须与应用的构建类型一致）。

### 9.1 约定与踩坑（改规范配置前先读）

- **格式化 diff 必须可逐行评审**：`SortIncludes: Never`、`IncludeBlocks: Preserve`、
  `ReflowComments: false`。include 排序会让格式化变成「整段搬行」，评审时看不出真实变化。
- **`.clang-tidy` 的 `Checks:` 是折叠标量**（`>`）：块内**不能写 `#` 注释**——注释会被
  当成通配模式混进 `Checks`，导致其后的 `-xxx` 禁用项**静默失效**（症状：明明禁了还在报）。
- **`.qmllint.ini` 的键是 PascalCase**（`MissingProperty=disable`），全小写形式会被静默忽略。
  当前仅禁用 `MissingProperty`：单例属性经 `AppTheme.colors` 间接访问时 qmllint 无法解析类型。
- **委托里的 `pragma ComponentBehavior: Bound` 是真修不是抑制**：让委托内对外部 id 的引用
  成为绑定，qmllint 的未限定访问告警因此消失（已用 `QT_QPA_PLATFORM=offscreen` 起窗验证无绑定错误）。
- **工具缺失直接失败**：`lint.ps1` 找不到 `clang-format` / `clang-tidy` / `qmllint` 立即退出 1，
  不静默跳过（静默跳过等于「永远绿」）。

### 9.2 流水线

[`.github/workflows/ci.yml`](../.github/workflows/ci.yml) 只负责**装环境**
（MSVC / Qt / vcpkg / LLVM / libmpv / mpvqt），构建、单测、规范校验全部调用
`scripts/ci.ps1`——避免「workflow 一套、本地一套」的双份逻辑漂移。

> CI 把 Qt 与 vcpkg 装到 `C:/Qt/6.8.3/msvc2022_64` 与 `C:/vcpkg/installed/x64-windows`，
> 因为预设的 `environment` 会覆盖父进程环境变量（见 §3），只能让环境去迁就预设。
>
> macOS 流水线与 `libsmb2` 的 macOS 构建一并留到跨平台阶段（见 [`TODO.md`](TODO.md) §0.1）。
