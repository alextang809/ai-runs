import AIRunsCore
import SwiftUI

/// Reads hook events, open Claude projects and the Threads list right now, for when a run
/// changed and AI Runs hasn't caught up yet.
struct RefreshButton: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Button { model.refreshNow() } label: {
            Image(systemName: "arrow.clockwise").font(.system(size: 10.5, weight: .bold))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help("Refresh: read new events, open Claude projects and the Threads list now")
        .accessibilityLabel("Refresh")
    }
}

/// Says why cloud threads can't show up, when the reason is one the user can
/// fix. Nothing when reading works or was turned off on purpose.
struct ThreadsHint: View {
    @ObservedObject var model: AppModel

    var body: some View {
        if model.threadsStatus == .needsPermission {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("Claude conversations need Accessibility. If AI Runs is already ticked in System Settings, remove it and add it again.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Palette.claude)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Button("Allow…") { model.allowAccessibility() }
                    .controlSize(.small)
            }
        }
    }
}
