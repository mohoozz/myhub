cmake_minimum_required(VERSION 3.21)

project(MyHub
    VERSION 1.0.0
    DESCRIPTION "MyHub desktop - personal content hub"
    LANGUAGES CXX
)

set(MYHUB_APP_ID "com.myhub.desktop" CACHE STRING "Application identifier")

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)
set(CMAKE_AUTOMOC ON)
# resources/*.qrc（窗口图标等）需要 AUTORCC 才会被编译进可执行文件
set(CMAKE_AUTORCC ON)

list(APPEND CMAKE_MODULE_PATH "${CMAKE_CURRENT_SOURCE_DIR}/cmake")

if(MSVC)
    add_compile_options(/utf-8 /W3 /permissive-)
    # libsmb2 的 ws2tcpip.h 要求 winsock2 先行；统一关掉 windows.h 的旧 winsock
    add_compile_definitions(WIN32_LEAN_AND_MEAN NOMINMAX)
endif()

# ---------------------------------------------------------------------------
# 依赖
# ---------------------------------------------------------------------------
find_package(Qt6 6.8 REQUIRED COMPONENTS
    Core Gui Quick QuickControls2 Network Concurrent WebEngineQuick Svg
)

# 许可红线（需求文档 §4.5 / §7.2）：GPL-only 模块一律禁止链接
include(LicenseGuard)

find_package(unofficial-sqlite3 CONFIG REQUIRED)
find_package(ZLIB REQUIRED)
find_package(LibArchive REQUIRED)
find_package(Libsmb2 REQUIRED)
find_package(Libmpv REQUIRED)

# mpvqt 的配置必须与本次构建类型一致：
#   Debug   应用依赖 Qt6Cored.dll / Qt6Quickd.dll
#   Release MpvQt.dll 依赖 Qt6Core.dll  / Qt6Quick.dll
# 混用会把两套 Qt 运行时载入同一进程，`new MpvVideoItem(...)` 在
# QQuickFramebufferObject 基类构造里直接 SIGSEGV（且没有任何日志）。
# 因此 Debug 构建只认 mpvqt-install-debug（由 build-mpvqt.ps1 -Config Debug 生成）。
if(CMAKE_BUILD_TYPE STREQUAL "Debug")
    set(_myhub_mpvqt_root "${CMAKE_CURRENT_SOURCE_DIR}/third_party/mpvqt-install-debug")
    set(_myhub_mpvqt_hint "powershell -ExecutionPolicy Bypass -File third_party\\build-mpvqt.ps1 -Config Debug")
else()
    set(_myhub_mpvqt_root "${CMAKE_CURRENT_SOURCE_DIR}/third_party/mpvqt-install")
    set(_myhub_mpvqt_hint "powershell -ExecutionPolicy Bypass -File third_party\\build-mpvqt.ps1")
endif()
if(NOT EXISTS "${_myhub_mpvqt_root}/lib/cmake/MpvQt/MpvQtConfig.cmake")
    message(FATAL_ERROR
        "mpvqt for ${CMAKE_BUILD_TYPE} not found at ${_myhub_mpvqt_root}.\n"
        "Run: ${_myhub_mpvqt_hint}")
endif()
# MpvQt_DIR 一旦被缓存就会绕过 CMAKE_PREFIX_PATH 搜索，故此处强制跟随构建类型，
# 保证同一份构建目录在 Debug / Release 之间切换预设时不会残留错误的那份。
set(MpvQt_DIR "${_myhub_mpvqt_root}/lib/cmake/MpvQt" CACHE PATH "mpvqt config dir (per build type)" FORCE)
# 预设里还带着 Release 安装目录，剔除以免 Libmpv / 其它查找命中隔壁那份
list(FILTER CMAKE_PREFIX_PATH EXCLUDE REGEX "/mpvqt-install(-debug)?$")
list(PREPEND CMAKE_PREFIX_PATH "${_myhub_mpvqt_root}")

