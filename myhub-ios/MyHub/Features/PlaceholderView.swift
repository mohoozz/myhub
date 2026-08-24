import SwiftUI

/// 脚手架占位页：各模块实现前临时展示
struct PlaceholderView: View {
    let title: String
    let symbol: String
    var message: String = "模块开发中"

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                Image(systemName: symbol)
                    .font(.system(size: 48))
                    .foregroundStyle(.secondary)
                Text(message)
                    .foregroundStyle(.secondary)
            }
            .navigationTitle(title)
        }
    }
}
