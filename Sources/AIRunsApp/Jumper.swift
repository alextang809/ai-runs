import AIRunsCore
import AppKit

/// Brings the user back to a session or a pinned link.
@MainActor
enum Jumper {
    static func bundleId(for terminal: TerminalContext) -> String? {
        if let bundle = terminal.bundleId, !bundle.isEmpty { return bundle }
        switch terminal.termProgram {
        case "iTerm.app": return "com.googlecode.iterm2"
        case "Apple_Terminal": return "com.apple.Terminal"
        case "vscode": return "com.microsoft.VSCode"
        case "ghostty": return "com.mitchellh.ghostty"
        case "WarpTerminal": return "dev.warp.Warp-Stable"
        case "WezTerm": return "com.github.wez.wezterm"
        default: return nil
        }
    }

    /// Apps where a session is a shell tab, so the resume command is a useful fallback.
    static let terminalBundles: Set<String> = [
        "com.googlecode.iterm2", "com.apple.Terminal", "com.mitchellh.ghostty", "dev.warp.Warp-Stable",
        "com.github.wez.wezterm", "net.kovidgoyal.kitty", "org.alacritty", "co.zeit.hyper",
    ]

    static func open(session: Session, show: @escaping (String) -> Void) {
        focus(tool: session.tool, sessionId: session.sessionId, cwd: session.cwd,
              terminal: session.terminal, title: session.title, show: show)
    }

    static func open(link: PinLink, show: @escaping (String) -> Void) {
        switch link {
        case .url(let string):
            guard let url = URL(string: string) else { return }
            NSWorkspace.shared.open(url)
        case .app(let bundleId, let name):
            if !activate(bundleId: bundleId) { show("Couldn’t open \(name).") }
        case .session(let tool, let sessionId, let cwd, let terminal):
            focus(tool: tool, sessionId: sessionId, cwd: cwd, terminal: terminal, title: nil, show: show)
        }
    }

    private static func focus(tool: AgentTool, sessionId: String, cwd: String?, terminal: TerminalContext,
                              title: String?, show: @escaping (String) -> Void) {
        let bundle = bundleId(for: terminal)
        let bundleName = bundle ?? ""
        switch bundleName {
        case "com.googlecode.iterm2":
            if let uuid = terminal.itermSessionId?.split(separator: ":").last,
               runScript(iTermScript(sessionUUID: String(uuid))) { return }
        case "com.apple.Terminal":
            if let tty = terminal.tty, runScript(terminalScript(tty: tty)) { return }
        case "com.microsoft.VSCode", "com.microsoft.VSCodeInsiders", "com.todesktop.230313mzl4w4u92", "com.vscodium":
            if let cwd, openEditor(bundleId: bundleName, folder: cwd) { return }
        default:
            break
        }
        // Desktop apps: open the exact thread when the app has a link for it.
        let inTerminal = bundle.map { terminalBundles.contains($0) } ?? false
        if tool == .codex, !inTerminal, openCodexThread(sessionId) { return }
        if tool == .claudeCode, bundleName == "com.anthropic.claudefordesktop" {
            let desktop = ClaudeDesktopIndex.session(forCLI: sessionId,
                                                     in: ClaudeDesktopIndex.load(root: ClaudeDesktopIndex.root()))
            if let desktop, openClaudeSession(desktop) { return }
            if activate(bundleId: bundleName) {
                selectInSidebar(name: desktop?.title ?? title, bundleId: bundleName, appName: "Claude", show: show)
                return
            }
        }
        // Otherwise bringing the app back is the best we can do.
        if let bundle, !terminalBundles.contains(bundle), activate(bundleId: bundle) { return }
        let resume = tool.resumeCommand(sessionId: sessionId)
        if let bundle, activate(bundleId: bundle) {
            copy(resume)
            show("Opened \(terminal.appName). Couldn’t find the exact tab, so “\(resume)” is on your clipboard.")
            return
        }
        copy(resume)
        show("Copied “\(resume)”. Paste it in a terminal to reopen the session.")
    }

    /// `codex://threads/<id>` opens a thread in the Codex (ChatGPT) desktop app.
    private static func openCodexThread(_ threadId: String) -> Bool {
        guard let url = URL(string: "codex://threads/\(threadId)"),
              NSWorkspace.shared.urlForApplication(toOpen: url) != nil else { return false }
        return NSWorkspace.shared.open(url)
    }

    /// Claude Desktop has no documented link to an existing Code session yet.
    /// When one is known to work on this Mac it is stored as a template, e.g.
    /// `defaults write io.github.alextang809.airuns claudeSessionLink 'claude://code/{id}'`
    /// (`{id}` = desktop ID, `{cli}` = Claude Code session ID).
    static let claudeLinkKey = "claudeSessionLink"

    private static func openClaudeSession(_ session: ClaudeDesktopSession) -> Bool {
        guard let template = UserDefaults.standard.string(forKey: claudeLinkKey), !template.isEmpty,
              let url = ClaudeDesktopIndex.link(template: template, session: session),
              NSWorkspace.shared.urlForApplication(toOpen: url) != nil else { return false }
        return NSWorkspace.shared.open(url)
    }

    private static let askedAccessibilityKey = "askedAccessibilityForSidebar"

