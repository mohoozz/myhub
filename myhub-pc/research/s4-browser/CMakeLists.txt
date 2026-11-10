# S4 预研：QtWebEngine 浏览器能力（多标签保活 / 无痕 / 下载接管 / UA / favicon）
cmake_minimum_required(VERSION 3.21)
project(MyHubS4Probe LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_AUTOMOC ON)

find_package(Qt6 6.8 REQUIRED COMPONENTS Core Gui Quick WebEngineQuick)

qt_standard_project_setup(REQUIRES 6.8)

qt_add_executable(browser_probe
    browser_probe.cpp
    TestServer.h
    TestServer.cpp
)
set_target_properties(browser_probe PROPERTIES WIN32_EXECUTABLE FALSE)

qt_add_qml_module(browser_probe
    URI S4Browser
    VERSION 1.0
    QML_FILES BrowserProbe.qml
)

target_link_libraries(browser_probe PRIVATE
    Qt6::Core
    Qt6::Gui
    Qt6::Quick
    Qt6::WebEngineQuick
)

if(MSVC)
    target_compile_options(browser_probe PRIVATE /utf-8)
endif()
