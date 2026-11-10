# LicenseGuard.cmake
#
# 需求文档 §4.5 / §7.2 许可红线：
# 链接任何 GPL-only 的 Qt 模块会导致整个应用被要求以 GPL 发布。
# 本模块在 configure 阶段即拦截，避免误用。
#
# 被禁模块：Qt HTTP Server / Charts / DataVisualization / Lottie / VirtualKeyboard
# 替代方案：HTTP 服务一律用 QTcpServer 自写（见 §4.1 回环代理）。

set(MYHUB_FORBIDDEN_QT_MODULES
    HttpServer
    Charts
    DataVisualization
    Lottie
    VirtualKeyboard
)

# 1) 这些模块不应被 find_package 找到并使用
foreach(_mod IN LISTS MYHUB_FORBIDDEN_QT_MODULES)
    if(TARGET Qt6::${_mod})
        message(FATAL_ERROR
            "[LicenseGuard] GPL-only module Qt6::${_mod} is linked. "
            "This would force the whole application under GPL. "
            "See 需求分析文档 §4.5 for approved alternatives.")
    endif()
endforeach()

# 2) 提供链接期校验函数：对目标的链接库做递归检查
function(myhub_assert_license_clean target)
    get_target_property(_libs ${target} LINK_LIBRARIES)
    if(NOT _libs)
        return()
    endif()
    foreach(_lib IN LISTS _libs)
        foreach(_mod IN LISTS MYHUB_FORBIDDEN_QT_MODULES)
            if("${_lib}" MATCHES "Qt6::${_mod}$")
                message(FATAL_ERROR
                    "[LicenseGuard] target '${target}' links GPL-only Qt6::${_mod}.")
            endif()
        endforeach()
    endforeach()
endfunction()

message(STATUS "[LicenseGuard] GPL-only Qt modules are blocked: ${MYHUB_FORBIDDEN_QT_MODULES}")
