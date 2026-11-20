import Foundation
import SwiftUI

@MainActor
final class SourceStore: ObservableObject {
    static let shared = SourceStore()
    @Published private(set) var sources: [MediaSource] = []
    private var providers: [UUID: SourceProvider] = [:]

    private init() {
        if let d = Keychain.getData("sources"), let s = try? JSONDecoder().decode([MediaSource].self, from: d) {
            sources = s
        }
        if !sources.contains(where: { $0.kind == .local }) {
            sources.insert(MediaSource(kind: .local, name: "本机文件"), at: 0)
        }
    }

    private func save() {
        if let d = try? JSONEncoder().encode(sources) { Keychain.setData(d, for: "sources") }
    }

    func source(_ id: UUID) -> MediaSource? { sources.first { $0.id == id } }

    func upsert(_ s: MediaSource) {
        if let i = sources.firstIndex(where: { $0.id == s.id }) { sources[i] = s } else { sources.append(s) }
        providers[s.id] = nil
        save()
    }

    /// Called by providers when tokens are refreshed: keeps the cached provider.
    func updateCredentials(_ s: MediaSource) {
        if let i = sources.firstIndex(where: { $0.id == s.id }) { sources[i] = s; save() }
    }

    func remove(_ s: MediaSource) {
        sources.removeAll { $0.id == s.id }
        providers[s.id] = nil
        save()
    }

    func move(from: IndexSet, to: Int) { sources.move(fromOffsets: from, toOffset: to); save() }

    func provider(for s: MediaSource) -> SourceProvider {
        if let p = providers[s.id] { return p }
        let p = Providers.make(s)
        providers[s.id] = p
        return p
    }
}

// MARK: - HTTP helper

enum HTTP {
    static let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 30
        c.httpCookieStorage = nil
        c.httpShouldSetCookies = false
        return URLSession(configuration: c)
    }()

    static func request(_ url: URL, method: String = "GET", headers: [String: String] = [:], json: [String: Any]? = nil, form: [String: String]? = nil, body: Data? = nil) -> URLRequest {
        var r = URLRequest(url: url)
        r.httpMethod = method
        for (k, v) in headers { r.setValue(v, forHTTPHeaderField: k) }
        if let json {
            r.httpBody = try? JSONSerialization.data(withJSONObject: json)
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        } else if let form {
            r.httpBody = form.map { "\($0.key)=\($0.value.urlQueryEncoded)" }.joined(separator: "&").data(using: .utf8)
            r.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        } else if let body {
            r.httpBody = body
        }
        return r
    }

    static func data(_ r: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (d, resp) = try await session.data(for: r)
        guard let h = resp as? HTTPURLResponse else { throw AppError.message("无效响应") }
        return (d, h)
    }

    /// Fetch and decode a JSON object, throwing on non-2xx.
    static func json(_ r: URLRequest) async throws -> [String: Any] {
        let (d, h) = try await data(r)
        let obj = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any]
        guard (200..<300).contains(h.statusCode) else {
            let msg = (obj?["message"] as? String) ?? (obj?["error_description"] as? String) ?? (obj?["error"] as? String) ?? String(data: d.prefix(200), encoding: .utf8) ?? ""
            throw AppError.message("HTTP \(h.statusCode) \(msg)")
        }
        guard let obj else { throw AppError.message("无法解析服务器响应") }
        return obj
    }
}

extension Dictionary where Key == String, Value == Any {
    func str(_ k: String) -> String? {
        if let s = self[k] as? String { return s }
        if let n = self[k] as? NSNumber { return n.stringValue }
        return nil
    }
    func int(_ k: String) -> Int? {
        if let n = self[k] as? NSNumber { return n.intValue }
        if let s = self[k] as? String { return Int(s) }
        return nil
    }
    func int64(_ k: String) -> Int64? {
        if let n = self[k] as? NSNumber { return n.int64Value }
        if let s = self[k] as? String { return Int64(s) }
        return nil
    }
    func dict(_ k: String) -> [String: Any]? { self[k] as? [String: Any] }
    func arr(_ k: String) -> [[String: Any]] { self[k] as? [[String: Any]] ?? [] }
}
