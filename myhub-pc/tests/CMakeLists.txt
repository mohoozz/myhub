# QTest 单测：覆盖纯逻辑层（需求文档 §13）
#
# 覆盖目标：StoragePath 归一化、错误自愈分类、PROPFIND 解析、
#          自然排序、内外网判定、数据库迁移与浏览链路集成。
# （RangeZipReader / TextEncodingDetector / ChapterRuleTable / 锚点换算
#   随 M3 阅读器实现后补充）

find_package(Qt6 6.8 REQUIRED COMPONENTS Test Qml)

# 测试可执行文件运行时需要 Qt 与 vcpkg 的 DLL（sqlite3 / smb2 / zlib ...）。
# 不设置 PATH 会导致 0xc0000135（找不到 DLL），故由 CTest 环境显式注入。
set(_test_dll_dirs "")
if(WIN32)
    get_target_property(_qt_core_loc Qt6::Core IMPORTED_LOCATION_RELEASE)
    if(NOT _qt_core_loc)
        get_target_property(_qt_core_loc Qt6::Core IMPORTED_LOCATION)
    endif()
    if(_qt_core_loc)
        get_filename_component(_qt_bin "${_qt_core_loc}" DIRECTORY)
        list(APPEND _test_dll_dirs "${_qt_bin}")
    endif()

    myhub_find_vcpkg_bin(_vcpkg_bin)
    if(_vcpkg_bin)
        file(TO_NATIVE_PATH "${_vcpkg_bin}" _vcpkg_bin_native)
        list(APPEND _test_dll_dirs "${_vcpkg_bin_native}")
    endif()
endif()

# 只登记 ctest 条目（PATH 注入），供自定义目标复用
function(myhub_register_test name)
    add_test(NAME ${name} COMMAND ${name})

    if(WIN32 AND _test_dll_dirs)
        # CMake 列表分隔符是 ';'，与 Windows PATH 一致，但需转义以免被解析为多个属性值
        string(REPLACE ";" "\\;" _path_value "${_test_dll_dirs}")
        set_tests_properties(${name} PROPERTIES
            ENVIRONMENT_MODIFICATION "PATH=path_list_prepend:${_path_value}"
        )
    endif()
endfunction()

function(myhub_add_test name)
    qt_add_executable(${name} ${name}.cpp)
    target_link_libraries(${name} PRIVATE myhub_core Qt6::Test)
    # 控制台子系统，便于 CTest 捕获输出
    set_target_properties(${name} PROPERTIES WIN32_EXECUTABLE FALSE)
    myhub_register_test(${name})
endfunction()

myhub_add_test(tst_storagepath)
myhub_add_test(tst_storageerror)
myhub_add_test(tst_naturalsort)
myhub_add_test(tst_webdavparse)
myhub_add_test(tst_networkheuristics)
myhub_add_test(tst_playercore)
myhub_add_test(tst_decoderouter)
myhub_add_test(tst_progress)
myhub_add_test(tst_readingentry)
myhub_add_test(tst_embeddedcover)
myhub_add_test(tst_fileoperations)
myhub_add_test(tst_trash)
myhub_add_test(tst_transfer)
myhub_add_test(tst_streamcache)
myhub_add_test(tst_streamproxy)
myhub_add_test(tst_movecopy)
myhub_add_test(tst_textcodec)
myhub_add_test(tst_favorite)
myhub_add_test(tst_trackname)
myhub_add_test(tst_screenshotpath)
myhub_add_test(tst_subtitlematcher)

# 浏览页状态角标：features/ 下的模型编在 MyHub 可执行目标里（不在 myhub_core），
# 故测试目标自带这两份源文件；它们都带 QML_ELEMENT，需额外链接 Qt6::Qml。
qt_add_executable(tst_browsestatus
    tst_browsestatus.cpp
    ${CMAKE_SOURCE_DIR}/src/features/browse/BrowseDirectoryModel.h
    ${CMAKE_SOURCE_DIR}/src/features/browse/BrowseDirectoryModel.cpp
    ${CMAKE_SOURCE_DIR}/src/features/connections/ConnectionStore.h
    ${CMAKE_SOURCE_DIR}/src/features/connections/ConnectionStore.cpp
)
target_include_directories(tst_browsestatus PRIVATE
    "${CMAKE_SOURCE_DIR}/src"
    "${CMAKE_SOURCE_DIR}/src/features/browse"
    "${CMAKE_SOURCE_DIR}/src/features/connections"
)
target_link_libraries(tst_browsestatus PRIVATE myhub_core Qt6::Test Qt6::Qml)
set_target_properties(tst_browsestatus PROPERTIES WIN32_EXECUTABLE FALSE)
myhub_register_test(tst_browsestatus)

# 传输队列 QML 视图模型（Transfers 单例）依赖 QtQml，
# 而 myhub_core 只允许 QtCore/QtNetwork，故单列一个测试目标复用源文件。
qt_add_executable(tst_transfermodel
    tst_transfermodel.cpp
    ${CMAKE_SOURCE_DIR}/src/features/transfer/TransferListModel.h
    ${CMAKE_SOURCE_DIR}/src/features/transfer/TransferListModel.cpp
)
target_include_directories(tst_transfermodel PRIVATE
    "${CMAKE_SOURCE_DIR}/src"
    "${CMAKE_SOURCE_DIR}/src/features/transfer"
)
target_link_libraries(tst_transfermodel PRIVATE myhub_core Qt6::Test Qt6::Qml)
set_target_properties(tst_transfermodel PROPERTIES WIN32_EXECUTABLE FALSE)
myhub_register_test(tst_transfermodel)

# 集成测试：数据库迁移 + 本地适配器 + 目录缓存（需要事件循环）
myhub_add_test(tst_e2e_browse)
