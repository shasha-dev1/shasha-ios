import SwiftUI
import UIKit
import Libmpv

// mpv engine (MPVKit: libmpv + FFmpeg + libplacebo + libdovi + libass, drawn with Vulkan via MoltenVK on a CAMetalLayer).
// Stage 1 (historical): the hand-off mpv player used before mpv became the only engine. MPVController/MPVPlayerView
// are no longer shown; the shared helpers here (MPVLab, MPVMetalLayer, MPVSessionFile, MPVFonts, MPVSubScale) are used.

/// mpv lab: exactly one factor changed at a time (exclusive choice), for the current hand-off only.
enum MPVLab: String, CaseIterable {
    case normal = "عادي (gpu-next + فك عتادي)"
    case voGPU = "مخرج vo=gpu بدل gpu-next"
    case copyHwdec = "فك عتادي بالنسخ (videotoolbox-copy)"
    case noHwdec = "بدون فك عتادي (hwdec=no)"
    /// Memory only (0.8.4): 0.8.3 saved the choice, so a mode that crashes mpv stayed on for every later
    /// file with no way back. Now every hand-off starts in normal mode, and the old saved value is erased.
    private static var mode: MPVLab = { UserDefaults.standard.removeObject(forKey: "mpvLab"); return .normal }()
    static var current: MPVLab {
        get { mode }
        set { mode = newValue }
    }
}

/// One hand-off to mpv.
struct MPVPlayback: Identifiable {
    let id = UUID()
    let url: URL
    let title: String
    let start: Double
}

/// MoltenVK workarounds taken from MPVKit's demo (drawable 1x1 flicker; EDR flag must be set on the main thread).
final class MPVMetalLayer: CAMetalLayer {
    /// Breadcrumb hook (set by the controller) so the session file shows whether the HDR surface was requested.
    static var onEDR: ((String) -> Void)?
    override var drawableSize: CGSize {
        get { super.drawableSize }
        set { if Int(newValue.width) > 1 && Int(newValue.height) > 1 { super.drawableSize = newValue } }
    }
    override var wantsExtendedDynamicRangeContent: Bool {
        get { super.wantsExtendedDynamicRangeContent }
        set {
            MPVMetalLayer.onEDR?("EDR=\(newValue) من \(Thread.isMainThread ? "الواجهة" : "خيط mpv")")
            if Thread.isMainThread { super.wantsExtendedDynamicRangeContent = newValue }
            // async, not sync (0.8.2): the demo's main.sync can deadlock when the main thread is itself waiting
            // inside an mpv call (our 0.5 s property reads) while the video thread sets up an HDR/Dolby Vision surface.
            else { DispatchQueue.main.async { super.wantsExtendedDynamicRangeContent = newValue } }
        }
    }
}

final class MPVController: UIViewController {
    let metal = MPVMetalLayer()
    private(set) var mpv: OpaquePointer?
    private let events = DispatchQueue(label: "app.shasha.mpv.events")
    private let playback: MPVPlayback
    /// Warnings/errors from mpv for the info sheet (links removed before display).
    private(set) var log: [String] = []
    private let logLock = NSLock()
    var onEndOfFile: ((_ reason: String) -> Void)?

    init(_ p: MPVPlayback) { playback = p; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        metal.frame = view.bounds
        metal.contentsScale = UIScreen.main.nativeScale
        metal.framebufferOnly = true
        metal.backgroundColor = UIColor.black.cgColor
        view.layer.addSublayer(metal)
        start()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        metal.frame = view.bounds
    }

