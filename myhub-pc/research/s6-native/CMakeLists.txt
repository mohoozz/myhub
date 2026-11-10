# S6 预研：原生依赖实链路验证
cmake_minimum_required(VERSION 3.21)
project(MyHubS6Probe LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

list(APPEND CMAKE_MODULE_PATH "${CMAKE_CURRENT_SOURCE_DIR}/../../cmake")

find_package(LibArchive REQUIRED)
find_package(Libsmb2 REQUIRED)
find_package(Libmpv REQUIRED)
find_package(Qt6 6.8 REQUIRED COMPONENTS Core Network)

# S6-A：libarchive 漫画解页
add_executable(archive_probe archive_probe.cpp)
target_link_libraries(archive_probe PRIVATE LibArchive::LibArchive)

# S6-B：libsmb2 SMB2/3 实链路
add_executable(smb_probe smb_probe.cpp)
target_link_libraries(smb_probe PRIVATE Libsmb2::Libsmb2)

# S6-C：回环 HTTP Range 服务 + libmpv 拉流
add_executable(loopback_probe loopback_probe.cpp)
target_link_libraries(loopback_probe PRIVATE
    Qt6::Core Qt6::Network Libmpv::Libmpv)

foreach(t archive_probe smb_probe loopback_probe)
    set_target_properties(${t} PROPERTIES
        WIN32_EXECUTABLE FALSE
        AUTOMOC ON
    )
    if(MSVC)
        # 源码含中文注释
        target_compile_options(${t} PRIVATE /utf-8)
    endif()
endforeach()
