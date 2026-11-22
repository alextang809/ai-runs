import Foundation

/// What a pinned card opens when clicked.
public enum PinLink: Codable, Equatable, Sendable {
    /// A web page, e.g. a claude.ai or chatgpt.com conversation.
    case url(String)
    /// An app to bring to the front.
    case app(bundleId: String, name: String)
    /// A Claude Code or Codex session, reopened through its terminal.
    case session(tool: AgentTool, sessionId: String, cwd: String?, terminal: TerminalContext)

    public var label: String {
        switch self {
        case .url(let string):
            // A link into the Claude app (`claude://code/project/…`).
            if URL(string: string)?.scheme == "claude" { return "Claude" }
            return URL(string: string)?.host ?? string
        case .app(_, let name):
            return name
        case .session(let tool, _, let cwd, _):
            let project = TextUtils.projectName(fromPath: cwd)
            return project.isEmpty ? tool.displayName : "\(tool.displayName) · \(project)"
        }
    }
}

public struct PinAttachment: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public let title: String
    public let link: PinLink

    public init(id: UUID = UUID(), title: String, link: PinLink) {
        self.id = id
        self.title = title
        self.link = Self.restoreWebLink(link)
    }

    private static func restoreWebLink(_ link: PinLink) -> PinLink {
        // Legacy browser pins only saved the ID extracted by the browser extension.
        guard case let .session(tool, id, _, _) = link, tool.isWeb,
              id.range(of: #"\A[A-Za-z0-9-]{8,128}\z"#, options: .regularExpression) != nil else {
            return link
        }
        let prefix = tool == .claudeWeb ? "https://claude.ai/chat/" : "https://chatgpt.com/c/"
        return .url(prefix + id)
    }

    public static func session(_ session: Session) -> Self {
        let link: PinLink
        if let project = session.claudeAppLink {
            link = .url(project.absoluteString)
        } else if session.tool == .claudeWeb, let address = session.webURL, let url = artifactURL(address),
                  url.scheme?.lowercased() == "https", url.host?.lowercased() == "claude.ai" {
            link = .url(url.absoluteString)
        } else {
            link = .session(tool: session.tool, sessionId: session.sessionId, cwd: session.cwd, terminal: session.terminal)
        }
        return Self(title: session.title, link: link)
    }

    public static func artifact(_ input: String, title: String = "") -> Self? {
        let address = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = artifactURL(address), let host = url.host else { return nil }
        let label = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let destination = host + (url.path == "/" ? "" : url.path)
        return Self(title: TextUtils.truncate(label.isEmpty ? destination : label, limit: 120),
                    link: .url(url.absoluteString))
    }

    public func matches(_ other: Self) -> Bool {
        switch (link, other.link) {
        case let (.session(tool, id, _, _), .session(otherTool, otherID, _, _)):
            return tool == otherTool && id == otherID
        case let (.app(bundleID, _), .app(otherBundleID, _)):
            return bundleID == otherBundleID
        default:
            return link == other.link
        }
    }

    private static func artifactURL(_ address: String) -> URL? {
        let invalidCharacters = CharacterSet.whitespacesAndNewlines.union(.controlCharacters)
        guard address.utf8.count <= 8_192, !address.contains("\\"),
              address.rangeOfCharacter(from: invalidCharacters) == nil,
              let components = URLComponents(string: address),
              let scheme = components.scheme?.lowercased(), scheme == "https" || scheme == "http",
              let host = components.host, !host.isEmpty, host.rangeOfCharacter(from: invalidCharacters) == nil,
              components.port.map({ (1...65_535).contains($0) }) ?? true,
              components.user == nil, components.password == nil else { return nil }
        return components.url
    }
}