    private func start() {
        MPVSessionFile.begin(secrets: MPVSessionFile.secrets(of: playback.url))
        MPVMetalLayer.onEDR = { [weak self] in self?.note("[مرحلة] \($0)") }
        note("[مرحلة] إنشاء mpv | البداية عند \(Int(playback.start)) ث")
        guard let h = mpv_create() else { note("mpv_create failed"); return }
        mpv = h
        mpv_request_log_messages(h, "info")
        var layerPtr = metal
        set("wid", int64Pointer: &layerPtr)
        let lab = MPVLab.current
        note("[مرحلة] وضع الاختبار: \(lab.rawValue)")
        set("vo", lab == .voGPU ? "gpu" : "gpu-next")
        set("gpu-api", "vulkan")
        set("gpu-context", "moltenvk")
        set("hwdec", lab == .noHwdec ? "no" : lab == .copyHwdec ? "videotoolbox-copy" : "videotoolbox")
        set("video-rotate", "no")
        set("keep-open", "yes")                 // stay on the last frame; the app decides what happens at the end
        set("cache", "yes")
        set("demuxer-max-bytes", "150MiB")
        set("slang", "ar,ara,arabic")
        set("subs-fallback", "yes")
        // 0.8.6: the session log showed libass has no system font provider here ("can't find selected font
        // provider", then no fallback glyphs), so subtitles were decoded but drawn with no font at all.
        // Give libass a font of its own: Noto Sans Arabic (SIL OFL, bundled), which also covers Latin.
        if let dir = MPVFonts.directory() {
            set("sub-fonts-dir", dir)
            set("sub-font", "Noto Sans Arabic")
            note("[مرحلة] خط الترجمة: Noto Sans Arabic من مجلد خاص")
        } else {
            note("[مرحلة] خط الترجمة: الخط المرفق غير موجود")
        }
        set("sub-font-size", "46")
        set("sub-scale", String(format: "%.2f", MPVSubScale.value))   // ASS sizes come from the file; this scales them
        if playback.start > 5 { set("start", String(format: "%.0f", playback.start)) }
        let pref = PlayerPrefs.audio
        if pref.contains("ara") { set("alang", "ar,ara,arabic") } else if pref.contains("eng") { set("alang", "en,eng,english") }
        check(mpv_initialize(h), "initialize")
        note("[مرحلة] تمت التهيئة")
        mpv_set_wakeup_callback(h, { ctx in
            guard let ctx else { return }
            Unmanaged<MPVController>.fromOpaque(ctx).takeUnretainedValue().drainEvents()
        }, Unmanaged.passUnretained(self).toOpaque())
        note("[مرحلة] فتح الملف")
        command(["loadfile", playback.url.absoluteString, "replace"])
        NotificationCenter.default.addObserver(self, selector: #selector(background), name: UIApplication.didEnterBackgroundNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(foreground), name: UIApplication.willEnterForegroundNotification, object: nil)
    }

    // Fix from the demo: the Metal surface is lost in the background; drop video and bring it back.
    @objc private func background() { setFlag("pause", true); set("vid", "no") }
    @objc private func foreground() { set("vid", "auto") }

    func shutdown() {
        NotificationCenter.default.removeObserver(self)
        guard let h = mpv else { return }
        note("[مرحلة] إغلاق طبيعي")
        MPVMetalLayer.onEDR = nil
        mpv_set_wakeup_callback(h, nil, nil)
        // 0.9.0: wait for the event queue before destroying. Before, the handle could be destroyed on the main
        // thread while drainEvents was still inside mpv_wait_event(h) on its own queue (use after free) — a crash
        // that shows up only sometimes, when going back from mpv to VLC.
        events.sync { self.mpv = nil }
        mpv_terminate_destroy(h)
    }

    deinit { shutdown() }

    // MARK: Small API

    func set(_ name: String, _ value: String) {
        guard let h = mpv else { return }
        check(mpv_set_option_string(h, name, value), "option \(name)")
    }
    private func set(_ name: String, int64Pointer p: UnsafeMutableRawPointer) {
        guard let h = mpv else { return }
        check(mpv_set_option(h, name, MPV_FORMAT_INT64, p), "option \(name)")
    }
    func setProperty(_ name: String, _ value: String) {
        guard let h = mpv else { return }
        check(mpv_set_property_string(h, name, value), "set \(name)")
    }
    func setFlag(_ name: String, _ on: Bool) {
        guard let h = mpv else { return }
        var v: Int32 = on ? 1 : 0
        mpv_set_property(h, name, MPV_FORMAT_FLAG, &v)
    }
    func flag(_ name: String) -> Bool {
        guard let h = mpv else { return false }
        var v: Int32 = 0
        mpv_get_property(h, name, MPV_FORMAT_FLAG, &v)
        return v != 0
    }
    func double(_ name: String) -> Double {
        guard let h = mpv else { return 0 }
        var v: Double = 0
        mpv_get_property(h, name, MPV_FORMAT_DOUBLE, &v)
        return v
    }
    func string(_ name: String) -> String? {
        guard let h = mpv, let c = mpv_get_property_string(h, name) else { return nil }
        defer { mpv_free(c) }
        return String(cString: c)
    }
    func command(_ args: [String]) {
        guard let h = mpv else { return }
        var cargs: [UnsafePointer<CChar>?] = args.map { UnsafePointer(strdup($0)) }
        cargs.append(nil)
        defer { cargs.forEach { if let p = $0 { free(UnsafeMutablePointer(mutating: p)) } } }
        check(mpv_command(h, &cargs), args.first ?? "command")
    }

    struct Track: Identifiable { let id: String; let name: String; let selected: Bool; let codec: String }

    /// Audio ("audio") or subtitle ("sub") tracks from mpv's track-list.
    func tracks(_ type: String) -> [Track] {
        let n = Int(string("track-list/count") ?? "0") ?? 0
        var out: [Track] = []
        for i in 0..<n where string("track-list/\(i)/type") == type {
            let id = string("track-list/\(i)/id") ?? "\(i)"
            let lang = string("track-list/\(i)/lang") ?? ""
            let title = string("track-list/\(i)/title") ?? ""
            let codec = string("track-list/\(i)/codec") ?? "?"
            let ext = string("track-list/\(i)/external") == "yes" ? " · خارجية" : ""
            let name = [title, lang.isEmpty ? nil : "[\(lang)]"].compactMap { $0?.isEmpty == false ? $0 : nil }.joined(separator: " ")
            out.append(Track(id: id, name: (name.isEmpty ? "مسار \(id)" : name) + ext,
                             selected: string("track-list/\(i)/selected") == "yes", codec: codec))
        }
        return out
    }

    // MARK: Events and log

    private func drainEvents() {
        events.async { [weak self] in
            guard let self else { return }
            while let h = self.mpv, let e = mpv_wait_event(h, 0), e.pointee.event_id != MPV_EVENT_NONE {
                switch e.pointee.event_id {
                case MPV_EVENT_LOG_MESSAGE:
                    if let m = UnsafeMutablePointer<mpv_event_log_message>(OpaquePointer(e.pointee.data))?.pointee,
                       let p = m.prefix, let l = m.level, let t = m.text {
                        self.note("[\(String(cString: l))] \(String(cString: p)): \(String(cString: t).trimmingCharacters(in: .newlines))")
                    }
                case MPV_EVENT_END_FILE:
                    let reason: String
                    if let d = UnsafeMutablePointer<mpv_event_end_file>(OpaquePointer(e.pointee.data))?.pointee {
                        switch d.reason {
                        case MPV_END_FILE_REASON_EOF: reason = "eof"
                        case MPV_END_FILE_REASON_ERROR: reason = "error: " + String(cString: mpv_error_string(d.error))
                        default: reason = "other"
                        }
                    } else { reason = "?" }
                    self.note("end-file: \(reason)")
                    DispatchQueue.main.async { self.onEndOfFile?(reason) }
                case MPV_EVENT_START_FILE: self.note("[مرحلة] بدء الملف")
                case MPV_EVENT_FILE_LOADED: self.note("[مرحلة] الملف محمّل")
                case MPV_EVENT_VIDEO_RECONFIG: self.note("[مرحلة] تهيئة مخرج الفيديو")
                case MPV_EVENT_PLAYBACK_RESTART: self.note("[مرحلة] بدأ العرض")
                case MPV_EVENT_SHUTDOWN:
                    return
                default: break
                }
            }
        }
    }

    private func check(_ status: Int32, _ what: String) {
        if status < 0 { note("API \(what): \(String(cString: mpv_error_string(status)))") }
    }

    func note(_ s: String) {
        logLock.lock(); log.append(s); if log.count > 300 { log.removeFirst(log.count - 300) }; logLock.unlock()
        MPVSessionFile.append(s)
    }

    func logLines() -> [String] { logLock.lock(); defer { logLock.unlock() }; return log }
}

struct MPVControllerView: UIViewControllerRepresentable {
    let controller: MPVController
    func makeUIViewController(context: Context) -> MPVController { controller }
    func updateUIViewController(_ c: MPVController, context: Context) {}
}

/// Minimal controls around the mpv view: play/pause, ±10 s, seek bar, audio/subtitle lists, engine info.
struct MPVPlayerView: View {
    let playback: MPVPlayback
    /// position s, duration s, reached the end
    let onClose: (Double, Double, Bool) -> Void
    @State private var controller: MPVController
    @State private var time: Double = 0
    @State private var duration: Double = 0
    @State private var paused = false
    @State private var buffering = true
    @State private var controls = true
    @State private var scrub: Double?
    @State private var panel: String?          // "audio" / "sub" / "info"
    @State private var info = ""
    @State private var ended = false
    @State private var beat = 0
    @State private var subScale = MPVSubScale.value
    private let tick = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()

