import Foundation
import Network

/// Blu-ray / DVD ISO on a drive: read the UDF file system with HTTP range requests, find the main
/// movie (largest .m2ts in BDMV/STREAM, or largest .vob for DVD) and serve just that file through a
/// local HTTP proxy, so VLC/MPV play it like a plain .m2ts.
enum IsoError: Error { case bad(String) }

private struct Ext { var off: Int64; var len: Int64 }   // byte range inside the ISO

final class IsoReader {
    let url: URL; let headers: [String: String]
    init(url: URL, headers: [String: String]) { self.url = url; self.headers = headers }

    func read(_ off: Int64, _ len: Int) async throws -> Data {
        if url.isFileURL {
            let h = try FileHandle(forReadingFrom: url); defer { try? h.close() }
            try h.seek(toOffset: UInt64(off)); return h.readData(ofLength: len)
        }
        var r = URLRequest(url: url, timeoutInterval: 30)
        for (k, v) in headers { r.setValue(v, forHTTPHeaderField: k) }
        r.setValue("bytes=\(off)-\(off + Int64(len) - 1)", forHTTPHeaderField: "Range")
        let (d, resp) = try await URLSession.shared.data(for: r)
        if let h = resp as? HTTPURLResponse, h.statusCode == 200, off > 0 {
            // server ignored Range: slice what we asked for (only sane for small files)
            guard d.count >= Int(off) + len else { throw IsoError.bad("服务器不支持分段读取") }
            return d.subdata(in: Int(off)..<Int(off) + len)
        }
        return d
    }
}

private extension Data {
    func u8(_ o: Int) -> Int { o < count ? Int(self[startIndex + o]) : 0 }
    func u16(_ o: Int) -> Int { u8(o) | u8(o + 1) << 8 }
    func u32(_ o: Int) -> Int64 { Int64(u16(o)) | Int64(u16(o + 2)) << 16 }
    func u64(_ o: Int) -> Int64 { u32(o) | u32(o + 4) << 32 }
}

final class UDF {
    let r: IsoReader
    static let S = 2048
    private var physStart: Int64 = 0                 // physical partition start sector
    private var maps: [(meta: Bool, metaFile: Int64)] = []
    private var metaExts: [Ext] = []                 // metadata partition → ISO bytes
    init(_ r: IsoReader) { self.r = r }

    private func sector(_ n: Int64, count: Int = 1) async throws -> Data { try await r.read(n * Int64(Self.S), count * Self.S) }

    /// Byte offset in the ISO of logical block `lbn` in partition map `p`.
    private func addr(_ p: Int, _ lbn: Int64) throws -> Int64 {
        if p < maps.count, maps[p].meta {
            var pos = lbn * Int64(Self.S)
            for e in metaExts { if pos < e.len { return e.off + pos }; pos -= e.len }
            throw IsoError.bad("元数据越界")
        }
        return (physStart + lbn) * Int64(Self.S)
    }

    struct Entry { var exts: [Ext]; var size: Int64; var data: Data? }

    private func entry(at off: Int64, part: Int) async throws -> Entry {
        let d = try await r.read(off, Self.S)
        let tag = d.u16(0)
        let (lea, lad, base): (Int, Int, Int)
        if tag == 261 { (lea, lad, base) = (Int(d.u32(168)), Int(d.u32(172)), 176) }
        else if tag == 266 { (lea, lad, base) = (Int(d.u32(208)), Int(d.u32(212)), 216) }
        else { throw IsoError.bad("不是 UDF 文件项 (\(tag))") }
        let size = d.u64(56)
        let kind = d.u16(34) & 7
        let start = base + lea
        if kind == 3 { return Entry(exts: [], size: size, data: d.subdata(in: d.startIndex + start ..< d.startIndex + min(d.count, start + lad))) }
        var exts: [Ext] = []
        var o = start
        let step = kind == 0 ? 8 : 16
        // Like libudfread: directories stay in their (metadata) partition, file data is in the physical one.
        let isDir = d.u8(27) == 4
        let phys = maps.firstIndex { !$0.meta } ?? 0
        let shortPart = isDir ? part : phys
        while o + step <= start + lad {
            let rawLen = d.u32(o); let len = rawLen & 0x3FFF_FFFF; let typ = rawLen >> 30
            if len == 0 { break }
            if typ == 3 { break }       // continuation – not needed for the files we read
            let lbn = d.u32(o + 4)
            let p = kind == 0 ? shortPart : (isDir ? d.u16(o + 8) : phys)
            if typ == 0 { exts.append(Ext(off: try addr(p, lbn), len: len)) }
            o += step
        }
        return Entry(exts: exts, size: size, data: nil)
    }

