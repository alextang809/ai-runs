// airuns-hook: called by Claude Code and Codex hooks.
//
//   airuns-hook <claude-code|codex>   (hook payload JSON on stdin)
//
// Appends one line to ~/.airuns/events.jsonl and exits. It must never slow
// down or break the agent, so every failure is silent and the exit code is
// always 0.

import AIRunsCore
import Foundation

let arguments = CommandLine.arguments
let tool = arguments.count > 1 ? arguments[1] : "unknown"
let input = FileHandle.standardInput.readDataToEndOfFile()

/// The terminal of the agent process that ran this hook, e.g. /dev/ttys004.
/// Used to bring the right Terminal.app tab back.
func parentTTY() -> String? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/ps")
    process.arguments = ["-o", "tty=", "-p", String(getppid())]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    do {
        try process.run()
        process.waitUntilExit()
    } catch {
        return nil
    }
    let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !output.isEmpty, output != "??" else { return nil }
    return output.hasPrefix("/dev/") ? output : "/dev/" + output
}

let line = HookRecord.makeLine(tool: tool, payload: input,
                               environment: ProcessInfo.processInfo.environment,
                               tty: parentTTY())
try? EventLogWriter.append(line, to: AIRunsPaths().events)

// Codex expects JSON on stdout from Stop hooks; an empty object changes nothing.
// Claude Code and Codex treat plain stdout on UserPromptSubmit as extra context,
// so nothing is printed for any other event.
if tool == AgentTool.codex.rawValue,
   let payload = try? JSONSerialization.jsonObject(with: input) as? [String: Any],
   payload["hook_event_name"] as? String == "Stop" {
    FileHandle.standardOutput.write(Data("{}\n".utf8))
}
exit(0)
