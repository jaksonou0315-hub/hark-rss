import AVKit
import UIKit

/// 画中画 for VLC/MPV: copy the video view's frames into an AVSampleBufferDisplayLayer and hand that to
/// AVPictureInPictureController (sample-buffer content source, iOS 15+).
final class SamplePiP: NSObject, AVPictureInPictureSampleBufferPlaybackDelegate, AVPictureInPictureControllerDelegate {
    let layer = AVSampleBufferDisplayLayer()
    private var pip: AVPictureInPictureController?
    private weak var source: UIView?
    private var timer: Timer?
    private var pool: CVPixelBufferPool?
    private var poolSize = CGSize.zero
    var isPlaying: () -> Bool = { false }
    var setPlaying: (Bool) -> Void = { _ in }
    var skipBy: (Double) -> Void = { _ in }
    var duration: () -> Double = { 0 }
    var current: () -> Double = { 0 }
    var onState: (Bool) -> Void = { _ in }
    private(set) var active = false

    static var supported: Bool { AVPictureInPictureController.isPictureInPictureSupported() }

    @MainActor func attach(to view: UIView, auto: Bool) {
        source = view
        layer.videoGravity = .resizeAspect
        let host = view.superview ?? view
        layer.frame = host.bounds
        if layer.superlayer == nil { host.layer.insertSublayer(layer, at: 0) }
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        try? AVAudioSession.sharedInstance().setActive(true)
        if pip == nil {
            let src = AVPictureInPictureController.ContentSource(sampleBufferDisplayLayer: layer, playbackDelegate: self)
            let p = AVPictureInPictureController(contentSource: src)
            p.delegate = self
            p.canStartPictureInPictureAutomaticallyFromInline = auto
            pip = p
        }
        startFeeding(fps: 4)   // a slow trickle keeps the layer ready for auto-PiP
    }

    @MainActor func toggle() {
        guard let p = pip else { return }
        if p.isPictureInPictureActive { p.stopPictureInPicture(); return }
        startFeeding(fps: 24)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { p.startPictureInPicture() }
    }

    @MainActor func detach() {
        timer?.invalidate(); timer = nil
        pip?.stopPictureInPicture(); pip = nil
        layer.flushAndRemoveImage(); layer.removeFromSuperlayer()
    }

    @MainActor private func startFeeding(fps: Double) {
        timer?.invalidate()
        let t = Timer(timeInterval: 1 / fps, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.push() } }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    @MainActor private func push() {
        guard let v = source, v.bounds.width > 1, v.bounds.height > 1 else { return }
        if let h = layer.superlayer, layer.frame != h.bounds { layer.frame = h.bounds }
        let w = min(960, v.bounds.width * 2)
        let sz = CGSize(width: Int(w) & ~1, height: Int(w * v.bounds.height / v.bounds.width) & ~1)
        if pool == nil || poolSize != sz {
            poolSize = sz
            let attrs: [String: Any] = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                                        kCVPixelBufferWidthKey as String: Int(sz.width), kCVPixelBufferHeightKey as String: Int(sz.height),
                                        kCVPixelBufferIOSurfacePropertiesKey as String: [:], kCVPixelBufferCGImageCompatibilityKey as String: true,
                                        kCVPixelBufferCGBitmapContextCompatibilityKey as String: true]
            CVPixelBufferPoolCreate(nil, nil, attrs as CFDictionary, &pool)
        }
        guard let pool else { return }
        var pb: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pb)
        guard let pb else { return }
        CVPixelBufferLockBaseAddress(pb, [])
        if let ctx = CGContext(data: CVPixelBufferGetBaseAddress(pb), width: Int(sz.width), height: Int(sz.height), bitsPerComponent: 8,
                               bytesPerRow: CVPixelBufferGetBytesPerRow(pb), space: CGColorSpaceCreateDeviceRGB(),
                               bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) {
            ctx.setFillColor(UIColor.black.cgColor); ctx.fill(CGRect(origin: .zero, size: sz))
            ctx.translateBy(x: 0, y: sz.height); ctx.scaleBy(x: sz.width / v.bounds.width, y: -sz.height / v.bounds.height)
            UIGraphicsPushContext(ctx)
            v.drawHierarchy(in: v.bounds, afterScreenUpdates: false)
            UIGraphicsPopContext()
        }
        CVPixelBufferUnlockBaseAddress(pb, [])
        var fmt: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: pb, formatDescriptionOut: &fmt)
        guard let fmt else { return }
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()), decodeTimeStamp: .invalid)
        var sb: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: pb, formatDescription: fmt, sampleTiming: &timing, sampleBufferOut: &sb)
        guard let sb else { return }
        if let arr = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: true), CFArrayGetCount(arr) > 0 {
            let d = unsafeBitCast(CFArrayGetValueAtIndex(arr, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(d, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(), Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        if layer.status == .failed { layer.flush() }
        layer.enqueue(sb)
    }

    // MARK: AVPictureInPictureSampleBufferPlaybackDelegate
    func pictureInPictureController(_ c: AVPictureInPictureController, setPlaying playing: Bool) {
        DispatchQueue.main.async { self.setPlaying(playing) }
    }
    func pictureInPictureControllerTimeRangeForPlayback(_ c: AVPictureInPictureController) -> CMTimeRange {
        let d = duration(), now = current()
        guard d > 0 else { return CMTimeRange(start: .negativeInfinity, duration: .positiveInfinity) }
        let start = CACurrentMediaTime() - now
        return CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 600), duration: CMTime(seconds: d, preferredTimescale: 600))
    }
    func pictureInPictureControllerIsPlaybackPaused(_ c: AVPictureInPictureController) -> Bool { !isPlaying() }
    func pictureInPictureController(_ c: AVPictureInPictureController, didTransitionToRenderSize newRenderSize: CMVideoDimensions) {}
    func pictureInPictureController(_ c: AVPictureInPictureController, skipByInterval skipInterval: CMTime, completion: @escaping () -> Void) {
        DispatchQueue.main.async { self.skipBy(skipInterval.seconds); completion() }
    }

    // MARK: AVPictureInPictureControllerDelegate
    func pictureInPictureControllerWillStartPictureInPicture(_ c: AVPictureInPictureController) {
        DispatchQueue.main.async { self.active = true; self.startFeeding(fps: 24); self.onState(true) }
    }
    func pictureInPictureControllerDidStopPictureInPicture(_ c: AVPictureInPictureController) {
        DispatchQueue.main.async { self.active = false; self.startFeeding(fps: 4); self.onState(false) }
    }
    func pictureInPictureController(_ c: AVPictureInPictureController, failedToStartPictureInPictureWithError error: Error) {
        DispatchQueue.main.async { self.active = false; self.onState(false) }
    }
}