    init(playback: MPVPlayback, onClose: @escaping (Double, Double, Bool) -> Void) {
        self.playback = playback
        self.onClose = onClose
        _controller = State(initialValue: MPVController(playback))
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            MPVControllerView(controller: controller).id(ObjectIdentifier(controller)).ignoresSafeArea()
                .onTapGesture { withAnimation { controls.toggle() } }
            if buffering && !paused { ProgressView().tint(.white).scaleEffect(1.5).allowsHitTesting(false) }
            if controls { overlay.transition(.opacity) }
            if let p = panel { panelView(p) }
        }
        .environment(\.layoutDirection, .leftToRight)
        .statusBarHidden(true)
        .onReceive(tick) { _ in
            beat += 1
            if beat % 10 == 1 { controller.note(String(format: "[نبض الواجهة] %.0f ث", time)) }
            time = controller.double("time-pos")
            duration = controller.double("duration")
            paused = controller.flag("pause")
            buffering = controller.flag("paused-for-cache") || controller.flag("seeking") || time == 0
        }
        .onAppear {
            controller.onEndOfFile = { reason in if reason == "eof" { ended = true; finish() } }
        }
    }

    private var overlay: some View {
        VStack {
            HStack(spacing: 14) {
                Button { finish() } label: {
                    Label("رجوع", systemImage: "chevron.down").font(.callout.bold())
                        .padding(.horizontal, 12).padding(.vertical, 8).background(.black.opacity(0.55), in: Capsule())
                }
                Text(playback.title).font(.headline).lineLimit(1)
                Spacer()
                Text("mpv").font(.caption2.bold()).padding(.horizontal, 7).padding(.vertical, 3)
                    .background(Theme.teal, in: RoundedRectangle(cornerRadius: 5)).foregroundStyle(.black)
                Button { panel = "audio" } label: { Image(systemName: "waveform").font(.title3).frame(width: 40, height: 40) }
                Button { panel = "sub" } label: { Image(systemName: "captions.bubble").font(.title3).frame(width: 40, height: 40) }
                Button { info = infoText(); panel = "info" } label: { Image(systemName: "stethoscope").font(.title3).frame(width: 40, height: 40) }
            }
            .padding(.horizontal, 16).padding(.top, 8)
            Spacer()
            HStack(spacing: 56) {
                Button { controller.command(["seek", "-10"]) } label: { Image(systemName: "gobackward.10").font(.system(size: 36)) }
                Button { controller.setFlag("pause", !paused) } label: {
                    Image(systemName: paused ? "play.fill" : "pause.fill").font(.system(size: 40))
                        .frame(width: 84, height: 84).background(.white.opacity(0.18), in: Circle())
                }
                Button { controller.command(["seek", "10"]) } label: { Image(systemName: "goforward.10").font(.system(size: 36)) }
            }
            Spacer()
            if duration > 0 {
                let shown = scrub ?? (time / max(duration, 1))
                HStack(spacing: 10) {
                    Text(fmt(shown * duration)).font(.caption.monospacedDigit())
                    Slider(value: Binding(get: { shown }, set: { scrub = $0 }), in: 0...1, onEditingChanged: { editing in
                        if !editing, let s = scrub {
                            controller.command(["seek", String(format: "%.1f", s * duration), "absolute"]); scrub = nil
                        }
                    }).tint(Theme.accent)
                    Text("-" + fmt(max(0, duration - shown * duration))).font(.caption.monospacedDigit())
                }
                .padding(.horizontal, 16).padding(.bottom, 12)
            }
        }
        .foregroundStyle(.white)
        .background(LinearGradient(colors: [.black.opacity(0.65), .clear, .clear, .black.opacity(0.7)], startPoint: .top, endPoint: .bottom)
            .ignoresSafeArea().allowsHitTesting(false))
    }

