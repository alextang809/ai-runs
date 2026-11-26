import Foundation
import NaturalLanguage

/// Only the active topic and one provisional change are kept, never a prompt history.
struct SessionTopic: Codable, Equatable, Sendable {
    var title: String?
    var startedAt: Date?
    var sequence = 0
    var prompt: String?
    var latestPrompt: String?
    var observedAt: Date?
    var candidate: Candidate?

    struct Candidate: Codable, Equatable, Sendable {
        let title: String
        let prompt: String
    }
}

extension Session {
    /// A name the user chose is shown as typed; a title taken from a prompt
    /// loses its Markdown marks ("Push `notes.md`" reads "Push notes.md").
    public var currentTopicTitle: String {
        titleIsCustom == true ? title : TextUtils.plainText(topic?.title ?? title)
    }
    /// Pair this with the stable session identity when saving a point to return to.
    public var currentTopicID: String {
        if let topic, let start = topic.startedAt {
            return "topic:\(Int64(start.timeIntervalSince1970)):\(topic.sequence)"
        }
        return "initial:\(Int64(startedAt.timeIntervalSince1970))"
    }
    public var isInitialTopic: Bool { topic?.startedAt == nil }
    public var currentTopicReply: String? { lastMessage }
    public var currentTopicPrompt: String? { topic?.prompt ?? firstPrompt.flatMap(UserTopicPrompt.init)?.original }
    public var latestUserPrompt: String? { topic?.latestPrompt ?? currentTopicPrompt }

    mutating func observeTopic(prompt: UserTopicPrompt, at time: Date) {
        var updated = topic ?? SessionTopic()
        guard updated.observedAt.map({ time >= $0 }) ?? true,
              let request = TopicRequest(prompt) else { return }
        updated.observedAt = time
        let active = updated.title ?? title
        if request.explicit, request.title.caseInsensitiveCompare(active) != .orderedSame {
            updated.begin(title: request.title, prompt: request.original, at: time)
        } else if request.explicit || firstPrompt == nil || request.overlaps(active)
                    || (updated.title == nil && firstPrompt.map(request.overlaps) == true) {
            updated.candidate = nil
            updated.latestPrompt = request.original
        } else if let candidate = updated.candidate, request.overlaps(candidate.title) {
            if candidate.title.caseInsensitiveCompare(request.title) != .orderedSame {
                updated.begin(title: candidate.title, prompt: candidate.prompt, at: time)
                updated.latestPrompt = request.original
            }
        } else {
            updated.candidate = .init(title: request.title, prompt: request.original)
        }
        if updated.sequence != (topic?.sequence ?? 0) {
            lastMessage = nil
            planSteps = nil
            progress = nil
        }
        topic = updated
    }
}

private extension SessionTopic {
    mutating func begin(title: String, prompt: String, at time: Date) {
        self.title = title
        self.prompt = prompt
        latestPrompt = prompt
        startedAt = time
        sequence += 1
        candidate = nil
    }
}

/// A user-authored request, excluding tool wrappers and attachment-only/system envelopes.
struct UserTopicPrompt {
    let original: String
    let cleaned: String

    init?(_ raw: String) {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let marker = text.range(of: #"(?im)^## My request(?: for Codex)?:[ \t]*$"#, options: .regularExpression) {
            text = String(text[marker.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard text.utf8.count <= 16_384, !Self.isContextEnvelope(text),
              let cleaned = TextUtils.cleanPrompt(text), !cleaned.hasPrefix("<") else { return nil }
        self.cleaned = cleaned
        let flattened = text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        original = TextUtils.truncate(flattened == cleaned ? text : cleaned, limit: 600)
    }

    private static func isContextEnvelope(_ text: String) -> Bool {
        let headers = ["# Files mentioned by the user:", "# AGENTS.md instructions", "# Context from my IDE setup",
                       "This is an app-generated request", "User: This is an app-generated request"]
        return headers.contains(where: text.hasPrefix)
    }
}

/// Extract a short label locally. An explicit switch stands on its own; otherwise two
/// distinct substantive requests must share a subject that differs from the active one.
private struct TopicRequest {
    let title: String
    let original: String
    let explicit: Bool
    private let terms: Set<String>

    init?(_ prompt: UserTopicPrompt) {
        var subject = prompt.cleaned
        let switchPattern = #"(?i)^(?:(?:ok(?:ay)?|好[的了]?|可以)[,，。.!！\s]+)?(?:new (?:topic|task)\b|(?:switch|change)(?:ing)? (?:topics?\b|(?:the )?subject\b)(?: to\b)?|let.s move on to\b|换(?:一?个|下)?(?:话题|主题|任务)|切换(?:话题|主题|任务)(?:到|至)?|另一个(?:话题|任务)(?:是)?|接下来(?:我们)?(?:来聊|来做|改做)|现在(?:改做|改聊|来聊))\s*[,，。:：.!！\-]*\s*"#
        if let range = subject.range(of: switchPattern, options: .regularExpression) {
            explicit = true
            subject.removeSubrange(range)
        } else {
            explicit = false
        }
        let filler = #"(?i)^(?:(?:please\s+|could you\s+|can you\s+|help me\s+)|(?:麻烦(?:你)?|请(?:你)?|帮我|帮忙))+"#
        subject = subject.replacingOccurrences(of: filler, with: "", options: .regularExpression)
        subject = String(subject.prefix { !"。！？!?\n".contains($0) })
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ".,，；;:：")))
        let title = TextUtils.truncate(subject, limit: 56)
        let terms = Self.keywords(title)
        guard !terms.isEmpty else { return nil }
        original = prompt.original
        self.title = title
        self.terms = terms
    }

    func overlaps(_ title: String) -> Bool { !terms.isDisjoint(with: Self.keywords(title)) }

    /// The system tokenizer also separates Chinese words without whitespace.
    private static func keywords(_ text: String) -> Set<String> {
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = text
        var words = Set<String>()
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            let word = text[range].lowercased()
            if word.count >= 2, !ignoredWords.contains(word),
               word.rangeOfCharacter(from: .letters) != nil {
                words.insert(word)
            }
            return true
        }
        return words
    }

    private static let ignoredWords = Set("""
    the a an and or to of for with from into in on my me you we that this these those it is are
    can could would should please thanks thank yes sure ok okay good great go ahead continue
    second first third last next option version plan step as suggested do use using proceed
    now new topic topics help build design fix add change make create update review trace check test
    帮我 帮忙 请你 麻烦 我们 这个 那个 这些 那些 一下 一点 然后 先来 接下来 现在
    可以 好的 继续 开始 第二 第二版 方案 版本 执行 按照 建议 按照计划 检查 修改 开发 实现
    帮助 设计 处理 创建 添加 改进 改成 再次 再来
    """.split(whereSeparator: \.isWhitespace).map(String.init))
}
