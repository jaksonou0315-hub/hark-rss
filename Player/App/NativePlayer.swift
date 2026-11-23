import Foundation
import SwiftUI
import AVKit
import AVFoundation
import Combine

/// Apple-native engine (AVPlayer) for MP4/MOV/M4V over http(s)/file: system Dolby Vision, HDR10, Dolby Atmos (E-AC-3 JOC) and spatial audio.
enum EngineChooser {
    static let nativeExts: Set<String> = ["mp4", "m4v", "mov"]
    static func useNative(_ r: PlayRequest) -> Bool {
        guard AppSettings.shared.nativeEngine else { return false }
        guard r.source.kind != .smb else { return false }
        return nativeExts.contains(r.file.ext)
    }
}

struct PlayerEntry: View {
    let request: PlayRequest
    var body: some View {
        if EngineChooser.useNative(request) { NativePlayerView(request: request) } else { PlayerView(request: request) }
    }
}

enum DolbyBadges {
    /// VLC four-character codes → badge text.
    static func audioBadge(fourcc: UInt32) -> String? {
        let b = withUnsafeBytes(of: fourcc.littleEndian) { Array($0) }
        let s = String(bytes: b, encoding: .ascii)?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
        switch s {
        case "trhd", "mlp": return "Dolby TrueHD"
        case "eac3": return "Dolby Digital Plus"
        case "a52": return "Dolby Digital"
        case "dts": return "DTS"
        default: return nil
        }
    }
    static func nameHintsDV(_ name: String) -> Bool {
        let n = name.lowercased()
        return n.contains("dovi") || n.contains("dolby.vision") || n.contains("dolby vision") || n.contains(".dv.") || n.contains(" dv ") || n.contains("-dv") || n.contains(".dv-")
    }
    static func nameHintsAtmos(_ name: String) -> Bool { name.lowercased().contains("atmos") }

    /// Inspect an AVAsset for Dolby Vision / HDR / Dolby audio.
    static func inspect(_ asset: AVURLAsset) async -> [String] {
        var out: [String] = []
        if let v = try? await asset.loadTracks(withMediaType: .video).first {
            let fds = (try? await v.load(.formatDescriptions)) ?? []
            var dv = false, hdr = false
            for fd in fds {
                let sub = CMFormatDescriptionGetMediaSubType(fd)
                if sub == fourCC("dvh1") || sub == fourCC("dvhe") || sub == fourCC("dva1") || sub == fourCC("dvav") { dv = true }
                if let ext = CMFormatDescriptionGetExtensions(fd) as? [String: Any] {
                    if let atoms = ext["SampleDescriptionExtensionAtoms"] as? [String: Any],
                       atoms.keys.contains(where: { $0 == "dvcC" || $0 == "dvvC" || $0 == "dvwC" }) { dv = true }
                    let tf = ext[kCMFormatDescriptionExtension_TransferFunction as String] as? String
                    if tf == (kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ as String) || tf == (kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG as String) { hdr = true }
                }
            }
            if dv { out.append("杜比视界") } else if hdr { out.append("HDR") }
        }
        if let tracks = try? await asset.loadTracks(withMediaType: .audio) {
            var best: String?
            for t in tracks {
                for fd in (try? await t.load(.formatDescriptions)) ?? [] {
                    let sub = CMFormatDescriptionGetMediaSubType(fd)
                    if sub == kAudioFormatEnhancedAC3 { best = "Dolby Digital Plus" }
                    else if sub == kAudioFormatAC3, best == nil { best = "Dolby Digital" }
                    else if sub == DolbyBadges.fourCC("ac-4") { best = "Dolby AC-4" }
                }
            }
            if let best { out.append(best) }
        }
        return out
    }
    static func fourCC(_ s: String) -> FourCharCode { s.utf8.reduce(0) { ($0 << 8) | FourCharCode($1) } }
}

