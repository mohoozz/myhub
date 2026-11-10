# 原生依赖（third_party）

本目录记录 MyHub 桌面端的原生依赖来源、锁定版本与获取方式。
对应《需求分析文档》§8.3 关键依赖清单、§4.5 许可合规，以及 `TODO.md` §0.2 与 §0.1-S6。

> 复现顺序：`vcpkg` 依赖 → `fetch-libmpv.ps1` → `build-mpvqt.ps1` → `deps-check/run.ps1`

---

## 1. 依赖总表

| 依赖 | 版本 | 许可 | 获取方式 | 链接方式 |
| --- | --- | --- | --- | --- |
| **zlib** | 1.3.2#2 | zlib | vcpkg | 动态（`z.dll`） |
| **sqlite3** | 3.53.4#2（+json1） | Public Domain | vcpkg | 动态（`sqlite3.dll`） |
| **libarchive** | 3.8.9（bzip2/crypto/lzma） | BSD-2-Clause | vcpkg | 动态（`archive.dll`） |
| **libsmb2** | 6.2 | **LGPL-2.1-or-later** | vcpkg | **动态（`smb2.dll`，LGPL 强制要求）** |
| **libmpv** | 0.41.0-1154-gec38361c5（release 20261014） | **见下方许可状态** | `fetch-libmpv.ps1` | 动态（`libmpv-2.dll`） |
| **mpvqt** | v1.2.0（KDE） | **LGPL-2.1/3.0** | `build-mpvqt.ps1` | **动态（`MpvQt.dll`）** |
| openssl | 3.6.5#1 | Apache-2.0 | vcpkg（libarchive `crypto` 传递依赖） | 动态 |
| bzip2 / liblzma | 1.0.8#6 / 5.8.4 | BSD / 0BSD | vcpkg（传递依赖） | 动态 |
| ECM（KDE） | 6.30.0 | BSD-3-Clause | vcpkg（**仅 mpvqt 构建期需要**，不参与分发） | — |

vcpkg 版本由仓库根部 [`../vcpkg.json`](../vcpkg.json) 锁定
（`builtin-baseline: 44ccfd88b3eca6929d6d16398c7b19945c29a5f6`，triplet `x64-windows`）。

### 为什么统一用动态库（x64-windows 而非 x64-windows-static）

`libsmb2`、`libmpv`、`mpvqt` 均为 **LGPL**，按 §4.5 必须动态链接并保持安装目录内可替换，
以满足「重新链接」义务。因此整条依赖链统一采用动态库 triplet。

---

## 2. 许可状态（⚠️ 发布前必须处理）

### libmpv 当前为 GPL 构建，与「LGPL 闭源分发」目标冲突

`fetch-libmpv.ps1` 锁定的 shinchiro 预编译包**是 GPL 构建**，其 FFmpeg 链接了
**x264 / x265**（GPL-2.0+）、**libdvdcss**（GPL-2.0+）等组件。mpv 本体虽为 LGPL-2.1+，
但链接 GPL 依赖后整体落入 **GPL-2.0+**。

这与《需求分析文档》§4.5「附许可证副本并明示使用 Qt… 闭源分发」的前提不符。

**现状定位**：当前用于 M-1 预研与开发期技术验证。libmpv 的 C API 在 GPL / LGPL
两种构建下**完全一致**，故业务代码无需为此改动，替换构建只需换 DLL + 重新生成导入库。

**发布前（M6 打包）必须二选一**：

1. **自行编译 LGPL 版 libmpv**（推荐）
   - mpv 侧：`--enable-lgpl`
   - FFmpeg 侧：不加 `--enable-gpl`，不链接 x264/x265/libdvdcss
   - 本项目**只做解码播放，不需要任何编码器**，去掉 x264/x265 无功能损失，产物更小
2. **改用 libVLC**（LGPL-2.1+）作为主引擎
   - 《需求分析文档》§4.1 已将 `VlcEngine` 列为兜底引擎并预留接口

> 若项目最终决定以 GPL 开源发布，则当前包可直接沿用，但需在「关于 → 开源许可」页
> 按 GPL 要求声明，并承担源码开放义务。

### mpvqt 的本地修改（LGPL 修改公开义务）

为适配 Qt 6.8 LTS，对 mpvqt v1.2.0 施加了一处补丁，diff 保存在
[`patches/mpvqt-0001-qt68-logging-category.patch`](patches/mpvqt-0001-qt68-logging-category.patch)：

- `Q_STATIC_LOGGING_CATEGORY` 为 **Qt 6.9+** 新增宏，而 mpvqt 的 `CMakeLists.txt`
  仍声明 `REQUIRED_QT_VERSION 6.5.0`（上游声明滞后）。
- 补丁在 Qt < 6.9 时回退为等价的 `static Q_LOGGING_CATEGORY`，不改变行为。

按 LGPL 要求，该补丁随源码一并保留并公开。

---

## 3. 获取与构建步骤

