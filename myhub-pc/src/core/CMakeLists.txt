# myhub_core —— 纯逻辑层
#
# 分层约束（需求文档 §5.2）：本目标只链接 Qt6::Core / Qt6::Network / Qt6::Concurrent，
# 不得依赖 QtQuick / QtGui。这样逻辑层可被 QTest 直接覆盖，也降低未来迁移成本。
# 约束由「不链接」从编译期强制：一旦 include <QGuiApplication> 等即编译失败。

add_library(myhub_core STATIC
    storage/StoragePath.h              storage/StoragePath.cpp
    storage/StorageError.h             storage/StorageError.cpp
    storage/FileEntry.h
    storage/StorageAdapter.h           storage/StorageAdapter.cpp
    storage/LocalAdapter.h             storage/LocalAdapter.cpp
    storage/WebDAVAdapter.h            storage/WebDAVAdapter.cpp
    storage/RoutedWebDAVAdapter.h      storage/RoutedWebDAVAdapter.cpp
    storage/SMBAdapter.h               storage/SMBAdapter.cpp
    storage/StorageAdapterFactory.h    storage/StorageAdapterFactory.cpp

    database/AppDatabase.h             database/AppDatabase.cpp
    database/Migrations.h              database/Migrations.cpp

    preferences/AppSettings.h          preferences/AppSettings.cpp

    history/ProgressRepository.h       history/ProgressRepository.cpp
    history/ReadingEntry.h             history/ReadingEntry.cpp

    favorites/FavoriteRepository.h     favorites/FavoriteRepository.cpp

    credentials/CredentialStore.h      credentials/CredentialStore.cpp

    cache/DirectoryCache.h             cache/DirectoryCache.cpp

    files/TrashStore.h                 files/TrashStore.cpp
    files/FileOperations.h             files/FileOperations.cpp

    transfer/TransferManager.h         transfer/TransferManager.cpp
    transfer/RelayStream.h             transfer/RelayStream.cpp

    text/TextCodec.h                   text/TextCodec.cpp

    cover/EmbeddedCoverExtractor.h     cover/EmbeddedCoverExtractor.cpp

    player/PlaybackTypes.h
    player/PlaybackEngine.h
    player/DecodeRouter.h              player/DecodeRouter.cpp
    player/PlayerCore.h                player/PlayerCore.cpp
    player/PlaybackProgressTracker.h   player/PlaybackProgressTracker.cpp
    player/SubtitleMatcher.h           player/SubtitleMatcher.cpp

    network/NetworkHeuristics.h        network/NetworkHeuristics.cpp

    stream/RangeSource.h               stream/RangeSource.cpp
    stream/AdapterRangeSource.h        stream/AdapterRangeSource.cpp
    stream/SegmentCache.h              stream/SegmentCache.cpp
    stream/CachedRangeReader.h         stream/CachedRangeReader.cpp
    stream/LocalStreamProxy.h          stream/LocalStreamProxy.cpp

    utils/AppLogger.h                  utils/AppLogger.cpp
    utils/CrashReporter.h              utils/CrashReporter.cpp
    utils/MediaType.h                  utils/MediaType.cpp
    utils/TrackName.h                  utils/TrackName.cpp
    utils/ScreenshotPath.h             utils/ScreenshotPath.cpp
    utils/NaturalSort.h                utils/NaturalSort.cpp
    utils/Formatters.h                 utils/Formatters.cpp
    utils/AppPaths.h                   utils/AppPaths.cpp
)

target_include_directories(myhub_core PUBLIC
    ${CMAKE_CURRENT_SOURCE_DIR}/..
)

target_link_libraries(myhub_core PUBLIC
    Qt6::Core
    Qt6::Network
    Qt6::Concurrent
    unofficial::sqlite3::sqlite3
    Libsmb2::Libsmb2
)

target_compile_definitions(myhub_core PUBLIC
    MYHUB_VERSION="${PROJECT_VERSION}"
    MYHUB_APP_ID="${MYHUB_APP_ID}"
)

if(WIN32)
    # CredentialStore 使用 Windows Credential Manager（wincred.h）
    target_link_libraries(myhub_core PRIVATE credui advapi32)
endif()

if(APPLE)
    # TextCodec 的 GB18030 / Big5 转码走 CoreFoundation（Qt 未带 ICU，QStringConverter 不支持这两族）
    target_link_libraries(myhub_core PRIVATE "-framework CoreFoundation")
endif()
