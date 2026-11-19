import AIRunsCore
import AppKit
import SwiftUI

struct UsageSummaryView: View {
    let snapshot: UsageSnapshot
    @Binding var period: UsagePeriod
    @State private var selectedProvider: UsageProviderSelection?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Tokens · This Mac").font(AppTypography.section).foregroundStyle(.secondary)
                    .help("Recorded local tokens, separate from subscription allowance")
                Spacer()
                UsagePeriodMenu(period: $period)
            }
            ForEach(snapshot.providers) { usage in providerRow(usage) }
        }
        .popover(item: $selectedProvider) { selection in
            if let usage = snapshot.providers.first(where: { $0.provider == selection.provider }) {
                FittedVerticalScroll(maximumHeight: 500) {
                    UsageProviderDetails(usage: usage, period: snapshot.period, updatedAt: snapshot.updatedAt)
                        .padding(14)
                }
                .frame(width: 310)
            }
        }
    }

    private func providerRow(_ usage: ProviderTokenUsage) -> some View {
        Button { selectedProvider = UsageProviderSelection(provider: usage.provider) } label: {
            HStack(spacing: 7) {
                UsageProviderIcon(provider: usage.provider)
                Text(usage.provider.displayName)
                Spacer(minLength: 8)
                if snapshot.period == period {
                    if let status = UsagePresentation.statusText(usage) {
                        Text(status).font(AppTypography.section).foregroundStyle(.secondary)
                    }
                    Text(UsagePresentation.valueText(usage)).monospacedDigit()
                        .foregroundStyle(usage.counts == nil ? .secondary : .primary)
                } else {
                    Text("Updating…").foregroundStyle(.secondary)
                }
            }
            .font(AppTypography.body)
            .frame(height: 20)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(snapshot.period != period)
        .help("View recorded local token details for \(usage.provider.displayName)")
        .accessibilityLabel("\(usage.provider.displayName), \(UsagePresentation.accessibilityValue(usage))")
        .accessibilityHint("Show token breakdown")
    }
}

/// A separate reading surface for local token details; the main menu stays compact.
struct UsageDashboardView: View {
    let snapshot: UsageSnapshot
    @Binding var period: UsagePeriod
    let refresh: () -> Void

    var body: some View {
        GlassSurface(cornerRadius: 20, fallbackMaterial: .windowBackground) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Token usage").font(AppTypography.appTitle)
                    Spacer()
                    UsagePeriodMenu(period: $period)
                    Button(action: refresh) {
                        Image(systemName: "arrow.clockwise")
                            .font(AppTypography.section).frame(width: 24, height: 24)
                    }
                    .buttonStyle(.plain)
                    .help("Refresh recorded token usage")
                    .accessibilityLabel("Refresh token usage")
                }
                HStack {
                    Text("Recorded on this Mac")
                    Spacer()
                    if let date = snapshot.updatedAt { Text("Updated \(date.formatted(date: .omitted, time: .shortened))") }
                }
                .font(AppTypography.metadata).foregroundStyle(.secondary)
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        ForEach(snapshot.providers) { usage in
                            UsageProviderDetails(usage: usage, period: snapshot.period, updatedAt: nil)
                            if usage.id != snapshot.providers.last?.id { Divider() }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                Text("Token usage is separate from account limits and billing.")
                    .font(AppTypography.metadata).foregroundStyle(.secondary)
            }
            .padding(18)
            .frame(width: 480, height: min(620, max(320, (NSScreen.main?.visibleFrame.height ?? 820) - 100)))
        }
    }
}

private struct UsageProviderSelection: Identifiable {
    let provider: UsageProvider
    var id: UsageProvider { provider }
}

private struct UsagePeriodMenu: View {
    @Binding var period: UsagePeriod

    var body: some View {
        Menu {
            ForEach(UsagePeriod.allCases, id: \.self) { option in
                Button { period = option } label: {
                    if option == period {
                        Label(UsagePresentation.periodTitle(option), systemImage: "checkmark")
                    } else {
                        Text(UsagePresentation.periodTitle(option))
                    }
                }
            }
        } label: {
            Text(period.title).font(AppTypography.section)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Choose the local usage period")
        .accessibilityLabel("Token usage period, \(UsagePresentation.periodTitle(period))")
    }
}

private struct UsageProviderIcon: View {
    let provider: UsageProvider

    var body: some View {
        AppIcon(bundleId: provider == .codex ? "com.openai.codex" : "com.apple.Terminal")
            .scaleEffect(16.0 / 26.0)
            .frame(width: 16, height: 16)
            .accessibilityHidden(true)
    }
}

private struct UsageProviderDetails: View {
    let usage: ProviderTokenUsage
    let period: UsagePeriod
    let updatedAt: Date?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                UsageProviderIcon(provider: usage.provider)
                Text(usage.provider.displayName).font(AppTypography.rowTitle)
                Spacer(minLength: 8)
                if let status = UsagePresentation.statusText(usage) {
                    Text(status).font(AppTypography.section).foregroundStyle(.secondary)
                }
            }
            Text(UsagePresentation.periodTitle(period)).font(AppTypography.metadata).foregroundStyle(.secondary)
            if let counts = usage.counts {
                Text("\(UsagePresentation.exact(counts.total)) tokens").font(AppTypography.metric).monospacedDigit()
                    .lineLimit(1).minimumScaleFactor(0.65)
                counterRows(counts)
            } else {
                Text(UsagePresentation.valueText(usage)).font(AppTypography.body).foregroundStyle(.secondary)
            }
            Text(UsagePresentation.coverageDescription(usage))
                .font(AppTypography.metadata).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(usage.issues.sorted { $0.rawValue < $1.rawValue }, id: \.self) { issue in
                Text(UsagePresentation.issueDescription(issue))
                    .font(AppTypography.metadata).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !usage.models.isEmpty { modelRows }
            if let date = updatedAt {
                Text("Updated \(date.formatted(date: .abbreviated, time: .shortened))")
                    .font(AppTypography.metadata).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func counterRows(_ counts: TokenCounts) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            UsageCounterRow(title: "Input", value: counts.input)
            UsageCounterRow(title: "Output", value: counts.output)
            Divider().padding(.vertical, 2)
            UsageCounterRow(title: "Cache reads", value: counts.cacheRead)
            UsageCounterRow(title: "Cache writes", value: counts.cacheWrite)
            if counts.reasoning > 0 { UsageCounterRow(title: "Reasoning", value: counts.reasoning) }
            Text("Cache reads and writes are included in Input. Reported reasoning is included in Output.")
                .font(AppTypography.metadata).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var modelRows: some View {
        VStack(alignment: .leading, spacing: 5) {
            Divider().padding(.vertical, 2)
            Text("By model").font(AppTypography.section).foregroundStyle(.secondary)
            ForEach(Array(usage.models.prefix(20))) { model in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(model.model).lineLimit(1).truncationMode(.middle).help(model.model)
                    Spacer(minLength: 4)
                    Text(UsagePresentation.exact(model.counts.total)).monospacedDigit()
                }
                .font(AppTypography.body)
            }
            if usage.models.count > 20 {
                Text("Showing 20 of \(usage.models.count) recorded models.")
                    .font(AppTypography.metadata).foregroundStyle(.secondary)
            }
        }
    }
}

private struct UsageCounterRow: View {
    let title: String
    let value: Int64

    var body: some View {
        HStack {
            Text(title).foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(UsagePresentation.exact(value)).monospacedDigit()
        }
        .font(AppTypography.body)
    }
}
