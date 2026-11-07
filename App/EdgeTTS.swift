import Foundation

/// Natural online voices from Microsoft Edge's read-aloud service (no key needed).
struct EdgeVoice: Identifiable, Hashable {
    let id: String
    let name: String
    let desc: String
    let male: Bool
}

enum EdgeTTS {
    static let voices: [EdgeVoice] = [
        .init(id: "zh-CN-XiaoxiaoNeural", name: "晓晓", desc: "女声 · 温暖", male: false),
        .init(id: "zh-CN-XiaoyiNeural", name: "晓伊", desc: "女声 · 活泼少女", male: false),
        .init(id: "zh-CN-YunxiNeural", name: "云希", desc: "男声 · 阳光青年", male: true),
        .init(id: "zh-CN-YunjianNeural", name: "云健", desc: "男声 · 激昂", male: true),
        .init(id: "zh-CN-YunyangNeural", name: "云扬", desc: "男声 · 新闻播音", male: true),
        .init(id: "zh-CN-YunxiaNeural", name: "云夏", desc: "童声 · 男孩", male: true),
        .init(id: "zh-CN-liaoning-XiaobeiNeural", name: "晓北", desc: "女声 · 东北话", male: false),
        .init(id: "zh-CN-shaanxi-XiaoniNeural", name: "晓妮", desc: "女声 · 陕西话", male: false),
        .init(id: "zh-TW-HsiaoChenNeural", name: "曉臻", desc: "女声 · 台湾腔", male: false),
        .init(id: "zh-TW-YunJheNeural", name: "雲哲", desc: "男声 · 台湾腔", male: true),
        .init(id: "zh-HK-HiuMaanNeural", name: "曉曼", desc: "女声 · 粤语", male: false),
        .init(id: "zh-HK-WanLungNeural", name: "雲龍", desc: "男声 · 粤语", male: true),
    ]
    static let defaultVoice = "zh-CN-XiaoxiaoNeural"

    /// Voice for an article: the chosen Chinese voice, or a same-gender voice for other languages.
    static func voice(for language: String, chosen: String) -> String {
        let male = voices.first { $0.id == chosen }?.male ?? false
        switch language {
        case let l where l.hasPrefix("zh"): return chosen
        case let l where l.hasPrefix("en"): return male ? "en-US-AndrewNeural" : "en-US-AvaNeural"
        case let l where l.hasPrefix("ja"): return male ? "ja-JP-KeitaNeural" : "ja-JP-NanamiNeural"
        case let l where l.hasPrefix("ko"): return male ? "ko-KR-InJoonNeural" : "ko-KR-SunHiNeural"
        default: return male ? "en-US-AndrewMultilingualNeural" : "en-US-AvaMultilingualNeural"
        }
    }

    static let trusted = "6A5AA1D4EAFF4E9FB37E23D68491D6F4"
    static let chromium = "143.0.3650.75"
    private static let muid: String = (0..<16).map { _ in String(format: "%02X", UInt8.random(in: 0...255)) }.joined()

    struct Failure: Error {}

    /// MP3 audio for one piece of text. rate in percent (-50...50), pitch in Hz.
    static func synthesize(_ text: String, voice: String, rate: Int, pitch: Int) async throws -> Data {
        try await withThrowingTaskGroup(of: Data.self) { g in
            g.addTask { try await run(text, voice: voice, rate: rate, pitch: pitch) }
            g.addTask { try await Task.sleep(nanoseconds: 25_000_000_000); throw Failure() }
            let d = try await g.next()!
            g.cancelAll()
            return d
        }
    }

