import UIKit
import AVKit
import Libmpv

// mpv as the main player's engine (stage 2). Unlike the stage 1 hand-off controller, the main thread never
// waits on mpv: every value the player needs is observed (mpv_observe_property) and cached on mpv's event queue,
// and every write is asynchronous. Only the diagnostics/track panels read properties directly, on demand.

/// View that holds mpv's Metal layer (Vulkan via MoltenVK).
final class MPVHostView: UIView {
    let metal = MPVMetalLayer()
    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        metal.contentsScale = UIScreen.main.nativeScale
        metal.framebufferOnly = true
        metal.backgroundColor = UIColor.black.cgColor
        layer.addSublayer(metal)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        metal.frame = bounds
        CATransaction.commit()
    }
}

final class MPVCore {
    let view = MPVHostView()
    private(set) var mpv: OpaquePointer?
    private let events = DispatchQueue(label: "app.shasha.mpv.core")
    private let lock = NSLock()

    /// Values cached from mpv's property-change events.
    struct State {
        var time: Double = 0
        var duration: Double = 0
        var paused = false
        var pausedForCache = false
        var seeking = false
        var eof = false
        var coreIdle = true
        var loaded = false
        var height = 0
        var trackJSON = ""
        var endError: String?
    }
    private var st = State()
    var state: State { lock.lock(); defer { lock.unlock() }; return st }
    private func update(_ f: (inout State) -> Void) { lock.lock(); f(&st); lock.unlock() }

    /// Picture in picture output state (see setPiPOutput).
    var pipOutput = false
    var pipOutputReady = false
    var pipOutputFailed = false
    /// The floating window shows a Dolby Vision file through the libplacebo filter (see setPiPOutput).
    var pipDolbyVision = false
    var createdLabVO: String { createdLab == .voGPU ? "gpu" : "gpu-next" }

    private var log: [String] = []
    func note(_ s: String) {
        lock.lock(); log.append(s); if log.count > 300 { log.removeFirst(log.count - 300) }; lock.unlock()
        MPVSessionFile.append(s)
    }
    func logLines() -> [String] { lock.lock(); defer { lock.unlock() }; return log }

