import SwiftUI

/// The neutral glass of the Mac panel, on the phone: a quiet backdrop, frosted section cards, and one
/// Liquid Glass surface for the live clock. Never glass on glass, and no colour of its own.
struct GlassBackdrop: View {
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        let dark = scheme == .dark
        ZStack {
            (dark ? Color(white: 0.06) : Color(white: 0.92))
            RadialGradient(colors: [.white.opacity(dark ? 0.16 : 0.75), .clear],
                           center: UnitPoint(x: 0.15, y: 0.05), startRadius: 0, endRadius: 420)
            RadialGradient(colors: [(dark ? Color.white : .black).opacity(dark ? 0.09 : 0.08), .clear],
                           center: UnitPoint(x: 0.9, y: 0.55), startRadius: 0, endRadius: 380)
            RadialGradient(colors: [.white.opacity(dark ? 0.07 : 0.4), .clear],
                           center: UnitPoint(x: 0.2, y: 1), startRadius: 0, endRadius: 340)
        }
        .ignoresSafeArea()
    }
}

/// A List whose sections are frosted cards over the backdrop.
struct GlassList<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        List { Group { content }.listRowBackground(Rectangle().fill(.ultraThinMaterial)) }
            .scrollContentBackground(.hidden)
            .background { GlassBackdrop() }
    }
}

extension View {
    /// Liquid Glass on iOS 26 and later, the same shape in material before that, with the Mac's bright top edge.
    func glassHero() -> some View {
        let shape = RoundedRectangle(cornerRadius: 26, style: .continuous)
        return self.padding(16)
            .modifier(HeroGlass(shape: shape))
            .overlay {
                shape.strokeBorder(LinearGradient(colors: [.white.opacity(0.45), .white.opacity(0.04)],
                                                  startPoint: .top, endPoint: .bottom), lineWidth: 0.75)
            }
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
    }
}

private struct HeroGlass: ViewModifier {
    var shape: RoundedRectangle
    func body(content: Content) -> some View {
        if #available(iOS 26, *) {
            content.glassEffect(.regular, in: shape)
        } else {
            content.background(.ultraThinMaterial, in: shape)
        }
    }
}
