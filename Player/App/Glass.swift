import SwiftUI

extension View {
    /// Liquid Glass on iOS 26, frosted material on older systems.
    @ViewBuilder
    func glass<S: Shape>(in shape: S, tint: Color? = nil, interactive: Bool = false) -> some View {
        if #available(iOS 26.0, *) {
            self.glassEffect(Glass.regular.tint(tint).interactive(interactive), in: shape)
        } else {
            self.background(.ultraThinMaterial, in: shape)
                .overlay(shape.stroke(Color.white.opacity(0.18), lineWidth: 0.7))
                .background(shape.fill((tint ?? .clear).opacity(0.6)))
        }
    }

    @ViewBuilder
    func glassButton(prominent: Bool = false) -> some View {
        if #available(iOS 26.0, *) {
            if prominent { self.buttonStyle(.glassProminent) } else { self.buttonStyle(.glass) }
        } else {
            if prominent { self.buttonStyle(.borderedProminent) } else { self.buttonStyle(.bordered) }
        }
    }

    @ViewBuilder
    func minimizingTabBar() -> some View {
        if #available(iOS 26.0, *) {
            self.tabBarMinimizeBehavior(.onScrollDown)
        } else {
            self
        }
    }
}

struct GlassGroup<Content: View>: View {
    var spacing: CGFloat = 12
    @ViewBuilder var content: Content
    var body: some View {
        if #available(iOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) { content }
        } else {
            content
        }
    }
}

struct AuroraBackground: View {
    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.05, green: 0.05, blue: 0.12), Color(red: 0.10, green: 0.04, blue: 0.16), Color(red: 0.02, green: 0.09, blue: 0.14)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            Circle().fill(Color.pink.opacity(0.28)).frame(width: 340).blur(radius: 110).offset(x: -130, y: -300)
            Circle().fill(Color.cyan.opacity(0.22)).frame(width: 320).blur(radius: 110).offset(x: 150, y: 280)
            Circle().fill(Color.indigo.opacity(0.3)).frame(width: 260).blur(radius: 90).offset(x: 120, y: -60)
        }
        .ignoresSafeArea()
    }
}

struct PosterImage: View {
    var url: URL?
    var title: String
    var body: some View {
        AsyncImage(url: url, transaction: Transaction(animation: .easeOut)) { phase in
            switch phase {
            case .success(let img):
                // fill the frame but never spill past it: Color sizes to the proposed frame, the image is an overlay
                Color.clear.overlay { img.resizable().scaledToFill().allowsHitTesting(false) }.clipped()
            default:
                ZStack {
                    LinearGradient(colors: [.indigo.opacity(0.6), .purple.opacity(0.4)], startPoint: .top, endPoint: .bottom)
                    VStack(spacing: 6) {
                        Image(systemName: "film").font(.title2)
                        Text(title).font(.caption.weight(.semibold)).multilineTextAlignment(.center).lineLimit(3).padding(.horizontal, 6)
                    }
                    .foregroundStyle(.white.opacity(0.85))
                }
            }
        }
    }
}
