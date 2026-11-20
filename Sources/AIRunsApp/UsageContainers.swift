import SwiftUI

struct ObservedUsageSummary: View {
    @ObservedObject var monitor: UsageMonitor
    var body: some View {
        UsageSummaryView(snapshot: monitor.snapshot,
                         period: Binding(get: { monitor.period }, set: { monitor.select($0) }))
    }
}

struct ObservedUsageDashboard: View {
    @ObservedObject var monitor: UsageMonitor
    var body: some View {
        UsageDashboardView(snapshot: monitor.snapshot,
                           period: Binding(get: { monitor.period }, set: { monitor.select($0) }),
                           refresh: { monitor.refreshNow() })
    }
}

struct MenuQuickActions: View {
    @ObservedObject var manager: AccountManager
    let openAccounts: () -> Void
    let openUsage: () -> Void
    let openStatus: (URL) -> Void

    var body: some View {
        VStack(spacing: 0) {
            if !manager.accounts.isEmpty {
                MenuRow(title: "Plan Usage", shortcut: "›", systemImage: "gauge", action: openAccounts)
                    .help("View connected accounts and their available plan limits")
            }
            MenuRow(title: "Add Account…", systemImage: "plus", action: openAccounts)
            MenuRow(title: "Usage Dashboard", systemImage: "chart.bar", action: openUsage)
            Menu {
                statusItem("OpenAI (ChatGPT & Codex)", url: "https://status.openai.com/")
                statusItem("Claude", url: "https://status.claude.com/")
                statusItem("DeepSeek", url: "https://status.deepseek.com/")
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "waveform.path.ecg")
                        .font(AppTypography.body)
                        .frame(width: 16)
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    Text("Status Page").font(AppTypography.action)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
                .padding(.horizontal, 9)
                .frame(height: 28)
                .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(height: 28)
            .accessibilityLabel("Status Page")
        }
        .padding(.horizontal, 5)
    }

    private func statusItem(_ title: String, url: String) -> some View {
        Button(title) {
            if let destination = URL(string: url) { openStatus(destination) }
        }
    }
}
