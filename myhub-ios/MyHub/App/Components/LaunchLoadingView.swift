import SwiftUI

/// 首启 / 网络判定期 loading 页（TODO §1.1）：品牌图标 + 旋转动画，杜绝长白屏。
struct LaunchLoadingView: View {
    @State private var rotating = false

    var body: some View {
        ZStack {
            AppColors.pageBackground.ignoresSafeArea()
            VStack(spacing: 28) {
                Image("BrandLogo")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 88, height: 88)
                    .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .shadow(color: AppColors.primary.opacity(0.25), radius: 16, y: 8)
                VStack(spacing: 14) {
                    Text("MyHub")
                        .font(.title2.weight(.bold))
                        .foregroundStyle(AppColors.textPrimary)
                    Circle()
                        .trim(from: 0, to: 0.7)
                        .stroke(AppColors.primary, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                        .frame(width: 26, height: 26)
                        .rotationEffect(.degrees(rotating ? 360 : 0))
                        .onAppear {
                            withAnimation(.linear(duration: 0.9).repeatForever(autoreverses: false)) {
                                rotating = true
                            }
                        }
                }
            }
        }
    }
}
