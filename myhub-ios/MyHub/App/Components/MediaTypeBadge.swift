import SwiftUI

/// 类型徽标（浏览页 / 正在阅读共用）：文案统一取 `MediaType.label`
struct MediaTypeBadge: View {
    let type: MediaType

    var body: some View {
        Text(type.label)
            .font(.caption2.weight(.medium))
            .foregroundStyle(.white)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(AppColors.primary)
            .clipShape(Capsule())
    }
}
