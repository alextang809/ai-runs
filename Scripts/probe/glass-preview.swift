// macOS 26 native preview with fictitious sessions; does not initialize AppModel.
// From the repository root:
// swiftc -parse-as-library Sources/AIRunsApp/GlassSurface.swift Scripts/probe/glass-preview.swift -o /tmp/airuns-glass-preview
// /tmp/airuns-glass-preview /tmp/airuns-glass-preview-images

import AppKit
import ScreenCaptureKit
import SwiftUI

struct PreviewRun: Identifiable {
    let id: Int
    let title: String
    let tool: String
    let activity: String
    let state: String
    let needs: Bool
    let claude: Bool
    var tint: Color { claude ? Color(red: 0.851, green: 0.467, blue: 0.341) : .primary }
}

let previewRuns = [
    PreviewRun(id: 1, title: "Export report", tool: "Claude Code", activity: "Waiting for permission to save", state: "APPROVE", needs: true, claude: true),
    PreviewRun(id: 2, title: "Research notes", tool: "Claude project", activity: "Which sources should I include?", state: "NEEDS INPUT", needs: true, claude: true),
    PreviewRun(id: 3, title: "Polish settings", tool: "Codex", activity: "Refining the preferences panel", state: "WORKING", needs: false, claude: false),
    PreviewRun(id: 4, title: "Voice conversation", tool: "Codex", activity: "Preparing the next response", state: "WORKING", needs: false, claude: false),
]

struct PreviewLogo: View {
    var body: some View {
        ZStack {
            Circle().trim(from: 0.52, to: 0.98).stroke(.primary, style: StrokeStyle(lineWidth: 1.7, lineCap: .round))
                .frame(width: 18, height: 18).offset(y: 4)
            Circle().fill(.primary).frame(width: 4, height: 4).offset(y: 3)
        }.frame(width: 22, height: 20)
    }
}

struct PreviewRow: View {
    let run: PreviewRun
    var compact = false
    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            RoundedRectangle(cornerRadius: 2).fill(run.tint).frame(width: 3, height: compact ? 31 : 44)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    Text(run.title).font(.system(size: compact ? 12.5 : 13, weight: .semibold)).lineLimit(1)
                    Spacer(minLength: 4)
                    Text(run.state).font(.system(size: 9, weight: .semibold))
                        .padding(.horizontal, 6).padding(.vertical, 3)
                        .foregroundStyle(run.needs ? Color.white : run.tint)
                        .background(Capsule().fill(run.needs ? run.tint : Color.primary.opacity(0.035)))
                        .overlay(Capsule().strokeBorder(run.needs ? .clear : run.tint.opacity(0.65), lineWidth: 0.8))
                }
                if !compact { Text(run.tool + " · just now").font(.system(size: 10.5)).foregroundStyle(.secondary) }
                Text(run.activity).font(.system(size: compact ? 10.5 : 11.5)).foregroundStyle(.secondary).lineLimit(1)
            }
        }.padding(.horizontal, 12).padding(.vertical, compact ? 8 : 9)
    }
}

struct PreviewMenu: View {
    var body: some View {
        GlassSurface(cornerRadius: 20) {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 13) {
                    HStack {
                        PreviewLogo()
                        Text("AI Runs").font(.system(size: 16, weight: .semibold))
                        Spacer()
                        Image(systemName: "arrow.clockwise").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                    }
                    HStack(alignment: .bottom, spacing: 20) {
                        metric("2", "NEED YOU")
                        metric("2", "WORKING")
                        metric("6", "TODAY")
                        Spacer()
                        HStack(alignment: .bottom, spacing: 3) {
                            ForEach(0..<12) { index in
                                Capsule().fill(index % 3 == 0 ? Color(red: 0.851, green: 0.467, blue: 0.341) : Color.primary.opacity(0.5))
                                    .frame(width: 4, height: CGFloat([8, 14, 11, 21, 16, 28, 23, 18, 27, 21, 31, 24][index]))
                            }
                        }.frame(height: 34)
                    }
                    Text("Agents waited on you 8m today").font(.system(size: 11)).foregroundStyle(.secondary)
                }.padding(16)
                Divider().padding(.horizontal, 16)
                Text("ACTIVE · 4").font(.system(size: 10, weight: .semibold)).tracking(0.7)
                    .foregroundStyle(.secondary).padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 2)
                ForEach(previewRuns) { PreviewRow(run: $0) }
                Divider().padding(.horizontal, 16).padding(.vertical, 8)
                HStack {
                    Text("PINNED").font(.system(size: 10, weight: .semibold)).tracking(0.7)
                    Spacer()
                    Text("1").font(.system(size: 11)).monospacedDigit()
                }.foregroundStyle(.secondary).padding(.horizontal, 16).padding(.bottom, 7)
                HStack(spacing: 10) {
                    Image(systemName: "pin").foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Weekly release").font(.system(size: 12.5, weight: .semibold))
                        Text("Next: Review final notes").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text("3m").font(.system(size: 11)).foregroundStyle(.secondary)
                }.padding(.horizontal, 16).padding(.vertical, 8)
                Divider().padding(.horizontal, 16).padding(.vertical, 8)
                menuItem("Pin Front AI Window", "pin")
                menuItem("Hide Floating Window", "rectangle.on.rectangle")
                menuItem("Hooks & Settings…", "slider.horizontal.3")
                menuItem("Quit AI Runs", "power", shortcut: "⌘Q")
            }.padding(.bottom, 10).frame(width: 384)
        }
    }
    private func metric(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(value).font(.system(size: 22, weight: .semibold, design: .rounded)).monospacedDigit()
            Text(label).font(.system(size: 9, weight: .semibold)).tracking(0.5).foregroundStyle(.secondary)
        }
    }
    private func menuItem(_ title: String, _ symbol: String, shortcut: String = "") -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).frame(width: 16).foregroundStyle(.secondary)
            Text(title)
            Spacer()
            Text(shortcut).foregroundStyle(.secondary)
        }.font(.system(size: 12.5)).padding(.horizontal, 16).frame(height: 30)
    }
}