    private static func run(_ text: String, voice: String, rate: Int, pitch: Int) async throws -> Data {
        let cid = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        var c = URLComponents(string: "wss://speech.platform.bing.com/consumer/speech/synthesize/readaloud/edge/v1")!
        c.queryItems = [
            URLQueryItem(name: "TrustedClientToken", value: trusted),
            URLQueryItem(name: "ConnectionId", value: cid),
            URLQueryItem(name: "Sec-MS-GEC", value: EdgeGEC.token()),
            URLQueryItem(name: "Sec-MS-GEC-Version", value: "2-\(chromium)"),
        ]
        var req = URLRequest(url: c.url!)
        let major = chromium.split(separator: ".").first ?? "143"
        req.setValue("no-cache", forHTTPHeaderField: "Pragma")
        req.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        req.setValue("chrome-extension://jdiccldimpdaibmpdkjnbmckianbfold", forHTTPHeaderField: "Origin")
        req.setValue("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/\(major).0.0.0 Safari/537.36 Edg/\(major).0.0.0", forHTTPHeaderField: "User-Agent")
        req.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        req.setValue("muid=\(muid);", forHTTPHeaderField: "Cookie")
        let task = URLSession.shared.webSocketTask(with: req)
        task.resume()
        defer { task.cancel(with: .normalClosure, reason: nil) }

        let ts = timestamp()
        let config = "X-Timestamp:\(ts)\r\nContent-Type:application/json; charset=utf-8\r\nPath:speech.config\r\n\r\n"
            + "{\"context\":{\"synthesis\":{\"audio\":{\"metadataoptions\":{\"sentenceBoundaryEnabled\":\"false\",\"wordBoundaryEnabled\":\"false\"},\"outputFormat\":\"audio-24khz-48kbitrate-mono-mp3\"}}}}\r\n"
        try await task.send(.string(config))
        let lang = voice.split(separator: "-").prefix(2).joined(separator: "-")
        let ssml = "<speak version='1.0' xmlns='http://www.w3.org/2001/10/synthesis' xml:lang='\(lang)'><voice name='\(voice)'>"
            + "<prosody pitch='\(pitch >= 0 ? "+" : "")\(pitch)Hz' rate='\(rate >= 0 ? "+" : "")\(rate)%' volume='+0%'>\(escape(text))</prosody></voice></speak>"
        let rid = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        try await task.send(.string("X-RequestId:\(rid)\r\nContent-Type:application/ssml+xml\r\nX-Timestamp:\(ts)Z\r\nPath:ssml\r\n\r\n\(ssml)"))

        var audio = Data()
        while true {
            switch try await task.receive() {
            case .string(let s):
                if s.contains("Path:turn.end") {
                    if audio.isEmpty { throw Failure() }
                    return audio
                }
            case .data(let d):
                let b = [UInt8](d)
                guard b.count >= 2 else { continue }
                let hl = Int(b[0]) << 8 | Int(b[1])
                guard b.count >= 2 + hl else { continue }
                let header = String(decoding: b[2..<(2 + hl)], as: UTF8.self)
                if header.contains("Path:audio") { audio.append(contentsOf: b[(2 + hl)...]) }
            @unknown default: break
            }
        }
    }

    private static func timestamp() -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "EEE MMM dd yyyy HH:mm:ss"
        return f.string(from: Date()) + " GMT+0000 (Coordinated Universal Time)"
    }

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "'", with: "&apos;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    /// Splits text at sentence ends; the first piece is short so speech starts quickly.
    static func chunks(_ text: String) -> [String] {
        var out: [String] = []
        var cur = ""
        let enders: Set<Character> = ["。", "！", "？", "；", "!", "?", ";", "\n", "."]
        for ch in text {
            cur.append(ch)
            let limit = out.isEmpty ? 120 : 900
            if (enders.contains(ch) && cur.count >= limit / 3) || cur.count >= limit {
                let t = cur.trimmingCharacters(in: .whitespacesAndNewlines)
                if !t.isEmpty { out.append(t) }
                cur = ""
            }
        }
        let t = cur.trimmingCharacters(in: .whitespacesAndNewlines)
        if !t.isEmpty { out.append(t) }
        return out
    }
}

