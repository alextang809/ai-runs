import Foundation

/// One element of an app's accessibility tree, copied out so it can be read
/// (and tested) without the app.
public struct AXNode: Equatable, Sendable {
    /// `AXRole`, e.g. `AXLink`, `AXHeading`, `AXStaticText`, `AXGroup`.
    public var role: String
    public var title: String?
    public var value: String?
    /// `AXURL`, for links.
    public var url: String?
    public var children: [AXNode]

    public init(role: String, title: String? = nil, value: String? = nil, url: String? = nil, children: [AXNode] = []) {
        self.role = role
        self.title = title
        self.value = value
        self.url = url
        self.children = children
    }
}

/// How Claude itself files a project thread in its Threads list. The words
/// are Claude's; AI Runs repeats them rather than translating them.
public enum NativeThreadState: String, Codable, CaseIterable, Sendable {
    case working
    case waitingOnYou
    case readyForReview
    case idle

    /// The section heading in Claude's Threads list.
    public var heading: String {
        switch self {
        case .working: return "Working"
        case .waitingOnYou: return "Waiting on you"
        case .readyForReview: return "Ready for review"
        case .idle: return "Idle"
        }
    }

    /// The heading as a state word on a row.
    public var word: String { heading.uppercased() }

    /// Reads a heading such as "Waiting on you 2" or "Idle (3)". Nil for anything else.
    public static func from(heading text: String?) -> NativeThreadState? {
        guard let text else { return nil }
        let label = text.lowercased().trimmingCharacters(in: CharacterSet.letters.inverted)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return allCases.first { $0.heading.lowercased() == label }
    }
}

/// A project thread as it was seen in Claude's window.
public struct ThreadSighting: Equatable, Sendable {
    public var thread: ProjectThread
    /// The name Claude shows for it.
    public var title: String?
    /// Nil when the thread is listed but the section it sits in couldn't be read.
    public var state: NativeThreadState?

    public init(thread: ProjectThread, title: String? = nil, state: NativeThreadState? = nil) {
        self.thread = thread
        self.title = title
        self.state = state
    }
}

/// Finds project threads in a copy of the Claude desktop app's accessibility
/// tree (shape reported in collab/rounds/03-codex.md):
///
/// - a thread is an `AXLink` whose `AXURL` is
///   `https://claude.ai/epitaxy/project/<chan>?thread=<cmsg>`; its first
///   `AXStaticText` carries the name;
/// - its state is the heading of the section it sits in (`AXHeading` titled
///   "Waiting on you 2", "Ready for review 1", "Idle 2", …), or a "Working"
///   text in a container that holds this thread only.
///
/// Anything unclear is left without a state. A thread that is not in the tree
/// is simply not reported: the list is often only partly drawn, so absence
/// means nothing.
public enum ClaudeThreadsView {
    /// How far above a link its section may be (Codex found three steps).
    static let maxSteps = 5

    public static func sightings(in root: AXNode) -> [ThreadSighting] {
        var found: [ThreadSighting] = []
        _ = walk(root, into: &found)
        // The same thread can be linked twice (list and sidebar); states must agree.
        var merged: [ThreadSighting] = []
        var index: [ProjectThread: Int] = [:]
        var conflicted: Set<ProjectThread> = []
        for sighting in found {
            guard let at = index[sighting.thread] else {
                index[sighting.thread] = merged.count
                merged.append(sighting)
                continue
            }
            if merged[at].title == nil { merged[at].title = sighting.title }
            if let state = sighting.state {
                if let known = merged[at].state, known != state { conflicted.insert(sighting.thread) }
                merged[at].state = merged[at].state ?? state
            }
        }
        for thread in conflicted { if let at = index[thread] { merged[at].state = nil } }
        return merged
    }

    /// `https://claude.ai/epitaxy/project/chan_…?thread=cmsg_…` (or `/code/project/…`).
    public static func thread(fromLink link: String?) -> ProjectThread? {
        guard let link, let components = URLComponents(string: link), components.host == "claude.ai" else { return nil }
        let parts = components.path.split(separator: "/").map(String.init)
        guard parts.count == 3, parts[0] == "epitaxy" || parts[0] == "code", parts[1] == "project",
              let root = components.queryItems?.first(where: { $0.name == "thread" })?.value,
              ProjectThread.isProjectId(parts[2]), ProjectThread.isThreadId(root) else { return nil }
        return ProjectThread(projectId: parts[2], threadId: root)
    }

    private struct Pending {
        var index: Int
        var steps: Int
    }

    private struct Subtree {
        /// Section headings inside, and whether each already has its threads.
        var labels: [NativeThreadState: Bool] = [:]
        /// Threads inside that have no state yet.
        var pending: [Pending] = []
        /// A "Working" text outside any thread link.
        var workingText = false
        /// Distinct threads inside.
        var threads: Set<ProjectThread> = []
    }

    private static func walk(_ node: AXNode, into found: inout [ThreadSighting]) -> Subtree {
        var result = Subtree()
        if node.role == "AXLink", let thread = thread(fromLink: node.url) {
            let texts = staticTexts(in: node)
            var sighting = ThreadSighting(thread: thread, title: clean(texts.first ?? node.title))
            // A status inside the link itself, after the name.
            if texts.dropFirst().contains(where: { $0.caseInsensitiveCompare("Working") == .orderedSame }) {
                sighting.state = .working
            } else {
                result.pending = [Pending(index: found.count, steps: 0)]
            }
            found.append(sighting)
            result.threads = [thread]
            return result
        }
        if node.role == "AXHeading" || node.role == "AXButton", let state = NativeThreadState.from(heading: node.title) {
            result.labels[state] = false
        }
        if node.role == "AXStaticText", let value = node.value,
           value.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare("Working") == .orderedSame {
            result.workingText = true
        }
        for child in node.children {
            let sub = walk(child, into: &found)
            for (state, used) in sub.labels { result.labels[state] = (result.labels[state] ?? false) || used }
            result.pending += sub.pending.map { Pending(index: $0.index, steps: $0.steps + 1) }
            result.workingText = result.workingText || sub.workingText
            result.threads.formUnion(sub.threads)
        }
        result.pending.removeAll { $0.steps > maxSteps }
        guard !result.pending.isEmpty else { return result }

        if result.labels.isEmpty {
            // No section here: a "Working" text next to exactly one thread is that thread's.
            if result.workingText, result.threads.count == 1 {
                for item in result.pending where item.steps <= 3 { found[item.index].state = .working }
                result.pending = []
            }
        } else {
            // The nearest container with a heading decides. One fresh heading
            // is the thread's section; several, or one that already has its
            // threads, say nothing about this one.
            if result.labels.count == 1, let entry = result.labels.first, !entry.value {
                for item in result.pending { found[item.index].state = entry.key }
                result.labels[entry.key] = true
            }
            result.pending = []
        }
        return result
    }

    private static func staticTexts(in node: AXNode) -> [String] {
        var texts: [String] = []
        for child in node.children {
            if child.role == "AXStaticText", let value = child.value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
                texts.append(value)
            }
            texts += staticTexts(in: child)
        }
        return texts
    }

    private static func clean(_ text: String?) -> String? {
        guard let text else { return nil }
        let collapsed = text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return collapsed.isEmpty ? nil : TextUtils.truncate(collapsed, limit: 60)
    }
}