```powershell
# 0) 前置：MSVC (C:\BuildTools)、Qt 6.8.3 (C:\Qt)、CMake、Ninja、7-Zip、vcpkg (C:\vcpkg)

# 1) vcpkg 依赖（zlib / sqlite3 / libarchive / libsmb2）
C:\vcpkg\vcpkg.exe install --triplet x64-windows        # 在 myhub-pc/ 下按 vcpkg.json 解析
C:\vcpkg\vcpkg.exe install ecm:x64-windows              # 仅 mpvqt 构建期需要

# 2) libmpv（下载 + SHA256 校验 + 生成 mpv.lib）
powershell -ExecutionPolicy Bypass -File third_party\fetch-libmpv.ps1

# 3) mpvqt（源码构建到 third_party/mpvqt-install；Debug 构建另需 -Config Debug）
powershell -ExecutionPolicy Bypass -File third_party\build-mpvqt.ps1
powershell -ExecutionPolicy Bypass -File third_party\build-mpvqt.ps1 -Config Debug

# 4) 自检（逐库真实 API 调用）
powershell -ExecutionPolicy Bypass -File third_party\deps-check\run.ps1
```

### libmpv 的 MSVC 导入库

libmpv 官方包只提供 MinGW 格式的 `libmpv.dll.a`，**MSVC 无法直接链接**。
`libmpv/make-implib.ps1` 由 `dumpbin /exports` 解析 DLL 导出表（206 个符号）生成
`mpv.def`，再用 `lib.exe` 产出 `mpv.lib`。该步骤已包含在 `fetch-libmpv.ps1` 中。

---

## 4. 集成注意事项（踩坑记录）

### 4.1 libsmb2 的头文件顺序（Windows）

```cpp
// ① 必须在任何其他头文件之前拉入 winsock2，否则 windows.h 会带入旧版 winsock.h，
//    导致 ws2tcpip.h 中 getsockopt 重载冲突、IPPROTO_IPV6 未定义
#ifdef _WIN32
#  define WIN32_LEAN_AND_MEAN
#  define NOMINMAX
#  include <winsock2.h>
#  include <ws2tcpip.h>
#endif

// ② smb2.h 必须先于 libsmb2.h：前者定义 SMB2_GUID_SIZE、签名模式等协议常量
#include <smb2/smb2.h>
#include <smb2/libsmb2.h>
```

此外 libsmb2 不提供版本宏（无 `LIBSMB2_VERSION`），版本以 vcpkg 锁定为准。

### 4.2 CMake 目标名

| 依赖 | `find_package` | 链接目标 |
| --- | --- | --- |
| zlib | `ZLIB` | `ZLIB::ZLIB` |
| sqlite3 | `unofficial-sqlite3 CONFIG` | `unofficial::sqlite3::sqlite3` |
| libarchive | `LibArchive`（CMake 内置模块） | `LibArchive::LibArchive` |
| libsmb2 | `Libsmb2`（本项目 [`../cmake/FindLibsmb2.cmake`](../cmake/FindLibsmb2.cmake)） | `Libsmb2::Libsmb2` |
| libmpv | `Libmpv`（本项目 [`../cmake/FindLibmpv.cmake`](../cmake/FindLibmpv.cmake)） | `Libmpv::Libmpv` |
| mpvqt | `MpvQt CONFIG` | `MpvQt::MpvQt`（**带命名空间**，裸名 `MpvQt` 会被当作普通库名而链接失败） |

### 4.3 运行期 DLL 搜索路径

自检与开发运行需要以下目录在 `PATH` 中（部署时由 `windeployqt` + 自定义拷贝规则处理）：

```
C:\Qt\6.8.3\msvc2022_64\bin
C:\vcpkg\installed\x64-windows\bin
third_party\libmpv                     (libmpv-2.dll)
third_party\mpvqt-install\bin          (MpvQt.dll，Release 应用用)
third_party\mpvqt-install-debug\bin    (MpvQt.dll，Debug 应用用)
```

**`MpvQt.dll` 必须与应用的 Qt 配置一致**：Debug 应用加载 `Qt6Cored/Qt6Quickd`，
Release 版 `MpvQt.dll` 却依赖 `Qt6Core/Qt6Quick`，同一进程里出现两套 Qt 后，
第一次 `new MpvVideoItem` 就在基类构造中 SIGSEGV（无任何 Qt 日志，极易误判为 mpv 问题）。
顶层 `CMakeLists.txt` 按构建类型强制 `MpvQt_DIR`，缺失即 configure 失败。

---

## 5. 自检基线结果

`deps-check/run.ps1` 的通过基线（2026-10-14）：

```
[OK] sqlite3    : v3.53.4, in-memory CREATE/INSERT/SELECT rows=1
[OK] zlib       : v1.3.2, deflate roundtrip 512->14 bytes
[OK] libarchive : vlibarchive 3.8.9, formats: zip/rar/rar5/7zip/tar
[OK] libsmb2    : context init/destroy OK, signing-mode settable
[OK] libmpv     : api=2.5, mpv v0.41.0-1154-gec38361c5, ffmpeg=N-127521-g2ec8998c3
[OK] MpvQt      : linked successfully (runtime render test deferred to M-1 S1)
RESULT: ALL NATIVE DEPENDENCIES OK
```

`libarchive` 的 `zip/rar/rar5/7zip` 四种读取格式均已确认可用，覆盖 PC-207 漫画格式需求。
mpvqt 的**渲染期**验证（libmpv → Qt Quick 场景图）属 M-1 预研 S1/S3 范畴，需 GUI 环境，不在本自检内。

---

## 6. 未纳入的依赖

| 依赖 | 状态 | 说明 |
| --- | --- | --- |
| libVLC | 未引入 | 兜底引擎，接口预留，二期实现（§4.1） |
| Breakpad / Crashpad | 未引入 | 崩溃捕获，M0 阶段接入（PC-707） |
| 思源宋体 NotoSerifSC | 未引入 | 阅读器衬线字体，属 `resources/`（§8.3） |
