import Foundation

/// A text cue for the 副字幕 overlay (we draw it ourselves, so it works the same on VLC and MPV).
struct SubCue { let start: Int32; let end: Int32; let text: String }

enum SubCueParser {
    static func parse(url: URL) -> [SubCue] {
        guard let d = try? Data(contentsOf: url) else { return [] }
        let s = String(data: d, encoding: .utf8) ?? String(data: d, encoding: String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))) ?? String(decoding: d, as: UTF8.self)
        let ext = url.pathExtension.lowercased()
        return (ext == "ass" || ext == "ssa" ? ass(s) : srt(s)).sorted { $0.start < $1.start }
    }
    private static func ms(_ t: String) -> Int32? {
        let p = t.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".").split(separator: ":")
        guard p.count >= 2 else { return nil }
        let sec = Double(p.last!) ?? 0
        let min = Double(p[p.count - 2]) ?? 0
        let hr = p.count >= 3 ? Double(p[p.count - 3]) ?? 0 : 0
        return Int32((hr * 3600 + min * 60 + sec) * 1000)
    }
    private static func strip(_ s: String) -> String {
        s.replacingOccurrences(of: #"\{[^}]*\}|<[^>]*>"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: "\\N", with: "\n").replacingOccurrences(of: "\\n", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
    /// SRT and WebVTT
    private static func srt(_ s: String) -> [SubCue] {
        var out: [SubCue] = []
        let blocks = s.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n\n")
        for b in blocks {
            let lines = b.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            guard let i = lines.firstIndex(where: { $0.contains("-->") }) else { continue }
            let parts = lines[i].components(separatedBy: "-->")
            guard parts.count == 2, let a = ms(parts[0]), let e = ms(parts[1].split(separator: " ").first.map(String.init) ?? "") else { continue }
            let text = strip(lines[(i + 1)...].joined(separator: "\n"))
            if !text.isEmpty { out.append(SubCue(start: a, end: e, text: text)) }
        }
        return out
    }
    private static func ass(_ s: String) -> [SubCue] {
        var out: [SubCue] = []
        for line in s.components(separatedBy: .newlines) where line.hasPrefix("Dialogue:") {
            let f = line.dropFirst(9).split(separator: ",", maxSplits: 9, omittingEmptySubsequences: false).map(String.init)
            guard f.count == 10, let a = ms(f[1]), let e = ms(f[2]) else { continue }
            let text = strip(f[9])
            if !text.isEmpty { out.append(SubCue(start: a, end: e, text: text)) }
        }
        return out
    }
    static func line(_ cues: [SubCue], at t: Int32) -> String {
        var lo = 0, hi = cues.count
        while lo < hi { let m = (lo + hi) / 2; if cues[m].start <= t { lo = m + 1 } else { hi = m } }
        var res: [String] = []
        var i = lo - 1
        while i >= 0 && i >= lo - 6 { if cues[i].end > t { res.insert(cues[i].text, at: 0) }; i -= 1 }
        return res.joined(separator: "\n")
    }
}
