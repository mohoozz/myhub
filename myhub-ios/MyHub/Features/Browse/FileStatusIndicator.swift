import SwiftUI

/// 浏览列表文件状态指示（参考 Flutter `file_status_indicator.dart`）：
/// - 正在播放 → 三竖条均衡器动画（此时不显示进度环）；
/// - 有阅读记录 → 顶部起顺时针的环形进度；
/// - 二者皆无 → 不显示。
/// 优先级：正在播放 > 进度环 > 空。
struct FileStatusIndicator: View {
    /// 阅读进度 0~1；nil 表示无历史记录（不显示进度环）
    let progress: Double?
    /// 是否正在以（mini）播放器播放该文件
    let isPlaying: Bool
    var size: CGFloat = 16

    var body: some View {
        if isPlaying {
            PlayingBarsIndicator(size: size)
        } else if let progress {
            ReadingProgressRing(percent: progress, size: size)
        }
    }
}

// MARK: - 阅读进度环

/// 环形进度：底环浅色，进度弧从 12 点方向顺时针填充；100% 显示为更实的满环。
struct ReadingProgressRing: View {
    /// 0~1
    let percent: Double
    var size: CGFloat = 16

    private var clamped: Double { min(max(percent, 0), 1) }
    private var radius: CGFloat { size / 2 }

    var body: some View {
        ZStack {
            // 底环
            Circle()
                .stroke(AppColors.primary.opacity(0.25), lineWidth: radius * 0.22)

            if clamped >= 1 {
                // 满进度：更粗的满环
                Circle()
                    .stroke(AppColors.primary, style: StrokeStyle(lineWidth: radius * 0.5, lineCap: .round))
            } else if clamped > 0 {
                // 进度弧：从 12 点（-90°）顺时针
                Circle()
                    .trim(from: 0, to: clamped)
                    .stroke(AppColors.primary, style: StrokeStyle(lineWidth: radius * 0.34, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
        }
        .frame(width: size, height: size)
    }
}

// MARK: - 正在播放：三竖条均衡器动画

/// 三根错相位起伏的竖条（类似音乐 App 的「正在播放」指示），主色绘制。
struct PlayingBarsIndicator: View {
    var size: CGFloat = 16

    @State private var phase: Double = 0

    /// 用一个连续时间驱动三条正弦相位，避免多个 AnimationController
    var body: some View {
        TimelineView(.animation) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            Canvas { context, canvasSize in
                let barCount = 3
                let gap = size * 0.12
                let totalGap = gap * CGFloat(barCount - 1)
                let barWidth = (canvasSize.width - totalGap) / CGFloat(barCount)
                let maxHeight = canvasSize.height
                // 周期约 0.9s
                let base = t * 2 * .pi / 0.9
                for i in 0..<barCount {
                    let level = abs(sin(base + Double(i) * 1.1))
                    let barHeight = (0.35 + 0.65 * level) * maxHeight
                    let x = CGFloat(i) * (barWidth + gap)
                    let y = maxHeight - barHeight
                    let rect = CGRect(x: x, y: y, width: barWidth, height: barHeight)
                    let path = Path(roundedRect: rect, cornerRadius: barWidth / 2)
                    context.fill(path, with: .color(AppColors.primary))
                }
            }
        }
        .frame(width: size, height: size)
    }
}
