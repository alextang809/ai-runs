import Foundation

/// Public first-party Standard API rates, in USD per million tokens.
/// Uses base context rates and the standard cache write lifetimes (OpenAI 30m, Claude 5m).
public enum UsagePricing {
    public static let asOf = "2026-11-21"

    static func rate(for model: String, provider: UsageProvider) -> UsageTokenRate? {
        switch provider {
        case .codex: return openAIRate(for: model)
        case .claudeCode: return claudeRate(for: model)
        }
    }

    // https://developers.openai.com/api/docs/pricing
    // Previous generation rates and snapshot IDs come from the corresponding model pages.
    private static func openAIRate(for model: String) -> UsageTokenRate? {
        switch model {
        case "gpt-6.2-astra":
            return rate(input: 8_000, cached: 400, write: 10_000, output: 40_000)
        case "gpt-6.2-sol", "gpt-6.1-sol":
            return rate(input: 2_000, cached: 100, write: 2_500, output: 10_000)
        case "gpt-6.1-terra":
            return rate(input: 1_000, cached: 50, write: 1_250, output: 5_000)
        case "gpt-6-astra":
            return rate(input: 10_000, cached: 1_000, write: 12_500, output: 50_000)
        case "gpt-6-sol":
            return rate(input: 2_000, cached: 200, write: 2_500, output: 10_000)
        case "gpt-6-luna":
            return rate(input: 100, cached: 10, write: 125, output: 500)
        case "gpt-5.6-sol":
            // Published Standard rate through November 30, 2026.
            return rate(input: 4_000, cached: 400, write: 5_000, output: 20_000)
        case "gpt-5.6-terra":
            return rate(input: 2_000, cached: 200, write: 2_500, output: 12_000)
        case "gpt-5.6-luna":
            return rate(input: 200, cached: 20, write: 250, output: 1_200)
        case "gpt-5.5", "gpt-5.5-2026-04-23":
            return rate(input: 5_000, cached: 500, output: 30_000)
        case "gpt-5.4", "gpt-5.4-2026-03-05":
            return rate(input: 2_500, cached: 250, output: 15_000)
        case "gpt-5.4-mini", "gpt-5.4-mini-2026-03-17":
            return rate(input: 750, cached: 75, output: 4_500)
        case "gpt-5.4-nano":
            return rate(input: 200, cached: 20, output: 1_250)
        case "gpt-5.3-codex", "gpt-5.2", "gpt-5.2-2025-12-11", "gpt-5.2-codex":
            return rate(input: 1_750, cached: 175, output: 14_000)
        case "gpt-5.1", "gpt-5.1-codex", "gpt-5.1-codex-max", "gpt-5", "gpt-5-codex":
            return rate(input: 1_250, cached: 125, output: 10_000)
        case "gpt-5-mini", "gpt-5-mini-2025-08-07", "gpt-5.1-codex-mini":
            return rate(input: 250, cached: 25, output: 2_000)
        case "gpt-5-nano":
            return rate(input: 50, cached: 5, output: 400)
        default:
            return nil
        }
    }

    // https://platform.claude.com/docs/en/about-claude/pricing
    // https://platform.claude.com/docs/en/about-claude/model-deprecations
    private static func claudeRate(for model: String) -> UsageTokenRate? {
        switch model {
        case "claude-fable-5-2", "claude-mythos-5-2":
            return rate(input: 8_000, cached: 200, write: 10_000, output: 40_000)
        case "claude-fable-5-1", "claude-mythos-5-1":
            return rate(input: 10_000, cached: 250, write: 12_500, output: 50_000)
        case "claude-fable-5", "claude-mythos-5":
            return rate(input: 10_000, cached: 1_000, write: 12_500, output: 50_000)
        case "claude-opus-5-5":
            return rate(input: 4_000, cached: 200, write: 5_000, output: 20_000)
        case "claude-sonnet-5-5":
            return rate(input: 2_000, cached: 100, write: 2_500, output: 10_000)
        case "claude-sonnet-5":
            return rate(input: 2_000, cached: 200, write: 2_500, output: 10_000)
        case "claude-haiku-5-5":
            return rate(input: 100, cached: 10, write: 125, output: 500)
        case "claude-opus-5", "claude-opus-4-8", "claude-opus-4-7", "claude-opus-4-6",
             "claude-opus-4-5", "claude-opus-4-5-20251101":
            return rate(input: 5_000, cached: 500, write: 6_250, output: 25_000)
        case "claude-opus-4-1", "claude-opus-4-1-20250805", "claude-opus-4-20250514":
            return rate(input: 15_000, cached: 1_500, write: 18_750, output: 75_000)
        case "claude-sonnet-4-6", "claude-sonnet-4-5", "claude-sonnet-4-5-20250929", "claude-sonnet-4-20250514":
            return rate(input: 3_000, cached: 300, write: 3_750, output: 15_000)
        case "claude-haiku-4-5", "claude-haiku-4-5-20251001":
            return rate(input: 1_000, cached: 100, write: 1_250, output: 5_000)
        default:
            return nil
        }
    }

    /// Thousandths of a dollar keep the documented decimals exact.
    /// Older OpenAI models use the ordinary input rate for cache writes.
    private static func rate(input: Int, cached: Int, write: Int? = nil, output: Int) -> UsageTokenRate {
        UsageTokenRate(input: Decimal(input) / 1_000, cachedInput: Decimal(cached) / 1_000,
                       cacheWrite: Decimal(write ?? input) / 1_000, output: Decimal(output) / 1_000)
    }
}
