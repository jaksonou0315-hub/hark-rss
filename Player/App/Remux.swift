import Foundation
import Network
import Libavformat
import Libavcodec
import Libavutil

/// Infuse-style path for files AVPlayer can't open itself (MKV, MP4 with HEVC tagged hev1):
/// FFmpeg demuxes the file, every ~4–6 s keyframe-aligned piece is re-wrapped (no re-encode) into fragmented MP4
/// (HEVC tagged hvc1/dvh1, Dolby Vision dvcC kept, E-AC-3/Atmos passed through) and served as a local HLS stream
/// on 127.0.0.1 to AVPlayer, which then draws Dolby Vision / HDR10 and sends Atmos the system way.
enum RemuxError: LocalizedError {
    case open, noVideo, codec, audio, index
    var errorDescription: String? {
        switch self {
        case .open: return "重封装：打不开文件"
        case .noVideo: return "重封装：没有视频轨"
        case .codec: return "重封装：视频编码不是 H.264/H.265"
        case .audio: return "重封装：音轨格式原生内核不支持"
        case .index: return "重封装：文件没有关键帧索引"
        }
    }
}

private let NOPTS = Int64.min
private func tag(_ s: String) -> UInt32 { s.utf8.enumerated().reduce(0) { $0 | (UInt32($1.element) << (8 * UInt32($1.offset))) } }

private final class Sink { var data = Data() }

/// One fragmented-MP4 writer (FFmpeg mov muxer into memory). Writes ftyp+moov+moof+mdat; callers split at the first moof.
private final class FragMuxer {
    var ctx: UnsafeMutablePointer<AVFormatContext>?
    let sink = Sink()
    var pb: UnsafeMutablePointer<AVIOContext>?
    var inTB: [AVRational] = []

    init?(streams: [UnsafeMutablePointer<AVStream>], videoTag: UInt32) {
        guard avformat_alloc_output_context2(&ctx, nil, "mp4", nil) >= 0, let ctx else { return nil }
        for (i, ist) in streams.enumerated() {
            guard let os = avformat_new_stream(ctx, nil) else { cleanup(); return nil }
            avcodec_parameters_copy(os.pointee.codecpar, ist.pointee.codecpar)
            os.pointee.codecpar.pointee.codec_tag = i == 0 ? videoTag : 0
            os.pointee.time_base = ist.pointee.time_base
            inTB.append(ist.pointee.time_base)
        }
        let size: Int32 = 1 << 16
        guard let buf = av_malloc(Int(size)) else { cleanup(); return nil }
        pb = avio_alloc_context(buf.assumingMemoryBound(to: UInt8.self), size, 1,
                                Unmanaged.passUnretained(sink).toOpaque(), nil,
                                { opaque, b, n in
                                    guard let opaque, let b, n > 0 else { return n }
                                    Unmanaged<Sink>.fromOpaque(opaque).takeUnretainedValue().data.append(b, count: Int(n))
                                    return n
                                }, nil)
        guard pb != nil else { av_free(buf); cleanup(); return nil }
        ctx.pointee.pb = pb
        ctx.pointee.flags |= 0x0080 // AVFMT_FLAG_CUSTOM_IO
        ctx.pointee.strict_std_compliance = -1 // FF_COMPLIANCE_UNOFFICIAL: write Dolby Vision dvcC
        ctx.pointee.avoid_negative_ts = 0 // keep the file's own timestamps: every piece lands at its real time
        var opts: OpaquePointer?
        av_dict_set(&opts, "movflags", "+empty_moov+delay_moov+frag_custom+default_base_moof+frag_discont+skip_trailer", 0)
        av_dict_set(&opts, "use_editlist", "0", 0)
        let r = avformat_write_header(ctx, &opts)
        av_dict_free(&opts)
        if r < 0 { cleanup(); return nil }
    }

    func write(_ p: UnsafeMutablePointer<AVPacket>, _ idx: Int32) {
        guard let ctx, let os = ctx.pointee.streams[Int(idx)] else { return }
        p.pointee.stream_index = idx
        av_packet_rescale_ts(p, inTB[Int(idx)], os.pointee.time_base)
        p.pointee.pos = -1
        av_write_frame(ctx, p)
    }

    func finish() -> Data {
        guard let ctx else { return Data() }
        av_write_frame(ctx, nil)
        av_write_trailer(ctx)
        avio_flush(pb)
        let d = sink.data
        cleanup()
        return d
    }

