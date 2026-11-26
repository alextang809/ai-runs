import AIRunsCore
import AppKit

/// Brings the user back to a session or a pinned link.
@MainActor
enum Jumper {
    static func bundleId(for terminal: TerminalContext) -> String? {
        if let bundle = terminal.bundleId, !bundle.isEmpty { return bundle }
        if terminal.itermSessionId?.isEmpty == false { return "com.googlecode.iterm2" }
        switch terminal.termProgram {
        case "iTerm.app": return "com.googlecode.iterm2"
        case "Apple_Terminal": return "com.apple.Terminal"
        case "vscode": return "com.microsoft.VSCode"
        case "ghostty": return "com.mitchellh.ghostty"
        case "WarpTerminal": return "dev.warp.Warp-Stable"
        case "WezTerm": return "com.github.wez.wezterm"
        default: return terminal.termSessionId?.isEmpty == false ? "com.apple.Terminal" : nil
        }
    }

    /// A provider project's own address outranks the terminal that executed its hooks.
    static func hostBundle(for session: Session) -> String? {
        if session.claudeAppLink != nil { return "com.anthropic.claudefordesktop" }
        if let bundle = bundleId(for: session.terminal) { return bundle }
        guard session.tool == .codex, session.terminal.tty == nil, session.terminal.termProgram == nil,
              let path = session.transcriptPath,
              CodexDesktopOrigin.matches(path: path, sessionID: session.sessionId) else { return nil }
        return "com.openai.codex"
    }

    static func hostName(for session: Session) -> String? {
        hostName(bundle: hostBundle(for: session)) ?? (session.tool.isWeb ? "Browser" : nil)
    }

