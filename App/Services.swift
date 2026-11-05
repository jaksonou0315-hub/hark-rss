import Foundation
import AVFoundation
import MediaPlayer

enum FeedDiscovery {
    struct Candidate: Identifiable, Hashable {
        var id: String { url }
        let title: String
        let url: String
    }

    static func discover(_ raw: String) async throws -> [Candidate] {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if !s.contains("://") { s = "https://" + s }
        guard let base = URL(string: s) else { throw URLError(.badURL) }
        let (data, resp) = try await URLSession.shared.data(from: base)
        let final = resp.url ?? base
        if let c = looksLikeFeed(data, url: final.absoluteString) { return [c] }
        let html = String(decoding: data, as: UTF8.self)
        let ns = html as NSString
        var out: [Candidate] = []
        let re = try NSRegularExpression(pattern: "<link[^>]+>", options: .caseInsensitive)
        for m in re.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
            let tag = ns.substring(with: m.range)
            let low = tag.lowercased()
            guard low.contains("alternate"), low.contains("rss") || low.contains("atom") || low.contains("json") else { continue }
            guard let href = attr("href", in: tag), let u = URL(string: href, relativeTo: final)?.absoluteURL else { continue }
            out.append(Candidate(title: attr("title", in: tag) ?? (final.host ?? "订阅源"), url: u.absoluteString))
        }
        if out.isEmpty {
            for p in ["/feed", "/rss", "/rss.xml", "/atom.xml", "/feed.xml", "/index.xml", "/feed.json"] {
                guard let u = URL(string: p, relativeTo: final)?.absoluteURL,
                      let r = try? await URLSession.shared.data(from: u) else { continue }
                if let c = looksLikeFeed(r.0, url: u.absoluteString) { out.append(c); break }
            }
        }
        var seen = Set<String>()
        return out.filter { seen.insert($0.url).inserted }
    }

    static func looksLikeFeed(_ d: Data, url: String) -> Candidate? {
        let head = String(decoding: d.prefix(2000), as: UTF8.self).lowercased()
        guard head.contains("<rss") || head.contains("<feed") || head.contains("<rdf") || head.contains("jsonfeed.org") else { return nil }
        let title = FeedParser.parse(d, source: FeedSource(name: "", url: url)).0
        return Candidate(title: title.isEmpty ? (URL(string: url)?.host ?? url) : title, url: url)
    }

    static func attr(_ name: String, in tag: String) -> String? {
        guard let r = tag.range(of: "\(name)\\s*=\\s*[\"'][^\"']*[\"']", options: [.regularExpression, .caseInsensitive]) else { return nil }
        let m = String(tag[r])
        guard let q = m.firstIndex(where: { $0 == "\"" || $0 == "'" }) else { return nil }
        return String(m[m.index(after: q)...].dropLast()).replacingOccurrences(of: "&amp;", with: "&")
    }
}

enum FullText {
    static func extract(from urlString: String) async throws -> String {
        guard let u = URL(string: urlString) else { throw URLError(.badURL) }
        var req = URLRequest(url: u, timeoutInterval: 25)
        req.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1", forHTTPHeaderField: "User-Agent")
        let (d, _) = try await URLSession.shared.data(for: req)
        var html = String(data: d, encoding: .utf8) ?? String(decoding: d, as: UTF8.self)
        for tag in ["script", "style", "nav", "header", "footer", "aside", "form", "noscript", "svg"] {
            html = html.replacingOccurrences(of: "<\(tag)[\\s\\S]*?</\(tag)>", with: "", options: [.regularExpression, .caseInsensitive])
        }
        let body = firstMatch("<article[\\s\\S]*?</article>", in: html) ?? firstMatch("<main[\\s\\S]*?</main>", in: html) ?? html
        let parts = allMatches("<(p|h2|h3|h4|blockquote|pre|figure|ul|ol)[\\s>][\\s\\S]*?</\\1>", in: body)
        let result = parts.filter { $0.strippingHTML.count > 15 || $0.lowercased().contains("<img") }.joined(separator: "\n")
        guard !result.isEmpty else { throw URLError(.cannotParseResponse) }
        return result
    }
    static func firstMatch(_ p: String, in s: String) -> String? {
        s.range(of: p, options: [.regularExpression, .caseInsensitive]).map { String(s[$0]) }
    }
    static func allMatches(_ p: String, in s: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern: p, options: [.caseInsensitive]) else { return [] }
        let ns = s as NSString
        return re.matches(in: s, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range) }
    }
}

@MainActor
final class Player: ObservableObject {
    static let shared = Player()
    @Published var current: FeedItem?
    @Published var isPlaying = false
    let avPlayer = AVPlayer()

    private init() {
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
        let cc = MPRemoteCommandCenter.shared()
        cc.playCommand.addTarget { [weak self] _ in Task { @MainActor in self?.resume() }; return .success }
        cc.pauseCommand.addTarget { [weak self] _ in Task { @MainActor in self?.pause() }; return .success }
        cc.togglePlayPauseCommand.addTarget { [weak self] _ in Task { @MainActor in self?.toggle() }; return .success }
        cc.skipForwardCommand.preferredIntervals = [30]
        cc.skipForwardCommand.addTarget { [weak self] _ in Task { @MainActor in self?.skip(30) }; return .success }
        cc.skipBackwardCommand.preferredIntervals = [15]
        cc.skipBackwardCommand.addTarget { [weak self] _ in Task { @MainActor in self?.skip(-15) }; return .success }
    }

    func play(_ item: FeedItem) {
        guard let u = URL(string: item.enclosureURL) else { return }
        try? AVAudioSession.sharedInstance().setActive(true)
        if current?.id != item.id {
            avPlayer.replaceCurrentItem(with: AVPlayerItem(url: u))
            current = item
        }
        resume()
    }
    func toggle() { isPlaying ? pause() : resume() }
    func pause() { avPlayer.pause(); isPlaying = false; updateNowPlaying() }
    func resume() { avPlayer.play(); isPlaying = true; updateNowPlaying() }
    func skip(_ s: Double) {
        let now = avPlayer.currentTime().seconds
        let t = (now.isFinite ? now : 0) + s
        avPlayer.seek(to: CMTime(seconds: max(0, t), preferredTimescale: 600))
    }
    func stop() {
        avPlayer.pause()
        avPlayer.replaceCurrentItem(with: nil)
        current = nil
        isPlaying = false
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }
    private func updateNowPlaying() {
        guard let c = current else { return }
        let el = avPlayer.currentTime().seconds
        MPNowPlayingInfoCenter.default().nowPlayingInfo = [
            MPMediaItemPropertyTitle: c.title,
            MPMediaItemPropertyArtist: c.source,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: el.isFinite ? el : 0,
        ]
    }
}
