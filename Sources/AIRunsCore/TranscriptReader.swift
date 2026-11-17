import Foundation

/// Finds the first thing the user typed in a session transcript, to name
/// sessions that started before AI Runs saw their first prompt.
///
/// Understands Claude Code transcripts (`{"type":"user","message":{...}}`)
/// and Codex rollouts (`{"type":"response_item","payload":{"type":"message","role":"user",...}}`).
public enum TranscriptReader {
    public static func firstUserPrompt(at url: URL, maxBytes: Int = 1_000_000) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let data = (try? handle.read(upToCount: maxBytes)) ?? Data()
        for line in data.split(separator: 0x0A) {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else { continue }
            if let text = claudeUserText(object) ?? codexUserText(object) { return text }
        }
        return nil
    }

    static func claudeUserText(_ object: [String: Any]) -> String? {
        guard object["type"] as? String == "user",
              object["isMeta"] as? Bool != true,
              let message = object["message"] as? [String: Any],
              message["role"] as? String == "user"
        else { return nil }
        if let text = message["content"] as? String { return usable(text) }
        if let parts = message["content"] as? [[String: Any]] {
            let text = parts.filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }.joined(separator: " ")
            return usable(text)
        }
        return nil
    }

    static func codexUserText(_ object: [String: Any]) -> String? {
        guard object["type"] as? String == "response_item",
              let payload = object["payload"] as? [String: Any],
              payload["type"] as? String == "message",
              payload["role"] as? String == "user",
              let parts = payload["content"] as? [[String: Any]]
        else { return nil }
        let text = parts.compactMap { $0["text"] as? String }.joined(separator: " ")
        return usable(text)
    }

    /// Skips injected context and slash-command bookkeeping, which start with a tag.
    private static func usable(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("<"), !trimmed.hasPrefix("Caveat:") else { return nil }
        return trimmed
    }
}
