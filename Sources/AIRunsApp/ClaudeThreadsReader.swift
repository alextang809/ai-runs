import AIRunsCore
import AppKit
import ApplicationServices

/// Reads the Claude desktop app's window through the Accessibility API to
/// find project threads and the section Claude files them under ("Waiting on
/// you", "Idle", …). This is the only way AI Runs can see threads that work
/// in the cloud: they fire no local hooks.
///
/// It only reads: nothing is pressed, typed or focused. It needs the
/// Accessibility permission and never asks for it by itself; without it,
/// nothing is read.
enum ClaudeThreadsReader {
    static let bundleId = "com.anthropic.claudefordesktop"
    static let enabledKey = "readClaudeThreads"

    /// On unless the user turned it off in Settings.
    static var isEnabled: Bool { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }

    /// The running Claude app, when reading is on and allowed.
    static func target() -> pid_t? {
        guard isEnabled, AXIsProcessTrusted() else { return nil }
        return NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).first?.processIdentifier
    }

    /// Reads off the main thread; calls `completion` on the main thread.
    static func read(pid: pid_t, completion: @escaping @Sendable ([ThreadSighting]) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            let found = sightings(pid: pid)
            DispatchQueue.main.async { completion(found) }
        }
    }

    private static func sightings(pid: pid_t) -> [ThreadSighting] {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.5)
        // Electron apps only build their accessibility tree when asked
        // (SidebarClicker asks the same way).
        AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        let windows = (copy(app, kAXWindowsAttribute) as? [AXUIElement]) ?? []
        var budget = 5000
        let children = windows.compactMap { node($0, depth: 0, budget: &budget) }
        return ClaudeThreadsView.sightings(in: AXNode(role: "AXApplication", children: children))
    }

    /// Copies the part of the tree that matters, with limits so a huge window can't stall.
    private static func node(_ element: AXUIElement, depth: Int, budget: inout Int) -> AXNode? {
        guard budget > 0, depth < 60 else { return nil }
        budget -= 1
        guard let role = copy(element, kAXRoleAttribute) as? String else { return nil }
        var result = AXNode(role: role)
        switch role {
        case "AXLink":
            let url = copy(element, kAXURLAttribute)
            result.url = (url as? URL)?.absoluteString ?? (url as? String)
            result.title = copy(element, kAXTitleAttribute) as? String
            // Only thread links are worth going into.
            guard ClaudeThreadsView.thread(fromLink: result.url) != nil else { return result }
        case "AXHeading", "AXButton":
            result.title = copy(element, kAXTitleAttribute) as? String
        case "AXStaticText":
            result.value = copy(element, kAXValueAttribute) as? String
            return result
        default:
            break
        }
        let children = (copy(element, kAXChildrenAttribute) as? [AXUIElement]) ?? []
        for child in children {
            if let childNode = node(child, depth: depth + 1, budget: &budget) { result.children.append(childNode) }
        }
        return result
    }

    private static func copy(_ element: AXUIElement, _ attribute: String) -> AnyObject? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value
    }
}
