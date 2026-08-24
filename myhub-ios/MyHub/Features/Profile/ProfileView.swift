import SwiftUI

/// 个人主页（占位）
struct ProfileView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "person.crop.circle.fill")
                .font(.system(size: 72))
                .foregroundStyle(AppColors.primary)
            Text("我的主页")
                .font(.title2.weight(.semibold))
                .foregroundStyle(AppColors.textPrimary)
            Text("个人主页开发中")
                .font(.subheadline)
                .foregroundStyle(AppColors.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AppColors.pageBackground)
        .navigationTitle("个人主页")
    }
}

/// 头像入口：点击直达个人主页（TODO §1.1 / IOS-704）
struct ProfileEntryButton: View {
    var body: some View {
        NavigationLink {
            ProfileView()
        } label: {
            Image(systemName: "person.crop.circle.fill")
                .font(.title3)
                .foregroundStyle(AppColors.primary)
                .frame(width: 32, height: 32)
                .contentShape(Rectangle())
        }
        .buttonStyle(.pressScale)
    }
}
