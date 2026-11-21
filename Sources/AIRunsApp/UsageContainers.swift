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
    let addAccount: () -> Void
    let openUsage: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            if !manager.accounts.isEmpty {
                MenuRow(title: "Accounts…", systemImage: "person.crop.circle", action: openAccounts)
            }
            MenuRow(title: "Add Account…", systemImage: "plus", action: addAccount)
            MenuRow(title: "Usage Dashboard", systemImage: "chart.bar", action: openUsage)
        }
        .padding(.horizontal, 5)
    }
}