    private func cleanup() {
        if let pb {
            av_free(pb.pointee.buffer)
            var p: UnsafeMutablePointer<AVIOContext>? = pb
            avio_context_free(&p)
            self.pb = nil
        }
        if let ctx { avformat_free_context(ctx); self.ctx = nil }
    }
    deinit { cleanup() }

    /// Offset of the first top-level `moof` box.
    static func moofOffset(_ d: Data) -> Int? {
        var o = 0
        let b = [UInt8](d)
        while o + 8 <= b.count {
            var size = Int(b[o]) << 24 | Int(b[o+1]) << 16 | Int(b[o+2]) << 8 | Int(b[o+3])
            let type = String(bytes: b[(o+4)..<(o+8)], encoding: .ascii) ?? ""
            if type == "moof" { return o }
            if size == 1, o + 16 <= b.count { size = b[(o+8)..<(o+16)].reduce(0) { $0 << 8 | Int($1) } }
            if size < 8 { return nil }
            o += size
        }
        return nil
    }
}

final class RemuxSession {
    let id = UUID().uuidString
    private var fmt: UnsafeMutablePointer<AVFormatContext>?
    private var vIdx: Int32 = -1, aIdx: Int32 = -1
    private var vTB = AVRational(num: 1, den: 1000), aTB = AVRational(num: 1, den: 1000)
    private var bounds: [Int64] = []     // segment boundaries in video time base (count = segments + 1)
    private var useDts = false
    private var videoTag: UInt32 = 0
    private var initData: Data?
    private var cache: [Int: Data] = [:]
    private var nextSeg = -1
    private var carry: [UnsafeMutablePointer<AVPacket>] = []
    private(set) var width = 0, height = 0
    private(set) var range = "SDR"
    private(set) var bandwidth = 20_000_000
    private(set) var dvProfile = 0
    let q = DispatchQueue(label: "remux.session")

