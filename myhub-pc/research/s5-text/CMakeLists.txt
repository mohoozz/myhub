# S5 预研：QTextLayout 行级分页 + 排版无关锚点（纯 QtGui，无 QML/窗口）
cmake_minimum_required(VERSION 3.21)
project(MyHubS5Probe LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

find_package(Qt6 6.8 REQUIRED COMPONENTS Core Gui)

qt_standard_project_setup(REQUIRES 6.8)

qt_add_executable(text_probe
    text_probe.cpp
    TextCorpus.h
    TextCorpus.cpp
    TextLayoutEngine.h
    TextLayoutEngine.cpp
)
set_target_properties(text_probe PROPERTIES WIN32_EXECUTABLE FALSE)

target_link_libraries(text_probe PRIVATE
    Qt6::Core
    Qt6::Gui
)

if(MSVC)
    target_compile_options(text_probe PRIVATE /utf-8)
endif()