@MainActor
final class NativePlayerModel: ObservableObject {
    let request: PlayRequest
    let player = AVPlayer()
    @Published var errorText: String?
    @Published var badges: [String] = []
    @Published var showBadges = true
    private var resumeKey: String?
    private var timeObs: Any?
    private var endObs: NSObjectProtocol?
    private var styleSub: AnyCancellable?

    init(_ r: PlayRequest) { request = r }

    func start() async {
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback, policy: .longFormVideo)
        try? AVAudioSession.sharedInstance().setActive(true)
        let provider = SourceStore.shared.provider(for: request.source)
        do {
            let p = try await DownloadStore.shared.playable(provider, request.file)
            // closed while the link was still loading: never start playback into a torn-down view
            guard !stopped else { return }
            resumeKey = p.resumeKey
            var opts: [String: Any] = [:]
            if !p.headers.isEmpty { opts["AVURLAssetHTTPHeaderFieldsKey"] = p.headers }
            let asset = AVURLAsset(url: p.url, options: opts)
            let item = AVPlayerItem(asset: asset)
            item.textStyleRules = SubtitleStyle.shared.avTextStyleRules
            styleSub = SubtitleStyle.shared.objectWillChange
                .debounce(for: .milliseconds(200), scheduler: RunLoop.main)
                .sink { [weak item] _ in item?.textStyleRules = SubtitleStyle.shared.avTextStyleRules }
            item.externalMetadata = [Self.meta(.commonIdentifierTitle, request.title ?? request.file.baseName)]
            player.replaceCurrentItem(with: item)
            player.appliesMediaSelectionCriteriaAutomatically = true
            if AppSettings.shared.resumePlayback {
                let ms = Resume.get(p.resumeKey)
                if ms > 10_000 { await player.seek(to: CMTime(value: CMTimeValue(ms), timescale: 1000)) }
            }
            guard !stopped else { player.pause(); return }
            player.play()
            timeObs = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 5, preferredTimescale: 1), queue: .main) { [weak self] t in
                Task { @MainActor in
                    guard let self, let k = self.resumeKey, t.seconds > 10 else { return }
                    Resume.set(k, Int32(t.seconds * 1000), total: Int32(((self.player.currentItem?.duration.seconds).flatMap { $0.isFinite ? $0 : nil } ?? 0) * 1000))
                }
            }
            endObs = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
                Task { @MainActor in if let k = self?.resumeKey { Resume.clear(k) } }
            }
            var b = await DolbyBadges.inspect(asset)
            if DolbyBadges.nameHintsAtmos(request.file.name), let i = b.firstIndex(of: "Dolby Digital Plus") { b[i] = "杜比全景声" }
            badges = b
            if let e = item.error { errorText = e.localizedDescription }
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            showBadges = false
        } catch {
            errorText = error.localizedDescription
        }
    }

    private var stopped = false
    func stop() {
        // close() and onDisappear both call this; the second call came while SwiftUI was tearing the
        // player view down, and AVPlayer threw from _removeAllLayersAndVideoTargets (闪退 on closing).
        guard !stopped else { return }
        stopped = true
        if let k = resumeKey, player.currentTime().seconds > 10 {
            let d = player.currentItem?.duration.seconds ?? 0
            if d.isFinite, d - player.currentTime().seconds < 5 { Resume.clear(k) } else { Resume.set(k, Int32(player.currentTime().seconds * 1000), total: Int32((d.isFinite ? d : 0) * 1000)) }
        }
        if let timeObs { player.removeTimeObserver(timeObs) }
        if let endObs { NotificationCenter.default.removeObserver(endObs) }
        timeObs = nil; endObs = nil
        styleSub = nil
        player.pause()
        // no replaceCurrentItem(nil) here: during SwiftUI teardown AVPlayer throws from
        // _removeAllLayersAndVideoTargets (闪退). The player and item are released with the model.
    }

    static func meta(_ id: AVMetadataIdentifier, _ v: String) -> AVMetadataItem {
        let m = AVMutableMetadataItem()
        m.identifier = id; m.value = v as NSString; m.extendedLanguageTag = "und"
        return m
    }
}