    init(url: URL, headers: [String: String]) throws {
        var opts: OpaquePointer?
        if !headers.isEmpty {
            av_dict_set(&opts, "headers", headers.map { "\($0.key): \($0.value)\r\n" }.joined(), 0)
            if let ua = headers.first(where: { $0.key.lowercased() == "user-agent" })?.value { av_dict_set(&opts, "user_agent", ua, 0) }
        }
        av_dict_set(&opts, "rw_timeout", "20000000", 0)
        av_dict_set(&opts, "reconnect", "1", 0)
        av_dict_set(&opts, "probesize", "5000000", 0)
        av_dict_set(&opts, "analyzeduration", "3000000", 0)
        let path = url.isFileURL ? url.path : url.absoluteString
        var f: UnsafeMutablePointer<AVFormatContext>?
        let r = avformat_open_input(&f, path, nil, &opts)
        av_dict_free(&opts)
        guard r >= 0, let f else { throw RemuxError.open }
        fmt = f
        f.pointee.probesize = 5_000_000
        f.pointee.max_analyze_duration = 3_000_000
        avformat_find_stream_info(f, nil)
        useDts = String(cString: f.pointee.iformat.pointee.name).contains("mov")

        vIdx = av_find_best_stream(f, AVMEDIA_TYPE_VIDEO, -1, -1, nil, 0)
        guard vIdx >= 0, let vs = f.pointee.streams[Int(vIdx)] else { throw RemuxError.noVideo }
        let vp = vs.pointee.codecpar!
        vTB = vs.pointee.time_base
        width = Int(vp.pointee.width); height = Int(vp.pointee.height)
        switch vp.pointee.codec_id {
        case AV_CODEC_ID_H264: videoTag = tag("avc1")
        case AV_CODEC_ID_HEVC:
            videoTag = tag("hvc1")
            if let sd = av_packet_side_data_get(vp.pointee.coded_side_data, vp.pointee.nb_coded_side_data, AV_PKT_DATA_DOVI_CONF) {
                dvProfile = Int(sd.pointee.data.withMemoryRebound(to: AVDOVIDecoderConfigurationRecord.self, capacity: 1) { $0.pointee.dv_profile })
                if dvProfile == 5 { videoTag = tag("dvh1") }
                if dvProfile == 7 {
                    // dual-layer profile 7: AVPlayer can't do it; drop the DV record and play the HDR10 base layer
                    av_packet_side_data_remove(vp.pointee.coded_side_data, &vp.pointee.nb_coded_side_data, AV_PKT_DATA_DOVI_CONF)
                    dvProfile = 0
                }
            }
        default: throw RemuxError.codec
        }
        let trc = vp.pointee.color_trc
        if dvProfile > 0 || trc == AVCOL_TRC_SMPTE2084 { range = "PQ" } else if trc == AVCOL_TRC_ARIB_STD_B67 { range = "HLG" }
        if f.pointee.bit_rate > 0 { bandwidth = Int(f.pointee.bit_rate) }

        // audio: the default track if AVPlayer can play it, otherwise the best one it can (E-AC-3 first: Atmos)
        let ok: [UInt32: Int] = [AV_CODEC_ID_EAC3.rawValue: 6, AV_CODEC_ID_AC3.rawValue: 5, AV_CODEC_ID_AAC.rawValue: 4, AV_CODEC_ID_ALAC.rawValue: 3, AV_CODEC_ID_FLAC.rawValue: 2, AV_CODEC_ID_MP3.rawValue: 1, AV_CODEC_ID_OPUS.rawValue: 1]
        let best = av_find_best_stream(f, AVMEDIA_TYPE_AUDIO, -1, vIdx, nil, 0)
        var pick: Int32 = -1, score = 0
        if best >= 0, let s = f.pointee.streams[Int(best)], ok[s.pointee.codecpar.pointee.codec_id.rawValue] != nil { pick = best }
        else {
            for i in 0..<Int32(f.pointee.nb_streams) {
                guard let s = f.pointee.streams[Int(i)], s.pointee.codecpar.pointee.codec_type == AVMEDIA_TYPE_AUDIO,
                      let sc = ok[s.pointee.codecpar.pointee.codec_id.rawValue], sc > score else { continue }
                pick = i; score = sc
            }
        }
        var hasAudio = false
        for i in 0..<Int(f.pointee.nb_streams) where f.pointee.streams[i]?.pointee.codecpar.pointee.codec_type == AVMEDIA_TYPE_AUDIO { hasAudio = true }
        if hasAudio && pick < 0 { throw RemuxError.audio }
        aIdx = pick
        if aIdx >= 0, let a = f.pointee.streams[Int(aIdx)] { aTB = a.pointee.time_base }

        // keyframe index → segments of at least 4 s
        let n = avformat_index_get_entries_count(vs)
        var kfs: [Int64] = []
        for i in 0..<n {
            if let e = avformat_index_get_entry(vs, i), e.pointee.flags & 1 != 0, e.pointee.timestamp != NOPTS { kfs.append(e.pointee.timestamp) }
        }
        kfs.sort()
        guard kfs.count >= 2 else { throw RemuxError.index }
        let minLen = Int64(4.0 * Double(vTB.den) / Double(max(vTB.num, 1)))
        var b = [kfs[0]]
        for t in kfs.dropFirst() where t - b.last! >= minLen { b.append(t) }
        var end: Int64 = 0
        if vs.pointee.duration > 0, vs.pointee.duration != NOPTS {
            end = vs.pointee.duration + (vs.pointee.start_time == NOPTS ? 0 : vs.pointee.start_time)
        } else if f.pointee.duration > 0 {
            end = av_rescale_q(f.pointee.duration, AVRational(num: 1, den: 1_000_000), vTB) + (vs.pointee.start_time == NOPTS ? 0 : vs.pointee.start_time)
        }
        if end > b.last! + minLen / 4 { b.append(end) } else if b.count >= 2 { b[b.count - 1] = max(end, b.last!) } else { throw RemuxError.index }
        bounds = b
    }

    deinit {
        carry.forEach { var p: UnsafeMutablePointer<AVPacket>? = $0; av_packet_free(&p) }
        if fmt != nil { avformat_close_input(&fmt) }
    }

    var masterPlaylist: String {
        "#EXTM3U\n#EXT-X-VERSION:7\n#EXT-X-INDEPENDENT-SEGMENTS\n#EXT-X-STREAM-INF:BANDWIDTH=\(bandwidth),RESOLUTION=\(width)x\(height),VIDEO-RANGE=\(range)\nmedia.m3u8\n"
    }
    var mediaPlaylist: String {
        let sec = { (t: Int64) in Double(t) * Double(self.vTB.num) / Double(self.vTB.den) }
        var durs: [Double] = []
        for i in 0..<(bounds.count - 1) { durs.append(max(0.04, sec(bounds[i+1]) - sec(bounds[i]))) }
        var s = "#EXTM3U\n#EXT-X-VERSION:7\n#EXT-X-TARGETDURATION:\(Int((durs.max() ?? 6).rounded(.up)))\n#EXT-X-MEDIA-SEQUENCE:0\n#EXT-X-PLAYLIST-TYPE:VOD\n#EXT-X-INDEPENDENT-SEGMENTS\n#EXT-X-MAP:URI=\"init.mp4\"\n"
        for (i, d) in durs.enumerated() { s += String(format: "#EXTINF:%.3f,\n", d) + "seg\(i).m4s\n" }
        return s + "#EXT-X-ENDLIST\n"
    }