    private func panelView(_ p: String) -> some View {
        HStack(spacing: 0) {
            Color.black.opacity(0.35).contentShape(Rectangle()).onTapGesture { panel = nil }
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text(p == "audio" ? "الصوت" : p == "sub" ? "الترجمة" : "معلومات المحرّك").font(.headline)
                    Spacer()
                    if p == "info" { Button("نسخ") { UIPasteboard.general.string = info } }
                    Button { panel = nil } label: { Image(systemName: "xmark").frame(width: 40, height: 40) }
                }
                .padding(.horizontal, 16).padding(.top, 10)
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        if p == "info" {
                            Text("مختبر mpv — عامل واحد فقط في كل مرة، يعيد الفتح من نفس النقطة").font(.caption.bold()).padding(.horizontal, 12).padding(.top, 8)
                            ForEach(MPVLab.allCases, id: \.self) { m in
                                row(m.rawValue, selected: MPVLab.current == m) { reopen(with: m) }
                            }
                            Text(info).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading).padding(12)
                        } else {
                            let list = controller.tracks(p)
                            if p == "sub" {
                                HStack(spacing: 10) {
                                    Text("حجم الترجمة \(Int((subScale * 100).rounded()))٪").font(.callout)
                                    Spacer()
                                    sizeButton("textformat.size.smaller", -0.1)
                                    sizeButton("textformat.size.larger", 0.1)
                                }
                                .padding(12)
                            }
                            if p == "sub" { row("بدون ترجمة", selected: !list.contains(where: \.selected)) { controller.setProperty("sid", "no"); panel = nil } }
                            if list.isEmpty { Text(p == "sub" ? "لا توجد ترجمة" : "لا توجد مسارات").foregroundStyle(.secondary).padding(12) }
                            ForEach(list) { t in
                                row("\(t.name)  (\(t.codec))", selected: t.selected) {
                                    controller.setProperty(p == "sub" ? "sid" : "aid", t.id); panel = nil
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 8)
                }
            }
            .frame(width: 360).frame(maxHeight: .infinity)
            .background(.ultraThinMaterial).background(Color.black.opacity(0.55))
            .environment(\.layoutDirection, .rightToLeft)
        }
        .foregroundStyle(.white)
        .ignoresSafeArea()
    }

    private func row(_ text: String, selected: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle").foregroundStyle(selected ? Theme.accent : .white.opacity(0.35))
                Text(text).lineLimit(2).multilineTextAlignment(.leading)
                Spacer(minLength: 0)
            }
            .padding(12).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// What mpv itself reports: output, decoder, colour description of the video (Dolby Vision shows as colormatrix "dolbyvision").
    private func infoText() -> String {
        func p(_ n: String) -> String { controller.string(n) ?? "غير متاح" }
        var l = ["وضع الاختبار: \(MPVLab.current.rawValue)",
                 "المحرّك: mpv \(p("mpv-version")) | FFmpeg \(p("ffmpeg-version"))",
                 "مخرج الفيديو: \(p("current-vo")) | gpu-api: vulkan (MoltenVK)",
                 "الترجمة: sid=\(p("sid")) | sub-visibility=\(p("sub-visibility")) | النص الحالي: \(p("sub-text").isEmpty ? "(فارغ)" : p("sub-text"))",
                 "فك الترميز العتادي: \(p("hwdec-current"))",
                 "ترميز الفيديو: \(p("video-codec")) | \(p("video-params/w"))x\(p("video-params/h")) | \(p("video-params/pixelformat"))",
                 "colormatrix: \(p("video-params/colormatrix")) | gamma: \(p("video-params/gamma")) | primaries: \(p("video-params/primaries")) | sig-peak: \(p("video-params/sig-peak"))",
                 "الحاوية: \(p("file-format")) | الترجمة المحددة: \(p("current-tracks/sub/codec")) [\(p("current-tracks/sub/lang"))]",
                 "", "— تحذيرات mpv"]
        l += controller.logLines().suffix(80)
        return DiagRule.redact(l.joined(separator: "\n"), secrets: [])
    }

    private func sizeButton(_ icon: String, _ step: Double) -> some View {
        Button {
            subScale = min(3.0, max(0.5, ((subScale + step) * 10).rounded() / 10))
            MPVSubScale.value = subScale
            controller.setProperty("sub-scale", String(format: "%.2f", subScale))
        } label: {
            Image(systemName: icon).font(.title3).frame(width: 48, height: 40).background(.white.opacity(0.15), in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }

    /// Reopen the same file at the current position with another lab mode.
    private func reopen(with m: MPVLab) {
        guard m != MPVLab.current else { return }
        MPVLab.current = m
        let pos = controller.double("time-pos")
        controller.shutdown()
        let fresh = MPVController(MPVPlayback(url: playback.url, title: playback.title, start: pos > 5 ? pos : playback.start))
        fresh.onEndOfFile = { reason in if reason == "eof" { ended = true; finish() } }
        controller = fresh
        panel = nil; time = 0; duration = 0; buffering = true
    }

    private func finish() {
        let pos = controller.double("time-pos"), dur = controller.double("duration")
        controller.shutdown()
        onClose(pos, dur, ended)
    }

    private func fmt(_ s: Double) -> String {
        let t = Int(max(0, s))
        return t >= 3600 ? String(format: "%d:%02d:%02d", t / 3600, t / 60 % 60, t % 60) : String(format: "%02d:%02d", t / 60, t % 60)
    }
}

/// The last mpv session written line by line to a file, so it survives a crash or a forced close and can be
/// copied from the diagnostics on the next launch. Links and account parts are removed before writing.
enum MPVSessionFile {
    private static let lock = NSLock()
    private static var handle: FileHandle?
    private static var lines = 0
    private static var secrets: [String] = []
    static var url: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("mpv-last-session.log")
    }

    /// Host, user, password and the other path parts of the stream link.
    static func secrets(of u: URL) -> [String] {
        ([u.host, u.user, u.password].compactMap { $0 } + u.pathComponents).filter { $0.count >= 3 && $0 != "movie" && $0 != "series" }
    }

    /// The session before the current one (kept so a crash log survives the next open, 0.9.4).
    static var previousURL: URL { url.deletingLastPathComponent().appendingPathComponent("mpv-prev-session.log") }

    static func begin(secrets s: [String]) {
        lock.lock(); defer { lock.unlock() }
        try? handle?.close()
        let fm = FileManager.default
        if fm.fileExists(atPath: url.path) {
            try? fm.removeItem(at: previousURL)
            try? fm.moveItem(at: url, to: previousURL)
        }
        fm.createFile(atPath: url.path, contents: nil)
        handle = try? FileHandle(forWritingTo: url)
        lines = 0
        secrets = s
    }

    static func append(_ line: String) {
        lock.lock(); defer { lock.unlock() }
        guard let h = handle, lines < 3000 else { return }
        lines += 1
        let stamp = String(format: "%.3f", Date().timeIntervalSince1970.truncatingRemainder(dividingBy: 1000))
        let clean = DiagRule.redact(line, secrets: secrets)
        if let d = "\(stamp) \(clean)\n".data(using: .utf8) { h.write(d); try? h.synchronize() }
    }

    /// Text of the session before the current one.
    static func beforeCurrent() -> String? {
        guard let d = try? Data(contentsOf: previousURL), !d.isEmpty else { return nil }
        return String(decoding: d, as: UTF8.self)
    }

    /// Text of the previous session (or nil if there is none).
    static func previous() -> String? {
        lock.lock(); defer { lock.unlock() }
        guard let d = try? Data(contentsOf: url), !d.isEmpty else { return nil }
        return String(decoding: d, as: UTF8.self)
    }
}

/// A folder holding only the bundled subtitle font (libass reads every file in sub-fonts-dir, so the app
/// bundle itself can't be used).
enum MPVFonts {
    static func directory() -> String? {
        guard let src = Bundle.main.url(forResource: "NotoSansArabic", withExtension: "ttf") else { return nil }
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("mpv-fonts", isDirectory: true)
        let dst = dir.appendingPathComponent("NotoSansArabic.ttf")
        let fm = FileManager.default
        if !fm.fileExists(atPath: dst.path) {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            do { try fm.copyItem(at: src, to: dst) } catch { return nil }
        }
        return dir.path
    }
}

/// The viewer's subtitle size in mpv (a taste, so it is kept between launches). 1.0 = the file's own size.
enum MPVSubScale {
    static var value: Double {
        get { let v = UserDefaults.standard.double(forKey: "mpvSubScale"); return v > 0 ? v : 1.6 }
        set { UserDefaults.standard.set(newValue, forKey: "mpvSubScale") }
    }
}