    init() {
        NotificationCenter.default.addObserver(self, selector: #selector(background), name: UIApplication.didEnterBackgroundNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(foreground), name: UIApplication.willEnterForegroundNotification, object: nil)
    }
    deinit { destroy() }

    // The Metal surface is lost in the background (fix from MPVKit's demo): drop video, keep audio.
    @objc private func background() { if mpv != nil, !pipOutput { setAsync("vid", "no") } }
    @objc private func foreground() { if mpv != nil, !pipOutput { setAsync("vid", "auto") } }

    /// Creates the mpv instance once (options can only be set before mpv_initialize).
    private func create(lab: MPVLab) -> Bool {
        guard let h = mpv_create() else { note("mpv_create failed"); return false }
        mpv = h
        mpv_request_log_messages(h, "info")
        var layerPtr = view.metal
        mpv_set_option(h, "wid", MPV_FORMAT_INT64, &layerPtr)
        opt("vo", lab == .voGPU ? "gpu" : "gpu-next")
        opt("gpu-api", "vulkan")
        opt("gpu-context", "moltenvk")
        opt("hwdec", lab == .noHwdec ? "no" : lab == .copyHwdec ? "videotoolbox-copy" : "videotoolbox")
        opt("video-rotate", "no")
        opt("keep-open", "yes")             // stay on the last frame: the app decides (EndRule) what the end means
        opt("idle", "yes")
        opt("cache", "yes")
        opt("demuxer-max-bytes", "150MiB")
        opt("volume-max", "200")
        opt("audio-channels", "auto")       // was auto-safe (stereo): request the file's layout; the route decides
        opt("subs-fallback", "yes")
        opt("sub-font-size", "46")
        opt("sub-scale", String(format: "%.2f", MPVSubScale.value))
        if let dir = MPVFonts.directory() { opt("sub-fonts-dir", dir); opt("sub-font", "Noto Sans Arabic") }
        opt("network-timeout", "20")
        opt("avfoundation-composite-osd", "yes")   // subtitles drawn into the frames in picture in picture
        // No automatic reconnect loop of our own; FFmpeg's own short reconnect inside one request is left as is.
        let r = mpv_initialize(h)
        if r < 0 { note("API initialize: \(String(cString: mpv_error_string(r)))"); mpv_terminate_destroy(h); mpv = nil; return false }
        let observed: [(String, mpv_format)] = [
            ("time-pos", MPV_FORMAT_DOUBLE), ("duration", MPV_FORMAT_DOUBLE), ("pause", MPV_FORMAT_FLAG),
            ("paused-for-cache", MPV_FORMAT_FLAG), ("seeking", MPV_FORMAT_FLAG), ("eof-reached", MPV_FORMAT_FLAG),
            ("core-idle", MPV_FORMAT_FLAG), ("height", MPV_FORMAT_INT64), ("track-list", MPV_FORMAT_STRING),
        ]
        for (i, o) in observed.enumerated() { mpv_observe_property(h, UInt64(i + 1), o.0, o.1) }
        mpv_set_wakeup_callback(h, { ctx in
            guard let ctx else { return }
            Unmanaged<MPVCore>.fromOpaque(ctx).takeUnretainedValue().drain()
        }, Unmanaged.passUnretained(self).toOpaque())
        return true
    }
    private(set) var createdLab: MPVLab?

    /// Opens a stream. `alang`/`slang` are mpv language lists ("ara,ar,arabic").
    func open(_ url: URL, start: Double, live: Bool, alang: String, slang: String, lab: MPVLab) {
        // A lab mode changes creation-time options, so a different mode needs a fresh instance.
        if mpv != nil, createdLab != lab { destroy() }
        MPVSessionFile.begin(secrets: MPVSessionFile.secrets(of: url))
        MPVMetalLayer.onEDR = { [weak self] in self?.note("[مرحلة] \($0)") }
        note("[مرحلة] فتح في المشغّل الرئيسي | البداية عند \(Int(start)) ث | \(live ? "بث مباشر" : "فيلم/حلقة") | وضع الاختبار: \(lab.rawValue)")
        if mpv == nil { guard create(lab: lab) else { update { $0.endError = "تعذّر تشغيل mpv" }; return }; createdLab = lab }
        update { $0 = State() }
        setAsync("alang", alang.isEmpty ? "" : alang)
        setAsync("slang", slang.isEmpty ? "ar,ara,arabic" : slang)
        setAsync("start", start > 5 ? String(format: "%.0f", start) : "none")
        setAsync("pause", "no")
        setAsync("vid", "auto")
        // Track choices, delay and picture shape set at runtime are options in mpv and would carry over to the
        // next file: back to the defaults for every open (the player re-applies the viewer's choices itself).
        setAsync("aid", "auto"); setAsync("sid", "auto")
        setAsync("sub-delay", "0"); setAsync("panscan", "0.0"); setAsync("video-aspect-override", "no")
        commandAsync(["loadfile", url.absoluteString, "replace"])
    }

    /// Stops playback and closes the connection (the instance stays for the next open).
    func stopPlayback() {
        guard mpv != nil else { return }
        commandAsync(["stop"])
        update { $0.loaded = false }
    }

    func destroy() {
        guard let h = mpv else { return }
        note("[مرحلة] إغلاق طبيعي")
        MPVMetalLayer.onEDR = nil
        mpv_set_wakeup_callback(h, nil, nil)
        let t0 = Perf.now()
        events.sync { self.mpv = nil }       // never destroy while the event queue is inside mpv_wait_event
        mpv_terminate_destroy(h)
        // 1.0.3 measurement only: is closing mpv part of the ~900 ms stall when leaving the player?
        Perf.shared.record("mpv: إغلاق المحرّك", since: t0)
        createdLab = nil
    }

    // MARK: Writes (asynchronous: the main thread never waits for mpv)

    private func opt(_ name: String, _ value: String) {
        guard let h = mpv else { return }
        let r = mpv_set_option_string(h, name, value)
        if r < 0 { note("API option \(name): \(String(cString: mpv_error_string(r)))") }
    }
    // 1.0.1: every async write gets its own reply id, and its result (MPV_EVENT_SET_PROPERTY_REPLY /
    // MPV_EVENT_COMMAND_REPLY, mpv_event.error < 0 on failure — client.h) is checked in drain(). Before, the
    // results were never read, so a failed "vo"/"wid" switch for picture in picture was only seen as a timeout.
    private struct Pending { let what: String; let pip: Bool; let gen: Int }
    /// Which PiP output switch a write belongs to: a late reply from an older switch can't fail a newer attempt.
    private var pipGen = 0
    private var pending: [UInt64: Pending] = [:]
    private var nextReply: UInt64 = 1
    private func track(_ what: String, pip: Bool) -> UInt64 {
        lock.lock(); defer { lock.unlock() }
        let id = nextReply; nextReply += 1
        pending[id] = Pending(what: what, pip: pip, gen: pipGen)
        if pending.count > 200, let oldest = pending.keys.min() { pending[oldest] = nil }
        return id
    }
    private func untrack(_ id: UInt64) -> Pending? {
        lock.lock(); defer { lock.unlock() }
        return pending.removeValue(forKey: id)
    }
    /// A write failed (now, or in its reply). A failed write of the PiP output switch fails the current attempt.
    private func failed(_ p: Pending, _ code: Int32) {
        note("[خطأ أمر] \(p.what): \(String(cString: mpv_error_string(code)))")
        lock.lock(); let current = p.gen == pipGen; lock.unlock()
        // Only the output itself (vo, wid) decides; a failed DV filter/hwdec write is logged but not fatal.
        if p.pip && current && pipOutput { pipOutputFailed = true }
    }

    /// `pip`: the output part (vo, wid) of the picture-in-picture switch (see setPiPOutput).
    func setAsync(_ name: String, _ value: String, pip: Bool = false) {
        guard let h = mpv else { return }
        // Property values are short settings (no links); "wid" is a layer address.
        let id = track("\(name)=\(value)", pip: pip)
        let r: Int32 = name.withCString { n in
            value.withCString { v in
                var p: UnsafePointer<CChar>? = v
                return mpv_set_property_async(h, id, n, MPV_FORMAT_STRING, &p)
            }
        }
        if r < 0, let p = untrack(id) { failed(p, r) }
    }
    func commandAsync(_ args: [String]) {
        guard let h = mpv else { return }
        var cargs: [UnsafePointer<CChar>?] = args.map { UnsafePointer(strdup($0)) }
        cargs.append(nil)
        defer { cargs.forEach { if let p = $0 { free(UnsafeMutablePointer(mutating: p)) } } }
        // Only the command name is logged: "loadfile" carries the stream link (login data).
        let id = track(args.first ?? "command", pip: false)
        let r = mpv_command_async(h, id, &cargs)
        if r < 0, let p = untrack(id) { failed(p, r) }
    }

    /// Direct read, for panels and diagnostics only.
    func string(_ name: String) -> String? {
        guard let h = mpv, let c = mpv_get_property_string(h, name) else { return nil }
        defer { mpv_free(c) }
        return String(cString: c)
    }

    // MARK: Tracks

    struct Track { let id: String; let type: String; let name: String; let selected: Bool; let codec: String; let lang: String }

    var tracks: [Track] {
        guard let d = state.trackJSON.data(using: .utf8),
              let arr = (try? JSONSerialization.jsonObject(with: d)) as? [[String: Any]] else { return [] }
        return arr.compactMap { t in
            guard let type = t["type"] as? String, let idn = t["id"] as? Int else { return nil }
            let lang = t["lang"] as? String ?? ""
            let title = t["title"] as? String ?? ""
            let codec = t["codec"] as? String ?? "?"
            var parts: [String] = []
            if !title.isEmpty { parts.append(title) }
            if !lang.isEmpty { parts.append("[\(lang)]") }
            if type == "audio", let ch = t["demux-channel-count"] as? Int {
                parts.append(ch == 6 ? "5.1" : ch == 8 ? "7.1" : ch == 2 ? "ستيريو" : ch == 1 ? "أحادي" : "\(ch) قنوات")
            }
            var name = parts.isEmpty ? "مسار \(idn)" : parts.joined(separator: " ")
            if (t["forced"] as? Bool) == true { name += " · إجبارية" }
            if (t["external"] as? Bool) == true { name += " · خارجية" }
            return Track(id: String(idn), type: type, name: name + "  (\(codec))", selected: (t["selected"] as? Bool) == true,
                         codec: codec, lang: lang)
        }
    }

    // MARK: Events

    private func drain() {
        events.async { [weak self] in
            guard let self else { return }
            while let h = self.mpv, let e = mpv_wait_event(h, 0), e.pointee.event_id != MPV_EVENT_NONE {
                switch e.pointee.event_id {
                case MPV_EVENT_PROPERTY_CHANGE:
                    guard let p = UnsafeMutablePointer<mpv_event_property>(OpaquePointer(e.pointee.data))?.pointee,
                          let cname = p.name else { break }
                    let name = String(cString: cname)
                    switch p.format {
                    case MPV_FORMAT_DOUBLE:
                        let v = p.data.assumingMemoryBound(to: Double.self).pointee
                        self.update { if name == "time-pos" { $0.time = v } else if name == "duration" { $0.duration = v } }
                    case MPV_FORMAT_FLAG:
                        let v = p.data.assumingMemoryBound(to: Int32.self).pointee != 0
                        self.update {
                            switch name {
                            case "pause": $0.paused = v
                            case "paused-for-cache": $0.pausedForCache = v
                            case "seeking": $0.seeking = v
                            case "eof-reached": $0.eof = v
                            case "core-idle": $0.coreIdle = v
                            default: break
                            }
                        }
                    case MPV_FORMAT_INT64:
                        let v = p.data.assumingMemoryBound(to: Int64.self).pointee
                        if name == "height" { self.update { $0.height = Int(v) } }
                    case MPV_FORMAT_STRING:
                        if let s = p.data.assumingMemoryBound(to: UnsafePointer<CChar>?.self).pointee {
                            let v = String(cString: s)
                            if name == "track-list" { self.update { $0.trackJSON = v } }
                        }
                    case MPV_FORMAT_NONE:
                        // Property unavailable (nothing loaded): reset what depends on a file.
                        self.update {
                            if name == "time-pos" { $0.time = 0 } else if name == "duration" { $0.duration = 0 }
                            else if name == "height" { $0.height = 0 }
                        }
                    default: break
                    }
                case MPV_EVENT_LOG_MESSAGE:
                    if let m = UnsafeMutablePointer<mpv_event_log_message>(OpaquePointer(e.pointee.data))?.pointee,
                       let p = m.prefix, let l = m.level, let t = m.text {
                        let line = "[\(String(cString: l))] \(String(cString: p)): \(String(cString: t).trimmingCharacters(in: .newlines))"
                        self.note(line)
                        if self.pipOutput {
                            if line.contains("VO: [avfoundation]") { self.pipOutputReady = true }
                            // Only the avfoundation output's own failure counts (other outputs log errors while switching).
                            if line.contains("[error]") && line.contains("avfoundation") { self.pipOutputFailed = true }
                        }
                    }
                case MPV_EVENT_SET_PROPERTY_REPLY, MPV_EVENT_COMMAND_REPLY:
                    let id = e.pointee.reply_userdata, code = e.pointee.error
                    if let p = self.untrack(id), code < 0 { self.failed(p, code) }
                case MPV_EVENT_START_FILE: self.note("[مرحلة] بدء الملف")
                case MPV_EVENT_FILE_LOADED: self.note("[مرحلة] الملف محمّل"); self.update { $0.loaded = true; $0.endError = nil }
                case MPV_EVENT_VIDEO_RECONFIG: self.note("[مرحلة] تهيئة مخرج الفيديو")
                case MPV_EVENT_PLAYBACK_RESTART: self.note("[مرحلة] بدأ العرض")
                case MPV_EVENT_END_FILE:
                    if let d = UnsafeMutablePointer<mpv_event_end_file>(OpaquePointer(e.pointee.data))?.pointee {
                        switch d.reason {
                        case MPV_END_FILE_REASON_ERROR:
                            let msg = String(cString: mpv_error_string(d.error))
                            self.note("end-file: error: \(msg)")
                            self.update { $0.endError = msg; $0.loaded = false }
                        case MPV_END_FILE_REASON_EOF:
                            self.note("end-file: eof")
                            self.update { $0.eof = true }
                        case MPV_END_FILE_REASON_STOP: self.note("end-file: stop")
                        default: self.note("end-file: other")
                        }
                    }
                case MPV_EVENT_SHUTDOWN:
                    return
                default: break
                }
            }
        }
    }
}

// MARK: - Picture in picture for mpv (0.9.3)
//
// Normal playback stays on gpu-next (libplacebo: Dolby Vision, HDR, libass). Picture in picture needs an
// AVSampleBufferDisplayLayer, so for the floating window only, mpv's video output is switched at runtime to
// "avfoundation" (our patched libmpv, see patches/libmpv) drawing into that layer, then switched back.


/// View whose layer is the AVSampleBufferDisplayLayer mpv draws into during picture in picture.
final class MPVPiPView: UIView {
    override class var layerClass: AnyClass { AVSampleBufferDisplayLayer.self }
    var displayLayer: AVSampleBufferDisplayLayer { layer as! AVSampleBufferDisplayLayer }
}

extension MPVCore {
    /// Switches mpv's video output: avfoundation into `pipLayer`, or back to the normal Metal output.
    func setPiPOutput(_ on: Bool, pipLayer: AVSampleBufferDisplayLayer) {
        guard mpv != nil else { return }
        pipOutput = on
        pipOutputReady = false; pipOutputFailed = false
        lock.lock(); pipGen += 1; lock.unlock()
        // Detailed log while the output switches, so a failure here is visible in the session file.
        if let h = mpv { mpv_request_log_messages(h, on ? "v" : "info") }
        // 0.9.5: changing "wid" makes mpv recreate the CURRENT video output with the new layer. The device crash
        // (-[CAMetalLayer flush] unrecognized selector in the avfoundation output) was the avfoundation output
        // recreated with the Metal layer. So the output goes through "null" (which ignores wid) while the layer
        // changes: no output is ever created with the other output's layer.
        let layer: AnyObject = on ? pipLayer : view.metal
        let ptr = Int(bitPattern: Unmanaged.passUnretained(layer).toOpaque())
        // 0.9.7: Apple's sample-buffer layer can't reshape Dolby Vision profile 5 (IPTPQc2), so those frames came out
        // green/purple in the floating window. For Dolby Vision only, FFmpeg's libplacebo filter does the reshaping
        // (apply_dolbyvision, on by default) on its own Vulkan device and hands back a small SDR BT.709 NV12 picture,
        // which the avfoundation output accepts. Normal playback (gpu-next) never uses this filter.
        if on { pipDolbyVision = (string("video-params/colormatrix") ?? "") == "dolbyvision" }
        note("[مرحلة] صورة داخل صورة: \(on ? "تحويل المخرج إلى avfoundation" : "رجوع المخرج إلى \(createdLabVO)")\(pipDolbyVision ? " | Dolby Vision: فلتر libplacebo" : "")")
        setAsync("vo", "null", pip: true)
        if pipDolbyVision {
            if on {
                setAsync("hwdec", "videotoolbox-copy")
                setAsync("vf", "libplacebo=w=1280:h=720:force_original_aspect_ratio=decrease:format=nv12:colorspace=bt709:color_primaries=bt709:color_trc=bt709:range=tv")
            } else {
                setAsync("vf", "")
                setAsync("hwdec", createdLab == .noHwdec ? "no" : createdLab == .copyHwdec ? "videotoolbox-copy" : "videotoolbox")
            }
        }
        setAsync("wid", String(ptr), pip: true)
        setAsync("vo", on ? "avfoundation" : createdLabVO, pip: true)
        if !on { pipDolbyVision = false }
    }
}

/// AVPictureInPictureController for mpv's sample-buffer layer, with the playback state iOS asks for.
final class MPVPiP: NSObject, AVPictureInPictureControllerDelegate, AVPictureInPictureSampleBufferPlaybackDelegate {
    private(set) var view = MPVPiPView()
    private(set) var controller: AVPictureInPictureController?
    /// Earlier layer+controller pairs, kept alive together (0.9.9): the device crash was AVKit reading, from the
    /// layer, a controller that had been released (objc_retain in avkit_sampleBufferDisplayLayerPlayerController).
    private var retired: [(MPVPiPView, AVPictureInPictureController)] = []
    private var timebase: CMTimebase?

