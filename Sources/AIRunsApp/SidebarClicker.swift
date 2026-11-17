import AppKit
import ApplicationServices

/// For apps without a link to a specific thread: finds the thread's name in
/// the app's window (its sidebar) through the Accessibility API and presses
/// it, the way a person would. Needs the Accessibility permission once.
///
/// Only an element whose text is exactly the thread's name is pressed, so a
/// miss does nothing rather than opening the wrong thread.
enum SidebarClicker {
    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Shows the system prompt that sends the user to Privacy & Security ›
    /// Accessibility. Returns whether AI Runs is already trusted.
    @discardableResult
    static func requestTrust() -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        return AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    /// Looks for `title` in the frontmost window of the app and presses it.
    /// Runs off the main thread; calls `completion` on the main thread.
    static func click(title: String, in app: NSRunningApplication, completion: @escaping @Sendable (Bool) -> Void) {
        let pid = app.processIdentifier
        let wanted = normalize(title)
        DispatchQueue.global(qos: .userInitiated).async {
            let appElement = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(appElement, 0.5)
            // Electron apps (Claude, Codex, VS Code) only build their
            // accessibility tree when asked.
            AXUIElementSetAttributeValue(appElement, "AXManualAccessibility" as CFString, kCFBooleanTrue)
            var found = false
            for attempt in 0..<3 {
                if attempt > 0 { Thread.sleep(forTimeInterval: 0.35) }
                if let target = find(wanted, from: appElement) {
                    found = AXUIElementPerformAction(target, kAXPressAction as CFString) == .success
                    break
                }
            }
            DispatchQueue.main.async { completion(found) }
        }
    }

    private static func normalize(_ text: String) -> String {
        text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Breadth-first search, windows first, with limits so a huge tree can't stall.
    private static func find(_ wanted: String, from root: AXUIElement) -> AXUIElement? {
        var queue: [(AXUIElement, Int)] = [(root, 0)]
        var visited = 0
        while !queue.isEmpty, visited < 6000 {
            let (element, depth) = queue.removeFirst()
            visited += 1
            if depth > 0, matches(element, wanted), let pressable = pressable(element) {
                return pressable
            }
            guard depth < 45 else { continue }
            let children = (copy(element, depth == 0 ? kAXWindowsAttribute : kAXChildrenAttribute) as? [AXUIElement]) ?? []
            queue.append(contentsOf: children.map { ($0, depth + 1) })
        }
        return nil
    }

    private static func matches(_ element: AXUIElement, _ wanted: String) -> Bool {
        for attribute in [kAXTitleAttribute, kAXValueAttribute, kAXDescriptionAttribute] {
            if let text = copy(element, attribute) as? String, normalize(text) == wanted { return true }
        }
        return false
    }

    /// The element itself if it can be pressed, else the nearest ancestor that can
    /// (a sidebar row usually wraps the text that carries the name).
    private static func pressable(_ element: AXUIElement) -> AXUIElement? {
        var current: AXUIElement? = element
        for _ in 0..<5 {
            guard let candidate = current else { return nil }
            var actions: CFArray?
            if AXUIElementCopyActionNames(candidate, &actions) == .success,
               let names = actions as? [String], names.contains(kAXPressAction as String) {
                return candidate
            }
            current = copy(candidate, kAXParentAttribute).map { $0 as! AXUIElement }
        }
        return nil
    }

    private static func copy(_ element: AXUIElement, _ attribute: String) -> AnyObject? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value
    }
}
