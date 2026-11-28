import Foundation

public enum TextUtils {
    /// A short title from the first prompt of a session: pasted blocks and
    /// code removed, whitespace collapsed, cut at a word near `limit`.
    public static func title(fromPrompt prompt: String, limit: Int = 48) -> String {
        guard let text = cleanPrompt(prompt) else { return "Untitled session" }
        return truncate(text, limit: limit)
    }

    /// What the user actually typed: tagged blocks the tools insert
    /// (`<system-reminder>…</system-reminder>`, pasted content, IDE context),
    /// code blocks and extra whitespace removed. Nil when nothing is left.
    ///
    /// A Claude project's `<wake>` prompt is the exception: the request sits
    /// inside its `<message>`, so that text is kept instead of being stripped.
    public static func cleanPrompt(_ prompt: String) -> String? {
        var text = prompt
        var wrapped = false
        if let wake = PromptWrapper.wake(in: prompt) {
            guard let request = wake.request else { return nil }
            text = request
            wrapped = true
        }
        text = removingTaggedBlocks(text)
        text = text.replacingOccurrences(of: #"<[A-Za-z][\w-]*(\s[^>]*)?/?>"#, with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: #"(?s)```.*?```"#, with: " ", options: .regularExpression)
        // Wrappers escape the text inside them; tags are gone, so decoding can't make new ones.
        if wrapped { text = PromptWrapper.decodeEntities(text) }
        text = text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty || text.hasPrefix("Caveat:") { return nil }
        return text
    }

    /// Removes every `<tag …>…</tag>` block along with its content.
    static func removingTaggedBlocks(_ text: String) -> String {
        text.replacingOccurrences(of: #"(?s)<([A-Za-z][\w-]*)(\s[^>]*)?>.*?</\1[^>]*>"#,
                                  with: " ", options: .regularExpression)
    }

    /// The last question in a reply, used as the suggested next step.
    /// Returns nil when the reply asks nothing.
    public static func lastQuestion(in text: String?, limit: Int = 120) -> String? {
        guard let text, !text.isEmpty else { return nil }
        let sentences = splitSentences(text)
        guard let question = sentences.last(where: { $0.contains("?") || $0.contains("？") }) else { return nil }
        return truncate(question, limit: limit)
    }

    /// Markdown marks that a one-line list can't render: `**bold**`, `` `code` ``,
    /// `[link](url)`, heading and quote markers. Single `*` and `_` are left
    /// alone, since they are often part of a name (`snake_case`, `*.swift`).
    /// Text inside a code span is kept as written (`a**b` stays `a**b`).
    public static func plainText(_ text: String) -> String {
        var text = text
        text = text.replacingOccurrences(of: #"\[([^\]]+)\]\([^)\s]+\)"#, with: "$1", options: .regularExpression)
        text = text.replacingOccurrences(of: #"(?m)^\s{0,3}(#{1,6}|>)\s+"#, with: "", options: .regularExpression)
        var result = ""
        var rest = Substring(text)
        var inCode = false
        // Backticks alternate prose and code; a backtick with no partner is dropped.
        while let tick = rest.firstIndex(of: "`") {
            let part = rest[..<tick]
            result += inCode ? String(part) : part.replacingOccurrences(of: "**", with: "")
            rest = rest[rest.index(after: tick)...]
            inCode = !inCode && rest.firstIndex(of: "`") != nil
        }
        result += rest.replacingOccurrences(of: "**", with: "")
        return result
    }

    /// The last line of a reply worth showing as a preview, without Markdown marks.
    public static func preview(of text: String?, limit: Int = 220) -> String? {
        guard let text else { return nil }
        let collapsed = plainText(text).replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !collapsed.isEmpty else { return nil }
        return truncate(collapsed, limit: limit)
    }

    public static func projectName(fromPath path: String?) -> String {
        guard let path, !path.isEmpty else { return "" }
        return URL(fileURLWithPath: path).lastPathComponent
    }

    /// "now", "4m", "1h 05m", "2d 3h".
    public static func duration(_ seconds: TimeInterval) -> String {
        let minutes = Int(max(0, seconds) / 60)
        if minutes < 1 { return "now" }
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        if hours < 24 { return String(format: "%dh %02dm", hours, minutes % 60) }
        return "\(hours / 24)d \(hours % 24)h"
    }

    /// "now", "5h", "3d" — coarser, for card ages.
    public static func age(_ seconds: TimeInterval) -> String {
        let hours = Int(max(0, seconds) / 3600)
        if hours < 1 { return "now" }
        if hours < 24 { return "\(hours)h" }
        return "\(hours / 24)d"
    }

    public static func truncate(_ text: String, limit: Int) -> String {
        guard text.count > limit else { return text }
        let cut = text.prefix(limit)
        if let space = cut.lastIndex(of: " "), cut.distance(from: cut.startIndex, to: space) > limit / 2 {
            return String(cut[..<space]) + "…"
        }
        return String(cut) + "…"
    }

    /// The sentences of `text`, each trimmed. A line break ends a sentence, and
    /// so does `.`, `?` or `!`, unless a letter or digit follows it directly:
    /// that is the inside of a file name, a version or an address
    /// (`README.md`, `1.2.0`, `example.com/a?b=1`), not the end of a sentence.
    static func splitSentences(_ text: String) -> [String] {
        var sentences: [String] = []
        var current = ""
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            index = text.index(after: index)
            current.append(character)
            guard endsSentence(character, before: index < text.endIndex ? text[index] : nil) else { continue }
            let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { sentences.append(trimmed) }
            current = ""
        }
        let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { sentences.append(trimmed) }
        return sentences
    }

    private static func endsSentence(_ character: Character, before next: Character?) -> Bool {
        if "。？！\n".contains(character) { return true }
        guard ".?!".contains(character) else { return false }
        guard let next else { return true }
        return !(next.isASCII && (next.isLetter || next.isNumber))
    }
}
