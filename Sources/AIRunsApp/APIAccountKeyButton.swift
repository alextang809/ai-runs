import AIRunsCore
import SwiftUI

struct APIAccountKeyButton: View {
    let title: String
    let provider: AccountProvider
    let onConnect: (APIAccountCredentials) -> Void

    @State private var showingForm = false

    var body: some View {
        Button(title) { showingForm = true }
            .popover(isPresented: $showingForm) {
                APIAccountKeyForm(provider: provider) { credentials in
                    showingForm = false
                    onConnect(credentials)
                } onCancel: {
                    showingForm = false
                }
                .padding(14)
                .frame(width: 320)
            }
    }
}

struct APIAccountKeyForm: View {
    let provider: AccountProvider
    var canConnect = true
    let onConnect: (APIAccountCredentials) -> Void
    let onCancel: () -> Void

    @State private var key = ""
    @State private var platform: QwenAPIPlatform = .china
    @FocusState private var keyFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Connect \(provider.displayName)").font(AppTypography.appTitle)
            if provider == .qwen {
                Picker("Platform", selection: $platform) {
                    ForEach(QwenAPIPlatform.allCases, id: \.self) { platform in
                        Text(platform.displayName).tag(platform)
                    }
                }
                Text("Use a standard pay-as-you-go API key for the selected platform.")
                    .font(AppTypography.metadata).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            SecureField("API Key", text: $key)
                .textFieldStyle(.roundedBorder)
                .focused($keyFocused)
                .onSubmit(connect)
            HStack {
                Link("Get an API key", destination: apiKeyPage)
                    .font(AppTypography.metadata)
                Spacer()
                Button("Cancel", action: onCancel)
                Button("Connect", action: connect)
                    .buttonStyle(.borderedProminent)
                    .disabled(!canConnect || key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .onAppear { keyFocused = true }
        .onDisappear { key = "" }
    }

    private var apiKeyPage: URL {
        if provider == .deepseek { return URL(string: "https://platform.deepseek.com/api_keys")! }
        if platform == .china { return URL(string: "https://platform.qianwenai.com/home/api-keys")! }
        return URL(string: "https://home.qwencloud.com/api-keys")!
    }

    private func connect() {
        guard canConnect, !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let credentials = APIAccountCredentials(key: key, qwenPlatform: provider == .qwen ? platform : nil)
        key = ""
        onConnect(credentials)
    }
}
