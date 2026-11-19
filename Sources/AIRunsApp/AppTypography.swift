import SwiftUI

/// A single SF type hierarchy for text on the app's frosted surfaces.
/// Rounded and monospaced faces are reserved for special-purpose content.
enum AppTypography {
    static let appTitle = Font.system(size: 17)
    static let detailTitle = Font.system(size: 14, weight: .semibold)
    static let rowTitle = Font.system(size: 13.5)
    static let compactTitle = Font.system(size: 13, weight: .semibold)
    static let body = Font.system(size: 12)
    static let action = Font.system(size: 13)
    static let metadata = Font.system(size: 11.5)
    static let section = Font.system(size: 11)
    static let badge = Font.system(size: 10.5)
    static let elapsed = Font.system(size: 11).monospacedDigit()
    static let metric = Font.system(size: 24, weight: .medium).monospacedDigit()
    static let capsuleCount = Font.system(size: 14, weight: .semibold).monospacedDigit()
    static let controlIcon = Font.system(size: 11, weight: .medium)
}
