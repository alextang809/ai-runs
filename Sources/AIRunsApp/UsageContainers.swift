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

struct ObservedPlanEntry: View {
    @ObservedObject var manager: AccountManager
    let open: () -> Void
    var body: some View {
        if !manager.accounts.isEmpty {
            MenuRow(title: "Plan Usage", shortcut: "›", systemImage: "gauge") { open() }
                .help("View connected accounts and their available plan limits")
        }
    }
}
