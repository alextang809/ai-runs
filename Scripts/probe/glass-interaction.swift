// macOS 26 native interaction probe; synthetic content only, no AppModel.
// swiftc -parse-as-library Sources/AIRunsApp/GlassSurface.swift Sources/AIRunsApp/FloatingPanel.swift Scripts/probe/glass-interaction.swift -o /tmp/airuns-glass-interaction
// /tmp/airuns-glass-interaction

import AppKit
import SwiftUI

@MainActor final class InteractionState: ObservableObject {
    @Published var clicks = 0
    @Published var draft = ""
}

struct InteractionContent: View {
    @ObservedObject var state: InteractionState
    var body: some View {
        GlassSurface(cornerRadius: 20) {
            ZStack {
                Button("Test action") { state.clicks += 1 }
                    .frame(width: 120, height: 28).position(x: 110, y: 40)
                TextField("Quick note", text: $state.draft)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 160, height: 24).position(x: 110, y: 90)
            }.frame(width: 220, height: 140)
        }.padding(14)
    }
}

@main struct InteractionRunner {
    @MainActor static func main() async throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        let state = InteractionState()
        let panel = FloatingPanel()
        let host = NSHostingView(rootView: InteractionContent(state: state))
        host.frame = NSRect(x: 0, y: 0, width: 248, height: 168)
        panel.setContentSize(host.frame.size)
        panel.contentView = host
        panel.setFrameOrigin(NSPoint(x: 80, y: 80))
        panel.present()
        defer { panel.dismiss() }
        try await Task.sleep(for: .milliseconds(300))
        func click(_ point: NSPoint) {
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                let event = NSEvent.mouseEvent(with: type, location: point,
                    modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: panel.windowNumber, context: nil, eventNumber: 1,
                    clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0)!
                panel.sendEvent(event)
            }
        }
        click(NSPoint(x: 124, y: 114))
        try await Task.sleep(for: .milliseconds(100))
        guard state.clicks == 1 else { throw NSError(domain: "GlassButtonClickFailed", code: 1) }
        click(NSPoint(x: 124, y: 64))
        try await Task.sleep(for: .milliseconds(100))
        guard panel.firstResponder is NSTextView else { throw NSError(domain: "GlassTextFieldFocusFailed", code: 2) }
        print("Native glass button click: passed")
        print("Native glass text-field focus: passed")
        print("Persistent nonactivating floating-panel level:", panel.level.rawValue)
    }
}