struct AVPlayerVC: UIViewControllerRepresentable {
    let player: AVPlayer
    let onDone: () -> Void
    var onTap: () -> Void = {}
    func makeCoordinator() -> Coord { Coord(onDone, onTap) }
    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let vc = AVPlayerViewController()
        vc.player = player
        vc.allowsPictureInPicturePlayback = true
        vc.canStartPictureInPictureAutomaticallyFromInline = false
        vc.delegate = context.coordinator
        // watch taps (without stealing them) so our close button shows/hides together with the system controls
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coord.tapped))
        tap.cancelsTouchesInView = false
        tap.delegate = context.coordinator
        vc.view.addGestureRecognizer(tap)
        return vc
    }
    func updateUIViewController(_ vc: AVPlayerViewController, context: Context) {}
    static func dismantleUIViewController(_ vc: AVPlayerViewController, coordinator: Coord) {
        vc.player?.pause()
        vc.delegate = nil
    }
    final class Coord: NSObject, AVPlayerViewControllerDelegate, UIGestureRecognizerDelegate {
        let done: () -> Void
        let tap: () -> Void
        init(_ d: @escaping () -> Void, _ t: @escaping () -> Void) { done = d; tap = t }
        @objc func tapped() { tap() }
        func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith o: UIGestureRecognizer) -> Bool { true }
        func playerViewController(_ vc: AVPlayerViewController, willEndFullScreenPresentationWithAnimationCoordinator c: UIViewControllerTransitionCoordinator) { done() }
    }
}

struct NativePlayerView: View {
    @StateObject private var m: NativePlayerModel
    @Environment(\.dismiss) private var dismiss
    init(request: PlayRequest) { _m = StateObject(wrappedValue: NativePlayerModel(request)) }

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.ignoresSafeArea()
            AVPlayerVC(player: m.player, onDone: { close() }, onTap: { toggleClose() }).ignoresSafeArea()
            if m.showBadges, !m.badges.isEmpty {
                HStack(spacing: 8) {
                    ForEach(m.badges, id: \.self) { b in
                        Text(b).font(.caption.weight(.bold)).foregroundStyle(.white)
                            .padding(.horizontal, 10).padding(.vertical, 6).glass(in: Capsule())
                    }
                }
                .padding(.top, 64).allowsHitTesting(false).transition(.opacity)
            }
            if let e = m.errorText {
                VStack(spacing: 12) {
                    Text(e).foregroundStyle(.white).multilineTextAlignment(.center)
                    Button("关闭") { close() }.glassButton(prominent: true)
                }.padding(24).glass(in: RoundedRectangle(cornerRadius: 24, style: .continuous)).padding(.top, 200)
            }
            if showClose || m.errorText != nil {
                HStack {
                    Button { close() } label: { Image(systemName: "xmark").frame(width: 40, height: 40) }
                        .glass(in: Circle(), interactive: true).foregroundStyle(.white)
                    Spacer()
                }.padding(.horizontal, 16).padding(.top, 8).transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: showClose)
        .onAppear { scheduleHide(); OrientationLock.set(.allButUpsideDown) }
        .preferredColorScheme(.dark)
        .animation(.easeInOut, value: m.showBadges)
        .task { await m.start() }
        .onDisappear { m.stop(); OrientationLock.set(.portrait, force: .portrait) }
    }
    private func close() { m.stop(); OrientationLock.leavePlayer { dismiss() } }

    @State private var showClose = true
    @State private var hideTask: Task<Void, Never>?
    /// The system controls toggle on tap and fade after a few seconds; mirror that for the close button.
    private func toggleClose() {
        showClose.toggle()
        if showClose { scheduleHide() } else { hideTask?.cancel() }
    }
    private func scheduleHide() {
        hideTask?.cancel()
        hideTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(3.5))
            guard !Task.isCancelled else { return }
            if m.player.rate > 0 { showClose = false }
        }
    }
}
