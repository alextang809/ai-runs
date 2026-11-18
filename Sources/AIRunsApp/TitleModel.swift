import AIRunsCore
import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Suggests a short session name with Apple's on-device model (macOS 26 with
/// Apple Intelligence). Nothing leaves the Mac. Returns nil when the model is
/// not available, so callers fall back to the first prompt.
enum TitleModel {
    static func suggest(firstPrompt: String?, lastReply: String?) async -> String? {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            guard case .available = SystemLanguageModel.default.availability else { return nil }
            var input = ""
            if let firstPrompt, !firstPrompt.isEmpty { input += "The user asked: \(firstPrompt.prefix(600))\n" }
            if let lastReply, !lastReply.isEmpty { input += "The assistant replied: \(lastReply.prefix(900))\n" }
            guard !input.isEmpty else { return nil }
            input += "\nName this conversation."
            let session = LanguageModelSession(instructions: """
                You name AI chat and coding sessions so a busy person can tell them apart. \
                Reply with a title of 2 to 6 words naming the task the session is for, not its latest step. \
                Use the language of the conversation. No quotes, no ending punctuation, nothing else.
                """)
            do {
                let response = try await session.respond(to: input)
                return clean(response.content)
            } catch {
                return nil
            }
        }
        #endif
        return nil
    }

    /// Did the assistant finish, or does it need the user? Nil when the model
    /// is unavailable or unsure.
    static func judge(lastReply: String) async -> TurnOutcome? {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            guard case .available = SystemLanguageModel.default.availability else { return nil }
            let session = LanguageModelSession(instructions: """
                You read the last message an AI coding assistant wrote at the end of its turn. \
                Answer with exactly one word: DONE if it finished what it was asked and nothing is needed \
                from the user (an optional offer of more work still counts as DONE); INPUT if it asks a \
                question, needs a decision, is blocked, or asks the user to do something before it can \
                continue; UNSURE otherwise.
                """)
            do {
                let response = try await session.respond(to: String(lastReply.suffix(1500)))
                let word = response.content.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
                if word.hasPrefix("DONE") { return .done }
                if word.hasPrefix("INPUT") { return .needsInput }
                return nil
            } catch {
                return nil
            }
        }
        #endif
        return nil
    }

    static func clean(_ text: String) -> String? {
        var line = text.components(separatedBy: .newlines).first { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? ""
        if line.lowercased().hasPrefix("title:") { line = String(line.dropFirst(6)) }
        line = line.trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "\"'“”‘’*#.。")))
        guard !line.isEmpty, line.count <= 80 else { return nil }
        return line
    }
}
