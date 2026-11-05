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
}

extension View {
    /// Lets sibling glass shapes morph into each other on iOS 26.
    @ViewBuilder
    func glassID(_ id: String, _ ns: Namespace.ID) -> some View {
        if #available(iOS 26.0, *) { self.glassEffectID(id, in: ns) } else { self }
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
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        ZStack {
            LinearGradient(colors: scheme == .dark
                           ? [Color(red: 0.06, green: 0.07, blue: 0.16), Color(red: 0.12, green: 0.05, blue: 0.2), Color(red: 0.02, green: 0.13, blue: 0.17)]
                           : [Color(red: 0.86, green: 0.9, blue: 1.0), Color(red: 0.95, green: 0.88, blue: 0.98), Color(red: 0.84, green: 0.96, blue: 0.95)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            Circle().fill(Color.pink.opacity(scheme == .dark ? 0.35 : 0.3)).frame(width: 340).blur(radius: 100).offset(x: -130, y: -280)
            Circle().fill(Color.cyan.opacity(scheme == .dark ? 0.3 : 0.35)).frame(width: 320).blur(radius: 100).offset(x: 150, y: 260)
            Circle().fill(Color.indigo.opacity(0.3)).frame(width: 260).blur(radius: 90).offset(x: 120, y: -60)
        }
        .ignoresSafeArea()
    }
}

struct MiniPlayerBar: View {
    @ObservedObject private var p = Player.shared
    var body: some View {
        if let item = p.current {
            GlassGroup(spacing: 8) {
                HStack(spacing: 14) {
                    Image(systemName: item.isVideo ? "play.rectangle" : "waveform")
                        .font(.title3).symbolRenderingMode(.hierarchical)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(item.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                        Text(item.source).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    Button { p.skip(-15) } label: { Image(systemName: "gobackward.15") }
                    Button { p.toggle() } label: { Image(systemName: p.isPlaying ? "pause.fill" : "play.fill").font(.title3) }
                    Button { p.skip(30) } label: { Image(systemName: "goforward.30") }
                    Button { p.stop() } label: { Image(systemName: "xmark").font(.caption.bold()) }
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 18).padding(.vertical, 12)
                .glass(in: Capsule(), interactive: true)
            }
        }
    }
}