    var isPaused: () -> Bool = { false }
    var setPlaying: (Bool) -> Void = { _ in }
    var skip: (Double) -> Void = { _ in }
    var duration: () -> Double = { 0 }
    var isLive: () -> Bool = { false }
    var onActive: (Bool) -> Void = { _ in }
    var onFailed: (String) -> Void = { _ in }

    override init() {
        super.init()
        var tb: CMTimebase?
        CMTimebaseCreateWithSourceClock(allocator: kCFAllocatorDefault, sourceClock: CMClockGetHostTimeClock(), timebaseOut: &tb)
        if let tb {
            CMTimebaseSetTime(tb, time: .zero)
            CMTimebaseSetRate(tb, rate: 1)
            timebase = tb
        }
        configure(view)
        makeController()
    }

    private func configure(_ v: MPVPiPView) {
        v.backgroundColor = .black
        v.displayLayer.videoGravity = .resizeAspect
        if let timebase { v.displayLayer.controlTimebase = timebase }
    }

    private func makeController() {
        guard AVPictureInPictureController.isPictureInPictureSupported() else { return }
        let c = AVPictureInPictureController(contentSource: .init(sampleBufferDisplayLayer: view.displayLayer, playbackDelegate: self))
        c.delegate = self
        controller = c
    }

