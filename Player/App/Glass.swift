import SwiftUI
import ImageIO

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

/// Poster loader: memory cache + shared in-flight loads (re-renders never cancel a download) + URLCache on disk, retries twice.
@MainActor
final class PosterCache {
    static let shared = PosterCache()
    private let mem: NSCache<NSURL, UIImage> = { let c = NSCache<NSURL, UIImage>(); c.totalCostLimit = 120 << 20; return c }()
    private var inflight: [URL: Task<UIImage?, Never>] = [:]
    func clearMemory() { mem.removeAllObjects() }
    /// Own session so on-screen posters don't queue behind background precache / TMDB API calls on URLSession.shared.
    nonisolated static let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.urlCache = URLCache.shared
        c.httpMaximumConnectionsPerHost = 8
        c.timeoutIntervalForRequest = 30
        return URLSession(configuration: c)
    }()
    /// Decode straight to display size (ImageIO thumbnail) instead of full decode + preparingForDisplay.
    nonisolated static func downsample(_ d: Data, maxPixel: Int) -> UIImage? {
        guard let src = CGImageSourceCreateWithData(d as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else { return UIImage(data: d) }
        let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                                     kCGImageSourceShouldCacheImmediately: true, kCGImageSourceThumbnailMaxPixelSize: maxPixel]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return UIImage(data: d) }
        return UIImage(cgImage: cg)
    }
    func cached(_ u: URL) -> UIImage? { mem.object(forKey: u as NSURL) }
    func load(_ u: URL) async -> UIImage? {
        if let i = cached(u) { return i }
        if let t = inflight[u] { return await t.value }
        let t = Task.detached(priority: .userInitiated) { () -> UIImage? in
            for attempt in 0..<3 {
                var r = URLRequest(url: u, cachePolicy: .returnCacheDataElseLoad, timeoutInterval: 20)
                r.setValue("image/*", forHTTPHeaderField: "Accept")
                if let (d, resp) = try? await PosterCache.session.data(for: r),
                   (resp as? HTTPURLResponse).map({ $0.statusCode < 400 }) ?? true,
                   let img = PosterCache.downsample(d, maxPixel: u.absoluteString.contains("/w1280") ? 1400 : 560) {
                    return img
                }
                try? await Task.sleep(nanoseconds: UInt64(attempt + 1) * 800_000_000)
            }
            return nil
        }
        inflight[u] = t
        let img = await t.value
        inflight[u] = nil
        if let img { mem.setObject(img, forKey: u as NSURL, cost: Int(img.size.width * img.size.height * img.scale * img.scale * 4)) }
        return img
    }
}

struct PosterImage: View {
    var url: URL?
    var title: String
    @State private var image: UIImage?
    var body: some View {
        let img = image ?? url.flatMap { PosterCache.shared.cached($0) }
        Group {
            if let img {
                // fill the frame but never spill past it: Color sizes to the proposed frame, the image is an overlay
                Color.clear.overlay { Image(uiImage: img).resizable().scaledToFill().allowsHitTesting(false) }.clipped()
            } else {
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
        .task(id: url) {
            guard let url else { image = nil; return }
            if let c = PosterCache.shared.cached(url) { image = c; return }
            image = nil
            // a failed load (busy network while matching) retries while the tile stays on screen
            for wait in [0, 3, 8, 20, 45] as [UInt64] {
                if wait > 0 { try? await Task.sleep(nanoseconds: wait * 1_000_000_000) }
                if Task.isCancelled { return }
                if let i = await PosterCache.shared.load(url) { withAnimation(.easeOut(duration: 0.2)) { image = i }; return }
            }
        }
    }
}
