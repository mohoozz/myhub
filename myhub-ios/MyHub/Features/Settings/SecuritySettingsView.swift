import SwiftUI

/// 安全设置（TODO §10 / IOS-501）：应用锁（Face ID / Touch ID）+ 凭据安全说明
struct SecuritySettingsView: View {
    @State private var appLockEnabled = AppSettings.Security.appLockEnabled
    private let lock = AppLockManager.shared

    var body: some View {
        Form {
            Section {
                Toggle(isOn: toggleBinding) {
                    Label("应用锁（\(lock.biometryName)）", systemImage: lock.biometrySymbol)
                }
            } footer: {
                Text("开启后，应用进入后台再返回时需验证 \(lock.biometryName) 才能继续使用；开启/关闭均需先验证身份。")
            }

            Section("凭据安全") {
                infoRow(symbol: "key.fill", text: "连接源账号密码保存在系统钥匙串（仅本设备）")
                infoRow(symbol: "checkmark.shield.fill", text: "凭据与连接配置持久保存，不会因会话过期被清空")
                infoRow(symbol: "trash", text: "删除连接源时，对应凭据一并清除")
            }
        }
        .navigationTitle("应用锁与凭据")
        .tint(AppColors.primary)
    }

    /// 开关需先通过身份验证，失败则回弹
    private var toggleBinding: Binding<Bool> {
        Binding(
            get: { appLockEnabled },
            set: { newValue in
                Task {
                    let ok = await lock.setEnabled(newValue)
                    await MainActor.run {
                        appLockEnabled = AppSettings.Security.appLockEnabled
                    }
                }
            }
        )
    }

    private func infoRow(symbol: String, text: String) -> some View {
        Label(text, systemImage: symbol)
            .font(.subheadline)
            .foregroundStyle(AppColors.textPrimary)
    }
}

/// 应用锁全屏遮罩（RootView 顶层覆盖）：自动发起验证，也可手动点击解锁
struct AppLockView: View {
    @EnvironmentObject private var appLock: AppLockManager

    var body: some View {
        ZStack {
            AppColors.pageBackground.ignoresSafeArea()
            VStack(spacing: 20) {
                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 56))
                    .foregroundStyle(AppColors.primary)
                Text("MyHub 已锁定")
                    .font(.title3.bold())
                    .foregroundStyle(AppColors.textPrimary)
                Button {
                    Task { await appLock.unlock() }
                } label: {
                    Label("使用 \(appLock.biometryName) 解锁", systemImage: appLock.biometrySymbol)
                }
                .buttonStyle(.borderedProminent)
                .tint(AppColors.primary)
            }
        }
        .task { await appLock.unlock() }
    }
}