    /// A NEW layer with its own NEW controller for the next session (iOS refused a second start on the used ones).
    /// The used pair is never split: both stay alive together, so the old layer can't point at a released controller.
    /// The caller puts the new view in the hierarchy and gives its layer to mpv.
    func rebuild() {
        if let old = controller {
            old.delegate = nil
            retired.append((view, old))
            if retired.count > 6 { retired.removeFirst() }   // long finished by then
        }
        view = MPVPiPView()
        configure(view)
        makeController()
    }

    /// Clears a layer iOS left failed/interrupted after the last PiP session, so new frames are shown again.
    func resetLayer() {
        let l = view.displayLayer
        if l.status == .failed || l.requiresFlushToResumeDecoding { l.flush() }
        l.flushAndRemoveImage()
    }

    /// The layer is really showing frames (not just "output ready").
    var layerRendering: Bool { view.displayLayer.status == .rendering }

    /// Keeps the layer's clock on the playback position (PiP shows its progress from it). Small drift is left alone.
    func sync(timeS: Double, playing: Bool, rate: Float) {
        guard let tb = timebase else { return }
        let now = CMTimebaseGetTime(tb).seconds
        if !now.isFinite || abs(now - timeS) > 0.75 { CMTimebaseSetTime(tb, time: CMTime(seconds: timeS, preferredTimescale: 600)) }
        CMTimebaseSetRate(tb, rate: playing ? Float64(rate) : 0)
        controller?.invalidatePlaybackState()
    }