public struct PinCard: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var title: String
    /// One line: what the user does next on this thread.
    public var next: String
    /// True when `next` was suggested from the AI's last reply.
    public var nextIsSuggested: Bool
    public var group: String
    public fileprivate(set) var attachments: [PinAttachment]
    public var link: PinLink? { attachments.first?.link }
    /// A passage the user wanted to keep from a reply.
    public var excerpt: String?
    public var createdAt: Date
    /// Last time the user did anything with the card.
    public var touchedAt: Date

    public init(id: UUID = UUID(), title: String, next: String = "", nextIsSuggested: Bool = false,
                group: String = PinBoard.inbox, link: PinLink? = nil, excerpt: String? = nil,
                createdAt: Date = Date(), touchedAt: Date? = nil) {
        self.id = id
        self.title = title
        self.next = next
        self.nextIsSuggested = nextIsSuggested
        self.group = group
        self.attachments = link.map { [PinAttachment(id: id, title: title, link: $0)] } ?? []
        self.excerpt = excerpt
        self.createdAt = createdAt
        self.touchedAt = touchedAt ?? createdAt
    }

    fileprivate func withAttachments(_ attachments: [PinAttachment], at date: Date) -> Self {
        var copy = self
        copy.attachments = attachments
        copy.touchedAt = date
        return copy
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, next, nextIsSuggested, group, link, attachments, excerpt, createdAt, touchedAt
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        title = try values.decode(String.self, forKey: .title)
        next = try values.decode(String.self, forKey: .next)
        nextIsSuggested = try values.decode(Bool.self, forKey: .nextIsSuggested)
        group = try values.decode(String.self, forKey: .group)
        excerpt = try values.decodeIfPresent(String.self, forKey: .excerpt)
        createdAt = try values.decode(Date.self, forKey: .createdAt)
        touchedAt = try values.decode(Date.self, forKey: .touchedAt)
        if let saved = try values.decodeIfPresent([PinAttachment].self, forKey: .attachments) {
            attachments = saved
        } else if let legacy = try values.decodeIfPresent(PinLink.self, forKey: .link) {
            attachments = [PinAttachment(id: id, title: title, link: legacy)]
        } else {
            attachments = []
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(title, forKey: .title)
        try values.encode(next, forKey: .next)
        try values.encode(nextIsSuggested, forKey: .nextIsSuggested)
        try values.encode(group, forKey: .group)
        try values.encode(attachments, forKey: .attachments)
        try values.encodeIfPresent(link, forKey: .link)
        try values.encodeIfPresent(excerpt, forKey: .excerpt)
        try values.encode(createdAt, forKey: .createdAt)
        try values.encode(touchedAt, forKey: .touchedAt)
    }
}

/// The user's pinned threads and notes.
public struct PinBoard: Codable, Equatable, Sendable {
    public static let inbox = "Inbox"
    /// Cards untouched for this long move to "Maybe done".
    public static let staleAfter: TimeInterval = 3 * 24 * 3600

    public private(set) var cards: [PinCard] = []
    public private(set) var archived: [PinCard] = []

    public init() {}

    public struct Group: Equatable, Sendable {
        public var name: String
        public var cards: [PinCard]
    }

    public func isStale(_ card: PinCard, now: Date) -> Bool {
        now.timeIntervalSince(card.touchedAt) >= PinBoard.staleAfter
    }

    /// Fresh cards by group. Inbox first, then groups in order of their newest
    /// card; cards newest first.
    public func groups(now: Date) -> [Group] {
        let fresh = cards.filter { !isStale($0, now: now) }
        var byName: [String: [PinCard]] = [:]
        for card in fresh { byName[card.group, default: []].append(card) }
        return byName.map { Group(name: $0.key, cards: $0.value.sorted { $0.touchedAt > $1.touchedAt }) }
            .sorted { a, b in
                if a.name == PinBoard.inbox { return true }
                if b.name == PinBoard.inbox { return false }
                return (a.cards.first?.touchedAt ?? .distantPast) > (b.cards.first?.touchedAt ?? .distantPast)
            }
    }

    public func staleCards(now: Date) -> [PinCard] {
        cards.filter { isStale($0, now: now) }.sorted { $0.touchedAt > $1.touchedAt }
    }

    public var groupNames: [String] {
        var names = Array(Set(cards.map(\.group))).sorted()
        if !names.contains(PinBoard.inbox) { names.insert(PinBoard.inbox, at: 0) }
        return names
    }

    public func card(id: UUID) -> PinCard? { cards.first { $0.id == id } }

    public mutating func add(_ card: PinCard) {
        cards.insert(card, at: 0)
    }

