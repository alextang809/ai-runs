import AIRunsCore
import SwiftUI

struct PlanUsageView: View {
    let windows: [AccountRateWindow]
    let updatedAt: Date?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("Plan Usage").font(AppTypography.rowTitle)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                if let updatedAt {
                    Text("Updated \(updatedAt.formatted(date: .abbreviated, time: .shortened))")
                        .font(AppTypography.section)
                        .foregroundStyle(.secondary)
                }
            }
            if !windows.isEmpty {
                TimelineView(.periodic(from: .now, by: 15)) { context in
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(windows) { window in
                            quotaRow(window, now: context.date)
                        }
                    }
                }
            }
        }
    }

    private func quotaRow(_ window: AccountRateWindow, now: Date) -> some View {
        let remaining = 100 - window.usedPercent
        let percent = (remaining / 100).formatted(.percent.precision(.fractionLength(0...1)))
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(window.title)
                Spacer()
                Text("\(percent) remaining").monospacedDigit()
            }
            .font(AppTypography.body)
            .accessibilityElement(children: .combine)
            ProgressView(value: remaining, total: 100)
                .tint(Palette.tool(.codex))
                .accessibilityHidden(true)
            Text(PlanUsageReset(at: window.resetsAt, now: now).text)
                .font(AppTypography.section)
                .foregroundStyle(.secondary)
        }
    }
}

struct PlanUsageReset {
    let text: String

    init(at reset: Date?, now: Date) {
        guard let reset, let minutes = Int(exactly: (reset.timeIntervalSince(now) / 60).rounded(.up)) else {
            text = "Reset time unavailable"
            return
        }
        guard minutes > 0 else {
            text = "Reset time passed · awaiting new reading"
            return
        }
        let hours = minutes / 60
        let days = hours / 24
        switch (days, hours % 24, minutes % 60) {
        case (0, 0, let minute): text = "Resets in \(minute)m"
        case (0, let hour, 0): text = "Resets in \(hour)h"
        case (0, let hour, let minute): text = "Resets in \(hour)h \(minute)m"
        case (let day, 0, _): text = "Resets in \(day)d"
        case (let day, let hour, _): text = "Resets in \(day)d \(hour)h"
        }
    }
}
