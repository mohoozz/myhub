# FindLibmpv.cmake —— 定位 vendor 在 third_party/libmpv 的 libmpv
#
# libmpv 官方 Windows 发布包只提供 MinGW 格式的 libmpv.dll.a，
# MSVC 所需的 mpv.lib 由 third_party/libmpv/make-implib.ps1 生成。
#
# 输出:
#   Libmpv_FOUND / Libmpv_INCLUDE_DIRS / Libmpv_LIBRARIES / Libmpv_RUNTIME_LIBRARY
#   导入目标: Libmpv::Libmpv

set(_libmpv_root "${CMAKE_CURRENT_LIST_DIR}/../third_party/libmpv")

find_path(Libmpv_INCLUDE_DIR
    NAMES mpv/client.h
    HINTS "${_libmpv_root}/include"
    NO_DEFAULT_PATH
)

find_library(Libmpv_LIBRARY
    NAMES mpv libmpv
    HINTS "${_libmpv_root}"
    NO_DEFAULT_PATH
)

find_file(Libmpv_RUNTIME_LIBRARY
    NAMES libmpv-2.dll
    HINTS "${_libmpv_root}"
    NO_DEFAULT_PATH
)

# 从 client.h 读取 API 版本
if(Libmpv_INCLUDE_DIR AND EXISTS "${Libmpv_INCLUDE_DIR}/mpv/client.h")
    file(STRINGS "${Libmpv_INCLUDE_DIR}/mpv/client.h" _mpv_major
         REGEX "^#define[ \t]+MPV_CLIENT_API_VERSION[ \t]+MPV_MAKE_VERSION\\(")
    string(REGEX MATCH "MPV_MAKE_VERSION\\(([0-9]+), *([0-9]+)\\)" _m "${_mpv_major}")
    if(_m)
        set(Libmpv_VERSION "${CMAKE_MATCH_1}.${CMAKE_MATCH_2}")
    endif()
endif()

include(FindPackageHandleStandardArgs)
find_package_handle_standard_args(Libmpv
    REQUIRED_VARS Libmpv_LIBRARY Libmpv_INCLUDE_DIR
    VERSION_VAR Libmpv_VERSION
)

if(Libmpv_FOUND)
    set(Libmpv_INCLUDE_DIRS "${Libmpv_INCLUDE_DIR}")
    set(Libmpv_LIBRARIES    "${Libmpv_LIBRARY}")

    if(NOT TARGET Libmpv::Libmpv)
        add_library(Libmpv::Libmpv UNKNOWN IMPORTED)
        set_target_properties(Libmpv::Libmpv PROPERTIES
            IMPORTED_LOCATION "${Libmpv_LIBRARY}"
            INTERFACE_INCLUDE_DIRECTORIES "${Libmpv_INCLUDE_DIR}"
        )
    endif()
endif()

mark_as_advanced(Libmpv_INCLUDE_DIR Libmpv_LIBRARY Libmpv_RUNTIME_LIBRARY)
