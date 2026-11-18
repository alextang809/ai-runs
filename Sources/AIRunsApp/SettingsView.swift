import AIRunsCore
import AppKit
import ServiceManagement
import SwiftUI
import UserNotifications

struct SettingsView: View {
    @ObservedObject var model: AppModel
    let iconHidden: () -> Bool
    @State private var hidden = false
    @State private var statuses: [AgentTool: HookInstaller.Status] = [:]
    @State private var error: String?
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var showInDock = AppSettings.showInDock
    @AppStorage(FloatingSettings.autoExpandKey) private var autoExpand = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Hooks").font(.headline)
                Text("Hooks let Claude Code and Codex tell AI Runs when a session starts, finishes, or needs your approval. AI Runs only adds its own entries and keeps a backup of each file.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ForEach(AgentTool.hookTools, id: \.self) { tool in
                HookRow(tool: tool, status: statuses[tool] ?? .toolNotFound, lastSeen: model.store.lastSeen(tool),
                        file: model.installer.configFile(for: tool).path.replacingOccurrences(of: NSHomeDirectory(), with: "~")) {
                    run { try model.installHooks(tool) }
                } remove: {
                    run { try model.removeHooks(tool) }
                }
            }

            if statuses[.codex] == .installed, model.store.lastSeen(.codex) == nil {
                Label("Codex asks you to approve new hooks (Review hooks → Allow all, or /hooks). Until then it sends nothing.", systemImage: "info.circle")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            if model.helperMissing {
                Label("The airuns-hook helper is missing. Build the app with Scripts/package_app.sh.", systemImage: "exclamationmark.triangle")
                    .font(.system(size: 12))
                    .foregroundStyle(.orange)
            }
            if let error {
                Text(error).font(.system(size: 12)).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            BrowserSection(model: model)

            Divider()

            NotificationSection()

            Divider()

            ClaudeThreadsSection()

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Text("Floating window").font(.headline)
                Text("A capsule that stays on top of every app and Space. Open it from the menu: Show Floating Window. Click it to see your runs and the pinned board; drag it anywhere.")
                    .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Toggle("Open it by itself when a session needs you", isOn: $autoExpand)
                    .font(.system(size: 12.5))
            }

            Divider()

            VStack(alignment: .leading, spacing: 4) {
                Text("Open the panel from the menu bar icon or with \(HotKey.displayName) anywhere.")
                    .font(.system(size: 12))
                if hidden {
                    Label("Your menu bar is full, so the icon is hidden (usually behind the camera notch). Use \(HotKey.displayName), or quit a menu bar app you rarely use.", systemImage: "eye.slash")
                        .font(.system(size: 12))
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Toggle("Open AI Runs at login", isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) { _, enabled in
                    do {
                        if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                    } catch {
                        self.error = "Couldn’t change the login item: \(error.localizedDescription)"
                        launchAtLogin = SMAppService.mainApp.status == .enabled
                    }
                }

            Toggle("Also show AI Runs in the Dock", isOn: $showInDock)
                .onChange(of: showInDock) { _, enabled in AppSettings.showInDock = enabled }
            Text("Useful when the menu bar is full: click the Dock icon to open the panel.")
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .padding(.top, -10)

            HStack {
                Text("Everything stays on this Mac in ~/.airuns.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Show Data Folder") {
                    NSWorkspace.shared.activateFileViewerSelecting([model.paths.root])
                }
            }
        }
        .padding(20)
        .frame(width: 460)
        .onAppear(perform: refresh)
    }

    private func refresh() {
        hidden = iconHidden()
        var result: [AgentTool: HookInstaller.Status] = [:]
        for tool in AgentTool.hookTools { result[tool] = model.hookStatus(tool) }
        statuses = result
    }

    private func run(_ action: () throws -> Void) {
        do {
            try action()
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
        refresh()
    }
}

private struct HookRow: View {
    let tool: AgentTool
    let status: HookInstaller.Status
    let lastSeen: Date?
    let file: String
    let install: () -> Void
    let remove: () -> Void

    private var statusText: String {
        switch status {
        case .toolNotFound: return "Not found — install \(tool.displayName) first"
        case .notInstalled: return "Not set up"
        case .partiallyInstalled: return "Partly set up — install again to repair"
        case .installed:
            guard let lastSeen else { return "Set up in \(file) · no events yet" }
            let ago = TextUtils.duration(Date().timeIntervalSince(lastSeen))
            return "Set up in \(file) · last event \(ago == "now" ? "just now" : ago + " ago")"
        }
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: status != .installed ? "circle" : (lastSeen == nil ? "clock" : "checkmark.circle.fill"))
                .foregroundStyle(status != .installed ? Color.secondary : (lastSeen == nil ? Color.orange : Color.green))
            VStack(alignment: .leading, spacing: 2) {
                Text(tool.displayName).font(.system(size: 13, weight: .semibold))
                Text(statusText).font(.system(size: 11.5)).foregroundStyle(.secondary)
            }
            Spacer()
            switch status {
            case .installed:
                Button("Remove", action: remove)
            case .toolNotFound:
                Button("Install Anyway", action: install)
            default:
                Button("Install", action: install).keyboardShortcut(.defaultAction)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))
    }
}

