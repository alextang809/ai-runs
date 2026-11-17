import AIRunsCore
import AppKit
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @State private var statuses: [AgentTool: HookInstaller.Status] = [:]
    @State private var error: String?
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Hooks").font(.headline)
                Text("Hooks let Claude Code and Codex tell AI Runs when a session starts, finishes, or needs your approval. AI Runs only adds its own entries and keeps a backup of each file.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ForEach(AgentTool.allCases, id: \.self) { tool in
                HookRow(tool: tool, status: statuses[tool] ?? .toolNotFound,
                        file: model.installer.configFile(for: tool).path.replacingOccurrences(of: NSHomeDirectory(), with: "~")) {
                    run { try model.installHooks(tool) }
                } remove: {
                    run { try model.removeHooks(tool) }
                }
            }

            if statuses[.codex] == .installed {
                Label("In Codex, run /hooks once and trust the new AI Runs hooks.", systemImage: "info.circle")
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

            Toggle("Open AI Runs at login", isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) { _, enabled in
                    do {
                        if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                    } catch {
                        self.error = "Couldn’t change the login item: \(error.localizedDescription)"
                        launchAtLogin = SMAppService.mainApp.status == .enabled
                    }
                }

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
        var result: [AgentTool: HookInstaller.Status] = [:]
        for tool in AgentTool.allCases { result[tool] = model.hookStatus(tool) }
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
    let file: String
    let install: () -> Void
    let remove: () -> Void

    private var statusText: String {
        switch status {
        case .toolNotFound: return "Not found — install \(tool.displayName) first"
        case .notInstalled: return "Not set up"
        case .partiallyInstalled: return "Partly set up — install again to repair"
        case .installed: return "Set up in \(file)"
        }
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: status == .installed ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(status == .installed ? Color.green : Color.secondary)
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
