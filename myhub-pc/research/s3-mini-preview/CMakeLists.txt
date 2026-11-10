# S3 预研：mini 实时预览（单会话双处渲染）
cmake_minimum_required(VERSION 3.21)
project(MyHubS3Probe LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_AUTOMOC ON)

list(APPEND CMAKE_MODULE_PATH "${CMAKE_CURRENT_SOURCE_DIR}/../../cmake")

find_package(Libmpv REQUIRED)
find_package(Qt6 6.8 REQUIRED COMPONENTS Core Gui Quick)
find_package(MpvQt CONFIG REQUIRED)

qt_standard_project_setup(REQUIRES 6.8)

qt_add_executable(mini_preview_probe mini_preview_probe.cpp PreviewPlayer.h)
set_target_properties(mini_preview_probe PROPERTIES WIN32_EXECUTABLE FALSE)

qt_add_qml_module(mini_preview_probe
    URI S3Probe
    VERSION 1.0
    QML_FILES MiniPreviewProbe.qml
)

target_link_libraries(mini_preview_probe PRIVATE
    Qt6::Core
    Qt6::Gui
    Qt6::Quick
    Libmpv::Libmpv
    MpvQt::MpvQt
)

if(MSVC)
    target_compile_options(mini_preview_probe PRIVATE /utf-8)
endif()
