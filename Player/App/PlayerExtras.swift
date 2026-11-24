import SwiftUI
import UIKit
import MediaPlayer

// MARK: - Player preferences (设置 › 播放 / 操控)

enum PlayerPrefs {
    private static var d: UserDefaults { .standard }
    private static func bool(_ k: String, _ def: Bool) -> Bool { d.object(forKey: k) as? Bool ?? def }

    static var autoNext: Bool { bool("play.autoNext", true) }
    static var skipIntro: Bool { bool("play.skipIntro", false) }
    static var onlineSegments: Bool { bool("play.onlineSegments", true) }
    static var skipCredits: Bool { bool("play.skipCredits", false) }
    static var skipPreview: Bool { bool("play.skipPreview", false) }

    static var defaultRate: Double { d.object(forKey: "ctl.defaultRate") as? Double ?? 1.0 }
}

// MARK: - Intro / recap / credits / preview segments

struct SkipSegments: Equatable {
    struct Seg: Equatable { var start: Int32; var end: Int32? }   // ms; end nil = end of media
    var intro: Seg?
    var recap: Seg?
    var credits: Seg?
    var preview: Seg?
    var isEmpty: Bool { intro == nil && recap == nil && credits == nil && preview == nil }
}

/// Manual marks per series / film (key = library item id or folder path). Manual beats online.
enum ManualSegments {
    private static let key = "play.manualSegs"
    private static var all: [String: [String: Int]] {
        get { (UserDefaults.standard.dictionary(forKey: key) as? [String: [String: Int]]) ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }
    static func get(_ k: String) -> (introEnd: Int32?, creditsStart: Int32?) {
        let m = all[k] ?? [:]
        return (m["introEnd"].map { Int32($0) }, m["creditsStart"].map { Int32($0) })
    }
    /// creditsStart is stored as "ms before the end" so it works for every episode.
    static func setIntroEnd(_ k: String, _ ms: Int32?) { var a = all; var m = a[k] ?? [:]; m["introEnd"] = ms.map { Int($0) }; a[k] = m; all = a }
    static func setCreditsFromEnd(_ k: String, _ ms: Int32?) { var a = all; var m = a[k] ?? [:]; m["creditsStart"] = ms.map { Int($0) }; a[k] = m; all = a }
    static func clear(_ k: String) { var a = all; a[k] = nil; all = a }
}

enum IntroDB {
    /// TheIntroDB v4 (no key). Movies: tmdb id only; episodes: tmdb id + season + episode.
    static func fetch(tmdbId: Int, tv: Bool, season: Int?, episode: Int?, durationMs: Int32) async -> SkipSegments? {
        var s = "https://api.theintrodb.org/v4/media?tmdb_id=\(tmdbId)"
        if tv { guard let se = season, let ep = episode else { return nil }; s += "&season=\(se)&episode=\(ep)" }
        if durationMs > 0 { s += "&duration_ms=\(durationMs)" }
        guard let u = URL(string: s) else { return nil }
        var req = URLRequest(url: u); req.timeoutInterval = 8
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        func seg(_ k: String) -> SkipSegments.Seg? {
            guard let a = obj[k] as? [[String: Any]], let f = a.first else { return nil }
            let st = (f["start_ms"] as? NSNumber)?.int32Value ?? 0
            let en = (f["end_ms"] as? NSNumber)?.int32Value
            if let en, en <= st { return nil }
            return .init(start: st, end: en)
        }
        let r = SkipSegments(intro: seg("intro"), recap: seg("recap"), credits: seg("credits"), preview: seg("preview"))
        return r.isEmpty ? nil : r
    }
}

// MARK: - System volume / brightness

enum SystemLevels {
    private static let volumeView: MPVolumeView = {
        let v = MPVolumeView(frame: CGRect(x: -2000, y: -2000, width: 10, height: 10))
        v.alpha = 0.01
        return v
    }()
    static func install(in view: UIView) {
        if volumeView.superview !== view { view.addSubview(volumeView) }
    }
    private static var slider: UISlider? { volumeView.subviews.compactMap { $0 as? UISlider }.first }
    static var volume: Float {
        get { slider?.value ?? AVAudioSessionVolume.current }
        set { slider?.value = max(0, min(1, newValue)); slider?.sendActions(for: .valueChanged) }
    }
    static var brightness: CGFloat {
        get { (UIApplication.shared.connectedScenes.first as? UIWindowScene)?.screen.brightness ?? 0.5 }
        set { (UIApplication.shared.connectedScenes.first as? UIWindowScene)?.screen.brightness = max(0, min(1, newValue)) }
    }
}

import AVFoundation
enum AVAudioSessionVolume { static var current: Float { AVAudioSession.sharedInstance().outputVolume } }

// MARK: - Gesture layer (UIKit recognizers so tap / double tap / long press / pan / pinch don't fight)

struct GestureLayer: UIViewRepresentable {
    enum Zone { case left, center, right }
    var onTap: () -> Void
    var onDoubleTap: (Zone) -> Void
    var onLongBegan: () -> Void
    var onLongMoved: (CGSize) -> Void
    var onLongEnded: () -> Void
    var onPan: (_ began: Bool, _ leftSide: Bool, _ dy: CGFloat, _ ended: Bool) -> Void
    /// Vertical drag that starts in the middle third: total dy (up is negative), ended.
    var onSwipe: (_ dy: CGFloat, _ ended: Bool) -> Void = { _, _ in }
    var onPinch: (_ scale: CGFloat, _ ended: Bool) -> Void

