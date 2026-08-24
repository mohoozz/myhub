// swift-tools-version: 5.9
import PackageDescription

// 本地 vendored 的 UnrarKit（官方仓库不支持 SPM，此处按官方 podspec 的
// unrar-lib subspec 编译配置还原为 SPM 包）。
//
// 说明：
// - source_files 中列出的 .cpp 会被编译；
// - preserve_paths 及平台相关文件通过 exclude 排除（它们被其它 .cpp 以
//   #include 方式内联，或仅用于 Windows / SSE / 预编译头，不参与 iOS 编译）；
// - 编译宏 -DSILENT -DRARDLL 与官方 podspec 保持一致；
// - 链接 zlib（URKArchive.mm 使用 zlib.h）与 libc++（unrar 为 C++）。
let package = Package(
    name: "UnrarKit",
    platforms: [
        .iOS(.v16),
        .macOS(.v13)
    ],
    products: [
        .library(name: "UnrarKit", targets: ["UnrarKit"])
    ],
    targets: [
        .target(
            name: "UnrarKit",
            path: "Sources/UnrarKit",
            exclude: [
                // preserve_paths：被 unpack.cpp / threadpool.cpp / ui.cpp 等 #include
                "arccmt.cpp", "blake2sp.cpp", "cmdfilter.cpp", "cmdmix.cpp",
                "coder.cpp", "crypt1.cpp", "crypt2.cpp", "crypt3.cpp", "crypt5.cpp",
                "hardlinks.cpp", "log.cpp", "model.cpp",
                "recvol3.cpp", "recvol5.cpp", "suballoc.cpp", "uicommon.cpp",
                "uisilent.cpp", "ulinks.cpp", "unpack15.cpp", "unpack20.cpp",
                "unpack30.cpp", "unpack50.cpp", "unpack50frag.cpp", "unpackinline.cpp",
                "uowners.cpp", "win32stm.cpp",
                // 平台相关 / SSE 优化 / 预编译头，不参与 iOS 编译
                "blake2s_sse.cpp", "rarpch.cpp", "threadmisc.cpp", "uiconsole.cpp",
                "unpack50mt.cpp", "win32acl.cpp", "win32lnk.cpp"
            ],
            publicHeadersPath: ".",
            cxxSettings: [
                .define("SILENT"),
                .define("RARDLL")
            ],
            linkerSettings: [
                .linkedLibrary("z"),
                .linkedLibrary("c++")
            ]
        )
    ]
)
