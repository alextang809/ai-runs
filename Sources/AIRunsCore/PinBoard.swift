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

/// Identity and provenance captured when a user saves their place in a conversation.
public struct SavedTopic: Codable, Equatable, Sendable {
    public enum QuoteSource: String, Codable, Sendable { case reply, prompt }
    public let sessionID: String
    public let topicID: String
    public let quoteSource: QuoteSource?
    public let originalNext: String
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
    public fileprivate(set) var savedTopic: SavedTopic?
    public var isSavedForLater: Bool { savedTopic != nil }
    public var createdAt: Date
    /// Last time the user did anything with the card.
    public var touchedAt: Date
    public fileprivate(set) var menuNextAt: Date?

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
        case id, title, next, nextIsSuggested, group, link, attachments, excerpt, createdAt, touchedAt, menuNextAt, savedTopic
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        title = try values.decode(String.self, forKey: .title)
        next = try values.decode(String.self, forKey: .next)
        nextIsSuggested = try values.decode(Bool.self, forKey: .nextIsSuggested)
        group = try values.decode(String.self, forKey: .group)
        excerpt = try values.decodeIfPresent(String.self, forKey: .excerpt)
        savedTopic = try values.decodeIfPresent(SavedTopic.self, forKey: .savedTopic)
        createdAt = try values.decode(Date.self, forKey: .createdAt)
        touchedAt = try values.decode(Date.self, forKey: .touchedAt)
        menuNextAt = try values.decodeIfPresent(Date.self, forKey: .menuNextAt)
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
        try values.encodeIfPresent(savedTopic, forKey: .savedTopic)
        try values.encode(createdAt, forKey: .createdAt)
        try values.encode(touchedAt, forKey: .touchedAt)
        try values.encodeIfPresent(menuNextAt, forKey: .menuNextAt)
    }
}

/// The user's pinned threads and notes.
public struct PinBoard: Codable, Equatable, Sendable {
    public static let inbox = "Inbox"
    public static let maximumMenuNextCards = 3
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

    public var menuNextCards: [PinCard] {
        let selections = cards.compactMap { card -> (date: Date, card: PinCard)? in
            guard let date = card.menuNextAt, !card.next.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { return nil }
            return (date, card)
        }
        return selections.sorted { lhs, rhs in
            lhs.date == rhs.date ? lhs.card.id.uuidString < rhs.card.id.uuidString : lhs.date < rhs.date
        }.prefix(Self.maximumMenuNextCards).map(\.card)
    }

    @discardableResult
    public mutating func setMenuNext(_ selected: Bool, for cardID: UUID, now: Date = Date()) -> Bool {
        guard let index = cards.firstIndex(where: { $0.id == cardID }),
              selected == (cards[index].menuNextAt == nil) else { return false }
        let card = cards[index]
        if selected {
            guard menuNextCards.count < Self.maximumMenuNextCards,
                  !card.next.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        }
        var updated = card
        updated.menuNextAt = selected ? now : nil
        updated.touchedAt = now
        cards[index] = updated
        return true
    }

    public func card(id: UUID) -> PinCard? { cards.first { $0.id == id } }

    public mutating func add(_ card: PinCard) {
        cards.insert(card, at: 0)
    }

    public var savedForLaterCards: [PinCard] {
        cards.filter(\.isSavedForLater).sorted { $0.createdAt > $1.createdAt }
    }

    public func savedForLater(session: Session) -> PinCard? {
        cards.first { $0.savedTopic?.sessionID == session.id && $0.savedTopic?.topicID == session.currentTopicID }
    }

