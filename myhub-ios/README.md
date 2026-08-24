# MyHub iOS

纯本地化 iOS 原生应用（无服务器端）：本地直连 WebDAV / SMB 网络存储，内置全格式播放器（参考 nPlayer）、小说/漫画阅读器与内置浏览器。详见《需求分析文档.md》。

- **技术栈**：Swift 5.9 + SwiftUI（+ UIKit 桥接），最低 **iOS 16**，iPhone / iPad
- **数据**：全部本地——GRDB(SQLite) + UserDefaults + Keychain + 沙盒缓存

## 环境要求

| 项 | 要求 |
| --- | --- |
| macOS | 14+（开发机） |
| Xcode | 15+ |
| XcodeGen | `brew install xcodegen`（工程文件由 `project.yml` 生成，不入库） |
| 运行目标 | iOS 16+ 真机 / 模拟器 |

## 构建

```bash
cd myhub-ios
xcodegen generate        # 由 project.yml 生成 MyHub.xcodeproj
open MyHub.xcodeproj     # 首次打开会自动经 SPM 拉取依赖
```

1. 在 **Signing & Capabilities** 中选择你的 Development Team（Bundle ID：`com.myhub.MyHub`）。
2. 首次解析 **MobileVLCKit** 二进制较大（数百 MB），耐心等待；若拉取失败，可在 `project.yml` 中将其降级为 `from: 3.6.0` 或改用 FFmpegKit。
3. 修改工程配置（依赖/构建设置）请编辑 `project.yml` 后重新执行 `xcodegen generate`。

## 目录结构

```
myhub-ios/
├── project.yml                 # XcodeGen 工程定义（依赖/构建设置）
├── MyHub/
│   ├── Info.plist              # ATS、权限描述、后台音频、启动屏
│   ├── MyHub.entitlements      # Keychain Sharing
│   ├── App/                    # 入口、RootView 自适应导航、Theme（色板/主题）
│   ├── Core/
│   │   ├── Storage/            # StorageAdapter 协议（Local/WebDAV/SMB…）
│   │   ├── Database/           # AppDatabase（GRDB）
│   │   ├── Keychain/           # CredentialStore
│   │   ├── Cache/              # CacheManager（Caches 分区）
│   │   └── Utils/              # MediaType 等
│   ├── Player/                 # PlayerCore 统一播放门面（参考 nPlayer）
│   ├── Readers/                # Novel（txt/epub）/ Comic（zip/rar）
│   ├── Features/               # Reading / Favorites / Feed / Browse / Browser / Settings
│   ├── Domain/                 # Models / Services
│   └── Resources/
│       ├── Assets.xcassets     # AppIcon、BrandLogo、LaunchBackground
│       └── Fonts/              # NotoSerifSC（思源宋体，需手动放入）
└── MyHubTests/                 # （待建）
```

## 三方依赖（SPM）

| 包 | 用途 |
| --- | --- |
| AMSMB2 | SMB2/3 直连 |
| VLCKit（MobileVLCKit） | 全格式软解兜底 |
| ZIPFoundation | zip / cbz / epub 解包 |
| UnrarKit | rar / cbr 解析 |
| GRDB | SQLite 结构化存储 |
| Nuke | 图片加载与缓存（封面/缩略图） |

## 备注

- **启动屏**：`UILaunchScreen` 引用 `BrandLogo` + `LaunchBackground`（亮 #EEF4FB / 暗纯黑）。
- **后台音频**：已在 `Info.plist` 配置 `UIBackgroundModes: audio`；后台传输使用 background `URLSession`，无需额外 entitlement。
- **ATS**：已允许局域网 HTTP（`NSAllowsLocalNetworking`）与 Web 内容（内置浏览器）。
- **字体**：从 Google Fonts 下载 **Noto Serif SC**，放入 `MyHub/Resources/Fonts/` 并勾选 target 成员资格（阅读器正文用，TODO §5）。
- **应用图标**：品牌图标已内置（1024 单张，Xcode 自动派生各尺寸），可按版本替换 `AppIcon.png`。
