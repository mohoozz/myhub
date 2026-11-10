# RuntimeLibs.cmake —— 定位随包分发的原生运行库
#
# 供 src/CMakeLists.txt（构建后拷贝）与 Deploy.cmake（安装规则）共用。
#
# LGPL 合规（§4.5）：libmpv / libsmb2 / mpvqt 均为动态库，
# 随包分发且保持目录内可替换，满足重新链接义务。

# 收集需要随包分发的第三方 DLL（libmpv / MpvQt）
function(myhub_collect_runtime_libs out_var)
    set(_libs "")

    if(Libmpv_RUNTIME_LIBRARY AND EXISTS "${Libmpv_RUNTIME_LIBRARY}")
        list(APPEND _libs "${Libmpv_RUNTIME_LIBRARY}")
    endif()

    if(TARGET MpvQt::MpvQt)
        # 单配置生成器（Ninja）只写与构建时配置对应的 IMPORTED_LOCATION_<CFG>：
        #   Release 安装树 -> IMPORTED_LOCATION_RELEASE
        #   Debug   安装树 -> IMPORTED_LOCATION_DEBUG
        # 写死 RELEASE 会在 Debug 构建下取不到 DLL，运行期直接缺库起不来。
        set(_mpvqt_dll "")
        if(CMAKE_BUILD_TYPE)
            string(TOUPPER "${CMAKE_BUILD_TYPE}" _mpvqt_cfg)
            get_target_property(_mpvqt_dll MpvQt::MpvQt IMPORTED_LOCATION_${_mpvqt_cfg})
            if(NOT EXISTS "${_mpvqt_dll}")
                set(_mpvqt_dll "")
            endif()
        endif()
        if(NOT _mpvqt_dll)
            get_target_property(_mpvqt_dll MpvQt::MpvQt IMPORTED_LOCATION)
            if(NOT EXISTS "${_mpvqt_dll}")
                set(_mpvqt_dll "")
            endif()
        endif()
        if(NOT _mpvqt_dll AND DEFINED MpvQt_DIR)
            # 兜底：由安装前缀推导 bin/MpvQt.dll
            get_filename_component(_mpvqt_prefix "${MpvQt_DIR}/../../.." ABSOLUTE)
            set(_mpvqt_dll "${_mpvqt_prefix}/bin/MpvQt.dll")
        endif()
        if(_mpvqt_dll AND EXISTS "${_mpvqt_dll}")
            list(APPEND _libs "${_mpvqt_dll}")
        else()
            message(WARNING "MpvQt runtime library not found (MpvQt_DIR=${MpvQt_DIR})")
        endif()
    endif()

    set(${out_var} "${_libs}" PARENT_SCOPE)
endfunction()

# 定位 vcpkg 的 bin 目录（sqlite3 / smb2 / archive / zlib / openssl ...）
function(myhub_find_vcpkg_bin out_var)
    set(_found "")
    foreach(_p IN LISTS CMAKE_PREFIX_PATH)
        if(EXISTS "${_p}/bin" AND EXISTS "${_p}/include/smb2")
            set(_found "${_p}/bin")
            break()
        endif()
    endforeach()
    set(${out_var} "${_found}" PARENT_SCOPE)
endfunction()