/// Sec-MS-GEC v2 token, ported from edge-tts drm.py.
enum EdgeGEC {
    private typealias C = GECConst
    private static func rotr(_ x: UInt32, _ n: UInt32) -> UInt32 { (x >> n) | (x << (32 - n)) }
    private static func rol16(_ x: UInt32) -> UInt32 { (x << 16) | (x >> 16) }
    private static func s0(_ v: UInt32) -> UInt32 { (v >> 7) ^ (v << 25) ^ (v >> 18) ^ (v << 14) ^ (v >> 3) }
    private static func s1(_ v: UInt32) -> UInt32 { (v >> 17) ^ (v << 15) ^ (v >> 19) ^ (v << 13) ^ (v >> 10) }

    private static func rounds(_ st: [UInt32], _ w: [UInt32], _ first: Int, _ k: [UInt32]) -> [UInt32] {
        var a = st[0], b = st[1], c = st[2], d = st[3], e = st[4], f = st[5], g = st[6], h = st[7]
        for i in first..<64 {
            let S1 = rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25)
            let ch = g ^ (e & (f ^ g))
            let t1 = h &+ S1 &+ ch &+ k[i] &+ w[i]
            let S0 = rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22)
            let mj = (a & b) | (c & (a | b))
            let t2 = S0 &+ mj
            h = g; g = f; f = e; e = d &+ t1; d = c; c = b; b = a; a = t1 &+ t2
        }
        return [a, b, c, d, e, f, g, h]
    }
    private static func expand(_ w: inout [UInt32], from first: Int = 16) {
        for i in first..<64 { w.append(s1(w[i - 2]) &+ w[i - 7] &+ s0(w[i - 15]) &+ w[i - 16]) }
    }
    private static func be(_ b: ArraySlice<UInt8>) -> UInt32 { b.reduce(0) { ($0 << 8) | UInt32($1) } }

    private static func initState(_ data: [UInt8]) -> [UInt32] {
        var w = [UInt32](repeating: 0, count: 14) + [be(data[0..<3]), be(data[3..<7])]
        for i in 16..<30 {
            var v = C.schedule[i - 16]
            if i - 2 >= 14 { v = v &+ (i == 16 ? (s1(w[i - 2]) ^ C.sigma1Adj) : s1(w[i - 2])) }
            if i - 7 >= 14 { v = v &+ w[i - 7] }
            if i - 15 >= 14 { v = v &+ (i == 29 ? (s0(w[i - 15]) ^ C.sigma0Adj) : s0(w[i - 15])) }
            w.append(v)
        }
        w.append(s1(w[28]) &+ w[23] &+ s0(w[15]) &+ w[14] &+ C.adj &- C.k[14])
        expand(&w, from: 31)
        let wk = rounds(C.state, w, 14, C.blockK)
        return zip(C.initial, wk).map { $0 &+ $1 }
    }

    static func sha(_ data: [UInt8]) -> [UInt8] {
        let length = 57 + data.count
        var p = Array(data[7...]) + [0x80]
        let zeros = ((55 - length) % 64 + 64) % 64
        p += [UInt8](repeating: 0, count: zeros)
        let bits = UInt64(length * 8)
        p += (0..<8).reversed().map { UInt8((bits >> (UInt64($0) * 8)) & 0xFF) }
        var st = initState(data)
        var o = 0
        while o < p.count {
            var w = (0..<16).map { be(p[(o + $0 * 4)..<(o + $0 * 4 + 4)]) }
            expand(&w)
            let wk = rounds(st, w, 0, C.k)
            st = zip(st, wk).map { $0 &+ $1 }
            o += 64
        }
        return st.flatMap { v in [UInt8(v >> 24), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)] }
    }

    private static func le(_ b: [UInt8], _ i: Int) -> UInt32 {
        UInt32(b[i]) | UInt32(b[i + 1]) << 8 | UInt32(b[i + 2]) << 16 | UInt32(b[i + 3]) << 24
    }

    static func cs64(_ data: [UInt8], _ digest: [UInt8]) -> (UInt32, UInt32) {
        let keyA = le(digest, 0) | 1, keyB = le(digest, 4) | 1
        let factors = [keyA &* C.cs64Factor, keyB &* C.cs64Factor]
        var terms = C.cs64Coef.enumerated().map { $1 &* factors[$0 % 2] }
        var offsets = C.cs64Off
        var padded = [0] + data
        while padded.count % 4 != 0 { padded.append(0) }
        var words = stride(from: 0, to: padded.count, by: 4).map { le(padded, $0) }
        if words.count % 2 == 1 { words.append(0) }
        for (i, word) in words.enumerated() {
            var term = word &* (i % 2 == 0 ? keyA : keyB)
            var off = rol16(word) &* (i % 2 == 0 ? 0xEF0569FB : 0xC31713DB)
            if i == 0 { term = term &+ C.cs64Adj0 &* factors[0]; off = off &+ C.cs64Adj1 }
            terms.append(term); offsets.append(off)
        }
        var swapAcc: UInt32 = 0, swapLast: UInt32 = 0, state: UInt32 = 0, acc: UInt32 = 0
        var i = 0
        while i < terms.count {
            let x = terms[i], y = terms[i + 1]
            var t = rol16(offsets[i] &+ x)
            var q = t &* 0x76F50F34
            swapAcc = swapAcc &+ (rol16(q) &* 0xC3EFEA97 &+ q)
            t = rol16(offsets[i + 1] &+ y)
            q = t &* 0x1881CE3C
            swapLast = rol16(q) &* 0x35BD1EC9 &+ q
            swapAcc = swapAcc &+ swapLast
            state = state &* keyA &+ x
            state = rol16(state) &* 0xCF98B111
            state = rol16(state) &* 0x87085B9F
            state = rol16(state) &* 0x12CEB96D
            state = rol16(state) &* 0x257E1D83
            acc = acc &+ state
            t = state &* keyB &+ y
            t = rol16(t) &* 0xA27416F5
            t = rol16(t) &* 0xD38396FF
            state = rol16(rol16(t) &* 0x7C932B89) &* 0xBFA49F69
            acc = acc &+ state
            i += 2
        }
        return (swapLast ^ state, swapAcc ^ acc)
    }

    static func token(unix: Double = Date().timeIntervalSince1970) -> String {
        var s = Int64(unix.rounded(.down)) + 11_644_473_600
        s -= s % 300
        let data = Array("\(s * 10_000_000)\(EdgeTTS.trusted)".utf8)
        let d = sha(data)
        let (a, b) = cs64(data, d)
        func leHex(_ v: UInt32) -> String { (0..<4).map { String(format: "%02X", (v >> (UInt32($0) * 8)) & 0xFF) }.joined() }
        return leHex(a) + leHex(b) + "-" + d.map { String(format: "%02X", $0) }.joined()
    }
}

