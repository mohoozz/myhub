# 原生依赖自检工程：验证全部第三方库可被发现、可链接、可调用
# 用法见同目录 run.ps1
cmake_minimum_required(VERSION 3.21)
project(MyHubDepsCheck LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

list(APPEND CMAKE_MODULE_PATH "${CMAKE_CURRENT_SOURCE_DIR}/../../cmake")

find_package(Qt6 6.8 REQUIRED COMPONENTS Core Quick)
find_package(unofficial-sqlite3 CONFIG REQUIRED)
find_package(ZLIB REQUIRED)
find_package(LibArchive REQUIRED)
find_package(Libsmb2 REQUIRED)
find_package(Libmpv REQUIRED)
find_package(MpvQt REQUIRED)

qt_standard_project_setup(REQUIRES 6.8)

qt_add_executable(deps_check main.cpp)
set_target_properties(deps_check PROPERTIES WIN32_EXECUTABLE FALSE)

target_link_libraries(deps_check PRIVATE
    Qt6::Core
    Qt6::Quick
    unofficial::sqlite3::sqlite3
    ZLIB::ZLIB
    LibArchive::LibArchive
    Libsmb2::Libsmb2
    Libmpv::Libmpv
    MpvQt::MpvQt
)
