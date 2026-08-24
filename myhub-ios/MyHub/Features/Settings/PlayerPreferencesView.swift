import SwiftUI

/// 播放器偏好（TODO §10 / IOS-503）：默认倍速/解码偏好/预读窗口/字幕样式/纯音频默认/音量步进（默认 5%）
struct PlayerPreferencesView: View {
    @State private var defaultSpeed = AppSettings.Player.defaultSpeed
    @State private var decodePreference = AppSettings.Player.decodePreference
    @State private var preloadSeconds = AppSettings.Player.preloadSeconds
    @State private var subtitleFontSize = AppSettings.Player.subtitleFontSize
    @State private var subtitleDelay = AppSettings.Player.subtitleDelay
    @State private var audioOnlyByDefault = AppSettings.Player.audioOnlyByDefault
    @State private var volumeStep = AppSettings.Player.volumeStep
    @State private var seekStepSeconds = AppSettings.Player.seekStepSeconds

    private static let speedOptions: [Double] = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0, 2.5, 3.0]
    private static let seekStepOptions: [Double] = [5, 10, 15, 30]
    private static let volumeStepOptions: [Double] = [0.01, 0.05, 0.10]

    var body: some View {
        Form {
            Section("播放") {
                Picker("默认倍速", selection: $defaultSpeed) {
                    ForEach(Self.speedOptions, id: \.self) { speed in
                        Text("\(speed, specifier: "%.2g")x").tag(speed)
                    }
                }
                Picker("双击快进/快退", selection: $seekStepSeconds) {
                    ForEach(Self.seekStepOptions, id: \.self) { step in
                        Text("\(Int(step)) 秒").tag(step)
                    }
                }
                Toggle("默认纯音频模式", isOn: $audioOnlyByDefault)
            }
            Section {
                Picker("解码偏好", selection: $decodePreference) {
                    Text("自动").tag(DecodePreference.auto)
                    Text("强制硬解").tag(DecodePreference.hardware)
                    Text("强制软解").tag(DecodePreference.software)
                }
                valueRow(title: "预读窗口", value: "\(Int(preloadSeconds)) 秒") {
                    Slider(value: $preloadSeconds, in: 10...120, step: 10)
                }
            } header: {
                Text("解码与缓冲")
            } footer: {
                Text("自动模式按格式路由硬解/软解，硬解失败自动回退软解；预读窗口决定向前缓冲的数据量。")
            }
            Section("字幕") {
                valueRow(title: "字幕字号", value: "\(Int(subtitleFontSize))") {
                    Slider(value: $subtitleFontSize, in: 12...32, step: 1)
                }
                valueRow(title: "字幕延迟", value: String(format: "%+.1f 秒", subtitleDelay)) {
                    Slider(value: $subtitleDelay, in: -5...5, step: 0.5)
                }
            }
            Section {
                Picker("音量步进", selection: $volumeStep) {
                    ForEach(Self.volumeStepOptions, id: \.self) { step in
                        Text("\(Int(step * 100))%").tag(step)
                    }
                }
            } header: {
                Text("音量")
            } footer: {
                Text("播放器手势调节音量与系统音量联动，默认步进 5%。")
            }
        }
        .navigationTitle("播放器偏好")
        .tint(AppColors.primary)
        .onChange(of: defaultSpeed) { AppSettings.Player.defaultSpeed = $0 }
        .onChange(of: decodePreference) { AppSettings.Player.decodePreference = $0 }
        .onChange(of: preloadSeconds) { AppSettings.Player.preloadSeconds = $0 }
        .onChange(of: subtitleFontSize) { AppSettings.Player.subtitleFontSize = $0 }
        .onChange(of: subtitleDelay) { AppSettings.Player.subtitleDelay = $0 }
        .onChange(of: audioOnlyByDefault) { AppSettings.Player.audioOnlyByDefault = $0 }
        .onChange(of: volumeStep) { AppSettings.Player.volumeStep = $0 }
        .onChange(of: seekStepSeconds) { AppSettings.Player.seekStepSeconds = $0 }
    }

    private func valueRow<Content: View>(
        title: String, value: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                Spacer()
                Text(value)
                    .font(.caption)
                    .foregroundStyle(AppColors.textSecondary)
            }
            content()
        }
    }
}
