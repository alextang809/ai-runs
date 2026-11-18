import Foundation

/// A Claude project thread: the conversation a person has in a Claude project.
/// It runs in the cloud; local Claude Code sessions it wakes are its executors.
///
/// Addressed by the project (`chan_…`) and the thread's root message (`cmsg_…`),
/// both read from the `<wake>` wrapper around the prompts it sends.
public struct ProjectThread: Codable, Equatable, Hashable, Sendable {
    /// `wake/project@id`, e.g. `chan_example123`.
    public var projectId: String
    /// `wake/project/thread@ts`, the thread's root, e.g. `cmsg_root123`. Not the
    /// id of the message inside it, which changes with every turn.
    public var threadId: String

    public init(projectId: String, threadId: String) {
        self.projectId = projectId
        self.threadId = threadId
    }

    /// Only the shapes seen so far; anything else is not linked to a thread.
    static func isProjectId(_ value: String) -> Bool { value.range(of: #"^chan_[A-Za-z0-9]{4,}$"#, options: .regularExpression) != nil }
    static func isThreadId(_ value: String) -> Bool { value.range(of: #"^cmsg_[A-Za-z0-9]{4,}$"#, options: .regularExpression) != nil }
}

/// What a `<wake>` prompt carries: where it comes from and what was asked.
public struct WakePrompt: Equatable, Sendable {
    /// Nil when the wrapper has no valid address, or the wakes in one prompt disagree.
    public var thread: ProjectThread?
    /// The text of the message that woke the session, as written (tags and
    /// entities still in it). Nil when only the system wrote.
    public var request: String?
}

/// Reads the wrappers Claude projects put around prompts:
///
/// ```
/// <wake reason="…" current-time="…">
///   <project id="chan_…" type="…">
///     <thread ts="cmsg_…">
///       <message trigger="true" from="human" id="cmsg_…" …>The request.</message>
///     </thread>
///   </project>
/// </wake>
/// ```
///
/// The request is inside `<message>`, not after the wrapper. A prompt can hold
/// several wakes, `<relay>` blocks and system notes next to each other.
public enum PromptWrapper {
    /// The wake(s) a prompt starts with. Nil when the prompt doesn't start with
    /// one (after other tagged blocks), so a wake pasted into a request is ignored.
    public static func wake(in prompt: String) -> WakePrompt? {
        guard let first = prompt.range(of: #"<wake[\s>]"#, options: .regularExpression) else { return nil }
        let before = String(prompt[..<first.lowerBound])
        guard TextUtils.removingTaggedBlocks(before).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }

        var addresses: Set<ProjectThread> = []
        var invalid = false
        var messages: [(attributes: String, body: String)] = []
        for wake in matches(#"(?s)<wake(?:\s[^>]*)?>(.*?)</wake>"#, in: prompt) {
            let body = wake[1]
            let project = matches(#"<project(\s[^>]*)?>"#, in: body).first.flatMap { attribute("id", in: $0[1]) }
            let thread = matches(#"<thread(\s[^>]*)?>"#, in: body).first.flatMap { attribute("ts", in: $0[1]) }
            if let project, let thread, ProjectThread.isProjectId(project), ProjectThread.isThreadId(thread) {
                addresses.insert(ProjectThread(projectId: project, threadId: thread))
            } else {
                invalid = true
            }
            messages += matches(#"(?s)<message(\s[^>]*)?>(.*?)</message>"#, in: body).map { (attributes: $0[1], body: $0[2]) }
        }
        // Several wakes are fine when they agree; anything unclear stays unlinked.
        let thread = !invalid && addresses.count == 1 ? addresses.first : nil

        // The message a person (not the system) wrote, preferring the one that triggered the wake.
        let written = messages.filter { attribute("from", in: $0.attributes) != "system" }
        let trigger = written.last(where: { attribute("trigger", in: $0.attributes) == "true" }) ?? written.last
        let request = trigger?.body.trimmingCharacters(in: .whitespacesAndNewlines)
        return WakePrompt(thread: thread, request: request?.isEmpty == false ? request : nil)
    }

    /// An attribute's value in a tag's attribute text. `id` doesn't match `author-id`.
    static func attribute(_ name: String, in attributes: String) -> String? {
        let pattern = #"(?:^|\s)"# + NSRegularExpression.escapedPattern(for: name) + #"="([^"]*)""#
        return matches(pattern, in: attributes).first?[1]
    }

    /// Every match of `pattern`, each as its capture groups (index 0 is the whole match;
    /// a group that didn't take part is empty).
    static func matches(_ pattern: String, in text: String) -> [[String]] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { match in
            (0..<match.numberOfRanges).map { index in
                let range = match.range(at: index)
                return range.location == NSNotFound ? "" : ns.substring(with: range)
            }
        }
    }

    /// `&lt;`, `&#39;`, `&#x27;` and friends, as wrappers escape the text inside them.
    static func decodeEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        let named = ["lt": "<", "gt": ">", "amp": "&", "quot": "\"", "apos": "'"]
        var result = ""
        var rest = Substring(text)
        while let amp = rest.firstIndex(of: "&") {
            result += rest[..<amp]
            let after = rest[rest.index(after: amp)...]
            if let semi = after.prefix(10).firstIndex(of: ";") {
                let name = String(after[..<semi])
                var decoded: String?
                if let value = named[name] {
                    decoded = value
                } else if name.hasPrefix("#x") || name.hasPrefix("#X"), let code = UInt32(name.dropFirst(2), radix: 16) {
                    decoded = Unicode.Scalar(code).map { String(Character($0)) }
                } else if name.hasPrefix("#"), let code = UInt32(name.dropFirst()) {
                    decoded = Unicode.Scalar(code).map { String(Character($0)) }
                }
                if let decoded {
                    result += decoded
                    rest = after[after.index(after: semi)...]
                    continue
                }
            }
            result += "&"
            rest = after
        }
        return result + rest
    }
}