    /// The app is in front but has no link to the thread: press the thread's
    /// name in its sidebar. If that can't be done, say where it is and put the
    /// name on the clipboard, so the user is never left guessing.
    private static func selectInSidebar(name: String?, bundleId: String, appName: String,
                                        show: @escaping (String) -> Void) {
        guard let name, !name.isEmpty else { return }
        func fallBack() {
            copy(name)
            show("\(appName) is open. Look for “\(TextUtils.truncate(name, limit: 40))” in its sidebar (name copied).")
        }
        guard SidebarClicker.isTrusted else {
            if !UserDefaults.standard.bool(forKey: askedAccessibilityKey) {
                UserDefaults.standard.set(true, forKey: askedAccessibilityKey)
                show("To open the exact \(appName) thread next time, allow AI Runs under Accessibility.")
                SidebarClicker.requestTrust()
                copy(name)
            } else {
                fallBack()
            }
            return
        }
        // Give the app a moment to come forward before reading its window.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            MainActor.assumeIsolated {
                guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).first else {
                    fallBack()
                    return
                }
                SidebarClicker.click(title: name, in: app) { pressed in
                    MainActor.assumeIsolated { if !pressed { fallBack() } }
                }
            }
        }
    }

    static func activate(bundleId: String) -> Bool {
        if let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).first {
            return running.activate()
        }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) else { return false }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        return true
    }

    private static func openEditor(bundleId: String, folder: String) -> Bool {
        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) else { return false }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.open([URL(fileURLWithPath: folder)], withApplicationAt: appURL, configuration: configuration)
        return true
    }

    private static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// Runs an AppleScript that returns true when it found the window.
    static func runScript(_ source: String) -> Bool {
        var error: NSDictionary?
        guard let script = NSAppleScript(source: source) else { return false }
        let result = script.executeAndReturnError(&error)
        return error == nil && result.booleanValue
    }

    private static func escaped(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }

    private static func iTermScript(sessionUUID: String) -> String {
        """
        tell application id "com.googlecode.iterm2"
            repeat with w in windows
                repeat with t in tabs of w
                    repeat with s in sessions of t
                        if (unique id of s) is "\(escaped(sessionUUID))" then
                            tell w to select
                            tell t to select
                            tell s to select
                            activate
                            return true
                        end if
                    end repeat
                end repeat
            end repeat
        end tell
        return false
        """
    }

    private static func terminalScript(tty: String) -> String {
        """
        tell application id "com.apple.Terminal"
            repeat with w in windows
                repeat with t in tabs of w
                    if (tty of t) is "\(escaped(tty))" then
                        set selected of t to true
                        set index of w to 1
                        activate
                        return true
                    end if
                end repeat
            end repeat
        end tell
        return false
        """
    }
}

/// Reads the title and address of the front browser tab, or names the front app.
@MainActor
enum FrontWindowCapture {
    struct Captured {
        var title: String
        var link: PinLink
    }

    private static let safari = ["com.apple.Safari", "com.apple.SafariTechnologyPreview"]
    private static let chromium = ["com.google.Chrome", "com.google.Chrome.canary", "company.thebrowser.Browser",
                                   "com.brave.Browser", "com.microsoft.edgemac", "com.vivaldi.Vivaldi"]

    /// Desktop apps for AI chats.
    static let aiApps: Set<String> = [
        "com.anthropic.claudefordesktop", "com.openai.chat", "com.openai.codex", "ai.perplexity.mac",
        "com.google.GeminiMacOS", "com.microsoft.copilot-mac",
    ]
    static let editors: Set<String> = [
        "com.microsoft.VSCode", "com.microsoft.VSCodeInsiders", "com.todesktop.230313mzl4w4u92", "com.vscodium",
        "dev.zed.Zed",
    ]

    static func isPinnable(_ app: NSRunningApplication) -> Bool {
        guard let bundle = app.bundleIdentifier, bundle != Bundle.main.bundleIdentifier else { return false }
        return safari.contains(bundle) || chromium.contains(bundle) || aiApps.contains(bundle)
            || editors.contains(bundle) || Jumper.terminalBundles.contains(bundle)
    }

    static func capture(app: NSRunningApplication) -> Captured? {
        guard let bundle = app.bundleIdentifier else { return nil }
        let name = app.localizedName ?? bundle
        var script: String?
        if safari.contains(bundle) {
            script = "tell application id \"\(bundle)\" to return {name of current tab of front window, URL of current tab of front window}"
        } else if chromium.contains(bundle) {
            script = "tell application id \"\(bundle)\" to return {title of active tab of front window, URL of active tab of front window}"
        }
        if let script, let pair = runListScript(script), let address = pair.1, !address.isEmpty {
            let title = (pair.0?.isEmpty == false ? pair.0! : URL(string: address)?.host) ?? address
            return Captured(title: TextUtils.truncate(title, limit: 60), link: .url(address))
        }
        return Captured(title: "\(name) conversation", link: .app(bundleId: bundle, name: name))
    }

    private static func runListScript(_ source: String) -> (String?, String?)? {
        var error: NSDictionary?
        guard let script = NSAppleScript(source: source) else { return nil }
        let result = script.executeAndReturnError(&error)
        guard error == nil, result.numberOfItems >= 2 else { return nil }
        return (result.atIndex(1)?.stringValue, result.atIndex(2)?.stringValue)
    }
}
