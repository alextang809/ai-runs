import Foundation

/// The project's main conversation or one of its child threads. Main has no
/// thread id; it must not borrow the identity of a thread linked nearby.
public struct ClaudeConversation: Codable, Equatable, Hashable, Sendable {
    public let projectId: String
    public let threadId: String?

    public init(projectId: String, threadId: String? = nil) {
        self.projectId = projectId
        self.threadId = threadId
    }

    public var thread: ProjectThread? {
        guard Self.valid(projectId, prefix: "chan_"), let threadId,
              Self.valid(threadId, prefix: "cmsg_") else { return nil }
        return ProjectThread(projectId: projectId, threadId: threadId)
    }

    public var appLink: URL? {
        guard Self.valid(projectId, prefix: "chan_") else { return nil }
        if let threadId {
            guard Self.valid(threadId, prefix: "cmsg_") else { return nil }
            return URL(string: "claude://code/project/\(projectId)?thread=\(threadId)")
        }
        return URL(string: "claude://code/project/\(projectId)")
    }

    fileprivate static func valid(_ value: String, prefix: String) -> Bool {
        value.range(of: "\\A\(prefix)[A-Za-z0-9]{4,}\\z", options: .regularExpression) != nil
    }
}

/// Identity-only evidence. It says which conversation is open, not its state.
public struct CurrentClaudeView: Equatable, Sendable {
    public let conversation: ClaudeConversation
    public let title: String?

    public init(conversation: ClaudeConversation, title: String? = nil) {
        self.conversation = conversation
        self.title = title
    }
}

/// Reads only the web area's own route and title. Conversation messages,
/// list-section headings and nearby activity indicators cannot identify it.
public enum ClaudeCurrentView {
    public static func sightings(in root: AXNode) -> [CurrentClaudeView] {
        let current: [CurrentClaudeView]
        if root.role == "AXWebArea", let conversation = conversation(from: root.url) {
            let headers = toolbars(in: root)
            if conversation.threadId == nil {
                current = [CurrentClaudeView(conversation: conversation,
                                             title: visibleProjectTitle(in: headers, documentTitle: root.title) ?? title(root.title))]
            } else {
                let main = visibleProjectTitle(in: headers, documentTitle: root.title).map {
                    CurrentClaudeView(conversation: ClaudeConversation(projectId: conversation.projectId), title: $0)
                }
                current = [main].compactMap { $0 } + [CurrentClaudeView(conversation: conversation, title: threadTitle(in: headers))]
            }
        } else {
            current = []
        }
        let found = current + root.children.flatMap { sightings(in: $0) }
        return found.reduce([CurrentClaudeView]()) { merged, view in
            guard let index = merged.firstIndex(where: { $0.conversation == view.conversation }) else {
                return merged + [view]
            }
            guard merged[index].title == nil, view.title != nil else { return merged }
            return merged.enumerated().map { $0.offset == index ? view : $0.element }
        }
    }

    private static func conversation(from text: String?) -> ClaudeConversation? {
        guard let text, let parts = URLComponents(string: text), parts.scheme?.lowercased() == "https",
              parts.host?.lowercased() == "claude.ai", parts.user == nil, parts.password == nil,
              parts.port == nil || parts.port == 443 else { return nil }
        guard parts.path.range(of: #"\A/(epitaxy|code)/project/chan_[A-Za-z0-9]{4,}/?\z"#,
                               options: .regularExpression) != nil else { return nil }
        let project = parts.path.split(separator: "/").last.map(String.init) ?? ""
        let parameters = (parts.queryItems ?? []).filter { $0.name.lowercased() == "thread" }
        guard parameters.count <= 1 else { return nil }
        if let parameter = parameters.first {
            guard parameter.name == "thread", let thread = parameter.value,
                  ClaudeConversation.valid(thread, prefix: "cmsg_") else { return nil }
            return ClaudeConversation(projectId: project, threadId: thread)
        }
        return ClaudeConversation(projectId: project)
    }

    /// Stop at each toolbar and nested web area: only controls belonging to
    /// this web area can supply its project or child-thread header.
    private static func toolbars(in node: AXNode) -> [AXNode] {
        node.children.flatMap { child -> [AXNode] in
            if child.role == "AXWebArea" { return [] }
            if child.role == "AXToolbar" { return [child] }
            return toolbars(in: child)
        }
    }

    /// Header wrappers are groups. Do not descend into a heading's text or a
    /// nested toolbar, where unrelated content could otherwise supply a name.
    private static func controls(in node: AXNode) -> [AXNode] {
        node.children.flatMap { child -> [AXNode] in
            if child.role == "AXGroup" { return controls(in: child) }
            return ["AXHeading", "AXButton"].contains(child.role) ? [child] : []
        }
    }

    private static func threadTitle(in headers: [AXNode]) -> String? {
        let names = headers.compactMap { toolbar -> String? in
            let items = controls(in: toolbar)
            guard items.contains(where: { $0.role == "AXButton" && $0.title == "Threads" }) else { return nil }
            let headings = items.filter { $0.role == "AXHeading" }
            guard headings.count == 1 else { return nil }
            return normalized(headings.first?.title)
        }
        return Set(names).count == 1 ? title(names.first, allowGeneric: true) : nil
    }

    /// The main-project toolbar has a heading with a same-name dropdown button.
    /// Match the web area's document title as well before adding a second row.
    private static func visibleProjectTitle(in headers: [AXNode], documentTitle: String?) -> String? {
        guard let documentTitle = normalized(documentTitle) else { return nil }
        let names = headers.compactMap { toolbar -> String? in
            let headings = controls(in: toolbar).filter { $0.role == "AXHeading" }
            guard headings.count == 1, let heading = headings.first,
                  let name = normalized(heading.title), document(documentTitle, identifies: name),
                  controls(in: heading).contains(where: { $0.role == "AXButton" && normalized($0.title) == name }) else { return nil }
            return name
        }
        return Set(names).count == 1 ? title(names.first, allowGeneric: true) : nil
    }

    private static func document(_ document: String, identifies project: String) -> Bool {
        if document == project { return true }
        let separators = [" - ", " — ", " · ", " | ", " / ", " – "]
        if document.hasPrefix(project) {
            let remainder = document.dropFirst(project.count)
            return separators.contains { remainder.hasPrefix($0) }
        }
        if document.hasSuffix(project) {
            let remainder = document.dropLast(project.count)
            return separators.contains { remainder.hasSuffix($0) }
        }
        return false
    }

    private static func normalized(_ text: String?) -> String? {
        guard let text else { return nil }
        let clean = text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return clean.isEmpty ? nil : clean
    }

    private static func title(_ text: String?, allowGeneric: Bool = false) -> String? {
        guard let clean = normalized(text), allowGeneric || !["claude", "claude.ai", "threads"].contains(clean.lowercased()) else { return nil }
        return TextUtils.truncate(clean, limit: 60)
    }
}
