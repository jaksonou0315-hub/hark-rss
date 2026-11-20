import Foundation
import SwiftUI

enum SourceKind: String, Codable, CaseIterable, Identifiable {
    case local, smb, webdav, emby, jellyfin, aliyun, pan115, baidu, quark, guangya
    var id: String { rawValue }
    var title: String {
        switch self {
        case .local: return "本机文件"
        case .smb: return "SMB 共享"
        case .webdav: return "WebDAV"
        case .emby: return "Emby"
        case .jellyfin: return "Jellyfin"
        case .aliyun: return "阿里云盘"
        case .pan115: return "115 网盘"
        case .baidu: return "百度网盘"
        case .quark: return "夸克网盘"
        case .guangya: return "光鸭云盘"
        }
    }
    var icon: String {
        switch self {
        case .local: return "iphone"
        case .smb: return "externaldrive.connected.to.line.below"
        case .webdav: return "globe"
        case .emby: return "play.tv"
        case .jellyfin: return "sparkles.tv"
        case .aliyun: return "icloud"
        case .pan115: return "cloud"
        case .baidu: return "cloud.circle"
        case .quark: return "sparkles"
        case .guangya: return "bird"
        }
    }
    var tint: Color {
        switch self {
        case .local: return .gray
        case .smb: return .blue
        case .webdav: return .teal
        case .emby: return .green
        case .jellyfin: return .purple
        case .aliyun: return .orange
        case .pan115: return .cyan
        case .baidu: return .indigo
        case .quark: return .blue
        case .guangya: return .yellow
        }
    }
    var needsQRLogin: Bool { self == .aliyun || self == .pan115 || self == .baidu || self == .quark }
    var isMediaServer: Bool { self == .emby || self == .jellyfin }
}

struct MediaSource: Codable, Identifiable, Hashable {
    var id = UUID()
    var kind: SourceKind
    var name: String
    /// host / base URL (smb: "192.168.1.2", webdav: "https://nas:5006/dav", emby: "http://nas:8096")
    var host: String = ""
    var username: String = ""
    var password: String = ""
    var token: String = ""
    var refreshToken: String = ""
    var userId: String = ""
    var tokenExpiry: Date? = nil
    var extra: [String: String] = [:]

    var isLoggedIn: Bool {
        switch kind {
        case .local, .smb, .webdav: return true
        case .pan115: return !(extra["cookie"] ?? "").isEmpty
        default: return !token.isEmpty || !refreshToken.isEmpty
        }
    }
}

struct RemoteFile: Codable, Identifiable, Hashable {
    var id: String
    var name: String
    var path: String
    var isDir: Bool
    var size: Int64 = 0
    var posterURL: URL? = nil
    var overview: String? = nil
    var year: Int? = nil
    var meta: [String: String] = [:]

    var ext: String { (name as NSString).pathExtension.lowercased() }
    var baseName: String { (name as NSString).deletingPathExtension }
    var isVideo: Bool {
        if let t = meta["type"] { return ["Movie", "Episode", "Video", "MusicVideo", "Trailer"].contains(t) }
        return !isDir && FileKinds.video.contains(ext)
    }
    var isSubtitle: Bool { !isDir && FileKinds.subtitle.contains(ext) }
    var sizeText: String {
        guard size > 0 else { return "" }
        return ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }
}

enum FileKinds {
    static let video: Set<String> = ["mkv", "mp4", "m4v", "mov", "avi", "wmv", "flv", "ts", "m2ts", "mts", "webm", "rmvb", "rm", "mpg", "mpeg", "vob", "iso", "3gp", "ogv", "f4v", "divx", "asf"]
    static let subtitle: Set<String> = ["srt", "ass", "ssa", "vtt", "sub", "idx", "sup", "smi", "lrc"]
}

/// Everything VLC needs to open one item.
struct PlayableMedia {
    var url: URL
    var title: String
    var headers: [String: String] = [:]
    var subtitleFiles: [URL] = []           // local/remote sidecars to attach
    var resumeKey: String

    var vlcOptions: [String] {
        var o: [String] = [":network-caching=1500"]
        if let ua = headers["User-Agent"] { o.append(":http-user-agent=\(ua)") }
        if let ref = headers["Referer"] { o.append(":http-referrer=\(ref)") }
        let enc = AppSettings.shared.subtitleEncoding
        if !enc.isEmpty { o.append(":subsdec-encoding=\(enc)") }
        return o
    }
}

struct PlayRequest: Identifiable {
    let id = UUID()
    var source: MediaSource
    var file: RemoteFile
    var siblings: [RemoteFile] = []
    var title: String? = nil
    var extraSubtitles: [RemoteFile] = []
}

enum AppError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        if case .message(let m) = self { return m }
        return nil
    }
}

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
    var urlPathEncoded: String { addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? self }
    var urlQueryEncoded: String {
        var set = CharacterSet.urlQueryAllowed
        set.remove(charactersIn: "&=+?/")
        return addingPercentEncoding(withAllowedCharacters: set) ?? self
    }
    var userInfoEncoded: String {
        var set = CharacterSet.urlUserAllowed
        set.remove(charactersIn: ":@/")
        return addingPercentEncoding(withAllowedCharacters: set) ?? self
    }
}