/// Permission, and which moments to announce.
struct ClaudeThreadsSection: View {
    @AppStorage(ClaudeThreadsReader.enabledKey) private var enabled = true
    @State private var trusted = SidebarClicker.isTrusted

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Claude project threads").font(.headline)
                Spacer()
                if enabled, trusted {
                    Label("On", systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.system(size: 12))
                } else if enabled {
                    Button("Allow Accessibility…") { _ = SidebarClicker.requestTrust() }.controlSize(.small)
                }
            }
            Text("Threads that work in the cloud send AI Runs nothing. While the Threads list is on screen in Claude, AI Runs reads each thread’s name and where Claude files it (Working, Waiting on you, Ready for review, Idle), so those threads get a row too. It only reads, and only the Claude app.")
                .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Toggle("Show threads from Claude’s Threads list", isOn: $enabled)
                .font(.system(size: 12.5))
        }
        .onAppear { trusted = SidebarClicker.isTrusted }
    }
}

struct NotificationSection: View {
    @State private var status: UNAuthorizationStatus = .notDetermined
    @AppStorage(NotificationSettings.key(.approval)) private var approval = true
    @AppStorage(NotificationSettings.key(.input)) private var input = true
    @AppStorage(NotificationSettings.key(.replied)) private var replied = false
    @AppStorage(NotificationSettings.key(.done)) private var done = false
    @AppStorage(NotificationSettings.key(.stalled)) private var stalled = false
    @AppStorage(NotificationSettings.remindKey) private var remind = true

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Notifications").font(.headline)
                Spacer()
                switch status {
                case .authorized, .provisional:
                    Label("On", systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.system(size: 12))
                case .denied:
                    Button("Turn On in System Settings…") { Notifier.openSystemSettings() }.controlSize(.small)
                default:
                    Button("Allow Notifications") {
                        Task {
                            await Notifier.shared.requestAuthorization()
                            status = await Notifier.shared.authorizationStatus()
                        }
                    }
                    .controlSize(.small)
                }
            }
            Text("A banner when a session needs you, so you can work elsewhere. None while you're already in that session's app.")
                .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Group {
                Toggle("Approval requests (APPROVE)", isOn: $approval)
                Toggle("Questions and blockers (NEEDS INPUT)", isOn: $input)
                Toggle("Unclear replies (REPLIED)", isOn: $replied)
                Toggle("Finished work (DONE)", isOn: $done)
                Toggle("Stalled runs (NO UPDATE)", isOn: $stalled)
                Toggle("Remind me once if it's still waiting after 15 minutes", isOn: $remind)
            }
            .font(.system(size: 12.5))
            .disabled(status == .denied)
        }
        .task { status = await Notifier.shared.authorizationStatus() }
    }
}

/// ChatGPT and Claude in the browser: connect the browsers, then load the extension.
struct BrowserSection: View {
    @ObservedObject var model: AppModel
    @State private var browsers: [(browser: BrowserConnector.Browser, connected: Bool)] = []
    @State private var note: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Browser").font(.headline)
            Text("Follow chats on chatgpt.com and claude.ai in Chrome, Arc, Brave or Edge: what's still writing, what's done, and a notification when a reply is ready.")
                .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if browsers.isEmpty {
                Text("No Chromium browser found (Chrome, Arc, Brave, Edge, Vivaldi). Safari isn't supported yet.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            } else {
                HStack(spacing: 10) {
                    ForEach(browsers, id: \.browser.name) { item in
                        Label(item.browser.name, systemImage: item.connected ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 12))
                            .foregroundStyle(item.connected ? Color.primary : Color.secondary)
                    }
                }
                HStack {
                    Button(browsers.allSatisfy(\.connected) ? "Reconnect Browsers" : "1. Connect Browsers") {
                        do {
                            let names = try model.connectBrowsers()
                            note = names.isEmpty ? nil : "Connected \(names.joined(separator: ", "))."
                        } catch {
                            note = error.localizedDescription
                        }
                        browsers = model.browserStatus()
                    }
                    Button("2. Show Extension Folder") { model.revealExtension() }
                }
                .controlSize(.small)
                Text("3. In the browser open chrome://extensions (arc://extensions, brave://extensions, edge://extensions), turn on Developer mode, click Load unpacked and choose the folder. Then reload your ChatGPT and Claude tabs.")
                    .font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            if let note { Text(note).font(.system(size: 11.5)).foregroundStyle(.secondary) }
        }
        .onAppear { browsers = model.browserStatus() }
    }
}
