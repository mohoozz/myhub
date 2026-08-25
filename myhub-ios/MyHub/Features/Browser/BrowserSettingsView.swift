import SwiftUI
import WebKit

/// 浏览器设置（TODO §8.3，IOS-405）：默认搜索引擎 / 默认 UA / 清除浏览数据。
struct BrowserSettingsView: View {
    @State private var clearingData = false
    @State private var showingClearConfirm = false

    var body: some View {
        List {
            Section {
                Picker("默认搜索引擎", selection: searchEngineBinding) {
                    ForEach(SearchEngine.allCases, id: \.self) { engine in
                        Text(engine.displayName).tag(engine)
                    }
                }
                if AppSettings.Browser.searchEngine == .custom {
                    TextField("搜索模板（%@ 为查询占位符）", text: customTemplateBinding)
                        .keyboardType(.URL)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                }
            } header: {
                Text("搜索")
            } footer: {
                Text("地址栏输入非网址内容时，将使用该搜索引擎。")
            }

            Section("用户代理") {
                Picker("默认用户代理", selection: userAgentBinding) {
                    Text("跟随平台").tag(BrowserUserAgent.platform)
                    Text("桌面").tag(BrowserUserAgent.desktop)
                    Text("移动").tag(BrowserUserAgent.mobile)
                }
                .pickerStyle(.segmented)
            }

            Section("隐私") {
                Button(role: .destructive) {
                    showingClearConfirm = true
                } label: {
                    HStack {
                        Text("清除浏览数据")
                        Spacer()
                        if clearingData {
                            ProgressView()
                        }
                    }
                }
                .disabled(clearingData)
            } footer: {
                Text("清除缓存、Cookie 与浏览历史。")
            }
        }
        .navigationTitle("浏览器设置")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("确定清除缓存、Cookie 与浏览历史？", isPresented: $showingClearConfirm, titleVisibility: .visible) {
            Button("清除", role: .destructive) { clearBrowsingData() }
            Button("取消", role: .cancel) {}
        }
    }

    // MARK: - 绑定

    private var searchEngineBinding: Binding<SearchEngine> {
        Binding(
            get: { AppSettings.Browser.searchEngine },
            set: { AppSettings.Browser.searchEngine = $0 }
        )
    }

    private var customTemplateBinding: Binding<String> {
        Binding(
            get: { AppSettings.Browser.customSearchTemplate },
            set: { AppSettings.Browser.customSearchTemplate = $0 }
        )
    }

    private var userAgentBinding: Binding<BrowserUserAgent> {
        Binding(
            get: { AppSettings.Browser.userAgent },
            set: { AppSettings.Browser.userAgent = $0 }
        )
    }

    // MARK: - 清除浏览数据

    private func clearBrowsingData() {
        clearingData = true
        let store = WKWebsiteDataStore.default()
        store.removeData(
            ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(),
            modifiedSince: .distantPast
        ) { [self] in
            Task { @MainActor in
                BrowserDataStore.shared.clearHistory()
                clearingData = false
                AppLogger.shared.log("浏览器浏览数据已清除", level: .info, module: "browser")
            }
        }
    }
}