    /// init.mp4 (ftyp+moov): taken from the first piece, since E-AC-3/AC-3 need a packet before the moov can be written.
    func initSegment() -> Data? {
        if let initData { return initData }
        _ = segment(0)
        return initData
    }

    private func nextPacket() -> UnsafeMutablePointer<AVPacket>? {
        if !carry.isEmpty { return carry.removeFirst() }
        guard let p = av_packet_alloc() else { return nil }
        if av_read_frame(fmt, p) < 0 { var o: UnsafeMutablePointer<AVPacket>? = p; av_packet_free(&o); return nil }
        return p
    }
    private func free(_ p: UnsafeMutablePointer<AVPacket>) { var o: UnsafeMutablePointer<AVPacket>? = p; av_packet_free(&o) }
    private func time(_ p: UnsafeMutablePointer<AVPacket>, dts: Bool) -> Int64 {
        let a = dts ? p.pointee.dts : p.pointee.pts, b = dts ? p.pointee.pts : p.pointee.dts
        return a != NOPTS ? a : b
    }

    func segment(_ n: Int) -> Data? {
        if let d = cache[n] { return d }
        guard let fmt, n >= 0, n < bounds.count - 1, let vs = fmt.pointee.streams[Int(vIdx)] else { return nil }
        if n != nextSeg {
            carry.forEach { free($0) }; carry = []
            av_seek_frame(fmt, vIdx, bounds[n], 1) // AVSEEK_FLAG_BACKWARD
        }
        let start = bounds[n], end = bounds[n+1], last = n == bounds.count - 2
        var streams = [vs]
        if aIdx >= 0, let a = fmt.pointee.streams[Int(aIdx)] { streams.append(a) }
        var m0 = FragMuxer(streams: streams, videoTag: videoTag)
        if m0 == nil, videoTag == tag("dvh1") { videoTag = tag("hvc1"); m0 = FragMuxer(streams: streams, videoTag: videoTag) }
        guard let mux = m0 else { return nil }
        let aStart = aIdx >= 0 ? av_rescale_q(start, vTB, aTB) : 0
        let aEnd = aIdx >= 0 ? av_rescale_q(end, vTB, aTB) : 0
        var vStarted = false, vDone = false, aDone = aIdx < 0
        var newCarry: [UnsafeMutablePointer<AVPacket>] = []
        let tol = max(Int64(1), Int64(Double(vTB.den) / Double(max(vTB.num, 1)) / 100)) // 10 ms
        while !(vDone && aDone) {
            guard let p = nextPacket() else { break }
            let si = p.pointee.stream_index
            if si == vIdx {
                if vDone { newCarry.append(p); continue }
                let t = time(p, dts: useDts), key = p.pointee.flags & 1 != 0
                if !vStarted {
                    // after a seek: drop everything before this piece's own keyframe
                    if key && t >= start - tol { vStarted = true } else { free(p); continue }
                } else if !last && key && t >= end - tol { vDone = true; newCarry.append(p); continue }
                mux.write(p, 0); free(p)
            } else if si == aIdx {
                if aDone { newCarry.append(p); continue }
                let t = time(p, dts: false)
                if t < aStart { free(p); continue }
                if !last && t >= aEnd { aDone = true; newCarry.append(p); continue }
                mux.write(p, 1); free(p)
            } else { free(p) }
        }
        carry = newCarry + carry
        nextSeg = n + 1
        let d = mux.finish()
        guard let m = FragMuxer.moofOffset(d) else { return nil }
        if initData == nil { initData = d.prefix(m) }
        let seg = d.suffix(from: m)
        cache[n] = Data(seg)
        if cache.count > 4, let k = cache.keys.filter({ $0 != n }).min(by: { abs($0 - n) > abs($1 - n) }) { cache[k] = nil }
        return cache[n]
    }
}

/// Tiny HTTP server on 127.0.0.1 serving each session as /<id>/master.m3u8, media.m3u8, init.mp4, segN.m4s.
final class RemuxServer {
    static let shared = RemuxServer()
    private var listener: NWListener?
    private var port: UInt16 = 0
    private var sessions: [String: RemuxSession] = [:]
    private let lock = NSLock()
    private let netQ = DispatchQueue(label: "remux.net", attributes: .concurrent)

