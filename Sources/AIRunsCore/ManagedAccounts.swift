import Foundation

public enum AccountProvider: String, Codable, CaseIterable, Sendable {
    case codex, claude, deepseek
    case qwenSubscription = "qwen-subscription"
    case qwen

    public var displayName: String {
        switch self {
        case .codex: return "ChatGPT"
        case .claude: return "Claude"
        case .deepseek: return "DeepSeek"
        case .qwen: return "Qwen"
        case .qwenSubscription: return "Qwen Subscription"
        }
    }

    public var usesAPIKey: Bool { self == .deepseek || self == .qwen }
}

/// Display metadata only. Credentials are stored separately.
public struct ManagedAccount: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let provider: AccountProvider
    public let label: String
    public let email: String?
    public let plan: String?
    public let createdAt: Date
    public let lastVerifiedAt: Date?

    public init(id: UUID = UUID(), provider: AccountProvider, label: String = "",
                email: String? = nil, plan: String? = nil, createdAt: Date = Date(),
                lastVerifiedAt: Date? = nil) {
        self.id = id
        self.provider = provider
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        self.label = trimmed.isEmpty ? provider.displayName : trimmed
        self.email = email
        self.plan = plan
        self.createdAt = createdAt
        self.lastVerifiedAt = lastVerifiedAt
    }

    public func verified(email: String?, plan: String?, at date: Date = Date()) -> Self {
        Self(id: id, provider: provider, label: label, email: email, plan: plan,
             createdAt: createdAt, lastVerifiedAt: date)
    }
}

public struct AccountRateWindow: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let title: String
    public let usedPercent: Double
    public let durationMinutes: Int?
    public let resetsAt: Date?

    public init?(id: String, title: String, usedPercent: Double,
                 durationMinutes: Int? = nil, resetsAt: Date? = nil) {
        guard !id.isEmpty, id.count <= 256, !title.isEmpty, title.count <= 256,
              usedPercent.isFinite, (0...100).contains(usedPercent),
              durationMinutes.map({ $0 > 0 }) ?? true,
              resetsAt.map({ $0.timeIntervalSince1970.isFinite }) ?? true else { return nil }
        self.id = id
        self.title = title
        self.usedPercent = usedPercent
        self.durationMinutes = durationMinutes
        self.resetsAt = resetsAt
    }

    private enum CodingKeys: CodingKey { case id, title, usedPercent, durationMinutes, resetsAt }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        guard let result = Self(id: try values.decode(String.self, forKey: .id),
                title: try values.decode(String.self, forKey: .title),
                usedPercent: try values.decode(Double.self, forKey: .usedPercent),
                durationMinutes: try values.decodeIfPresent(Int.self, forKey: .durationMinutes),
                resetsAt: try values.decodeIfPresent(Date.self, forKey: .resetsAt)) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                                                   debugDescription: "Invalid usage window"))
        }
        self = result
    }
}

public struct AccountConnectionResult: Equatable, Sendable {
    public let account: ManagedAccount
    public let windows: [AccountRateWindow]
    public let note: String?
    public let quotaRefreshed: Bool

    public init(account: ManagedAccount, windows: [AccountRateWindow], note: String? = nil,
                quotaRefreshed: Bool = true) {
        self.account = account
        self.windows = windows
        self.note = note
        self.quotaRefreshed = quotaRefreshed
    }
}

public enum AccountRegistryError: Error, LocalizedError, Sendable {
    case unsafePath, invalidMetadata, readFailed, writeFailed

    public var errorDescription: String? {
        switch self {
        case .unsafePath: return "The account storage folder must be private and cannot contain symbolic links."
        case .invalidMetadata: return "Saved account details are invalid. Existing profiles were left unchanged."
        case .readFailed: return "Saved account details could not be read."
        case .writeFailed: return "Account details could not be saved."
        }
    }
}
