import AIRunsCore
import SwiftUI

/// The selected window's estimate stays visible while token details scroll.
struct UsageCostOverview: View {
    let usage: ProviderTokenUsage
    let period: UsagePeriod
    let estimate: UsageCostEstimate
    let money: UsageMoneyDisplay
    @Binding var currency: String
    let exchangeCaption: String

    private static let commonCurrencies = ["USD", "SGD", "CNY", "HKD", "EUR", "GBP", "JPY", "AUD", "CAD"]

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline) {
                Text("Estimated Cost").font(AppTypography.detailTitle)
                Spacer()
                Text(exchangeCaption)
                    .font(AppTypography.metadata).foregroundStyle(.secondary)
                    .lineLimit(1)
                currencyMenu
            }
            HStack(spacing: 8) {
                metric("Today", window: usage.costHistory?.today, for: .today)
                if period == .last7Days {
                    metric("Last 7 days", window: nil, for: .last7Days)
                } else {
                    metric("Last 24 hours", window: usage.costHistory?.last24Hours, for: .last24Hours)
                }
                metric("Last 30 days", window: usage.costHistory?.last30Days, for: .last30Days)
            }
            .fixedSize(horizontal: false, vertical: true)
            if let note = coverageText {
                Text(note).font(AppTypography.section).foregroundStyle(.secondary)
            }
            if let history = usage.costHistory {
                UsageDailyCostTrend(days: history.days, money: money)
            }
        }
    }

    private func metric(_ title: String, window: UsageCostWindow?, for windowPeriod: UsagePeriod) -> some View {
        let selected = period == windowPeriod
        let cost = selected ? estimate : window?.estimate
        let tokens = selected ? usage.counts?.total : window?.tokens
        return VStack(alignment: .leading, spacing: 3) {
            Text(title).font(AppTypography.metadata).foregroundStyle(.secondary)
            Text(cost?.totalUSD.map { money.format($0) } ?? "—")
                .font(.system(size: 19, weight: .semibold).monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(tokens.map { "\(UsagePresentation.compact($0)) tokens" } ?? "Tokens unavailable")
                .font(AppTypography.section).foregroundStyle(.secondary)
            if !selected, cost?.isPartial == true, cost?.totalUSD != nil {
                Text("Partial").font(AppTypography.section).foregroundStyle(.secondary)
            }
        }
        .lineLimit(1)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(selected ? Color.accentColor.opacity(0.10) : Color.primary.opacity(0.04),
                    in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityHint(Text(cost?.totalUSD == nil ? "Estimate unavailable" : ""))
    }

    private var currencyMenu: some View {
        Menu {
            ForEach(Self.commonCurrencies, id: \.self) { currencyOption($0) }
            Divider()
            ForEach(UsageExchangeQuote.supportedCurrencies.filter { !Self.commonCurrencies.contains($0) }, id: \.self) {
                currencyOption($0)
            }
        } label: {
            Text(currency).monospacedDigit()
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .accessibilityLabel("Display currency, \(currency)")
        .help("Change the currency used for estimated costs")
    }

    private func currencyOption(_ code: String) -> some View {
        let name = Locale.current.localizedString(forCurrencyCode: code) ?? code
        return Button {
            currency = code
        } label: {
            if currency == code {
                Label("\(code) · \(name)", systemImage: "checkmark")
            } else {
                Text("\(code) · \(name)")
            }
        }
    }

    private var coverageText: String? {
        if estimate.unpricedTokens > 0 {
            let tokens = UsagePresentation.exact(estimate.unpricedTokens)
            return estimate.totalUSD == nil ? "No estimate for \(tokens) recorded tokens."
                : "Partial estimate · \(tokens) unpriced tokens"
        }
        if usage.coverage == .scanning { return "Scanning local usage…" }
        if estimate.isPartial, estimate.totalUSD != nil { return "Subtotal from incomplete records" }
        if estimate.totalUSD == nil { return "No local cost estimate for this range" }
        return nil
    }
}

private struct UsageDailyCostTrend: View {
    let days: [UsageCostDay]
    let money: UsageMoneyDisplay
    private let chartHeight: CGFloat = 44

    var body: some View {
        if let peak = days.compactMap(\.estimate.totalUSD).max() {
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text("Daily estimates · Recent 30 days")
                    Spacer()
                    Text("High \(money.format(peak))").monospacedDigit()
                }
                .font(AppTypography.section).foregroundStyle(.secondary)
                HStack(alignment: .bottom, spacing: 3) {
                    ForEach(days, id: \.date) { day in
                        bar(day, peak: peak)
                    }
                }
                .frame(height: chartHeight, alignment: .bottom)
            }
            .accessibilityElement(children: .contain)
        }
    }

    private func bar(_ day: UsageCostDay, peak: Decimal) -> some View {
        let amount = day.estimate.totalUSD
        let ratio = amount.map { peak > 0 ? CGFloat(NSDecimalNumber(decimal: $0 / peak).doubleValue) : 0 }
        let label = "\(day.date.formatted(.dateTime.month().day())), "
            + (amount.map { "\(money.format($0))\(day.estimate.isPartial ? " partial" : "")" } ?? "estimate unavailable")
        return RoundedRectangle(cornerRadius: 2)
            .fill(amount == nil ? Color.clear : Color.accentColor.opacity(day.estimate.isPartial ? 0.53 : 0.88))
            .frame(height: ratio.map { max(1, chartHeight * $0) } ?? 0)
            .frame(maxWidth: .infinity)
            .frame(height: chartHeight, alignment: .bottom)
            .contentShape(Rectangle())
            .help(label)
            .accessibilityLabel(label)
    }
}
