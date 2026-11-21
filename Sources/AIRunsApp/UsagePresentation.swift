import AIRunsCore
import Foundation

struct UsageMoneyDisplay {
    let code: String
    private let unitsPerUSD: Decimal

    init(code: String, unitsPerUSD: Decimal?) {
        if code != "USD", let unitsPerUSD, unitsPerUSD > 0 {
            self.code = code
            self.unitsPerUSD = unitsPerUSD
        } else {
            self.code = "USD"
            self.unitsPerUSD = 1
        }
    }

    func format(_ amountUSD: Decimal, locale: Locale = .current) -> String {
        UsagePresentation.currency(amountUSD * unitsPerUSD, code: code, useISOCode: true, locale: locale)
    }
}

/// Formatting and availability semantics shared by the menu and usage window.
enum UsagePresentation {
    static func compact(_ count: Int64, locale: Locale = .current) -> String {
        guard count >= 0 else { return "—" }
        let units: [(Int64, String)] = [(1, ""), (1_000, "K"), (1_000_000, "M"), (1_000_000_000, "B")]
        var index = 0
        while index + 1 < units.count, count >= units[index + 1].0 { index += 1 }
        var scaled = Double(count) / Double(units[index].0)
        var decimals = fractionDigits(scaled)
        let factor = pow(10.0, Double(decimals))
        if index + 1 < units.count, (scaled * factor).rounded() / factor >= 1_000 {
            index += 1
            scaled = Double(count) / Double(units[index].0)
            decimals = fractionDigits(scaled)
        }
        let formatter = formatter(locale: locale, decimals: decimals, grouping: false)
        return (formatter.string(from: NSNumber(value: scaled)) ?? String(count)) + units[index].1
    }

    static func exact(_ count: Int64, locale: Locale = .current) -> String {
        formatter(locale: locale, decimals: 0, grouping: true).string(from: NSNumber(value: count)) ?? String(count)
    }

    static func usd(_ amount: Decimal, locale: Locale = .current) -> String {
        currency(amount, code: "USD", useISOCode: false, locale: locale)
    }

    static func currency(_ amount: Decimal, code: String, useISOCode: Bool, locale: Locale) -> String {
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = useISOCode ? .currencyISOCode : .currency
        formatter.currencyCode = code
        let digits = ["ISK", "JPY", "KRW"].contains(code) ? 0 : 2
        formatter.minimumFractionDigits = digits
        formatter.maximumFractionDigits = digits
        formatter.roundingMode = .halfUp
        let minorUnit = digits == 0 ? Decimal(1) : Decimal(1) / 100
        let belowMinorUnit = amount > 0 && amount < minorUnit
        let displayed = NSDecimalNumber(decimal: belowMinorUnit ? minorUnit : amount)
        return (belowMinorUnit ? "<" : "") + (formatter.string(from: displayed) ?? "\(code) \(displayed)")
    }

    static func valueText(_ usage: ProviderTokenUsage, locale: Locale = .current) -> String {
        if usage.coverage == .unavailable { return "No local records" }
        guard let counts = usage.counts else {
            return usage.coverage == .scanning ? "Scanning…" : "Unavailable"
        }
        return "\(compact(counts.total, locale: locale)) tokens"
    }

    static func statusText(_ usage: ProviderTokenUsage) -> String? {
        guard usage.counts != nil else { return nil }
        switch usage.coverage {
        case .scanning: return "Scanning"
        case .partial: return "Partial"
        case .complete, .unavailable: return nil
        }
    }

    static func accessibilityValue(_ usage: ProviderTokenUsage, locale: Locale = .current) -> String {
        guard usage.coverage != .unavailable, let counts = usage.counts else {
            return valueText(usage, locale: locale)
        }
        return "\(exact(counts.total, locale: locale)) recorded tokens"
            + (statusText(usage).map { ", \($0)" } ?? "")
    }

    static func periodTitle(_ period: UsagePeriod) -> String {
        switch period {
        case .today: return "Today"
        case .last24Hours: return "Last 24 hours"
        case .last7Days: return "Last 7 days"
        case .last30Days: return "Last 30 days"
        }
    }

    static func coverageDescription(_ usage: ProviderTokenUsage) -> String {
        switch usage.coverage {
        case .unavailable:
            return "No supported local token records were found for this provider."
        case .scanning:
            return usage.counts == nil ? "Reading recorded usage on this Mac…"
                : "Scan in progress. This is the subtotal of records read so far."
        case .partial:
            return usage.counts == nil ? "Some local records could not be read or accounted for. Usage is unavailable."
                : "Some local records could not be fully accounted for. This is the available subtotal."
        case .complete:
            return "Recorded on this Mac. Activity without local token records is not included."
        }
    }

    static func issueDescription(_ issue: UsageIssue) -> String {
        switch issue {
        case .ioFailure: return "Some local usage data could not be read or cached."
        case .unsupportedHistory: return "Some history is unsupported or exceeds the local scan limit."
        case .inconsistentUsage: return "Conflicting or invalid token counts were excluded."
        case .counterReset: return "A token counter restarted; unclear portions were excluded."
        case .unattributedUsage: return "Some usage could not be assigned to a request or time."
        case .missingIdentity: return "Some records lack a stable request identifier."
        case .malformedRecord: return "Some usage records could not be decoded."
        case .incompleteRecord: return "Some responses do not yet have complete usage."
        }
    }

    private static func fractionDigits(_ value: Double) -> Int { value >= 100 ? 0 : (value >= 10 ? 1 : 2) }

    private static func formatter(locale: Locale, decimals: Int, grouping: Bool) -> NumberFormatter {
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = grouping
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = decimals
        formatter.roundingMode = .halfUp
        return formatter
    }
}