    func makeCoordinator() -> Coord { Coord(self) }
    func makeUIView(context: Context) -> UIView {
        let v = UIView(); v.backgroundColor = .clear
        let c = context.coordinator
        let dbl = UITapGestureRecognizer(target: c, action: #selector(Coord.double(_:))); dbl.numberOfTapsRequired = 2
        let tap = UITapGestureRecognizer(target: c, action: #selector(Coord.tap(_:))); tap.require(toFail: dbl)
        let long = UILongPressGestureRecognizer(target: c, action: #selector(Coord.long(_:))); long.minimumPressDuration = 0.45
        let pan = UIPanGestureRecognizer(target: c, action: #selector(Coord.pan(_:))); pan.maximumNumberOfTouches = 1
        pan.delegate = c
        let pinch = UIPinchGestureRecognizer(target: c, action: #selector(Coord.pinch(_:)))
        [dbl, tap, long, pan, pinch].forEach { v.addGestureRecognizer($0) }
        SystemLevels.install(in: v)
        return v
    }
    func updateUIView(_ uiView: UIView, context: Context) { context.coordinator.p = self }

    final class Coord: NSObject, UIGestureRecognizerDelegate {
        var p: GestureLayer
        private var longStart: CGPoint = .zero
        private var panLeft = false
        private var panMiddle = false
        init(_ p: GestureLayer) { self.p = p }
        @objc func tap(_ g: UITapGestureRecognizer) { p.onTap() }
        @objc func double(_ g: UITapGestureRecognizer) {
            guard let v = g.view else { return }
            let x = g.location(in: v).x / max(1, v.bounds.width)
            p.onDoubleTap(x < 0.33 ? .left : x > 0.67 ? .right : .center)
        }
        @objc func long(_ g: UILongPressGestureRecognizer) {
            let pt = g.location(in: g.view)
            switch g.state {
            case .began: longStart = pt; p.onLongBegan()
            case .changed: p.onLongMoved(CGSize(width: pt.x - longStart.x, height: pt.y - longStart.y))
            case .ended, .cancelled, .failed: p.onLongEnded()
            default: break
            }
        }
        func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
            guard let pan = g as? UIPanGestureRecognizer else { return true }
            let v = pan.velocity(in: pan.view)
            return abs(v.y) > abs(v.x) * 1.3
        }
        @objc func pan(_ g: UIPanGestureRecognizer) {
            guard let v = g.view else { return }
            switch g.state {
            case .began:
                let x = g.location(in: v).x / max(1, v.bounds.width)
                panMiddle = x > 0.33 && x < 0.67
                panLeft = x < 0.5
                if panMiddle { p.onSwipe(0, false) } else { p.onPan(true, panLeft, 0, false) }
            case .changed:
                if panMiddle { p.onSwipe(g.translation(in: v).y, false); return }
                let dy = g.translation(in: v).y
                g.setTranslation(.zero, in: v)
                p.onPan(false, panLeft, -dy / max(200, v.bounds.height * 0.8), false)
            default:
                if panMiddle { p.onSwipe(g.translation(in: v).y, true) } else { p.onPan(false, panLeft, 0, true) }
            }
        }
        @objc func pinch(_ g: UIPinchGestureRecognizer) {
            switch g.state {
            case .changed: p.onPinch(g.scale, false)
            case .ended, .cancelled: p.onPinch(g.scale, true)
            default: break
            }
        }
    }
}

// MARK: - Snapshot

import VLCKitSPM
extension MediaEngine {
    /// Grabs the current video frame and saves it to Photos.
    func saveSnapshot(_ done: @escaping @MainActor (Bool) -> Void) {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("shot-\(UUID().uuidString).png").path
        if let v = self as? VLCEngine {
            v.player.saveVideoSnapshot(at: path, withWidth: 0, andHeight: 0)
        } else if let m = self as? MPVEngine {
            m.screenshot(to: path)
        } else { Task { @MainActor in done(false) }; return }
        Task { @MainActor in
            for _ in 0..<20 {
                try? await Task.sleep(nanoseconds: 150_000_000)
                if let img = UIImage(contentsOfFile: path) {
                    UIImageWriteToSavedPhotosAlbum(img, nil, nil, nil)
                    done(true); return
                }
            }
            done(false)
        }
    }
}

// MARK: - Picture fit (0 适应 / 1 填充 / 2 拉伸) and video size

extension MediaEngine {
    func applyFill(_ mode: Int, screen: CGSize) {
        if let v = self as? VLCEngine {
            let w = Int(max(1, screen.width).rounded()), h = Int(max(1, screen.height).rounded())
            let ratio = "\(w):\(h)"
            v.player.videoCropGeometry = mode == 1 ? strdup(ratio) : nil
            v.player.videoAspectRatio = mode == 2 ? strdup(ratio) : nil
        } else if let m = self as? MPVEngine {
            m.setFill(mode)
        }
    }
    var videoDims: CGSize {
        if let v = self as? VLCEngine { return v.player.videoSize }
        if let m = self as? MPVEngine { return m.videoDims }
        return .zero
    }
}
