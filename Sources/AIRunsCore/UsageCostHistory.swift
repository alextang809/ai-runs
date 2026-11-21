import Foundation

public struct UsageCostHistory: Equatable, Sendable {
    public let today: UsageCostWindow
    public let last24Hours: UsageCostWindow
    public let last30Days: UsageCostWindow
    /// The last 30 calendar days, oldest first, through the last scan.
    public let days: [UsageCostDay]
}

public struct UsageCostWindow: Equatable, Sendable {
    public let tokens: Int64?
    public let estimate: UsageCostEstimate
}

public struct UsageCostDay: Equatable, Sendable {
    public let date: Date
    public let estimate: UsageCostEstimate
}
