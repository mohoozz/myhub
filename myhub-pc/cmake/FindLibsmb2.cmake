# FindLibsmb2.cmake —— 定位 libsmb2（SMB2/3 客户端库）
#
# libsmb2 经 vcpkg 安装（x64-windows 动态库），但未提供 CMake config 文件。
# 注意：libsmb2 为 LGPL-2.1-or-later，必须动态链接（见需求文档 §4.5）。
#
# 输出:
#   Libsmb2_FOUND / Libsmb2_INCLUDE_DIRS / Libsmb2_LIBRARIES
#   导入目标: Libsmb2::Libsmb2

find_path(Libsmb2_INCLUDE_DIR
    NAMES smb2/libsmb2.h
    PATHS ${Libsmb2_ROOT} ENV Libsmb2_ROOT
)

find_library(Libsmb2_LIBRARY
    NAMES smb2 libsmb2
    PATHS ${Libsmb2_ROOT} ENV Libsmb2_ROOT
)

if(Libsmb2_INCLUDE_DIR AND EXISTS "${Libsmb2_INCLUDE_DIR}/smb2/libsmb2.h")
    file(STRINGS "${Libsmb2_INCLUDE_DIR}/smb2/libsmb2.h" _smb2_ver
         REGEX "^#define[ \t]+LIBSMB2_VERSION[ \t]+")
    string(REGEX MATCH "\"([^\"]+)\"" _m "${_smb2_ver}")
    if(_m)
        set(Libsmb2_VERSION "${CMAKE_MATCH_1}")
    endif()
endif()

include(FindPackageHandleStandardArgs)
find_package_handle_standard_args(Libsmb2
    REQUIRED_VARS Libsmb2_LIBRARY Libsmb2_INCLUDE_DIR
    VERSION_VAR Libsmb2_VERSION
)

if(Libsmb2_FOUND)
    set(Libsmb2_INCLUDE_DIRS "${Libsmb2_INCLUDE_DIR}")
    set(Libsmb2_LIBRARIES    "${Libsmb2_LIBRARY}")

    if(NOT TARGET Libsmb2::Libsmb2)
        add_library(Libsmb2::Libsmb2 UNKNOWN IMPORTED)
        set_target_properties(Libsmb2::Libsmb2 PROPERTIES
            IMPORTED_LOCATION "${Libsmb2_LIBRARY}"
            INTERFACE_INCLUDE_DIRECTORIES "${Libsmb2_INCLUDE_DIR}"
        )
        if(WIN32)
            # libsmb2 在 Windows 上依赖 Winsock
            set_property(TARGET Libsmb2::Libsmb2 APPEND PROPERTY
                INTERFACE_LINK_LIBRARIES ws2_32)
        endif()
    endif()
endif()

mark_as_advanced(Libsmb2_INCLUDE_DIR Libsmb2_LIBRARY)