    // MARK: AVPictureInPictureSampleBufferPlaybackDelegate
    func pictureInPictureController(_ c: AVPictureInPictureController, setPlaying playing: Bool) { setPlaying(playing) }
    func pictureInPictureControllerTimeRangeForPlayback(_ c: AVPictureInPictureController) -> CMTimeRange {
        if isLive() { return CMTimeRange(start: .negativeInfinity, duration: .positiveInfinity) }
        let d = duration()
        return d > 0 ? CMTimeRange(start: .zero, duration: CMTime(seconds: d, preferredTimescale: 600))
                     : CMTimeRange(start: .negativeInfinity, duration: .positiveInfinity)
    }
    func pictureInPictureControllerIsPlaybackPaused(_ c: AVPictureInPictureController) -> Bool { isPaused() }
    func pictureInPictureController(_ c: AVPictureInPictureController, didTransitionToRenderSize newRenderSize: CMVideoDimensions) {}
    func pictureInPictureController(_ c: AVPictureInPictureController, skipByInterval skipInterval: CMTime, completion completionHandler: @escaping () -> Void) {
        skip(skipInterval.seconds); completionHandler()
    }

    // MARK: AVPictureInPictureControllerDelegate
    func pictureInPictureControllerDidStartPictureInPicture(_ c: AVPictureInPictureController) { onActive(true) }
    func pictureInPictureControllerDidStopPictureInPicture(_ c: AVPictureInPictureController) { onActive(false) }
    func pictureInPictureController(_ c: AVPictureInPictureController, failedToStartPictureInPictureWithError error: Error) {
        onFailed(error.localizedDescription)
    }
    func pictureInPictureController(_ c: AVPictureInPictureController, restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void) {
        completionHandler(true)
    }
}
