import Foundation

/// Standard USD list prices per million tokens.
struct UsageTokenRate {
    let input: Decimal
    let cachedInput: Decimal
    let cacheWrite: Decimal
    let output: Decimal

    func usd(for counts: TokenCounts) -> Decimal {
        let freshInput = counts.input - counts.cacheRead - counts.cacheWrite
        return (Decimal(freshInput) * input
            + Decimal(counts.cacheRead) * cachedInput
            + Decimal(counts.cacheWrite) * cacheWrite
            + Decimal(counts.output) * output) / 1_000_000
    }
}

public struct UsageCostEstimate: Equatable, Sendable {
    public let totalUSD: Decimal?
    public let byModelUSD: [String: Decimal]
    public let unpricedTokens: Int64
    public let isPartial: Bool

    public static var pricingAsOf: String { UsagePricing.asOf }
}

/// Applies one pricing snapshot to the same deduplicated totals shown in Usage Dashboard.
public enum UsageCost {
    public static func estimate(_ usage: ProviderTokenUsage) -> UsageCostEstimate {
        let partialCoverage = usage.coverage == .partial || usage.coverage == .scanning
        guard let counts = usage.counts else {
            return UsageCostEstimate(totalUSD: nil, byModelUSD: [:], unpricedTokens: 0, isPartial: partialCoverage)
        }
        if counts.total == 0, partialCoverage, usage.models.isEmpty {
            return UsageCostEstimate(totalUSD: nil, byModelUSD: [:], unpricedTokens: 0, isPartial: true)
        }

        let priced = usage.models.compactMap { model -> (id: String, tokens: Int64, usd: Decimal)? in
            guard let rate = UsagePricing.rate(for: model.model, provider: usage.provider)
            else { return nil }
            return (model.id, model.counts.total, rate.usd(for: model.counts))
        }
        // Each model is a disjoint subtotal of the provider's already validated total.
        let unpriced = counts.total - priced.reduce(0) { $0 + $1.tokens }
        return UsageCostEstimate(
            totalUSD: unpriced == counts.total && counts.total > 0 ? nil : priced.reduce(0) { $0 + $1.usd },
            byModelUSD: Dictionary(uniqueKeysWithValues: priced.map { ($0.id, $0.usd) }),
            unpricedTokens: unpriced,
            isPartial: partialCoverage || unpriced > 0
        )
    }
}