    /// Opens the file (blocking network I/O: call off the main thread) and returns the local playlist URL.
    func open(url: URL, headers: [String: String]) async throws -> (URL, String) {
        let s = try await Task.detached(priority: .userInitiated) { try RemuxSession(url: url, headers: headers) }.value
        let p = try await start()
        lock.lock(); sessions[s.id] = s; lock.unlock()
        return (URL(string: "http://127.0.0.1:\(p)/\(s.id)/master.m3u8")!, s.id)
    }
    func close(_ id: String) { lock.lock(); sessions[id] = nil; lock.unlock() }

    private func start() async throws -> UInt16 {
        if listener != nil, port != 0 { return port }
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let l = try NWListener(using: params)
        l.newConnectionHandler = { [weak self] c in self?.handle(c) }
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<UInt16, Error>) in
            var done = false
            l.stateUpdateHandler = { [weak self] st in
                switch st {
                case .ready:
                    guard !done else { return }; done = true
                    let p = l.port?.rawValue ?? 0
                    self?.port = p
                    cont.resume(returning: p)
                case .failed(let e):
                    self?.listener = nil; self?.port = 0
                    guard !done else { return }; done = true
                    cont.resume(throwing: e)
                default: break
                }
            }
            listener = l
            l.start(queue: netQ)
        }
    }

    private func handle(_ c: NWConnection) {
        c.start(queue: netQ)
        c.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, _, _ in
            guard let self, let data, let req = String(data: data, encoding: .utf8) else { c.cancel(); return }
            let lines = req.components(separatedBy: "\r\n")
            let parts = lines.first?.split(separator: " ") ?? []
            guard parts.count >= 2 else { c.cancel(); return }
            let head = parts[0] == "HEAD"
            let comps = parts[1].split(separator: "/").map(String.init)
            var range: (Int, Int?)?
            if let r = lines.first(where: { $0.lowercased().hasPrefix("range:") }),
               let eq = r.firstIndex(of: "=") {
                let spec = r[r.index(after: eq)...].trimmingCharacters(in: .whitespaces).split(separator: "-", omittingEmptySubsequences: false)
                if let a = Int(spec.first ?? "") { range = (a, spec.count > 1 ? Int(spec[1]) : nil) }
            }
            guard comps.count == 2 else { self.reply(c, 404, nil, "text/plain", head: head, range: nil); return }
            self.lock.lock(); let s = self.sessions[comps[0]]; self.lock.unlock()
            guard let s else { self.reply(c, 404, nil, "text/plain", head: head, range: nil); return }
            let name = comps[1]
            var body: Data?, type = "application/octet-stream"
            s.q.sync {
                if name == "master.m3u8" { body = Data(s.masterPlaylist.utf8); type = "application/vnd.apple.mpegurl" }
                else if name == "media.m3u8" { body = Data(s.mediaPlaylist.utf8); type = "application/vnd.apple.mpegurl" }
                else if name == "init.mp4" { body = s.initSegment(); type = "video/mp4" }
                else if name.hasPrefix("seg"), name.hasSuffix(".m4s"), let n = Int(name.dropFirst(3).dropLast(4)) { body = s.segment(n); type = "video/iso.segment" }
            }
            self.reply(c, body == nil ? 404 : 200, body, type, head: head, range: range)
        }
    }

    private func reply(_ c: NWConnection, _ code: Int, _ body: Data?, _ type: String, head: Bool, range: (Int, Int?)?) {
        var status = code == 200 ? "200 OK" : "404 Not Found"
        var payload = body ?? Data()
        var extra = ""
        if code == 200, let range, let b = body, range.0 < b.count {
            let e = min(range.1 ?? (b.count - 1), b.count - 1)
            payload = b.subdata(in: range.0..<(e + 1))
            status = "206 Partial Content"
            extra = "Content-Range: bytes \(range.0)-\(e)/\(b.count)\r\n"
        }
        let h = "HTTP/1.1 \(status)\r\nContent-Type: \(type)\r\nContent-Length: \(payload.count)\r\nAccept-Ranges: bytes\r\n\(extra)Connection: close\r\n\r\n"
        var out = Data(h.utf8)
        if !head { out.append(payload) }
        c.send(content: out, completion: .contentProcessed { _ in c.cancel() })
    }
}