    @discardableResult
    public mutating func saveForLater(session: Session, now: Date = Date()) -> PinCard {
        if let existing = savedForLater(session: session) { return existing }
        let attachment = PinAttachment.session(session)
        let reply = Self.nonblank(session.currentTopicReply)
        let quote = reply ?? Self.nonblank(session.latestUserPrompt) ?? Self.nonblank(session.currentTopicPrompt)
        let source: SavedTopic.QuoteSource? = reply != nil ? .reply : (quote != nil ? .prompt : nil)
        let manual = manualNext(for: session, attachment: attachment)
        let next = manual ?? Self.action(in: reply) ?? ""
        var card = PinCard(title: session.currentTopicTitle, next: next, nextIsSuggested: manual == nil && !next.isEmpty,
                           group: session.project.isEmpty ? Self.inbox : session.project, link: attachment.link,
                           excerpt: quote, createdAt: now)
        card.savedTopic = SavedTopic(sessionID: session.id, topicID: session.currentTopicID,
                                    quoteSource: source, originalNext: next)
        add(card)
        return card
    }

    private func manualNext(for session: Session, attachment: PinAttachment) -> String? {
        // Older board cards have no topic identity. A transition makes their actions ambiguous.
        guard session.isInitialTopic else { return nil }
        let matches = cards.filter { card in
            !card.isSavedForLater && !card.nextIsSuggested && card.attachments.count == 1
                && card.attachments[0].matches(attachment) && Self.nonblank(card.next) != nil
        }
        return matches.count == 1 ? matches[0].next : nil
    }

    private static func nonblank(_ value: String?) -> String? {
        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return value
    }

    /// A labelled handoff or a direct invitation to act is safe to surface. Otherwise the quote suffices.
    private static func action(in reply: String?) -> String? {
        guard let reply else { return nil }
        // Skip quoted examples and fenced code; keep punctuation inside filenames and URLs.
        var fence: Substring?
        let prose = reply.split(whereSeparator: \.isNewline).compactMap { line -> String? in
            let clean = line.drop(while: \.isWhitespace)
            if let active = fence {
                if clean.hasPrefix(active) { fence = nil }
                return nil
            }
            if clean.hasPrefix("```") || clean.hasPrefix("~~~") {
                fence = clean.prefix(while: { $0 == clean.first })
                return nil
            }
            return clean.hasPrefix(">") ? nil : String(clean)
        }
        let sentences = prose.joined(separator: "\n")
            .replacingOccurrences(of: #"(?<=[.!?])\s+|(?<=[。！？])\s*|，(?=(?:你可以|可以开始|现在可以|请))"#,
                                  with: "\n", options: .regularExpression)
        for sentence in sentences.components(separatedBy: .newlines) {
            if let action = actionSentence(sentence) { return action }
        }
        return nil
    }

    private static func actionSentence(_ sentence: String) -> String? {
        let cue = #"(?i)^(?:next step\s*[:：]\s*|下一步\s*[:：]\s*|you can now\s+|please\s+|(?:现在|你)可以(?:开始)?|可以开始|请(?:你)?)(.+)$"#
        let line = sentence.replacingOccurrences(of: "**", with: "")
            .trimmingCharacters(in: CharacterSet(charactersIn: "-*• \t"))
        guard line.range(of: cue, options: .regularExpression) != nil else { return nil }
        let action = line.replacingOccurrences(of: cue, with: "$1", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !action.isEmpty, action.count <= 180, !action.contains("?"), !action.contains("？"),
              action.range(of: #"(?i)^(?:I(?:’|'|\s)|we\b|我|要不要|如果|是否)"#, options: .regularExpression) == nil
        else { return nil }
        return action
    }

    /// Pins a session. If it is already pinned, the existing card is refreshed instead.
    @discardableResult
    public mutating func pin(session: Session, now: Date = Date()) -> PinCard {
        let attachment = PinAttachment.session(session)
        if let index = cards.firstIndex(where: { card in
            !card.isSavedForLater && card.attachments.contains { $0.matches(attachment) || Self.isLegacyWebPin($0, for: session) }
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
            if next.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { cards[index].menuNextAt = nil }
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
        var card = archived.remove(at: position)
        if menuNextCards.count >= Self.maximumMenuNextCards { card.menuNextAt = nil }
        cards.insert(card, at: min(max(0, index), cards.count))
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
