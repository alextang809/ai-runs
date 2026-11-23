import Foundation

extension Session {
    /// Retain the pin, conversation identity and reply when there is no longer a live state.
    mutating func clearObservedState() {
        state = .unknown
        outcome = nil
        outcomeSource = nil
        native = nil
        approvalDetail = nil
        waitingSince = nil
        activity = nil
        progress = nil
        planSteps = nil
        scheduled = nil
        backgroundTasks = nil
        ignored = nil
    }
}
