import SwiftUI

/// 类型徽标（浏览页 / 正在阅读共用）：文案统一取 `MediaType.label`，
/// 避免各处再维护一份中文映射（历史上有「文件」/「其他」不一致）。
/// 目前只有「漫画」「压缩包」会在封面上打徽标。
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