    /// Pins a session. If it is already pinned, the existing card is refreshed instead.
    @discardableResult
    public mutating func pin(session: Session, now: Date = Date()) -> PinCard {
        let attachment = PinAttachment.session(session)
        if let index = cards.firstIndex(where: { card in
            card.attachments.contains { $0.matches(attachment) || Self.isLegacyWebPin($0, for: session) }
        }) {
            let card = cards[index]
            let refreshed = card.attachments.map { saved in
                guard saved.matches(attachment) || Self.isLegacyWebPin(saved, for: session) else { return saved }
                return PinAttachment(id: saved.id, title: attachment.title, link: attachment.link)
            }
            let updated = card.withAttachments(refreshed, at: now)
            cards[index] = updated
            if updated.attachments.count == 1, let question = TextUtils.lastQuestion(in: session.lastMessage),
               updated.nextIsSuggested || updated.next.isEmpty {
                cards[index].next = question
                cards[index].nextIsSuggested = true
            }
            return cards[index]
        }
        let question = TextUtils.lastQuestion(in: session.lastMessage)
        let card = PinCard(
            title: session.title,
            next: question ?? "",
            nextIsSuggested: question != nil,
            group: session.project.isEmpty ? PinBoard.inbox : session.project,
            link: attachment.link,
            excerpt: TextUtils.preview(of: session.lastMessage, limit: 400),
            createdAt: now
        )
        add(card)
        return card
    }

    private static func isLegacyWebPin(_ attachment: PinAttachment, for session: Session) -> Bool {
        guard session.tool == .claudeWeb, case let .session(tool, id, _, _) = attachment.link else { return false }
        return tool == session.tool && id == session.sessionId
    }

    @discardableResult
    public mutating func attach(_ attachment: PinAttachment, to cardID: UUID, now: Date = Date()) -> Bool {
        guard let index = cards.firstIndex(where: { $0.id == cardID }) else { return false }
        let card = cards[index]
        guard !card.attachments.contains(where: { $0.id == attachment.id || $0.matches(attachment) }) else { return false }
        cards[index] = card.withAttachments(card.attachments + [attachment], at: now)
        return true
    }

    @discardableResult
    public mutating func detach(_ attachmentID: UUID, from cardID: UUID, now: Date = Date()) -> Bool {
        guard let index = cards.firstIndex(where: { $0.id == cardID }) else { return false }
        let card = cards[index]
        let remaining = card.attachments.filter { $0.id != attachmentID }
        guard remaining.count != card.attachments.count else { return false }
        cards[index] = card.withAttachments(remaining, at: now)
        return true
    }

    public mutating func update(id: UUID, title: String? = nil, next: String? = nil, group: String? = nil,
                                now: Date = Date()) {
        guard let index = cards.firstIndex(where: { $0.id == id }) else { return }
        if let title, !title.trimmingCharacters(in: .whitespaces).isEmpty { cards[index].title = title }
        if let next {
            cards[index].next = next
            cards[index].nextIsSuggested = false
        }
        if let group {
            let trimmed = group.trimmingCharacters(in: .whitespaces)
            cards[index].group = trimmed.isEmpty ? PinBoard.inbox : trimmed
        }
        cards[index].touchedAt = now
    }

    /// "Still working on it": brings a stale card back.
    public mutating func touch(id: UUID, now: Date = Date()) {
        guard let index = cards.firstIndex(where: { $0.id == id }) else { return }
        cards[index].touchedAt = now
    }

    public mutating func archive(id: UUID) {
        guard let index = cards.firstIndex(where: { $0.id == id }) else { return }
        archived.insert(cards.remove(at: index), at: 0)
        if archived.count > 200 { archived.removeLast(archived.count - 200) }
    }

    /// Undoes `archive`: puts the card back where it was.
    public mutating func unarchive(id: UUID, at index: Int) {
        guard let position = archived.firstIndex(where: { $0.id == id }) else { return }
        cards.insert(archived.remove(at: position), at: min(max(0, index), cards.count))
    }

    public func index(of id: UUID) -> Int? { cards.firstIndex { $0.id == id } }

    /// Text to paste at the start of a new chat so it can pick up the thread.
    public static func handoff(for card: PinCard) -> String {
        var lines = ["Continuing from an earlier conversation: \(card.title)."]
        if let excerpt = card.excerpt, !excerpt.isEmpty {
            lines.append("")
            lines.append("Where we got to:")
            lines.append(excerpt)
        }
        if !card.next.isEmpty {
            lines.append("")
            lines.append("Next step: \(card.next)")
        }
        return lines.joined(separator: "\n")
    }
}