find_package(MpvQt CONFIG REQUIRED)
message(STATUS "MpvQt (${CMAKE_BUILD_TYPE}): ${MpvQt_DIR}")

qt_standard_project_setup(REQUIRES 6.8)
set(QT_QML_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/qml")

# ---------------------------------------------------------------------------
# myhub_core —— 纯逻辑层（分层约束：仅 QtCore / QtNetwork，禁止 QtQuick / QtGui）
#   见需求文档 §5.2「分层约定」与 §7.2 许可风险缓解
# ---------------------------------------------------------------------------
add_subdirectory(src/core)

# 运行库收集函数需在 src/ 中使用，故先行定义
include(RuntimeLibs)

# ---------------------------------------------------------------------------
# MyHub —— 应用层
#
# 可执行目标、C++ 源文件与 QML 模块**必须在同一 CMakeLists 中声明**：
# AUTOMOC 的 metatypes 收集与 qmltyperegistrar 依赖同目录的 autogen 产物，
# 跨目录（target_sources / qt_add_qml_module 分散在子目录）会导致
# metatypes json 为空、类型注册静默失败。
# ---------------------------------------------------------------------------
qt_add_executable(MyHub
    src/main.cpp
    # 窗口图标资源（main.cpp 里的 :/icons/app.svg）
    resources/icons.qrc

    src/app/AppState.h                      src/app/AppState.cpp
    src/app/AppRouter.h                     src/app/AppRouter.cpp
    src/app/WindowController.h              src/app/WindowController.cpp
    src/app/ThemeController.h               src/app/ThemeController.cpp
    src/app/SettingsBridge.h                src/app/SettingsBridge.cpp
    src/app/PlayerBridge.h                  src/app/PlayerBridge.cpp
    src/app/MediaSession.h                  src/app/MediaSession.cpp
    src/app/FileBridge.h                    src/app/FileBridge.cpp
    src/app/FormatBridge.h                  src/app/FormatBridge.cpp

    src/features/player/MpvVideoItem.h      src/features/player/MpvVideoItem.cpp
    src/features/player/MpvEngine.h         src/features/player/MpvEngine.cpp
    src/features/player/PlaybackStreamService.h
    src/features/player/PlaybackStreamService.cpp

    src/features/connections/ConnectionStore.h
    src/features/connections/ConnectionStore.cpp
    src/features/connections/ConnectionListModel.h
    src/features/connections/ConnectionListModel.cpp
    src/features/browse/BrowseDirectoryModel.h
    src/features/browse/BrowseDirectoryModel.cpp
    src/features/browse/BrowseController.h
    src/features/browse/BrowseController.cpp
    src/features/trash/TrashModel.h
    src/features/trash/TrashModel.cpp
    src/features/transfer/TransferListModel.h
    src/features/transfer/TransferListModel.cpp
    src/features/reading/ReadingHomeModel.h
    src/features/reading/ReadingHomeModel.cpp
    src/features/favorites/FavoriteListModel.h
    src/features/favorites/FavoriteListModel.cpp
    src/features/favorites/FavoritesBridge.h
    src/features/favorites/FavoritesBridge.cpp
    src/features/cover/CoverService.h
    src/features/cover/CoverService.cpp
)

set_target_properties(MyHub PROPERTIES
    WIN32_EXECUTABLE TRUE
    MACOSX_BUNDLE TRUE
    MACOSX_BUNDLE_GUI_IDENTIFIER "${MYHUB_APP_ID}"
    MACOSX_BUNDLE_BUNDLE_VERSION "${PROJECT_VERSION}"
    MACOSX_BUNDLE_SHORT_VERSION_STRING "${PROJECT_VERSION}"
)

# qmltyperegistrar 生成的注册代码以**裸文件名**包含头文件
# （#include <AppState.h>），故需把各含 QML_ELEMENT 的目录加入搜索路径。
target_include_directories(MyHub PRIVATE
    "${CMAKE_CURRENT_SOURCE_DIR}/src"
    "${CMAKE_CURRENT_SOURCE_DIR}/src/app"
    "${CMAKE_CURRENT_SOURCE_DIR}/src/features/browse"
    "${CMAKE_CURRENT_SOURCE_DIR}/src/features/trash"
    "${CMAKE_CURRENT_SOURCE_DIR}/src/features/transfer"
    "${CMAKE_CURRENT_SOURCE_DIR}/src/features/connections"
    "${CMAKE_CURRENT_SOURCE_DIR}/src/features/reading"
    "${CMAKE_CURRENT_SOURCE_DIR}/src/features/favorites"
    "${CMAKE_CURRENT_SOURCE_DIR}/src/features/cover"
    "${CMAKE_CURRENT_SOURCE_DIR}/src/features/player"
)

target_link_libraries(MyHub PRIVATE
    myhub_core
    Qt6::Core
    Qt6::Gui
    Qt6::Quick
    Qt6::QuickControls2
    Qt6::Network
    Qt6::Concurrent
    Qt6::Svg
    Qt6::WebEngineQuick
    # 播放内核：mpvqt 渲染面 + libmpv（动态链接，LGPL 合规见 LicenseGuard）
    MpvQt::MpvQt
    Libmpv::Libmpv
)

# ---- 平台适配层（唯一的平台分叉点，§5.2）----
if(WIN32)
    target_sources(MyHub PRIVATE
        src/platform/windows/WindowsIntegration.h
        src/platform/windows/WindowsIntegration.cpp
        src/platform/windows/WindowsMediaControls.h
        src/platform/windows/WindowsMediaControls.cpp
    )
    # WindowsApp = C++/WinRT 的伞形库；runtimeobject 提供 RoGetActivationFactory（SMTC interop）
    target_link_libraries(MyHub PRIVATE dwmapi shell32 WindowsApp runtimeobject)
elseif(APPLE)
    target_sources(MyHub PRIVATE
        src/platform/macos/MacIntegration.h
        src/platform/macos/MacIntegration.mm
        src/platform/macos/MacMediaControls.h
        src/platform/macos/MacMediaControls.mm
    )
    # 系统媒体集成用 ARC 写（block 里大量捕获 ObjC 对象，手动引用计数太易出错）
    set_source_files_properties(src/platform/macos/MacMediaControls.mm
        PROPERTIES COMPILE_OPTIONS "-fobjc-arc")
    target_link_libraries(MyHub PRIVATE
        "-framework AppKit"
        "-framework Security"
        "-framework MediaPlayer"
    )
endif()

# ---- QML 模块 ----
include(QmlModule)

# 许可红线校验（§4.5）
myhub_assert_license_clean(MyHub)
myhub_assert_license_clean(myhub_core)

# ---- 运行库拷贝（必须与目标同目录创建）----
if(WIN32)
    myhub_collect_runtime_libs(MYHUB_RUNTIME_LIBS)
    if(MYHUB_RUNTIME_LIBS)
        add_custom_command(TARGET MyHub POST_BUILD
            COMMAND ${CMAKE_COMMAND} -E copy_if_different
                    ${MYHUB_RUNTIME_LIBS} "$<TARGET_FILE_DIR:MyHub>"
            COMMENT "Copying native runtime libraries (libmpv / MpvQt)"
            VERBATIM
        )
    endif()

    myhub_find_vcpkg_bin(MYHUB_VCPKG_BIN)
    if(MYHUB_VCPKG_BIN)
        add_custom_command(TARGET MyHub POST_BUILD
            COMMAND ${CMAKE_COMMAND} -E copy_directory_if_different
                    "${MYHUB_VCPKG_BIN}" "$<TARGET_FILE_DIR:MyHub>"
            COMMENT "Copying vcpkg runtime libraries"
            VERBATIM
        )
    endif()
endif()

# ---------------------------------------------------------------------------
# 测试
# ---------------------------------------------------------------------------
include(CTest)
if(BUILD_TESTING)
    add_subdirectory(tests)
endif()

# ---------------------------------------------------------------------------
# 部署
# ---------------------------------------------------------------------------
include(Deploy)