    private func readAll(_ e: Entry) async throws -> Data {
        if let d = e.data { return d }
        var out = Data()
        for x in e.exts { out.append(try await r.read(x.off, Int(x.len))) }
        return out.prefix(Int(e.size))
    }

    struct Item { var name: String; var dir: Bool; var off: Int64; var part: Int }

    private func list(_ dir: Entry) async throws -> [Item] {
        let d = try await readAll(dir)
        var o = 0, out: [Item] = []
        while o + 38 <= d.count {
            guard d.u16(o) == 257 else { break }
            let ch = d.u8(o + 18), lfi = d.u8(o + 19), liu = d.u16(o + 36)
            let lbn = d.u32(o + 24), part = d.u16(o + 28)
            let nameStart = o + 38 + liu
            var name = ""
            if lfi > 1 {
                let raw = d.subdata(in: d.startIndex + nameStart + 1 ..< d.startIndex + nameStart + lfi)
                name = d.u8(nameStart) == 16 ? (String(data: raw, encoding: .utf16BigEndian) ?? "") : (String(data: raw, encoding: .isoLatin1) ?? "")
            }
            if ch & 8 == 0, !name.isEmpty { out.append(Item(name: name, dir: ch & 2 != 0, off: try addr(part, lbn), part: part)) }
            o += (38 + liu + lfi + 3) & ~3
        }
        return out
    }

    /// The main title's byte ranges inside the ISO.
    func mainTitle() async throws -> (name: String, exts: [Ext], size: Int64) {
        let avdp = try await sector(256)
        guard avdp.u16(0) == 2 else { throw IsoError.bad("不是 UDF 镜像（可能是旧式 ISO9660）") }
        let vdsLen = Int(avdp.u32(16)), vdsLoc = avdp.u32(20)
        let vds = try await sector(vdsLoc, count: max(1, min(32, vdsLen / Self.S)))
        var fsd: (Int64, Int) = (0, 0)
        var mapData = Data()
        for i in 0 ..< vds.count / Self.S {
            let s = vds.subdata(in: vds.startIndex + i * Self.S ..< vds.startIndex + (i + 1) * Self.S)
            switch s.u16(0) {
            case 5: physStart = s.u32(188)
            case 6:
                fsd = (s.u32(252), s.u16(256))
                let mtl = Int(s.u32(264))
                mapData = s.subdata(in: s.startIndex + 440 ..< s.startIndex + min(Self.S, 440 + mtl))
            case 8: break
            default: continue
            }
        }
        var o = 0
        while o + 2 <= mapData.count {
            let t = mapData.u8(o), l = mapData.u8(o + 1)
            if l == 0 { break }
            if t == 2, let id = String(data: mapData.subdata(in: mapData.startIndex + o + 5 ..< mapData.startIndex + o + 28), encoding: .ascii), id.contains("Metadata") {
                maps.append((true, mapData.u32(o + 40)))
            } else { maps.append((false, 0)) }
            o += l
        }
        if let mi = maps.firstIndex(where: { $0.meta }) {
            let phys = maps.firstIndex { !$0.meta } ?? 0
            let mf = try await entry(at: try addr(phys, maps[mi].metaFile), part: phys)
            metaExts = mf.exts
        }
        let fsdSec = try await r.read(try addr(fsd.1, fsd.0), Self.S)
        guard fsdSec.u16(0) == 256 else { throw IsoError.bad("找不到 UDF 文件集") }
        let root = try await entry(at: try addr(fsdSec.u16(408), fsdSec.u32(404)), part: fsdSec.u16(408))
        let top = try await list(root)
        func child(_ items: [Item], _ n: String) -> Item? { items.first { $0.dir && $0.name.uppercased() == n } }
        var cands: [Item] = []
        if let bd = child(top, "BDMV"), case let bdl = try await list(try await entry(at: bd.off, part: bd.part)),
           let st = child(bdl, "STREAM") {
            cands = try await list(try await entry(at: st.off, part: st.part)).filter { $0.name.lowercased().hasSuffix(".m2ts") }
        } else if let vt = child(top, "VIDEO_TS") {
            cands = try await list(try await entry(at: vt.off, part: vt.part)).filter { $0.name.uppercased().hasSuffix(".VOB") }
        }
        guard !cands.isEmpty else { throw IsoError.bad("镜像里没找到 BDMV/STREAM 或 VIDEO_TS") }
        var best: (Item, Entry)?
        for c in cands {
            let e = try await entry(at: c.off, part: c.part)
            if best == nil || e.size > best!.1.size { best = (c, e) }
        }
        guard let (it, e) = best, !e.exts.isEmpty else { throw IsoError.bad("正片文件为空") }
        return (it.name, e.exts, e.size)
    }
}

