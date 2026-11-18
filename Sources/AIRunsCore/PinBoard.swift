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

public struct PinCard: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var title: String
    /// One line: what the user does next on this thread.
    public var next: String
    /// True when `next` was suggested from the AI's last reply.
    public var nextIsSuggested: Bool
    public var group: String
    public var link: PinLink?
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
        self.link = link
        self.excerpt = excerpt
        self.createdAt = createdAt
        self.touchedAt = touchedAt ?? createdAt
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
        // A project thread is pinned by its own link: local sessions come and go.
        let threadLink = session.thread?.appLink.map { PinLink.url($0.absoluteString) }
        if let index = cards.firstIndex(where: {
            if let threadLink { return $0.link == threadLink }
            if case .session(let tool, let sessionId, _, _) = $0.link {
                return tool == session.tool && sessionId == session.sessionId
            }
            return false
        }) {
            cards[index].touchedAt = now
            if let question = TextUtils.lastQuestion(in: session.lastMessage), cards[index].nextIsSuggested || cards[index].next.isEmpty {
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
            link: threadLink ?? .session(tool: session.tool, sessionId: session.sessionId, cwd: session.cwd, terminal: session.terminal),
            excerpt: TextUtils.preview(of: session.lastMessage, limit: 400),
            createdAt: now
        )
        add(card)
        return card
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
