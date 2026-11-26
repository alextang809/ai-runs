import AppKit
import SwiftUI

/// Accessibility takes precedence over the system's available visual effects.
struct GlassPresentation: Equatable {
    enum Material: Equatable { case liquid, frosted, opaque }
    let material: Material
    let needsContrastBorder: Bool

    static func resolve(supportsLiquidGlass: Bool, reduceTransparency: Bool,
                        increasedContrast: Bool) -> GlassPresentation {
        let material: Material = reduceTransparency ? .opaque :
            (supportsLiquidGlass ? .liquid : .frosted)
        return GlassPresentation(material: material, needsContrastBorder: increasedContrast)
    }
}

/// One glass layer for an outer window surface, never for individual list rows:
/// rows that should read as panes on it use `GlassTile`, which is drawn.
struct GlassSurface<Content: View>: View {
    let cornerRadius: CGFloat
    let fallbackMaterial: NSVisualEffectView.Material
    let content: Content
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.colorScheme) private var colorScheme

    init(cornerRadius: CGFloat = 20,
         fallbackMaterial: NSVisualEffectView.Material = .menu,
         @ViewBuilder content: () -> Content) {
        self.cornerRadius = cornerRadius
        self.fallbackMaterial = fallbackMaterial
        self.content = content()
    }

    var body: some View {
        let presentation = GlassPresentation.resolve(
            supportsLiquidGlass: Self.supportsLiquidGlass,
            reduceTransparency: reduceTransparency,
            increasedContrast: contrast == .increased)
        materialSurface(presentation.material)
            .overlay {
                if presentation.needsContrastBorder || presentation.material != .liquid {
                    shape.strokeBorder(
                        Color.primary.opacity(presentation.needsContrastBorder ? 0.4 : 0.12),
                        lineWidth: presentation.needsContrastBorder ? 1.25 : 0.5)
                        .allowsHitTesting(false)
                }
            }
            .shadow(color: .black.opacity(colorScheme == .dark ? 0.18 : 0.1),
                    radius: 10, x: 0, y: 4)
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
    }

    @ViewBuilder
    private func materialSurface(_ material: GlassPresentation.Material) -> some View {
        switch material {
        case .opaque:
            content
                .background(Color(nsColor: .windowBackgroundColor))
                .clipShape(shape)
        case .frosted:
            frostedSurface
        case .liquid:
            // Older toolchains cannot name Liquid Glass, even inside a runtime check.
            #if compiler(>=6.2)
            if #available(macOS 26.0, *) {
                softenedGlassContent.glassEffect(.regular, in: shape)
            } else {
                frostedSurface
            }
            #else
            frostedSurface
            #endif
        }
    }

    /// Frost only the backdrop; text and controls stay sharp above the material.
    private var softenedGlassContent: some View {
        content
            .background {
                shape.fill(.regularMaterial)
                    .overlay { backgroundWash }
                    .allowsHitTesting(false)
            }
            .clipShape(shape)
    }

    private var frostedSurface: some View {
        content
            .background {
                LegacyGlassBackdrop(material: fallbackMaterial)
                    .overlay { backgroundWash }
                    .allowsHitTesting(false)
            }
            .clipShape(shape)
    }

    private var backgroundWash: some View {
        shape.fill(Color(nsColor: .windowBackgroundColor)
            .opacity(colorScheme == .dark ? 0.16 : 0.1))
            .allowsHitTesting(false)
    }

    private static var supportsLiquidGlass: Bool {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) { return true }
        #endif
        return false
    }
}

/// Kept private so this surface also works in isolated synthetic preview runners.
private struct LegacyGlassBackdrop: NSViewRepresentable {
    let material: NSVisualEffectView.Material

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
    }
}

/// A pane lying on the panel's glass: a translucent fill that is lighter at
/// the top, a bright hairline edge and, when raised, a hairline shadow. It is
/// drawn, not a second system glass layer, so glass never stacks on glass.
struct GlassTile: ViewModifier {
    enum Level { case raised, quiet }
    let level: Level
    var hovered = false
    var cornerRadius: CGFloat = 13
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        let dark = colorScheme == .dark
        let raised = level == .raised
        let top: Double = raised ? (dark ? 0.13 : 0.66) : (dark ? 0.045 : 0.24)
        let bottom: Double = raised ? (dark ? 0.07 : 0.42) : (dark ? 0.045 : 0.24)
        let edge: Double = raised ? (dark ? 0.2 : 0.8) : (dark ? 0.08 : 0.5)
        return content
            .background {
                if reduceTransparency {
                    shape.fill(Color(nsColor: .controlBackgroundColor).opacity(raised ? 1 : 0.55))
                } else {
                    shape.fill(LinearGradient(colors: [Color.white.opacity(top), Color.white.opacity(bottom)],
                                              startPoint: .top, endPoint: .bottom))
                        .shadow(color: .black.opacity(raised ? (dark ? 0.28 : 0.08) : 0), radius: 1, x: 0, y: 1)
                }
            }
            .overlay { shape.fill(Color.primary.opacity(hovered ? 0.06 : 0)).allowsHitTesting(false) }
            .overlay {
                if contrast == .increased {
                    shape.strokeBorder(Color.primary.opacity(0.4), lineWidth: 1).allowsHitTesting(false)
                } else {
                    shape.strokeBorder(Color.white.opacity(edge), lineWidth: 0.5).allowsHitTesting(false)
                }
            }
    }
}

extension View {
    func glassTile(_ level: GlassTile.Level, hovered: Bool = false, cornerRadius: CGFloat = 13) -> some View {
        modifier(GlassTile(level: level, hovered: hovered, cornerRadius: cornerRadius))
    }
}
