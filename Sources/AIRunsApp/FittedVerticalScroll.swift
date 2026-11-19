import SwiftUI

private struct FlyoutHeightLimitKey: EnvironmentKey {
    static let defaultValue: CGFloat = 600
}

extension EnvironmentValues {
    var flyoutHeightLimit: CGFloat {
        get { self[FlyoutHeightLimitKey.self] }
        set { self[FlyoutHeightLimitKey.self] = newValue }
    }
}

private struct ContentHeightPreference: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// Keeps a short card at its natural height and makes a long card scroll.
struct FittedVerticalScroll<Content: View>: View {
    let maximumHeight: CGFloat
    @ViewBuilder var content: Content
    @State private var contentHeight: CGFloat = 1

    var body: some View {
        ScrollView(.vertical) {
            content.fixedSize(horizontal: false, vertical: true)
                .background(GeometryReader { proxy in
                    Color.clear.preference(key: ContentHeightPreference.self, value: proxy.size.height)
                })
        }
        .frame(height: max(1, min(contentHeight, maximumHeight)))
        .onPreferenceChange(ContentHeightPreference.self) { contentHeight = $0 }
    }
}

/// Anchors near the row while keeping every detail action inside the screen.
struct PositionedFlyout<Content: View>: View {
    let rowTop: CGFloat
    let maximumHeight: CGFloat
    @ViewBuilder var content: Content
    @State private var contentHeight: CGFloat?

    var body: some View {
        content
            .background(GeometryReader { proxy in
                Color.clear.preference(key: ContentHeightPreference.self, value: proxy.size.height)
            })
            .onPreferenceChange(ContentHeightPreference.self) { contentHeight = $0 }
            .padding(.top, PanelLayout.flyoutOffset(rowTop: rowTop,
                        flyoutHeight: contentHeight ?? maximumHeight, maximumHeight: maximumHeight))
    }
}