// Generated from edge-tts drm.py (Sec-MS-GEC v2).
enum GECConst {
    static let initial: [UInt32] = [
        0x6A09E667, 0xBB67AE85, 0x3C6EF372, 0xA54FF53A, 0x510E527F, 0x9B05688C,
        0x1F83D9AB, 0x5BE0CD19]
    static let state: [UInt32] = [
        0xFD9FBEA2, 0x91243CE7, 0xBE499094, 0xCD2E1E0A, 0x6C006F49, 0x04BD35AB,
        0xFEB0A7E4, 0x03EFFBD2]
    static let schedule: [UInt32] = [
        0xEB24BF9E, 0x1558691F, 0xA0C09EE2, 0x0CFA32BA, 0xA622EE8C, 0xD1DD9491,
        0xC0DD25A0, 0xF9E70AB6, 0xF0C31573, 0x7058CE4E, 0x7188E606, 0x00E5AB33,
        0xD258B060, 0x72766564]
    static let k: [UInt32] = [
        0x428A2F98, 0x71374491, 0xB5C0FBCF, 0xE9B5DBA5, 0x3956C25B, 0x59F111F1,
        0x923F82A4, 0xAB1C5ED5, 0xD807AA98, 0x12835B01, 0x243185BE, 0x550C7DC3,
        0x72BE5D74, 0x80DEB1FE, 0x9BDC06A7, 0xC19BF174, 0xE49B69C1, 0xEFBE4786,
        0x0FC19DC6, 0x240CA1CC, 0x2DE92C6F, 0x4A7484AA, 0x5CB0A9DC, 0x76F988DA,
        0x983E5152, 0xA831C66D, 0xB00327C8, 0xBF597FC7, 0xC6E00BF3, 0xD5A79147,
        0x06CA6351, 0x14292967, 0x27B70A85, 0x2E1B2138, 0x4D2C6DFC, 0x53380D13,
        0x650A7354, 0x766A0ABB, 0x81C2C92E, 0x92722C85, 0xA2BFE8A1, 0xA81A664B,
        0xC24B8B70, 0xC76C51A3, 0xD192E819, 0xD6990624, 0xF40E3585, 0x106AA070,
        0x19A4C116, 0x1E376C08, 0x2748774C, 0x34B0BCB5, 0x391C0CB3, 0x4ED8AA4A,
        0x5B9CCA4F, 0x682E6FF3, 0x748F82EE, 0x78A5636F, 0x84C87814, 0x8CC70208,
        0x90BEFFFA, 0xA4506CEB, 0xBEF9A3F7, 0xC67178F2]
    static let blockK: [UInt32] = [
        0x428A2F98, 0x71374491, 0xB5C0FBCF, 0xE9B5DBA5, 0x3956C25B, 0x59F111F1,
        0x923F82A4, 0xAB1C5ED5, 0xD807AA98, 0x12835B01, 0x243185BE, 0x550C7DC3,
        0x72BE5D74, 0x80DEB1FE, 0xC9DC06A7, 0xC19BF174, 0xE49B69C1, 0xEFBE4786,
        0x0FC19DC6, 0x240CA1CC, 0x2DE92C6F, 0x4A7484AA, 0x5CB0A9DC, 0x76F988DA,
        0x983E5152, 0xA831C66D, 0xB00327C8, 0xBF597FC7, 0xC6E00BF3, 0xD5A79147,
        0x06CA6351, 0x14292967, 0x27B70A85, 0x2E1B2138, 0x4D2C6DFC, 0x53380D13,
        0x650A7354, 0x766A0ABB, 0x81C2C92E, 0x92722C85, 0xA2BFE8A1, 0xA81A664B,
        0xC24B8B70, 0xC76C51A3, 0xD192E819, 0xD6990624, 0xF40E3585, 0x106AA070,
        0x19A4C116, 0x1E376C08, 0x2748774C, 0x34B0BCB5, 0x391C0CB3, 0x4ED8AA4A,
        0x5B9CCA4F, 0x682E6FF3, 0x748F82EE, 0x78A5636F, 0x84C87814, 0x8CC70208,
        0x90BEFFFA, 0xA4506CEB, 0xBEF9A3F7, 0xC67178F2]
    static let cs64Coef: [UInt32] = [
        0xE82E91B1, 0x44DE24C6, 0x3BEB65BC, 0xC89C5933, 0x8D1EC211, 0x314EF5D5,
        0xE92491B1, 0xF0A5B9D5, 0x06064CF3, 0xDA79FA60, 0xBED20560, 0x89F9C9F8,
        0x35FA38C6, 0xCB49E3C6]
    static let cs64Off: [UInt32] = [
        0xB32700D0, 0x88DFF51D, 0x29514038, 0xB328CBDF, 0xD405B4D5, 0x26E55F3C,
        0x607801C6, 0x82B2C1FB, 0xFA51A3DA, 0x207CC464, 0x3C3C74F3, 0xD2D14B61,
        0xBB04A2C1, 0xC5626167]
    static let sigma1Adj: UInt32 = 0x000B92C0
    static let sigma0Adj: UInt32 = 0x059C0B80
    static let adj: UInt32 = 0xC9DC06A7
    static let cs64Factor: UInt32 = 0x82893933
    static let cs64Adj0: UInt32 = 0xF2F90B1A
    static let cs64Adj1: UInt32 = 0x0B1A0000
}
