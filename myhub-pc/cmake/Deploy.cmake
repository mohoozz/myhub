# Deploy.cmake —— 部署规则（需求文档 §8.4 / §12）
#
# LGPL 合规要点（§4.5）：Qt 与 libmpv / libsmb2 / mpvqt 一律**动态**随包分发，
# 安装目录保持动态库可替换，不做签名绑定校验。
#
# 注意：add_custom_command(TARGET ...) 要求与目标在同一目录创建，
# 故运行库拷贝由 src/CMakeLists.txt 调用 myhub_setup_runtime_deps() 完成。

if(NOT TARGET MyHub)
    return()
endif()

include(GNUInstallDirs)
include(RuntimeLibs)

myhub_collect_runtime_libs(MYHUB_RUNTIME_LIBS)

# ---- 安装规则 ----
install(TARGETS MyHub
    BUNDLE  DESTINATION .
    RUNTIME DESTINATION ${CMAKE_INSTALL_BINDIR}
)

if(MYHUB_RUNTIME_LIBS)
    install(FILES ${MYHUB_RUNTIME_LIBS} DESTINATION ${CMAKE_INSTALL_BINDIR})
endif()

# 许可证文本必须随包分发（LGPL 义务）
install(DIRECTORY "${CMAKE_SOURCE_DIR}/resources/licenses/"
    DESTINATION ${CMAKE_INSTALL_DATADIR}/licenses
    OPTIONAL
)

# windeployqt / macdeployqt（含 QtWebEngine 资源与 Helper 进程）
qt_generate_deploy_qml_app_script(
    TARGET MyHub
    OUTPUT_SCRIPT MYHUB_DEPLOY_SCRIPT
    MACOS_BUNDLE_POST_BUILD
    NO_UNSUPPORTED_PLATFORM_ERROR
)
install(SCRIPT ${MYHUB_DEPLOY_SCRIPT})
