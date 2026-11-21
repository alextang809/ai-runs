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

/// Local usage for one provider at a time, with the same period as the menu.
struct UsageDashboardView: View {
    let snapshot: UsageSnapshot
    @Binding var period: UsagePeriod
    let refresh: () -> Void
    @State private var provider: UsageProvider = .codex
    @AppStorage("usage.cost.currency") private var savedCurrency = "USD"
    @StateObject private var exchange = UsageExchangeRates()

    private var currency: String {
        UsageExchangeQuote.supportedCurrencies.contains(savedCurrency) ? savedCurrency : "USD"
    }

    private var money: UsageMoneyDisplay {
        UsageMoneyDisplay(code: currency, unitsPerUSD: exchange.quote?.unitsPerUSD(currency))
    }

    private var exchangeCaption: String {
        if currency == "USD" { return "Public API list rates" }
        if money.code == currency, let date = exchange.quote?.date { return "ECB · \(date)" }
        return exchange.isLoading ? "Loading rate · Showing USD" : "Rate unavailable · Showing USD"
    }

    private var contentHeight: CGFloat {
        min(530, max(290, (NSScreen.main?.visibleFrame.height ?? 820) - 100))
    }

    var body: some View {
        VStack(spacing: 0) {
            controls
            Divider()
            if snapshot.period != period {
                ProgressView("Updating usage…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let usage = snapshot.providers.first(where: { $0.provider == provider }) {
                let estimate = UsageCost.estimate(usage)
                UsageCostOverview(usage: usage, period: period, estimate: estimate, money: money,
                                  currency: Binding(get: { currency }, set: { savedCurrency = $0 }),
                                  exchangeCaption: exchangeCaption)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 14)
                Divider()
                ScrollView {
                    UsageDashboardDetails(usage: usage, estimate: estimate, money: money)
                        .padding(20)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .id(provider)
            }
        }
        .frame(width: 540, height: contentHeight)
        .background(Color(nsColor: .windowBackgroundColor))
        .task(id: currency != "USD") {
            if currency != "USD" { await exchange.refreshIfNeeded() }
        }
    }

    private var controls: some View {
        HStack(spacing: 14) {
            Picker("Usage provider", selection: $provider) {
                ForEach(UsageProvider.allCases, id: \.self) { provider in
                    Text(provider.displayName).tag(provider)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 210)

            Spacer(minLength: 4)
            if snapshot.period == period, let updated = snapshot.updatedAt {
                Text("Updated \(updated.formatted(date: .omitted, time: .shortened))")
                    .font(AppTypography.metadata)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            UsagePeriodMenu(period: $period)
            Button {
                refresh()
                if currency != "USD" { Task { await exchange.refreshIfNeeded() } }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .frame(width: 18, height: 18)
            }
            .help("Refresh recorded token usage")
            .accessibilityLabel("Refresh token usage")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }
}

private struct UsageDashboardDetails: View {
    let usage: ProviderTokenUsage
    let estimate: UsageCostEstimate
    let money: UsageMoneyDisplay

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            summary
            if !usage.models.isEmpty {
                UsageModelRows(models: usage.models, costs: estimate.byModelUSD, money: money)
            }
            if usage.counts != nil || !usage.issues.isEmpty {
                details
            }
        }
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Tokens recorded on this Mac")
                    .font(AppTypography.body)
                    .foregroundStyle(.secondary)
                Spacer()
                if let status = UsagePresentation.statusText(usage) {
                    Label(status, systemImage: usage.coverage == .partial ? "exclamationmark.circle" : "clock")
                        .font(AppTypography.metadata)
                        .foregroundStyle(.secondary)
                }
            }
            if let counts = usage.counts {
                Text(UsagePresentation.exact(counts.total))
                    .font(.system(size: 36, weight: .medium).monospacedDigit())
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .accessibilityLabel("\(UsagePresentation.exact(counts.total)) recorded tokens")
                Divider()
                HStack(spacing: 16) {
                    metric("Input", count: counts.input)
                    Divider()
                    metric("Output", count: counts.output)
                }
                .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(UsagePresentation.valueText(usage))
                    .font(AppTypography.detailTitle)
                Text(UsagePresentation.coverageDescription(usage))
                    .font(AppTypography.body)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: 10))
    }

    private func metric(_ title: String, count: Int64) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(AppTypography.metadata).foregroundStyle(.secondary)
            Text(UsagePresentation.exact(count))
                .font(AppTypography.detailTitle.monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private var details: some View {
        DisclosureGroup("Calculation & coverage") {
            VStack(alignment: .leading, spacing: 8) {
                if let counts = usage.counts {
                    UsageCounterRow(title: "Cache reads", value: counts.cacheRead)
                    UsageCounterRow(title: "Cache writes", value: counts.cacheWrite)
                    if counts.reasoning > 0 {
                        UsageCounterRow(title: "Reasoning", value: counts.reasoning)
                    }
                    Text("Input includes cache reads and writes. Output includes reported reasoning.")
                    Text("Estimated from recorded tokens at public standard API rates as of \(UsageCostEstimate.pricingAsOf), using short-context and default cache-write pricing.")
                        .fixedSize(horizontal: false, vertical: true)
                    if money.code != "USD" {
                        Text("All periods use the same displayed ECB reference rate for conversion.")
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                if usage.counts != nil {
                    Text(UsagePresentation.coverageDescription(usage))
                }
                ForEach(usage.issues.sorted { $0.rawValue < $1.rawValue }, id: \.self) { issue in
                    Text(UsagePresentation.issueDescription(issue))
                }
            }
            .font(AppTypography.metadata)
            .foregroundStyle(.secondary)
            .padding(.top, 8)
        }
        .font(AppTypography.body)
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
            if !usage.models.isEmpty {
                Divider().padding(.vertical, 2)
                UsageModelRows(models: usage.models)
            }
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
}

private struct UsageModelRows: View {
    let models: [UsageModelTotal]
    var costs: [String: Decimal]? = nil
    var money = UsageMoneyDisplay(code: "USD", unitsPerUSD: nil)
    private let costColumnWidth: CGFloat = 96

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 10) {
                Text("Model")
                Spacer()
                Text("Tokens")
                if costs != nil {
                    Text("Est. Cost").frame(width: costColumnWidth, alignment: .trailing)
                }
            }
            .font(AppTypography.section)
            .foregroundStyle(.secondary)
            Divider()
            ForEach(Array(models.prefix(20))) { model in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(model.model).lineLimit(1).truncationMode(.middle).help(model.model)
                    Spacer(minLength: 4)
                    Text(UsagePresentation.exact(model.counts.total)).monospacedDigit()
                    if let costs {
                        let cost = costs[model.model].map { money.format($0) }
                        Text(cost ?? "—")
                            .monospacedDigit()
                            .foregroundStyle(cost == nil ? .secondary : .primary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                            .frame(width: costColumnWidth, alignment: .trailing)
                            .accessibilityLabel(cost.map { "\($0) estimated cost" }
                                ?? "Cost estimate unavailable")
                    }
                }
                .font(AppTypography.body)
            }
            if models.count > 20 {
                Text("Showing 20 of \(models.count) recorded models.")
                    .font(AppTypography.metadata)
                    .foregroundStyle(.secondary)
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