/// Serves the main title of an ISO as http://127.0.0.1:port/iso/<id>.m2ts with byte ranges.
final class IsoServer {
    static let shared = IsoServer()
    private struct Src { let reader: IsoReader; let exts: [Ext]; let size: Int64 }
    private var srcs: [String: Src] = [:]
    private var listener: NWListener?
    private var port: UInt16 = 0
    private let lock = NSLock()
    private let q = DispatchQueue(label: "iso.net", attributes: .concurrent)

    func open(_ p: PlayableMedia) async throws -> PlayableMedia {
        let rd = IsoReader(url: p.url, headers: p.headers)
        let t = try await UDF(rd).mainTitle()
        let id = UUID().uuidString.prefix(8).lowercased()
        let port = try await start()
        lock.lock(); srcs[String(id)] = Src(reader: rd, exts: t.exts, size: t.size); lock.unlock()
        var out = PlayableMedia(url: URL(string: "http://127.0.0.1:\(port)/iso/\(id).\(t.name.lowercased().hasSuffix(".vob") ? "vob" : "m2ts")")!, title: p.title, resumeKey: p.resumeKey)
        out.subtitleFiles = p.subtitleFiles
        return out
    }

    private func start() async throws -> UInt16 {
        lock.lock(); if listener != nil, port != 0 { let p = port; lock.unlock(); return p }; lock.unlock()
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
                    let p = l.port?.rawValue ?? 0; self?.port = p; cont.resume(returning: p)
                case .failed(let e):
                    self?.listener = nil; self?.port = 0
                    guard !done else { return }; done = true; cont.resume(throwing: e)
                default: break
                }
            }
            listener = l
            l.start(queue: q)
        }
    }

    private func handle(_ c: NWConnection) {
        c.start(queue: q)
        c.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, _, _ in
            guard let self, let data, let req = String(data: data, encoding: .utf8) else { c.cancel(); return }
            let lines = req.components(separatedBy: "\r\n")
            let parts = lines.first?.split(separator: " ") ?? []
            guard parts.count >= 2 else { c.cancel(); return }
            let head = parts[0] == "HEAD"
            let id = String(parts[1].split(separator: "/").last?.split(separator: ".").first ?? "")
            self.lock.lock(); let s = self.srcs[id]; self.lock.unlock()
            guard let s else {
                c.send(content: Data("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8), completion: .contentProcessed { _ in c.cancel() }); return
            }
            var a: Int64 = 0, b: Int64 = s.size - 1, ranged = false
            if let r = lines.first(where: { $0.lowercased().hasPrefix("range:") }), let eq = r.firstIndex(of: "=") {
                let spec = r[r.index(after: eq)...].trimmingCharacters(in: .whitespaces).split(separator: "-", omittingEmptySubsequences: false)
                if let x = Int64(spec.first ?? "") { a = x; ranged = true }
                if spec.count > 1, let y = Int64(spec[1]) { b = min(y, s.size - 1) }
            }
            guard a < s.size else {
                c.send(content: Data("HTTP/1.1 416 Range Not Satisfiable\r\nContent-Range: bytes */\(s.size)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8), completion: .contentProcessed { _ in c.cancel() }); return
            }
            let h = "HTTP/1.1 \(ranged ? "206 Partial Content" : "200 OK")\r\nContent-Type: video/mp2t\r\nContent-Length: \(b - a + 1)\r\nAccept-Ranges: bytes\r\n"
                + (ranged ? "Content-Range: bytes \(a)-\(b)/\(s.size)\r\n" : "") + "Connection: close\r\n\r\n"
            c.send(content: Data(h.utf8), completion: .contentProcessed { err in
                if err != nil || head { c.cancel(); return }
                Task.detached { await self.pump(c, s, a, b) }
            })
        }
    }

    /// Stream [a, b] of the virtual file in 2 MB pieces; stops when the player hangs up (seek/close).
    private func pump(_ c: NWConnection, _ s: Src, _ a: Int64, _ b: Int64) async {
        var pos = a
        while pos <= b {
            // map virtual pos → ISO offset
            var v = pos, iso: Int64 = -1, room: Int64 = 0
            for e in s.exts { if v < e.len { iso = e.off + v; room = e.len - v; break }; v -= e.len }
            if iso < 0 { break }
            let n = Int(min(room, b - pos + 1, 2 << 20))
            guard let d = try? await s.reader.read(iso, n), !d.isEmpty else { break }
            let ok: Bool = await withCheckedContinuation { cont in
                c.send(content: d, completion: .contentProcessed { e in cont.resume(returning: e == nil) })
            }
            if !ok { break }
            pos += Int64(d.count)
        }
        c.cancel()
    }
}
