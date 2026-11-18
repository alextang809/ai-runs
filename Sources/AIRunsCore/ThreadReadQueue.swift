/// Serializes Claude AX reads. Explicit refreshes can request a larger scan.
public struct ThreadReadQueue: Equatable, Sendable {
    public enum Request: Equatable, Sendable {
        case regular
        case refresh
    }

    public let active: Request?
    public let refreshPending: Bool
    /// Only the explicit refresh result belongs to the user confirmation.
    public var shouldAnnounce: Bool { active == .refresh }

    public init() {
        active = nil
        refreshPending = false
    }

    private init(active: Request?, refreshPending: Bool) {
        self.active = active
        self.refreshPending = refreshPending
    }

    public func requesting(_ request: Request) -> Self {
        guard active != nil else { return Self(active: request, refreshPending: false) }
        guard request == .refresh else { return self }
        return Self(active: active, refreshPending: true)
    }

    /// Completing an unavailable or empty read releases the same gate as a full result.
    public func completing() -> Self {
        Self(active: refreshPending ? .refresh : nil, refreshPending: false)
    }
}
