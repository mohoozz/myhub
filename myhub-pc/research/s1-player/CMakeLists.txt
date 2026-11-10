# S1 预研：播放基础验证
#
# 独立于主工程，避免污染 M0 成果。两个探针：
#   decode_probe —— 纯解码能力（无 GUI，可在 CI 跑）
#   render_probe —— QML 渲染集成（需 GUI）
cmake_minimum_required(VERSION 3.21)
project(MyHubS1Probe LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

list(APPEND CMAKE_MODULE_PATH "${CMAKE_CURRENT_SOURCE_DIR}/../../cmake")

find_package(Libmpv REQUIRED)
find_package(Qt6 6.8 REQUIRED COMPONENTS Core Gui Quick WebEngineQuick)
find_package(MpvQt CONFIG REQUIRED)

qt_standard_project_setup(REQUIRES 6.8)

# ---- S1-A：纯解码探针（控制台）----
add_executable(decode_probe decode_probe.cpp)
set_target_properties(decode_probe PROPERTIES WIN32_EXECUTABLE FALSE)
target_link_libraries(decode_probe PRIVATE Libmpv::Libmpv)
if(MSVC)
    # 源码含中文注释，需显式 UTF-8 否则在 GBK 代码页下告警 C4819
    target_compile_options(decode_probe PRIVATE /utf-8)
endif()

# ---- S1-B：渲染集成探针（GUI）----
qt_add_executable(render_probe render_probe.cpp ProbePlayer.h)
set_target_properties(render_probe PROPERTIES WIN32_EXECUTABLE FALSE)

qt_add_qml_module(render_probe
    URI S1Probe
    VERSION 1.0
    QML_FILES RenderProbe.qml
)

target_link_libraries(render_probe PRIVATE
    Qt6::Core
    Qt6::Gui
    Qt6::Quick
    Libmpv::Libmpv
    MpvQt::MpvQt
)

# ---- S1-C：libmpv + QtWebEngine 共存探针 ----
# 独立 URI：一个 QML 模块只能归属一个目标，两个 exe 不能共用 S1Probe
qt_add_executable(compat_probe compat_probe.cpp ProbePlayer.h)
set_target_properties(compat_probe PROPERTIES WIN32_EXECUTABLE FALSE)

qt_add_qml_module(compat_probe
    URI S1Compat
    VERSION 1.0
    QML_FILES CompatProbe.qml
)

target_link_libraries(compat_probe PRIVATE
    Qt6::Core
    Qt6::Gui
    Qt6::Quick
    Qt6::WebEngineQuick
    Libmpv::Libmpv
    MpvQt::MpvQt
)