struct PreviewFloating: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            GlassSurface(cornerRadius: 22) {
                HStack(spacing: 9) {
                    PreviewLogo()
                    Text("2").font(.system(size: 13, weight: .semibold, design: .rounded))
                    Text("NEED YOU").font(.system(size: 10, weight: .semibold)).tracking(0.5).foregroundStyle(.secondary)
                    Divider().frame(height: 16)
                    ForEach(0..<4) { index in
                        Circle().fill(index < 2 ? Color(red: 0.851, green: 0.467, blue: 0.341) : Color.primary.opacity(0.2)).frame(width: 7, height: 7)
                    }
                }.padding(.horizontal, 13).frame(height: 44)
            }
            GlassSurface(cornerRadius: 20) {
                VStack(spacing: 0) {
                    HStack(spacing: 9) {
                        PreviewLogo()
                        Picker("View", selection: .constant(0)) {
                            Text("Runs").tag(0)
                            Text("Pinned").tag(1)
                        }.pickerStyle(.segmented).labelsHidden().controlSize(.small).frame(width: 130)
                        Spacer(minLength: 3)
                        Image(systemName: "arrow.clockwise")
                        Image(systemName: "chevron.up")
                        Image(systemName: "xmark")
                    }.font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                        .padding(.horizontal, 14).padding(.vertical, 14)
                    ForEach(previewRuns) { PreviewRow(run: $0, compact: true) }
                    Text("+ 2 done or ignored").font(.system(size: 10.5)).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 16).padding(.vertical, 12)
                }.frame(width: 310)
            }
            GlassSurface(cornerRadius: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Export report").font(.system(size: 14, weight: .semibold))
                    Text("Claude Code · Waiting for approval").font(.system(size: 11.5)).foregroundStyle(.secondary)
                    Text("Save the generated report to your project.").font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
                    Divider().padding(.vertical, 2)
                    HStack { Image(systemName: "arrow.up.forward.app"); Text("Open in Claude"); Spacer(); Text("↩").foregroundStyle(.secondary) }
                        .font(.system(size: 12))
                }.padding(16).frame(width: 284, alignment: .leading)
            }
        }.frame(width: 310, alignment: .leading)
    }
}

struct PreviewCanvas: View {
    let dark: Bool
    var body: some View {
        ZStack {
            LinearGradient(colors: dark ? [Color(red: 0.08, green: 0.13, blue: 0.22), Color(red: 0.2, green: 0.15, blue: 0.27)] : [Color(red: 0.77, green: 0.87, blue: 0.95), Color(red: 0.88, green: 0.84, blue: 0.94)], startPoint: .topLeading, endPoint: .bottomTrailing)
            Ellipse().fill(Color.cyan.opacity(dark ? 0.25 : 0.2)).frame(width: 600, height: 230).blur(radius: 45).rotationEffect(.degrees(-30)).offset(x: -200, y: -120)
            Ellipse().fill(Color.pink.opacity(dark ? 0.18 : 0.14)).frame(width: 550, height: 240).blur(radius: 50).rotationEffect(.degrees(-30)).offset(x: 230, y: 130)
            VStack(alignment: .leading, spacing: 20) {
                HStack {
                    Text(dark ? "DARK" : "LIGHT").font(.system(size: 11, weight: .semibold)).tracking(1.5)
                    Spacer()
                    Text("Native glass preview · fictitious sessions").font(.system(size: 11))
                }.foregroundStyle(.secondary)
                HStack(alignment: .top, spacing: 28) { PreviewMenu(); PreviewFloating() }
                Spacer(minLength: 0)
            }.padding(28)
        }.frame(width: 778, height: 774)
            .environment(\.colorScheme, dark ? .dark : .light)
    }
}

@main
struct GlassPreviewRunner {
    @MainActor static func main() async throws {
        guard CommandLine.arguments.count == 2 else {
            fputs("Usage: airuns-glass-preview OUTPUT_DIRECTORY\n", stderr)
            exit(64)
        }
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        for (name, dark) in [("light", false), ("dark", true)] {
            let host = NSHostingView(rootView: PreviewCanvas(dark: dark))
            host.frame = NSRect(x: 0, y: 0, width: 778, height: 774)
            let window = NSPanel(contentRect: host.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            window.contentView = host
            window.center()
            window.orderFrontRegardless()
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(500))
            let shareable = try await SCShareableContent.currentProcess
            guard let own = shareable.windows.first(where: { $0.windowID == window.windowNumber }) else { throw NSError(domain: "PreviewWindowMissing", code: 1) }
            let configuration = SCStreamConfiguration()
            configuration.width = 1556
            configuration.height = 1548
            configuration.showsCursor = false
            configuration.ignoreShadowsSingleWindow = true
            let capture = try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: own), configuration: configuration)
            let bitmap = NSBitmapImageRep(cgImage: capture)
            try bitmap.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent("glass-\(name).png"))
            window.orderOut(nil)
            print("Rendered", name)
        }
    }
}
