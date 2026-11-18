// airuns-hook: called by Claude Code and Codex hooks, and by browsers for
// the AI Runs extension.
//
//   airuns-hook <claude-code|codex>        (hook payload JSON on stdin)
//   airuns-hook chrome-extension://<id>/   (one native message on stdin)
//
// Appends one line to ~/.airuns/events.jsonl and exits. It must never slow
// down or break the agent, so every failure is silent and the exit code is
// always 0.

import AIRunsCore
import Darwin
import Foundation

let arguments = CommandLine.arguments

/// The app the given process belongs to, e.g. "com.google.Chrome" for any
/// process inside Google Chrome.app.
func bundleIdentifier(ofProcess pid: pid_t) -> String? {
    var buffer = [CChar](repeating: 0, count: 4096)
    guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
    let path = String(cString: buffer)
    guard let range = path.range(of: ".app/") else { return nil }
    return Bundle(path: String(path[..<range.lowerBound]) + ".app")?.bundleIdentifier
}

// Started by a browser for the AI Runs extension (native messaging): the
// first argument is the extension's origin. Read one message, record it,
// answer, exit.
if arguments.count > 1, arguments[1].hasPrefix("chrome-extension://") {
    let stdin = FileHandle.standardInput
    var reply: [String: Any] = ["ok": false]
    if arguments[1] == WebBridge.allowedOrigin,
       let data = WebBridge.readMessage({ stdin.readData(ofLength: $0) }),
       let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
        reply = ["ok": true, "app": "AI Runs"]
        if let record = WebBridge.record(from: message),
           let payload = try? JSONSerialization.data(withJSONObject: record.payload) {
            var environment: [String: String] = [:]
            if let browser = bundleIdentifier(ofProcess: getppid()) { environment["__CFBundleIdentifier"] = browser }
            let line = HookRecord.makeLine(tool: record.tool.rawValue, payload: payload,
                                           environment: environment, tty: nil)
            try? EventLogWriter.append(line, to: AIRunsPaths().events)
        }
    }
    FileHandle.standardOutput.write(WebBridge.frame(reply))
    exit(0)
}

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