    private static func hostName(bundle: String?) -> String? {
        guard let bundle else { return nil }
        switch bundle {
        case "com.openai.chat": return "ChatGPT"
        case "com.microsoft.VSCodeInsiders": return "VS Code Insiders"
        case "com.vscodium": return "VSCodium"
        case "dev.zed.Zed": return "Zed"
        case "com.github.wez.wezterm": return "WezTerm"
        case "net.kovidgoyal.kitty": return "kitty"
        case "org.alacritty": return "Alacritty"
        case "co.zeit.hyper": return "Hyper"
        case "com.google.Chrome.canary": return "Chrome Canary"
        default:
            let name = TerminalContext(bundleId: bundle).appName
            if name != "Terminal" || bundle == "com.apple.Terminal" { return name }
            return NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle)?
                .deletingPathExtension().lastPathComponent
        }
    }

    static func sessionForBookmark(_ session: Session) -> Session {
        guard session.terminal.bundleId == nil, let bundle = hostBundle(for: session) else { return session }
        var captured = session
        captured.terminal.bundleId = bundle
        return captured
    }

    static func openLabel(for session: Session) -> String {
        hostName(for: session).map { "Open in \($0)" } ?? "Open Conversation"
    }

    static func openLabel(for link: PinLink, in store: SessionStore) -> String {
        if let session = currentSession(for: link, in: store) { return openLabel(for: session) }
        switch link {
        case .session(_, _, _, let terminal):
            return hostName(bundle: bundleId(for: terminal)).map { "Open in \($0)" } ?? "Open Conversation"
        case .url(let address):
            return URL(string: address)?.scheme?.lowercased() == "claude" ? "Open in Claude" : "Open in Browser"
        case .app(_, let name): return "Open \(name)"
        }
    }

    /// Apps where a session is a shell tab, so the resume command is a useful fallback.
    static let terminalBundles: Set<String> = [
        "com.googlecode.iterm2", "com.apple.Terminal", "com.mitchellh.ghostty", "dev.warp.Warp-Stable",
        "com.github.wez.wezterm", "net.kovidgoyal.kitty", "org.alacritty", "co.zeit.hyper",
    ]

    static func open(session: Session, opened: @escaping () -> Void = {}, show: @escaping (String) -> Void) {
        if session.tool.isWeb {
            openWebChat(url: session.webURL, browser: session.terminal.bundleId, opened: opened, show: show)
            return
        }
        // Open a project main conversation or child thread at its own address.
        if let url = session.claudeAppLink {
            guard NSWorkspace.shared.urlForApplication(toOpen: url) != nil, NSWorkspace.shared.open(url) else {
                show("Couldn’t open this conversation in Claude.")
                return
            }
            opened()
            return
        }
        focus(tool: session.tool, sessionId: session.sessionId, cwd: session.cwd,
              terminal: session.terminal, bundle: hostBundle(for: session), title: session.title,
              isWorking: session.state == .working, opened: opened, show: show)
    }

    static func currentSession(for link: PinLink, in store: SessionStore) -> Session? {
        switch link {
        case .session(let tool, let sessionID, _, _):
            return store.sessions[Session.key(tool: tool, sessionId: sessionID)]
        case .url(let address):
            return store.sessions.values.first { session in
                session.claudeAppLink?.absoluteString == address || (session.tool.isWeb && session.webURL == address)
            }
        case .app:
            return nil
        }
    }

    static func open(link: PinLink, in store: SessionStore, show: @escaping (String) -> Void) {
        if let session = currentSession(for: link, in: store) {
            open(session: session, show: show)
            return
        }
        switch link {
        case .url(let string):
            guard let url = URL(string: string), NSWorkspace.shared.open(url) else {
                show("Couldn’t open this link.")
                return
            }
        case .app(let bundleId, _):
            activate(bundleId: bundleId, opened: {}, show: show)
        case .session(let tool, let sessionId, let cwd, let terminal):
            guard !tool.isWeb else {
                show("Reopen the original browser conversation to reconnect this saved link.")
                return
            }
            focus(tool: tool, sessionId: sessionId, cwd: cwd, terminal: terminal,
                  bundle: bundleId(for: terminal), title: nil, isWorking: false, show: show)
        }
    }

    private static func focus(tool: AgentTool, sessionId: String, cwd: String?, terminal: TerminalContext,
                              bundle: String?, title: String?, isWorking: Bool, opened: @escaping () -> Void = {},
                              show: @escaping (String) -> Void) {
        let bundleName = bundle ?? ""
        switch bundleName {
        case "com.googlecode.iterm2":
            if let uuid = terminal.itermSessionId?.split(separator: ":").last,
               runScript(iTermScript(sessionUUID: String(uuid))) { opened(); return }
        case "com.apple.Terminal":
            if let tty = terminal.tty, runScript(terminalScript(tty: tty)) { opened(); return }
        case "com.microsoft.VSCode", "com.microsoft.VSCodeInsiders", "com.todesktop.230313mzl4w4u92", "com.vscodium", "dev.zed.Zed":
            if let cwd, let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleName) {
                openURL(URL(fileURLWithPath: cwd), in: app, opened: opened, show: show)
                return
            }
        default:
            break
        }
        let inTerminal = bundle.map { terminalBundles.contains($0) } ?? false
        if !inTerminal {
            if tool == .codex, bundleName == "com.openai.codex" || (bundle == nil && terminal.tty == nil && terminal.termProgram == nil),
               openCodexThread(sessionId) { opened(); return }
            if tool == .claudeCode, bundleName == "com.anthropic.claudefordesktop" || bundle == nil {
                let claudeBundle = "com.anthropic.claudefordesktop"
                let desktop = ClaudeDesktopIndex.session(forCLI: sessionId,
                    in: ClaudeDesktopIndex.load(root: ClaudeDesktopIndex.root()))
                if let desktop, openClaudeSession(desktop) { opened(); return }
                if bundle == claudeBundle || desktop != nil {
                    activate(bundleId: claudeBundle, opened: {
                        opened()
                        selectInSidebar(name: desktop?.title ?? title, bundleId: claudeBundle, appName: "Claude", show: show)
                    }, show: show)
                    return
                }
            }
            if let bundle {
                activate(bundleId: bundle, opened: {
                    opened()
                    if bundle == "com.openai.codex" { show("Codex is open. Select this conversation in its sidebar.") }
                }, show: show)
                return
            }
            show("Couldn’t identify the app for this conversation.")
            return
        }

        if bundle != "com.apple.Terminal", bundle != "com.googlecode.iterm2" {
            activate(bundleId: bundleName, opened: opened, show: show)
            return
        }
        // A terminal session whose tab we couldn't find. Never hand the user a
        // command to paste: reopen the session in a new tab of the same
        // terminal, in its folder. Not while it may still be running in a tab
        // we failed to match, which would start a second copy.
        let terminalName = terminal.appName
        if isWorking {
            activate(bundleId: bundleName, opened: {
                opened()
                show("It’s still running in \(terminalName), but AI Runs couldn’t find the tab.")
            }, show: show)
            return
        }
        if sessionId.range(of: #"\A[A-Za-z0-9_-]{1,160}\z"#, options: .regularExpression) != nil,
           reopenInTerminal(bundle: bundle, command: tool.resumeCommand(sessionId: sessionId), cwd: cwd) {
            opened()
            show("The original tab was closed, so the session reopened in a new tab.")
            return
        }
        if tool == .codex, openCodexThread(sessionId) {
            opened()
            show("The terminal tab was closed, so the thread opened in Codex.")
            return
        }
        show("Couldn’t reopen this session in its terminal.")
    }

    /// Opens a new tab running `command` in `cwd`: iTerm2 when the session came
    /// from iTerm2, otherwise Terminal (Ghostty, Warp and others can't be scripted).
    private static func reopenInTerminal(bundle: String?, command: String, cwd: String?) -> Bool {
        var line = command
        if let cwd, !cwd.isEmpty {
            line = "cd '\(cwd.replacingOccurrences(of: "'", with: "'\\''"))' && \(command)"
        }
        let text = escaped(line)
        if bundle == "com.googlecode.iterm2" {
            return runScript("""
            tell application id "com.googlecode.iterm2"
                activate
                if (count of windows) is 0 then
                    create window with default profile
                else
                    tell current window to create tab with default profile
                end if
                tell current session of current window to write text "\(text)"
            end tell
            return true
            """)
        }
        return runScript("""
        tell application id "com.apple.Terminal"
            activate
            do script "\(text)"
        end tell
        return true
        """)
    }

    static func copyResumeCommand(for session: Session) {
        copy(session.tool.resumeCommand(sessionId: session.sessionId))
    }

    /// A ChatGPT or Claude chat: selects its tab if it is still open in the
    /// browser that reported it, otherwise opens the page there.
    private static func openWebChat(url text: String?, browser: String?, opened: @escaping () -> Void,
                                    show: @escaping (String) -> Void) {
        guard let text, let url = URL(string: text) else {
            show("This chat’s address isn’t known yet.")
            return
        }
        if let browser, selectTab(prefix: text, browser: browser) { opened(); return }
        if let browser, let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: browser) {
            openURL(url, in: app, opened: opened, show: show)
        } else if NSWorkspace.shared.open(url) {
            opened()
        } else {
            show("Couldn’t open this chat in a browser.")
        }
    }

    /// Finds a tab whose address starts with `prefix` and brings it forward.
    /// Chromium browsers share one AppleScript dictionary; Arc has its own.
    private static func selectTab(prefix: String, browser: String) -> Bool {
        let target = escaped(prefix)
        if browser == "company.thebrowser.Browser" {
            return runScript("""
            tell application id "company.thebrowser.Browser"
                repeat with w in windows
                    repeat with t in tabs of w
                        if (URL of t) starts with "\(target)" then
                            tell t to select
                            activate
                            return true
                        end if
                    end repeat
                end repeat
            end tell
            return false
            """)
        }
        guard ["com.google.Chrome", "com.google.Chrome.beta", "com.brave.Browser", "com.microsoft.edgemac",
               "com.vivaldi.Vivaldi", "org.chromium.Chromium"].contains(browser) else { return false }
        return runScript("""
        tell application id "\(browser)"
            repeat with w in windows
                set i to 0
                repeat with t in tabs of w
                    set i to i + 1
                    if (URL of t) starts with "\(target)" then
                        set active tab index of w to i
                        set index of w to 1
                        activate
                        return true
                    end if
                end repeat
            end repeat
        end tell
        return false
        """)
    }

    /// `codex://threads/<id>` opens a thread in the Codex (ChatGPT) desktop app.
    private static func openCodexThread(_ threadId: String) -> Bool {
        guard threadId.range(of: #"\A[A-Za-z0-9_-]{1,160}\z"#, options: .regularExpression) != nil,
              let url = URL(string: "codex://threads/\(threadId)"),
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

    private static func activate(bundleId: String, opened: @escaping () -> Void, show: @escaping (String) -> Void) {
        if let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).first {
            if running.activate() { opened() } else { show("Couldn’t activate the original app.") }
        } else if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) {
            NSWorkspace.shared.openApplication(at: app, configuration: NSWorkspace.OpenConfiguration()) { running, error in
                let success = running != nil && error == nil
                Task { @MainActor in
                    if success { opened() } else { show("Couldn’t open the original app.") }
                }
            }
        } else {
            show("Couldn’t find the original app on this Mac.")
        }
    }

    private static func openURL(_ url: URL, in app: URL, opened: @escaping () -> Void, show: @escaping (String) -> Void) {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.open([url], withApplicationAt: app, configuration: configuration) { running, error in
            let success = running != nil && error == nil
            Task { @MainActor in
                if success { opened() } else { show("Couldn’t open this item in the original app.") }
            }
        }
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
