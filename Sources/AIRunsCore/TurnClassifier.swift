import Foundation

/// What the end of a turn means for the user.
public enum TurnOutcome: String, Codable, Sendable {
    /// It asked a question, is blocked, or needs a decision before it can go on.
    case needsInput
    /// It finished what it was asked to do.
    case done
    /// It replied, and AI Runs can't tell which of the two it is.
    case replied
}

/// How AI Runs knows the outcome, so the panel can say so.
public enum OutcomeSource: String, Codable, Sendable {
    /// The agent used its "ask the user" tool.
    case asked
    /// Its step list is complete.
    case plan
    /// Read from the wording of its last message.
    case message
    /// Judged by the on-device model.
    case model

    public var explanation: String {
        switch self {
        case .asked: return "It asked you a question"
        case .plan: return "All steps of its plan are done"
        case .message: return "Judged from its last message"
        case .model: return "Judged by the on-device model"
        }
    }
}

/// Reads the end of an agent's last message to tell "finished" from "needs you".
///
/// It errs toward caution: a blocking question or a reported problem means
/// needs input; a clear completion means done; anything else is `replied`,
/// which the panel shows without claiming either.
public enum TurnClassifier {
    public static func classify(message: String?, progress: RunProgress?) -> (TurnOutcome, OutcomeSource) {
        let text = clean(message ?? "")
        let planDone = progress?.isFinished == true
        guard !text.isEmpty else { return planDone ? (.done, .plan) : (.replied, .message) }

        let tail = Self.tail(of: text)
        let lowerTail = tail.lowercased()
        let head = String(text.prefix(320)).lowercased()

        let asks = tail.contains("?") || tail.contains("？") || contains(lowerTail, askPhrases)
        let offers = contains(lowerTail, offerPhrases)
        let blocked = contains(lowerTail, blockedPhrases)
        let saysDone = (contains(head, donePhrases) || contains(lowerTail, donePhrases))
            && !contains(head + "\n" + lowerTail, notDonePhrases)
        let finished = planDone || saysDone

        if blocked && !(finished && offers) { return (.needsInput, .message) }
        if asks {
            // "Done. Want me to also update the docs?" is an optional offer
            // after finished work, not a blocking question.
            if offers && finished { return (.done, planDone ? .plan : .message) }
            return (.needsInput, .message)
        }
        if finished { return (.done, planDone ? .plan : .message) }
        return (.replied, .message)
    }

    /// The question the agent ends with, for the row's live line.
    public static func lastQuestion(in message: String?) -> String? {
        let text = clean(message ?? "")
        let sentences = tail(of: text)
            .components(separatedBy: CharacterSet(charactersIn: "\n"))
            .flatMap { TextUtils.splitSentences($0) }
        return sentences.last { $0.hasSuffix("?") || $0.hasSuffix("？") }.map { TextUtils.truncate($0, limit: 120) }
    }

    // MARK: - Text

    /// Drops code blocks and markdown decoration that would hide the wording.
    static func clean(_ text: String) -> String {
        var result = text.replacingOccurrences(of: #"```[\s\S]*?```"#, with: " ", options: .regularExpression)
        result = result.replacingOccurrences(of: #"[*_#>]+"#, with: "", options: .regularExpression)
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The last two non-empty paragraphs, at most ~400 characters: where
    /// agents put their question or their sign-off.
    static func tail(of text: String) -> String {
        let paragraphs = text.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("Sources:") }
        let tail = paragraphs.suffix(2).joined(separator: "\n")
        return tail.count > 400 ? String(tail.suffix(400)) : tail
    }

    private static func contains(_ text: String, _ phrases: [String]) -> Bool {
        phrases.contains { phrase in
            if phrase.hasPrefix("\\b") {
                return text.range(of: phrase, options: .regularExpression) != nil
            }
            return text.contains(phrase)
        }
    }

    // MARK: - Phrases (English and Chinese)

    static let askPhrases = [
        "which one", "which do you", "do you want", "would you prefer", "do you prefer", "should i ",
        "shall i ", "can you confirm", "please confirm", "let me know which", "how would you like",
        "are you ok with", "is that ok", "your call", "up to you",
        "你选", "你想", "你希望", "要不要", "请确认", "确认一下", "选哪", "哪一个", "是否", "你定", "告诉我",
        "可以吗", "好吗", "行吗",
    ]

    /// Optional follow-ups after finished work.
    static let offerPhrases = [
        "want me to", "would you like me to", "should i also", "shall i also", "if you want", "if you'd like",
        "happy to", "i can also", "next step", "let me know if",
        "要我", "要不要我", "需要我", "我可以再", "如果你愿意", "如果需要", "要的话", "下一步",
    ]

    static let blockedPhrases = [
        "i couldn't", "i could not", "i can't", "i cannot", "i was unable", "unable to", "failed to",
        "is blocked", "i'm blocked", "need you to", "you'll need to", "you need to", "please run",
        "waiting for you", "requires your", "permission denied", "access denied", "can't access",
        "无法", "失败", "需要你", "请你", "你需要", "麻烦你", "等你", "没有权限", "卡在",
    ]

    static let notDonePhrases = [
        "not done", "not finished", "isn't finished", "not complete", "not yet", "still need",
        "未完成", "没完成", "没有完成", "还没", "尚未",
    ]

    static let donePhrases = [
        "\\bdone\\b", "finished", "completed", "all tests pass", "tests pass", "pushed", "merged", "shipped",
        "deployed", "is ready", "now works", "fixed", "implemented", "ci passed", "build succeeded",
        "完成", "做好了", "搞定", "已推送", "推送了", "已合并", "合并了", "通过", "修好了", "改好了", "已上线", "都过了",
    ]
}