// MARK: - Settings

final class AppSettings: ObservableObject {
    static let shared = AppSettings()
    private let d = UserDefaults.standard

    @Published var tmdbKey: String { didSet { Keychain.set(tmdbKey, for: "tmdbKey") } }
    @Published var assrtToken: String { didSet { Keychain.set(assrtToken, for: "assrtToken") } }
    @Published var openSubtitlesKey: String { didSet { Keychain.set(openSubtitlesKey, for: "osKey") } }
    @Published var subtitleEncoding: String { didSet { d.set(subtitleEncoding, forKey: "subEnc") } }
    @Published var autoSidecar: Bool { didSet { d.set(autoSidecar, forKey: "autoSidecar") } }
    @Published var autoOnlineSubtitle: Bool { didSet { d.set(autoOnlineSubtitle, forKey: "autoOnlineSub") } }
    @Published var preferredSubLang: String { didSet { d.set(preferredSubLang, forKey: "subLang") } }
    @Published var resumePlayback: Bool { didSet { d.set(resumePlayback, forKey: "resume") } }
    @Published var tmdbLanguage: String { didSet { d.set(tmdbLanguage, forKey: "tmdbLang") } }
    @Published var aiSpeechLocale: String { didSet { d.set(aiSpeechLocale, forKey: "aiLocale") } }
    @Published var aiTranslate: Bool { didSet { d.set(aiTranslate, forKey: "aiTranslate") } }
    @Published var aiShowOriginal: Bool { didSet { d.set(aiShowOriginal, forKey: "aiShowOrig") } }
    @Published var translateTarget: String { didSet { d.set(translateTarget, forKey: "trTarget") } }
    @Published var bilingualSubs: Bool { didSet { d.set(bilingualSubs, forKey: "bilingual") } }
    @Published var nativeEngine: Bool { didSet { d.set(nativeEngine, forKey: "nativeEngine") } }
    @Published var dolbyStereo: Bool { didSet { d.set(dolbyStereo, forKey: "dolbyStereo") } }

    private init() {
        tmdbKey = Keychain.get("tmdbKey") ?? ""
        assrtToken = Keychain.get("assrtToken") ?? ""
        openSubtitlesKey = Keychain.get("osKey") ?? ""
        subtitleEncoding = d.string(forKey: "subEnc") ?? ""
        autoSidecar = d.object(forKey: "autoSidecar") as? Bool ?? true
        autoOnlineSubtitle = d.object(forKey: "autoOnlineSub") as? Bool ?? false
        preferredSubLang = d.string(forKey: "subLang") ?? "zh"
        resumePlayback = d.object(forKey: "resume") as? Bool ?? true
        tmdbLanguage = d.string(forKey: "tmdbLang") ?? "zh-CN"
        aiSpeechLocale = d.string(forKey: "aiLocale") ?? "en-US"
        aiTranslate = d.object(forKey: "aiTranslate") as? Bool ?? true
        aiShowOriginal = d.object(forKey: "aiShowOrig") as? Bool ?? true
        translateTarget = d.string(forKey: "trTarget") ?? "zh-Hans"
        bilingualSubs = d.object(forKey: "bilingual") as? Bool ?? true
        nativeEngine = d.object(forKey: "nativeEngine") as? Bool ?? true
        dolbyStereo = d.object(forKey: "dolbyStereo") as? Bool ?? true
    }
}

enum Resume {
    static func get(_ key: String) -> Int32 { Int32(UserDefaults.standard.integer(forKey: "resume." + key)) }
    static func set(_ key: String, _ ms: Int32) { UserDefaults.standard.set(Int(ms), forKey: "resume." + key) }
    static func clear(_ key: String) { UserDefaults.standard.removeObject(forKey: "resume." + key) }
}

// MARK: - Keychain

enum Keychain {
    private static let service = "com.ouyanghong.harkplayer"
    static func set(_ value: String, for key: String) { setData(Data(value.utf8), for: key) }
    static func get(_ key: String) -> String? { getData(key).flatMap { String(data: $0, encoding: .utf8) } }

    static func setData(_ data: Data, for key: String) {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service,
                                kSecAttrAccount as String: key]
        SecItemDelete(q as CFDictionary)
        var add = q
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        if SecItemAdd(add as CFDictionary, nil) != errSecSuccess {
            // Fallback when the sideloaded build has no keychain access group.
            UserDefaults.standard.set(data, forKey: "kc." + key)
        } else {
            UserDefaults.standard.removeObject(forKey: "kc." + key)
        }
    }
    static func getData(_ key: String) -> Data? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service,
                                kSecAttrAccount as String: key,
                                kSecReturnData as String: true,
                                kSecMatchLimit as String: kSecMatchLimitOne]
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess else {
            return UserDefaults.standard.data(forKey: "kc." + key)
        }
        return out as? Data
    }
}
