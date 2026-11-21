import SwiftUI
import UIKit
import MediaPlayer
import AVFoundation
import UniformTypeIdentifiers

/// What to play: a live channel inside its list (switch channels) or a film/episode inside its queue.
enum PlayItem: Identifiable {
    case live(list: [Channel], index: Int)
    case vod(list: [VodPlay], index: Int)

    var id: String {
        switch self {
        case .live(let l, let i): return "live:" + l[i].id
        case .vod(let l, let i): return "vod:" + l[i].key
        }
    }
}

/// A film, or one episode of a series (season/number set).
struct VodPlay: Hashable {
    let title: String
    let url: String
    let key: String
    var query: SubQuery
    var season: Int? = nil
    var number: Int? = nil
    /// Provider's ffprobe lines, and the file extension from the link (for diagnostics only).
    var probe: [String] = []
    var container: String? = nil
}

// MARK: - Engine

/// The player's engine: mpv (MPVCore), polled twice a second from its cached properties. VLC was removed in 1.0.0
/// (its last version is on the branch "vlc-engine").
final class PlayerModel: ObservableObject {
    let mpv = MPVCore()
    /// mpv lab mode for the next open (one factor, this open only).
    var mpvLab: MPVLab = .normal
    /// Picture in picture (mpv's avfoundation output into a sample-buffer layer).
    let mpvPiP = MPVPiP()
    /// Called when picture in picture can't be started (the screen shows why).
    var onMPVPiPUnavailable: ((String) -> Void)?
    private var pipAttempt = 0
    private var pipRetry = 0
    /// The video is in the floating window.
    @Published var pipActive = false

    /// 1.0.6 measurement: player models alive right now (should be 0 after leaving the player).
    static var alive = 0
    deinit {
        PlayerModel.alive -= 1
        Perf.shared.add("مشغّل: تحرير نموذج المشغّل", ms: 0, "الحية الآن \(PlayerModel.alive)")
    }

    init() {
        PlayerModel.alive += 1
        Perf.shared.add("مشغّل: إنشاء نموذج المشغّل", ms: 0, "الحية الآن \(PlayerModel.alive) · محركات mpv \(MPVCore.alive)")
        mpvPiP.isPaused = { [weak self] in self?.viewerPaused ?? true }
        mpvPiP.setPlaying = { [weak self] on in self?.command(on ? .play : .pause) }
        mpvPiP.skip = { [weak self] s in self?.jump(Int32(s)) }
        mpvPiP.duration = { [weak self] in Double(self?.lengthMs ?? 0) / 1000 }
        mpvPiP.isLive = { [weak self] in self?.live ?? false }
        mpvPiP.onActive = { [weak self] on in
            guard let self else { return }
            DiagLog.shared.note("[التطبيق] صورة داخل صورة: \(on ? "بدأت" : "انتهت")")
            self.pipActive = on
            // Inside the controller's own callback: no controller rebuild here; the next start makes a new pair.
            if !on { self.mpv.setPiPOutput(false, pipLayer: self.mpvPiP.view.displayLayer) }
        }
        mpvPiP.onFailed = { [weak self] msg in
            guard let self else { return }
            self.mpv.note("[مرحلة] صورة داخل صورة رفضها النظام: \(msg) | الطبقة: \(self.mpvPiP.view.displayLayer.status.rawValue) | محاولة \(self.pipRetry + 1)")
            if self.pipRetry == 0 {
                self.pipRetry = 1
                let attempt = self.pipAttempt
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    // 1.0.1: the retry belongs to this attempt only (not after a cancel, a new file or a new start).
                    guard attempt == self.pipAttempt, !self.pipActive else { return }
                    self.mpvPiP.rebuild(); self.installPiPView()
                    self.mpv.setPiPOutput(true, pipLayer: self.mpvPiP.view.displayLayer)
                    self.pipStartPoll()
                }
                return
            }
            self.pipRetry = 0
            self.mpv.setPiPOutput(false, pipLayer: self.mpvPiP.view.displayLayer)
            self.onMPVPiPUnavailable?(msg)
        }
    }

    func togglePiP() {
        if pipActive { cancelPiPAttempts(); mpvPiP.controller?.stopPictureInPicture() } else { startMPVPiP() }
    }

    /// 1.0.1: ends any start still waiting (poll or retry), so an old attempt can't start the window, switch the output
    /// or show a message later. If the output was switched for an attempt that never became a window, it goes back.
    private func cancelPiPAttempts() {
        pipAttempt += 1
        pipRetry = 0
        if mpv.pipOutput && !pipActive { mpv.setPiPOutput(false, pipLayer: mpvPiP.view.displayLayer) }
    }

    func startPiPIfPossible() {
        if !pipActive, playing { startMPVPiP() }
    }

    /// Puts the current PiP view under mpv's Metal view (replacing the previous one in the hierarchy).
    private func installPiPView() {
        guard let host = hostView else { return }
        for v in host.subviews where v is MPVPiPView && v !== mpvPiP.view { v.removeFromSuperview() }
        if mpvPiP.view.superview !== host {
            mpvPiP.view.frame = host.bounds
            mpvPiP.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            host.insertSubview(mpvPiP.view, at: 0)
        }
    }

    /// Switch the output to the sample-buffer layer, wait for its first frames, then start the floating window.
    func startMPVPiP() {
        guard mpvPiP.controller != nil else { onMPVPiPUnavailable?("الجهاز لا يدعم صورة داخل صورة"); return }
        cancelPiPAttempts()
        mpvPiP.rebuild()          // new layer + controller for every session, made while no PiP callback is running
        installPiPView()
        mpvPiP.sync(timeS: Double(timeMs) / 1000, playing: !viewerPaused, rate: rate)
        mpv.setPiPOutput(true, pipLayer: mpvPiP.view.displayLayer)
        pipStartPoll()
    }

    /// Waits until mpv's avfoundation output is up AND the layer is showing frames, then starts the window.
    private func pipStartPoll() {
        guard let c = mpvPiP.controller else { return }
        pipAttempt += 1
        let attempt = pipAttempt
        func poll(_ n: Int) {
            guard attempt == pipAttempt, !pipActive else { return }
            if mpv.pipOutputFailed {
                mpv.setPiPOutput(false, pipLayer: mpvPiP.view.displayLayer)
                onMPVPiPUnavailable?("مخرج avfoundation غير متاح في mpv")
                return
            }
            if mpv.pipOutputReady && mpvPiP.layerRendering && c.isPictureInPicturePossible {
                mpv.note("[مرحلة] صورة داخل صورة: بدء النافذة")
                c.startPictureInPicture()
                return
            }
            if n >= 40 {
                mpv.setPiPOutput(false, pipLayer: mpvPiP.view.displayLayer)
                onMPVPiPUnavailable?("لم تجهز خلال 4 ثوانٍ (المخرج: \(mpv.pipOutputReady ? "جاهز" : "غير جاهز")، الطبقة: \(mpvPiP.layerRendering ? "تعرض" : "لا تعرض")، النظام: \(c.isPictureInPicturePossible ? "يسمح" : "لا يسمح"))")
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { poll(n + 1) }
        }
        poll(0)
    }

    /// Values that change twice a second live in `clock`, observed only by the few small views that show them.
    /// Otherwise the whole player (and any open menu) would redraw on every tick: menus jumped under the finger.
    let clock = PlayerClock()
    var timeMs: Int32 { get { clock.timeMs } set { if clock.timeMs != newValue { clock.timeMs = newValue } } }
    var lengthMs: Int32 { get { clock.lengthMs } set { if clock.lengthMs != newValue { clock.lengthMs = newValue } } }
    var buffering: Bool { get { clock.buffering } set { if clock.buffering != newValue { clock.buffering = newValue } } }
    @Published var playing = false
    /// Live stream stopped, or the engine reported an error.
    @Published var failed = false
    /// Set once when a film/episode reaches the engine's end: finished, or stopped before the end.
    @Published var endDecision: EndDecision?
    /// The viewer's pause, shared by on-screen buttons and Control Center.
    @Published private(set) var viewerPaused = false
    /// Session whose numbers the engine is reporting (set when an item is opened).
    private(set) var engineSessionId: Int?
    /// Last clock seen while the item was really playing (the clock can read 0 after the end).
    private(set) var lastPlayingMs: Int32 = 0
    @Published var rate: Float = 1
    @Published var videoHeight: Int = 0
    @Published var subDelay: Double = 0
    private var timer: Timer?
    private var live = false
    /// The SwiftUI host the video views live in.
    weak var hostView: UIView?

    /// Puts mpv's views in the host. Called before each open.
    func attachDrawable() {
        guard let host = hostView else { return }
        if mpvPiP.view.superview !== host {
            mpvPiP.view.frame = host.bounds
            mpvPiP.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            host.insertSubview(mpvPiP.view, at: 0)     // under mpv's Metal view; PiP takes its frames
        }
        if mpv.view.superview !== host {
            mpv.view.frame = host.bounds
            mpv.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            host.addSubview(mpv.view)
        }
    }
    /// Subtitle track to re-select after a reopen (mpv track id).
    var pendingSubtitleId: String?
    private var stall = StallDetector()
    /// The item really played in this session.
    private var hasPlayed = false

    func open(_ url: String, startSeconds: Double = 0, live: Bool = false, session: Int) {
        engineSessionId = session
        guard let u = URL(string: url) else { failed = true; return }
        self.live = live
        failed = false; endDecision = nil; viewerPaused = false; hasPlayed = false
        subDelay = 0; stall.reset(); buffering = true; timeMs = 0; lengthMs = 0
        lastPlayingMs = Int32(max(0, startSeconds) * 1000)
        cancelPiPAttempts()
        attachDrawable()
        let lab = mpvLab; mpvLab = .normal
        DiagLog.shared.note(String(format: "[فتح] mpv | %@ | بداية من %.0f ث | وضع: %@", u.isFileURL ? "ملف محلي" : "HTTP", startSeconds, lab.rawValue))
        mpv.open(u, start: startSeconds, live: live, alang: PlayerPrefs.audio, slang: PlayerPrefs.subs, lab: lab)
        if rate != 1 { mpv.setAsync("speed", String(format: "%.2f", rate)) }
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.tick() }
    }

    /// StallDetector and EndRule (PlaybackLogic), fed from mpv's cached properties.
    private func tick() {
        let s = mpv.state
        let t = Int32(max(0, s.time) * 1000)
        if s.loaded { timeMs = t }
        if s.duration > 0 { lengthMs = Int32(s.duration * 1000) }
        let st: EngineState
        if s.endError != nil { st = .error }
        else if s.eof { st = .ended }
        else if !s.loaded { st = .opening }
        else if s.pausedForCache || s.seeking { st = .buffering }
        else if s.paused { st = .paused }
        else { st = .playing }
        let isPlaying = st == .playing || st == .buffering
        if playing != isPlaying { playing = isPlaying }
        if (st == .playing || st == .buffering), t > 0 { lastPlayingMs = t; hasPlayed = true }
        if !failed, st == .error || (live && hasPlayed && st == .ended) { failed = true }
        let stalled = stall.sample(timeMs: t, state: st, viewerPaused: viewerPaused)
        if !live, endDecision == nil, hasPlayed,
           EndRule.engineStopped(state: st, viewerPaused: viewerPaused, frozenMs: stall.frozenMs, timeMs: lastPlayingMs, lengthMs: lengthMs) {
            endDecision = EndRule.onEnded(lastTimeMs: lastPlayingMs, lengthMs: lengthMs)
        }
        buffering = !failed && endDecision == nil && (stalled || st == .opening)
        if let want = pendingSubtitleId, mpv.tracks.contains(where: { $0.type == "sub" && $0.id == want }) {
            pendingSubtitleId = nil
            selectSubtitle(want)
        }
        if s.height > 0 && s.height != videoHeight { videoHeight = s.height }
        if pipActive || mpv.pipOutput { mpvPiP.sync(timeS: s.time, playing: isPlaying && !viewerPaused, rate: rate) }
    }

    var quality: String? {
        switch videoHeight {
        case 0: return nil
        case 1900...: return "4K"
        case 1000...: return "FHD"
        case 700...: return "HD"
        default: return "SD"
        }
    }

    func setRate(_ r: Float) {
        mpv.setAsync("speed", String(format: "%.2f", r))
        rate = r
    }

    enum Fit: String, CaseIterable { case fit = "ملاءمة", fill = "ملء الشاشة", wide = "16:9", classic = "4:3" }

    /// Picture shape.
    func apply(_ f: Fit) {
        mpv.setAsync("panscan", f == .fill ? "1.0" : "0.0")
        mpv.setAsync("video-aspect-override", f == .wide ? "16:9" : f == .classic ? "4:3" : "no")
    }

    /// The only way to play/pause: on-screen buttons, Control Center and the floating window all come here.
    func command(_ c: PauseCommand) {
        viewerPaused = PauseRule.apply(c, viewerPaused: viewerPaused)
        mpv.setAsync("pause", viewerPaused ? "yes" : "no")
        playing = !viewerPaused
        stall.reset()
        mpvPiP.controller?.invalidatePlaybackState()
    }
    func jump(_ seconds: Int32) { seek(toMs: Int32(max(0, Int(timeMs) + Int(seconds) * 1000))) }
    func seek(toMs ms: Int32) {
        let target = lengthMs > 0 ? min(ms, lengthMs - 1000) : ms
        mpv.commandAsync(["seek", String(format: "%.2f", Double(max(0, target)) / 1000), "absolute"])
        timeMs = max(0, target); stall.reset()
        mpvPiP.controller?.invalidatePlaybackState()
    }

    /// App volume 0…200 (100 = normal).
    private var mpvVolume: Int32 = 100
    var volume: Int32 {
        get { mpvVolume }
        set { mpvVolume = max(0, min(200, newValue)); mpv.setAsync("volume", String(mpvVolume)) }
    }

    func stop() {
        timer?.invalidate(); timer = nil; engineSessionId = nil
        pipAttempt += 1; pipRetry = 0      // no pending PiP start outlives the player
        mpv.stopPlayback()
        clearRemote()
    }

    /// Subtitle delay in seconds. Positive = later.
    func shiftSubs(_ d: Double) {
        subDelay = d == 0 ? 0 : (subDelay + d)
        mpv.setAsync("sub-delay", String(format: "%.2f", subDelay))
    }

    /// Adds a downloaded subtitle file and switches to it.
    func addSubtitle(_ file: URL) { mpv.commandAsync(["sub-add", file.path, "select"]) }

    /// A track as shown in the panel. `id` is mpv's track id.
    struct Track: Identifiable { let id: String; let name: String; let selected: Bool }
    var audioTracks: [Track] { mpv.tracks.filter { $0.type == "audio" }.map { Track(id: $0.id, name: $0.name, selected: $0.selected) } }
    var subtitleTracks: [Track] { mpv.tracks.filter { $0.type == "sub" }.map { Track(id: $0.id, name: $0.name, selected: $0.selected) } }

    /// What happened on the last track pick (shown in diagnostics).
    private(set) var lastPick = "لا يوجد"

    @discardableResult func selectAudio(_ id: String) -> Bool { select(id, type: "audio", property: "aid", kind: "صوت") }
    @discardableResult func selectSubtitle(_ id: String) -> Bool { select(id, type: "sub", property: "sid", kind: "ترجمة") }

    private func select(_ id: String, type: String, property: String, kind: String) -> Bool {
        guard let t = mpv.tracks.first(where: { $0.type == type && $0.id == id }) else {
            lastPick = "\(kind): المسار \(id) غير موجود في قائمة mpv الحالية"
            return false
        }
        DiagLog.shared.note("[التطبيق] طلب اختيار \(kind) \(id) «\(t.name)»")
        mpv.setAsync(property, id)
        lastPick = "\(kind): طُلب اختيار \(property)=\(id) «\(t.name)»"
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard let self else { return }
            let now = self.mpv.tracks.filter { $0.type == type && $0.selected }.map { "\($0.id) «\($0.name)»" }
            self.lastPick += " → المحدد فعليًا بعد 0.6 ث: " + (now.isEmpty ? "لا شيء" : now.joined(separator: "، "))
        }
        return true
    }

    func subtitlesOff() {
        DiagLog.shared.note("[التطبيق] إيقاف كل الترجمات")
        mpv.setAsync("sid", "no")
        lastPick = "ترجمة: إيقاف كل المسارات"
    }

    // Lock screen / Control Center.
    private var remoteTargets: [Any] = []
    func nowPlaying(_ title: String) {
        var info: [String: Any] = [MPMediaItemPropertyTitle: title]
        if lengthMs > 0 {
            info[MPMediaItemPropertyPlaybackDuration] = Double(lengthMs) / 1000
            info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = Double(timeMs) / 1000
        }
        info[MPNowPlayingInfoPropertyPlaybackRate] = playing ? Double(rate) : 0
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        guard remoteTargets.isEmpty else { return }
        let c = MPRemoteCommandCenter.shared()
        remoteTargets = [
            c.playCommand.addTarget { [weak self] _ in self?.command(.play); return .success },
            c.pauseCommand.addTarget { [weak self] _ in self?.command(.pause); return .success },
            c.togglePlayPauseCommand.addTarget { [weak self] _ in self?.command(.toggle); return .success },
        ]
    }
    private func clearRemote() {
        let c = MPRemoteCommandCenter.shared()
        for t in remoteTargets { c.playCommand.removeTarget(t); c.pauseCommand.removeTarget(t); c.togglePlayPauseCommand.removeTarget(t) }
        remoteTargets = []
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }
}

/// Clock values shown by the small views that observe them.
final class PlayerClock: ObservableObject {
    @Published var timeMs: Int32 = 0
    @Published var lengthMs: Int32 = 0
    /// Spinner = the playback clock stopped moving (see StallDetector in PlaybackLogic).
    @Published var buffering = true
}

/// Redraws only its content when the clock ticks.
struct ClockReader<Content: View>: View {
    @ObservedObject var clock: PlayerClock
    @ViewBuilder let content: () -> Content
    var body: some View { content() }
}

struct VideoHostView: UIViewRepresentable {
    let model: PlayerModel
    func makeUIView(context: Context) -> UIView {
        let host = UIView(); host.backgroundColor = .black
        model.hostView = host
        model.attachDrawable()
        return host
    }
    func updateUIView(_ uiView: UIView, context: Context) {}
}

// MARK: - Screen

struct PlayerScreen: View {
    let item: PlayItem
    /// Closes the player (it is shown as an overlay so it can stay alive behind picture in picture).
    let close: () -> Void
    /// The overlay is hidden while the video is in the floating window.
    @Binding var minimized: Bool
    @EnvironmentObject var library: Library
    @EnvironmentObject var epg: EPG
    @StateObject private var model = PlayerModel()

    @State private var index = 0
    @State private var controls = true
    @State private var locked = false
    @State private var hideTask: Task<Void, Never>?
    @State private var fit: PlayerModel.Fit = .fit
    @State private var flash: String?
    @State private var flashIcon = ""
    @State private var notice: String?
    @State private var scrub: Double?          // 0…1 while dragging the bar or swiping
    @State private var gesture: GestureKind?
    @State private var gestureStart: Double = 0
    @State private var level: (icon: String, value: Double)?
    @State private var sheet: Sheet?
    @State private var resumeAt: Double?       // seconds; shows the "from the start" chip
    @State private var nextVisible = false
    @State private var nextDismissed = false
    @State private var stoppedEarlyAt: Int32?   // ms; panel "stopped before the end"
    @State private var gate = SessionGate()
    @State private var session: PlaybackSession?
    @State private var lastSavedAtMs: Int32?
    @State private var resumeTask: Task<Void, Never>?
    /// Side panel for audio / subtitles / picture / speed. While open, controls never auto-hide.
    @State private var panel: Panel?
    /// Tracks read once when a panel opens (and after each pick), so the list never moves under the finger.
    @State private var panelTracks: [PlayerModel.Track] = []
    @State private var applePlayer: ApplePlayback?

    enum Panel: String, Identifiable { case audio, subtitles, picture, speed, diag; var id: String { rawValue } }
    @State private var diagText = ""
    @ObservedObject private var samples = SampleStore.shared
    @State private var pickingSubtitle = false
    @State private var diagDetailed = false
    @Environment(\.scenePhase) private var scenePhase

    enum GestureKind { case seek, brightness, volume }
    enum Sheet: String, Identifiable { case subs, channels, episodes; var id: String { rawValue } }

    private var isLive: Bool { if case .live = item { return true } else { return false } }
    private var channels: [Channel] { if case .live(let l, _) = item { return l } else { return [] } }
    private var queue: [VodPlay] { if case .vod(let l, _) = item { return l } else { return [] } }
    private var current: VodPlay? { queue.indices.contains(index) ? queue[index] : nil }
    private var nextUp: VodPlay? { queue.indices.contains(index + 1) ? queue[index + 1] : nil }
    private var prevUp: VodPlay? { index > 0 && queue.indices.contains(index - 1) ? queue[index - 1] : nil }

    private var title: String {
        if isLive { return channels.indices.contains(index) ? channels[index].name : "" }
        return current?.title ?? ""
    }
    private var nowOnAir: EPGNow? {
        guard isLive, channels.indices.contains(index) else { return nil }
        return epg.now[channels[index].id]
    }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black.ignoresSafeArea()
                VideoHostView(model: model).ignoresSafeArea()
                touchLayer(geo.size).ignoresSafeArea()

                ClockReader(clock: model.clock) {
                    if model.buffering { ProgressView().tint(.white).scaleEffect(1.5).allowsHitTesting(false) }
                }
                if let flash { centerBadge(flash, flashIcon) }
                if let level { levelBar(level.icon, level.value) }
                if let s = scrub, !isLive, model.lengthMs > 0 { centerBadge(fmt(Int32(s * Double(model.lengthMs))) + " / " + fmt(model.lengthMs), "arrow.left.and.right") }

                if locked {
                    lockedOverlay
                } else if controls {
                    overlay(geo.size)
                }
                if let r = resumeAt, !locked { resumeChip(r) }
                if let n = nextUp, nextVisible, !nextDismissed, !locked, stoppedEarlyAt == nil {
                    ClockReader(clock: model.clock) { nextCard(n) }
                }
                if let notice {
                    Text(notice).font(.callout).padding(.horizontal, 14).padding(.vertical, 9)
                        .background(.black.opacity(0.75), in: Capsule()).foregroundStyle(.white)
                        .frame(maxHeight: .infinity, alignment: .top).padding(.top, 64).allowsHitTesting(false)
                }
                if let p = panel, !locked { panelView(p) }
                if model.failed { failedPanel }
                if let at = stoppedEarlyAt { stoppedEarlyPanel(at) }
            }
        }
        .statusBarHidden(!minimized)
        .persistentSystemOverlays(minimized ? .automatic : .hidden)
        .fileImporter(isPresented: $pickingSubtitle, allowedContentTypes: [.item], allowsMultipleSelection: false) { r in
            guard case .success(let urls) = r, let u = urls.first else { return }
            let ok = u.startAccessingSecurityScopedResource()
            defer { if ok { u.stopAccessingSecurityScopedResource() } }
            let dest = FileManager.default.temporaryDirectory.appendingPathComponent(u.lastPathComponent)
            try? FileManager.default.removeItem(at: dest)
            do {
                try FileManager.default.copyItem(at: u, to: dest)
                DiagLog.shared.note("[التطبيق] إضافة ترجمة من الملفات: \(u.lastPathComponent)")
                model.addSubtitle(dest); show("أُضيفت: \(u.lastPathComponent)")
            } catch { show(error.localizedDescription) }
        }
        .fullScreenCover(item: $applePlayer) { a in
            ApplePlayerView(playback: a) { pos, dur, failed in returnFromApplePlayer(pos, dur, failed) }
        }
        .sheet(item: $sheet) { s in
            switch s {
            case .subs:
                if let v = current { SubSearchSheet(query: v.query) { file in model.addSubtitle(file); show("تمت إضافة الترجمة") } }
            case .channels:
                ChannelPickerSheet(channels: channels, current: index) { i in sheet = nil; switchChannel(to: i) }
                    .environmentObject(library).environmentObject(epg)
            case .episodes:
                EpisodePickerSheet(queue: queue, current: index) { i in sheet = nil; playEpisode(i) }
            }
        }
        .onReceive(model.clock.$timeMs) { t in
            guard !isLive else { return }
            model.nowPlaying(title)
            let v = NextCardRule.visible(current: nextVisible, hasNext: nextUp != nil, dismissed: nextDismissed,
                                         timeMs: t, lengthMs: model.lengthMs, scrubbing: scrub != nil)
            if v != nextVisible { nextVisible = v }
            if model.playing, ResumeRule.periodicDue(lastSavedAtMs: lastSavedAtMs, timeMs: t) { saveResume() }
        }
        .onReceive(model.$endDecision) { d in
            guard let d, !isLive else { return }
            handleEnd(d)
        }
        .onChange(of: scenePhase) { p in
            if p != .active { saveResume() }
            // Leaving the app while a video plays: continue in the floating window.
            if p == .inactive && PlayerPrefs.autoPiP { model.startPiPIfPossible() }
        }
        .onChange(of: model.pipActive) { on in
            minimized = on
            if on { Orientation.portrait() } else { Orientation.landscape(); controls = true; scheduleHide() }
        }
        .onAppear {
            model.onMPVPiPUnavailable = { msg in
                DiagLog.shared.note("[التطبيق] صورة داخل صورة mpv غير متاحة: \(msg)")
                show("صورة داخل صورة ما اشتغلت (\(msg))")
            }
            start(); Orientation.landscape(); UIApplication.shared.isIdleTimerDisabled = true
            Perf.shared.memory("فتح المشغّل")
        }
        .onDisappear {
            // 1.0.4 measurement only: each part of leaving the player timed on its own (same order as before).
            Perf.shared.mark("رجوع: حفظ الاستكمال")
            Perf.shared.measure("رجوع: حفظ الاستكمال", minMs: 0) { saveResume() }
            hideTask?.cancel(); resumeTask?.cancel()
            gate.end(); session = nil
            Perf.shared.mark("رجوع: إيقاف التشغيل")
            Perf.shared.measure("رجوع: إيقاف التشغيل", minMs: 0) { model.stop() }
            Perf.shared.mark("رجوع: تدوير الشاشة")
            Perf.shared.measure("رجوع: طلب تدوير الشاشة", minMs: 0) { Orientation.portraitMeasured() }
            UIApplication.shared.isIdleTimerDisabled = false
            // Frames after this point: the app's screens redrawing (until mpv's own close marks itself).
            Perf.shared.untilNextFrame("رجوع: أول إطار بعد المشغّل")
            Perf.shared.mark("رجوع: تحديث الشاشات قبل الدوران")
            // Is the player (and its mpv) released? Logged 3 s later.
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                Perf.shared.add("رجوع: بعد 3 ث", ms: 0, "نماذج المشغّل الحية \(PlayerModel.alive) · محركات mpv \(MPVCore.alive)")
            }
            Perf.shared.memory("بعد إغلاق المشغّل بـ 3 ث", after: 3)
        }
    }

    // MARK: Touch: tap = controls, double tap sides = ±10 s, swipe sideways = seek, up/down = brightness (left) / volume (right)

    private func touchLayer(_ size: CGSize) -> some View {
        HStack(spacing: 0) { tapZone(-10); tapZone(10) }
            .environment(\.layoutDirection, .leftToRight)
            .simultaneousGesture(
                DragGesture(minimumDistance: 14)
                    .onChanged { v in if !locked { dragChanged(v, size) } }
                    .onEnded { _ in if !locked { dragEnded() } }
            )
            .simultaneousGesture(MagnificationGesture().onEnded { s in
                guard !locked else { return }
                let f: PlayerModel.Fit = s > 1 ? .fill : .fit
                if f != fit { fit = f; model.apply(f); show(f.rawValue) }
            })
    }

    private func tapZone(_ seconds: Int32) -> some View {
        Color.clear.contentShape(Rectangle())
            .onTapGesture(count: 2) {
                guard !locked, !isLive else { return }
                model.jump(seconds)
                flashIcon = seconds > 0 ? "goforward.10" : "gobackward.10"
                flashText(seconds > 0 ? "+10 ث" : "−10 ث")
            }
            .onTapGesture {
                controls.toggle()
                scheduleHide()
            }
    }

    private func dragChanged(_ v: DragGesture.Value, _ size: CGSize) {
        if gesture == nil {
            if abs(v.translation.width) > abs(v.translation.height) {
                guard !isLive, model.lengthMs > 0 else { return }
                gesture = .seek; gestureStart = Double(model.timeMs) / Double(model.lengthMs)
            } else if v.startLocation.x < size.width / 2 {
                gesture = .brightness; gestureStart = Double(UIScreen.main.brightness)
            } else {
                gesture = .volume; gestureStart = Double(model.volume) / 200
            }
        }
        switch gesture {
        case .seek:
            // A full-width swipe moves 3 minutes (or the whole file if shorter).
            let span = min(180_000, Double(model.lengthMs)) / Double(max(model.lengthMs, 1))
            scrub = max(0, min(1, gestureStart + Double(v.translation.width / max(size.width, 1)) * span))
        case .brightness:
            let b = max(0, min(1, gestureStart - Double(v.translation.height / max(size.height, 1)) * 1.4))
            UIScreen.main.brightness = CGFloat(b); level = ("sun.max.fill", b)
        case .volume:
            let x = max(0, min(1, gestureStart - Double(v.translation.height / max(size.height, 1)) * 1.4))
            model.volume = Int32(x * 200); level = (x == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill", x)
        case nil: break
        }
    }

    private func dragEnded() {
        if gesture == .seek, let s = scrub { model.seek(toMs: Int32(s * Double(model.lengthMs))) }
        gesture = nil; scrub = nil
        Task { try? await Task.sleep(nanoseconds: 600_000_000); await MainActor.run { level = nil } }
    }

    // MARK: Controls

    private func overlay(_ size: CGSize) -> some View {
        VStack(spacing: 0) {
            topBar
            Spacer()
            centerButtons
            Spacer()
            if isLive { liveBottom } else { vodBottom }
        }
        .foregroundStyle(.white)
        .background(
            LinearGradient(colors: [.black.opacity(0.7), .clear, .clear, .black.opacity(0.75)], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea().allowsHitTesting(false)
        )
        .transition(.opacity)
    }

    private var topBar: some View {
        HStack(spacing: 6) {
            iconButton("chevron.down") { close() }
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline).lineLimit(1)
                if let n = nowOnAir {
                    Text(n.next.map { "الآن: \(n.title) · التالي: \($0)" } ?? "الآن: \(n.title)").font(.caption).lineLimit(1).opacity(0.85)
                }
            }
            Spacer(minLength: 8)
            if let q = model.quality {
                Text(q).font(.caption2.bold()).padding(.horizontal, 7).padding(.vertical, 3)
                    .background(Theme.accent, in: RoundedRectangle(cornerRadius: 5)).foregroundStyle(.black)
            }
            iconButton(model.pipActive ? "pip.exit" : "pip.enter") { model.togglePiP() }
            iconButton("lock.open") { locked = true; controls = true; scheduleHide(); show("الشاشة مقفلة — اضغط القفل للفتح") }
            iconButton("waveform") { openPanel(.audio) }
            iconButton("captions.bubble") { openPanel(.subtitles) }
            iconButton("aspectratio") { openPanel(.picture) }
        }
        .padding(.horizontal, 12).padding(.top, 6)
    }

    private var centerButtons: some View {
        HStack(spacing: 56) {
            if isLive {
                bigButton("backward.end.fill", 34) { switchChannel(to: index - 1) }
            } else {
                bigButton("gobackward.10", 38) { model.jump(-10); scheduleHide() }
            }
            Button { model.command(.toggle); scheduleHide() } label: {
                Image(systemName: model.playing ? "pause.fill" : "play.fill").font(.system(size: 40))
                    .frame(width: 84, height: 84).background(.white.opacity(0.18), in: Circle())
            }
            if isLive {
                bigButton("forward.end.fill", 34) { switchChannel(to: index + 1) }
            } else {
                bigButton("goforward.10", 38) { model.jump(10); scheduleHide() }
            }
        }
        .environment(\.layoutDirection, .leftToRight)
    }

    private var vodBottom: some View {
        ClockReader(clock: model.clock) { vodBottomContent }
    }

    private var vodBottomContent: some View {
        VStack(spacing: 6) {
            if model.lengthMs > 0 {
                let shown = scrub ?? Double(model.timeMs) / Double(max(model.lengthMs, 1))
                HStack(spacing: 10) {
                    Text(fmt(Int32(shown * Double(model.lengthMs)))).font(.caption.monospacedDigit())
                    Slider(value: Binding(get: { shown }, set: { scrub = $0; scheduleHide() }), in: 0...1, onEditingChanged: { editing in
                        if !editing, let s = scrub { model.seek(toMs: Int32(s * Double(model.lengthMs))); scrub = nil }
                    })
                    .tint(Theme.accent)
                    Text("-" + fmt(max(0, model.lengthMs - Int32(shown * Double(model.lengthMs))))).font(.caption.monospacedDigit())
                }
                .environment(\.layoutDirection, .leftToRight)
            }
            HStack(spacing: 10) {
                if model.lengthMs > 0 {
                    Text("ينتهي \(endsAt)").font(.caption).opacity(0.85)
                }
                Spacer()
                pill(model.rate == 1 ? "السرعة" : rateText(model.rate), "speedometer") { openPanel(.speed) }
                if !queue.isEmpty && current?.season != nil {
                    pill("الحلقات", "list.bullet") { sheet = .episodes }
                }
                if prevUp != nil { pill("السابقة", "backward.end") { playEpisode(index - 1) } }
                if nextUp != nil { pill("التالية", "forward.end") { playEpisode(index + 1) } }
            }
        }
        .padding(.horizontal, 16).padding(.bottom, 10)
    }

    private var liveBottom: some View {
        HStack(spacing: 12) {
            if let n = nowOnAir {
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(timeText(n.start)) – \(timeText(n.end))  \(n.title)").font(.caption).lineLimit(1)
                    ProgressView(value: n.progress).tint(Theme.teal).frame(maxWidth: 260)
                }
            }
            Spacer()
            Text("\(index + 1) / \(channels.count)").font(.caption.monospacedDigit()).opacity(0.8)
            pill("القنوات", "list.bullet.rectangle") { sheet = .channels }
        }
        .padding(.horizontal, 16).padding(.bottom, 12)
    }

    private var lockedOverlay: some View {
        Group {
            if controls {
                Button { locked = false; show("تم فتح القفل"); scheduleHide() } label: {
                    Image(systemName: "lock.fill").font(.title2).padding(16).background(.black.opacity(0.6), in: Circle()).foregroundStyle(.white)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top).padding(.top, 20)
            }
        }
    }

    private var failedPanel: some View {
        VStack(spacing: 12) {
            Text(isLive ? "انقطع البث." : "تعذّر تشغيل الملف.").font(.headline)
            HStack {
                Button("إعادة المحاولة") { retry() }.buttonStyle(.borderedProminent)
                if isLive { Button("القنوات") { sheet = .channels }.buttonStyle(.bordered) }
                Button("إغلاق") { close() }.buttonStyle(.bordered)
            }
        }
        .padding(20).background(.black.opacity(0.75), in: RoundedRectangle(cornerRadius: 14)).foregroundStyle(.white)
    }

    private func stoppedEarlyPanel(_ at: Int32) -> some View {
        VStack(spacing: 12) {
            Text("توقّف الملف قبل نهايته عند \(fmt(at))").font(.headline)
            Text("حُفظ مكانك، ولم تُعلَّم الحلقة كمكتملة.").font(.caption).opacity(0.85)
            HStack {
                Button("إعادة المحاولة من نفس النقطة") { retryFrom(at) }.buttonStyle(.borderedProminent)
                if nextUp != nil { Button("الحلقة التالية") { playEpisode(index + 1) }.buttonStyle(.bordered) }
                Button("إغلاق") { close() }.buttonStyle(.bordered)
            }
        }
        .padding(20).background(.black.opacity(0.8), in: RoundedRectangle(cornerRadius: 14)).foregroundStyle(.white)
    }

    private func resumeChip(_ seconds: Double) -> some View {
        HStack(spacing: 10) {
            Text("استكمال من \(fmt(Int32(seconds * 1000)))").font(.callout)
            Button("من البداية") { restartFromBeginning() }.buttonStyle(.borderedProminent).controlSize(.small)
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(.black.opacity(0.7), in: Capsule()).foregroundStyle(.white)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        .padding(.leading, 20).padding(.bottom, controls ? 96 : 24)
        .environment(\.layoutDirection, .leftToRight)
    }

    /// Information only: the next episode starts by itself only after a real end, or when "Play now" is tapped.
    private func nextCard(_ n: VodPlay) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("الحلقة التالية — تبدأ عند انتهاء هذه (\(fmt(max(0, model.lengthMs - model.timeMs))))").font(.caption).opacity(0.8)
            Text(n.title).font(.headline).lineLimit(2)
            HStack {
                Button { playEpisode(index + 1) } label: { Label("شغّل الآن", systemImage: "play.fill") }
                    .buttonStyle(.borderedProminent)
                Button("إخفاء") { nextDismissed = true }.buttonStyle(.bordered)
            }
        }
        .padding(16).frame(maxWidth: 330, alignment: .leading)
        .background(.black.opacity(0.8), in: RoundedRectangle(cornerRadius: 14)).foregroundStyle(.white)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        .padding(.trailing, 20).padding(.bottom, controls ? 96 : 24)
        .environment(\.layoutDirection, .rightToLeft)
    }

    // MARK: Menus

    // MARK: Side panel (replaces pop-up menus: steady list, big rows, no auto-hide while open)

    private func openPanel(_ p: Panel) {
        hideTask?.cancel()
        if p == .diag { diagText = diagnostics() }
        panelTracks = p == .audio ? model.audioTracks : p == .subtitles ? model.subtitleTracks : []
        withAnimation(.easeOut(duration: 0.18)) { panel = p }
    }

    private func closePanel() {
        withAnimation(.easeIn(duration: 0.15)) { panel = nil }
        scheduleHide()
    }

    private func panelView(_ p: Panel) -> some View {
        HStack(spacing: 0) {
            Color.black.opacity(0.35).contentShape(Rectangle()).onTapGesture { closePanel() }
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text(panelTitle(p)).font(.headline)
                    Spacer()
                    Button { closePanel() } label: { Image(systemName: "xmark").font(.headline).frame(width: 40, height: 40) }
                }
                .padding(.horizontal, 16).padding(.top, 10)
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) { panelRows(p) }.padding(.horizontal, 8).padding(.bottom, 16)
                }
            }
            .frame(width: 340)
            .frame(maxHeight: .infinity)
            .background(.ultraThinMaterial)
            .background(Color.black.opacity(0.55))
            .environment(\.layoutDirection, .rightToLeft)
        }
        .environment(\.layoutDirection, .leftToRight)
        .foregroundStyle(.white)
        .ignoresSafeArea()
        .transition(.move(edge: .trailing).combined(with: .opacity))
    }

    private func panelTitle(_ p: Panel) -> String {
        switch p { case .audio: return "الصوت"; case .subtitles: return "الترجمة"; case .picture: return "الصورة"; case .speed: return "السرعة"; case .diag: return "تشخيص التشغيل" }
    }

    @ViewBuilder private func panelRows(_ p: Panel) -> some View {
        switch p {
        case .audio:
            if panelTracks.isEmpty { panelNote("لا توجد مسارات صوت في هذا الملف.") }
            ForEach(panelTracks) { t in
                panelRow(t.name, selected: t.selected) {
                    model.selectAudio(t.id); refreshTracks(.audio); show("الصوت: \(t.name)")
                }
            }
        case .subtitles:
            panelHeader("ترجمات الملف")
            if panelTracks.isEmpty { panelNote("لا توجد ترجمة داخل هذا الملف.") }
            else {
                panelRow("بدون ترجمة", selected: !panelTracks.contains(where: \.selected)) {
                    model.subtitlesOff(); refreshTracks(.subtitles); show("بدون ترجمة")
                }
            }
            ForEach(panelTracks) { t in
                panelRow(t.name, selected: t.selected) {
                    model.selectSubtitle(t.id); refreshTracks(.subtitles); show("الترجمة: \(t.name)")
                }
            }
            do {
                panelHeader("حجم الترجمة \(Int((MPVSubScale.value * 100).rounded()))٪")
                HStack(spacing: 10) {
                    panelButton("أصغر", "textformat.size.smaller") { changeSubScale(-0.1) }
                    panelButton("أكبر", "textformat.size.larger") { changeSubScale(0.1) }
                }
                .padding(.horizontal, 8).padding(.vertical, 6)
            }
            panelRow("تشخيص التشغيل", icon: "stethoscope") { openPanel(.diag) }
            if !isLive {
                panelHeader("من الإنترنت")
                panelRow("أفضل ترجمة عربية تلقائيًا", icon: "sparkles") { closePanel(); autoArabicSubtitle() }
                panelRow("بحث في OpenSubtitles…", icon: "globe") { closePanel(); sheet = .subs }
            }
            panelHeader("التوقيت: " + (model.subDelay == 0 ? "الأصلي" : String(format: "%+.1f ث", model.subDelay)))
            HStack(spacing: 10) {
                panelButton("أبكر ٠٫٥", "minus") { model.shiftSubs(-0.5); show(delayText) }
                panelButton("أتأخر ٠٫٥", "plus") { model.shiftSubs(0.5); show(delayText) }
                if model.subDelay != 0 { panelButton("الأصلي", "arrow.uturn.backward") { model.shiftSubs(0); show(delayText) } }
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
        case .picture:
            panelHeader("شكل الصورة")
            ForEach(PlayerModel.Fit.allCases, id: \.self) { f in
                panelRow(f.rawValue, selected: fit == f) { fit = f; model.apply(f); show(f.rawValue) }
            }
            if !isLive, current != nil {
                panelHeader("ألوان HDR / Dolby Vision")
                panelRow("فتح بمشغّل Apple", icon: "apple.logo") { closePanel(); openApplePlayer() }
                panelHeader("mpv بوضع اختبار (لملف ينهار قبل ما يفتح)")
                ForEach(MPVLab.allCases.filter { $0 != .normal }, id: \.self) { m in
                    panelRow(m.rawValue, icon: "flask") { closePanel(); reopenWithLab(m) }
                }
                panelNote("كل وضع يغيّر عاملًا واحدًا فقط، وللمرة هذي بس. إذا انهار، افتح التشخيص واضغط «نسخ».")
                panelNote("mpv يعالج Dolby Vision (ثبت على ملك الخواتم). مشغّل Apple يعرضها صح ويدعم AirPlay، لكنه لا يفتح ملفات MKV.")
            }
            panelRow("تشخيص التشغيل", icon: "stethoscope") { openPanel(.diag) }
        case .diag:
            HStack(spacing: 10) {
                panelButton("نسخ", "doc.on.doc") { UIPasteboard.general.string = diagText; show("تم نسخ التشخيص") }
                panelButton("تحديث", "arrow.clockwise") { diagText = diagnostics() }
                if let v = current {
                    panelButton("نسخ رابط الملف", "link") { UIPasteboard.general.string = v.url; show("تم نسخ الرابط — فيه بيانات دخولك، لا تشاركه") }
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
            if let last = MPVSessionFile.previous() {
                panelRow("نسخ سجل آخر جلسة mpv", icon: "bolt.horizontal.circle") {
                    UIPasteboard.general.string = "شاشة — سجل آخر جلسة mpv (الروابط وبيانات الحساب محذوفة)\n" + last
                    show("تم نسخ سجل mpv")
                }
                panelNote("يُكتب سطرًا بسطر أثناء تشغيل mpv، فيبقى حتى لو انهار التطبيق. إذا آخر سطر ليس «إغلاق طبيعي» فالجلسة انقطعت عند تلك المرحلة.")
            }
            panelRow(diagDetailed ? "تسجيل مفصّل: مفعّل" : "تسجيل مفصّل (لفحص الترجمة)", selected: diagDetailed, icon: "list.bullet.rectangle") {
                diagDetailed.toggle()
                DiagLog.shared.level = diagDetailed ? .debug : .warning
                show(diagDetailed ? "فعّل الترجمة الآن ثم ارجع وانسخ" : "رجع التسجيل للأخطاء فقط")
            }
            panelRow("من بداية الحلقة (بدون استكمال)", icon: "backward.end") { closePanel(); restartFromBeginning() }
            if let v = current, !v.url.hasPrefix("file:") {
                if let p = samples.progress {
                    panelNote(String(format: "تنزيل العينة… %.0f%%", p * 100))
                } else {
                    panelRow("تنزيل عينة 40MB (للمقارنة المحلية)", icon: "arrow.down.circle") { downloadSample(40) }
                    panelRow("تنزيل عينة 150MB", icon: "arrow.down.circle") { downloadSample(150) }
                }
            }
            if let f = samples.lastFile {
                panelRow("تشغيل العينة المحلية: \(f.lastPathComponent)", icon: "internaldrive") { playLocalSample(f) }
            }
            if let e = samples.error { panelNote("تنزيل العينة: " + e) }
            panelRow("تحميل ترجمة من ملفات الجهاز (ASS/SRT)", icon: "folder") { pickingSubtitle = true }
            panelNote("العينات في تطبيق «الملفات» ← على الـiPhone ← شاشة ← Samples.")
            Text(diagText).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                .environment(\.layoutDirection, .leftToRight)
                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12)
        case .speed:
            ForEach([Float(0.5), 0.75, 1, 1.25, 1.5, 2], id: \.self) { r in
                panelRow(rateText(r), selected: model.rate == r) { model.setRate(r); show("السرعة \(rateText(r))") }
            }
        }
    }

    /// Plain-text report of what the engine and the provider actually say. Links and login data are removed.
    private func diagnostics() -> String { mpvDiagnostics() }

    /// Diagnostics when mpv is the engine: what mpv itself reports, then its own log. Links and login data removed.
    private func mpvDiagnostics() -> String {
        let info = Bundle.main.infoDictionary
        let m = model.mpv
        func p(_ n: String) -> String { m.string(n) ?? "غير متاح" }
        let s = m.state
        var l: [String] = []
        l.append("شاشة \(info?["CFBundleShortVersionString"] as? String ?? "?") (\(info?["CFBundleVersion"] as? String ?? "?")) — تشخيص التشغيل (المحرّك: mpv)")
        l.append("الجهاز: iOS \(UIDevice.current.systemVersion)")
        l.append("المحرّك: mpv \(p("mpv-version")) | FFmpeg \(p("ffmpeg-version"))")
        l.append("العنوان: \(title)")
        if let v = current { l.append("الحاوية (حسب امتداد الرابط): \(v.container ?? "غير متاح")") } else { l.append("النوع: بث مباشر") }
        l.append("الحالة: محمّل=\(s.loaded) | إيقاف=\(s.paused) | تخزين=\(s.pausedForCache) | نهاية=\(s.eof) | خطأ=\(s.endError ?? "لا") | الوقت \(fmt(model.timeMs)) / \(fmt(model.lengthMs))")
        l.append("مخرج الفيديو: \(p("current-vo")) | فك عتادي: \(p("hwdec-current"))")
        l.append("الفيديو: \(p("video-codec")) | \(p("video-params/w"))x\(p("video-params/h")) | \(p("video-params/pixelformat"))")
        l.append("colormatrix: \(p("video-params/colormatrix")) | gamma: \(p("video-params/gamma")) | primaries: \(p("video-params/primaries")) | sig-peak: \(p("video-params/sig-peak"))")
        l.append("الترجمة: sid=\(p("sid")) | \(p("current-tracks/sub/codec")) [\(p("current-tracks/sub/lang"))] | الحجم \(Int((MPVSubScale.value * 100).rounded()))٪ | التأخير \(p("sub-delay"))")
        l.append("الصوت: aid=\(p("aid")) | \(p("current-tracks/audio/codec")) [\(p("current-tracks/audio/lang"))] | السرعة \(p("speed"))")
        let session = AVAudioSession.sharedInstance()
        let route = session.currentRoute.outputs.map { "\($0.portName) (\($0.portType.rawValue))" }.joined(separator: "، ")
        l.append("قنوات الملف: \(p("audio-params/channel-count")) (\(p("audio-params/hr-channels"))) → الخارج من mpv: \(p("audio-out-params/channel-count")) (\(p("audio-out-params/hr-channels")))")
        l.append("مخرج الصوت: \(route) | أقصى قنوات يقبلها: \(session.maximumOutputNumberOfChannels) | الحالية: \(session.outputNumberOfChannels)")
        l.append("")
        l.append("— بيانات المزوّد (ffprobe عند المزوّد)")
        if let v = current, !v.probe.isEmpty { l.append(contentsOf: v.probe) } else { l.append("غير متاح — المزوّد لم يرسل بيانات الملف") }
        l.append("")
        l.append("— المسارات (من mpv)")
        m.tracks.forEach { l.append("\($0.type) id=\($0.id) | \($0.name) | محدد=\($0.selected ? "نعم" : "لا")") }
        l.append("آخر اختيار: \(model.lastPick)")
        l.append("")
        l.append("— سجل mpv (الأخطاء والتحذيرات المختلفة أولًا، ثم آخر 80 سطر)")
        let lines = m.logLines()
        var seen = Set<String>()
        for e in lines where e.contains("[error]") || e.contains("[warn]") || e.contains("[fatal]") || e.contains("API ") || e.contains("end-file") {
            if seen.insert(e).inserted { l.append(e) }
        }
        l.append("…")
        l.append(contentsOf: lines.suffix(80))
        // The session before this one: after a crash, reopening starts a new session, so the crashed one is here.
        if let prev = MPVSessionFile.beforeCurrent() {
            let pl = prev.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
            l.append("")
            l.append("— الجلسة السابقة (\(pl.count) سطر) | آخر سطر: \(pl.last ?? "-")")
            l.append(contentsOf: pl.filter { $0.contains("[مرحلة]") || $0.contains("[error]") || $0.contains("[fatal]") || $0.contains("end-file") }.suffix(60))
            l.append("آخر 25 سطر:")
            l.append(contentsOf: pl.suffix(25))
        }
        var secrets: [String] = []
        if let x = library.xtream {
            secrets += [x.user, x.pass]
            if let host = URL(string: x.server)?.host { secrets.append(host) }
        }
        return DiagRule.redact(l.joined(separator: "\n"), secrets: secrets)
    }

    private func refreshTracks(_ p: Panel) {
        // mpv applies the pick asynchronously; read again shortly after so the tick shows the real choice.
        panelTracks = p == .audio ? model.audioTracks : model.subtitleTracks
        Task {
            try? await Task.sleep(nanoseconds: 400_000_000)
            await MainActor.run { if panel == p { panelTracks = p == .audio ? model.audioTracks : model.subtitleTracks } }
        }
    }

    private func panelRow(_ text: String, selected: Bool = false, icon: String? = nil, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: selected ? "checkmark.circle.fill" : (icon ?? "circle"))
                    .foregroundStyle(selected ? Theme.accent : .white.opacity(icon == nil ? 0.35 : 0.9))
                    .frame(width: 24)
                Text(text).multilineTextAlignment(.leading).lineLimit(2)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12).padding(.vertical, 12)
            .background(selected ? Theme.accent.opacity(0.16) : .clear, in: RoundedRectangle(cornerRadius: 10))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func panelButton(_ text: String, _ icon: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(text, systemImage: icon).font(.callout).padding(.horizontal, 12).padding(.vertical, 9)
                .background(.white.opacity(0.14), in: Capsule())
        }
        .buttonStyle(.plain)
    }

    private func panelHeader(_ t: String) -> some View {
        Text(t).font(.caption.bold()).foregroundStyle(.white.opacity(0.6)).padding(.horizontal, 12).padding(.top, 14).padding(.bottom, 4)
    }

    private func panelNote(_ t: String) -> some View {
        Text(t).font(.caption).foregroundStyle(.white.opacity(0.6)).padding(.horizontal, 12).padding(.vertical, 6)
    }

    // MARK: mpv lab reopen

    /// Reopens the current item from the same point with one mpv lab factor (this open only).
    private func reopenWithLab(_ lab: MPVLab) {
        let at = Double(model.timeMs) / 1000
        saveResume()
        model.mpvLab = lab
        if isLive { openLive() } else if let v = current { openVod(v, from: at > 0 ? at : nil) }
        show("mpv — " + lab.rawValue)
        scheduleHide()
    }

    private func changeSubScale(_ step: Double) {
        let v = min(3.0, max(0.5, ((MPVSubScale.value + step) * 10).rounded() / 10))
        MPVSubScale.value = v
        model.mpv.setAsync("sub-scale", String(format: "%.2f", v))
        show("حجم الترجمة \(Int((v * 100).rounded()))٪")
    }

    // MARK: Apple player (AVKit): correct Dolby Vision colours, AirPlay, system picture in picture

    private func openApplePlayer() {
        guard let v = current, let url = URL(string: v.url) else { return }
        saveResume()
        let start = Double(model.timeMs) / 1000
        // Stop mpv completely: many providers allow only one connection per account.
        model.stop()
        applePlayer = ApplePlayback(url: url, start: start, key: v.key)
    }

    /// Back from the Apple player: save its position and continue in mpv from there (or close if it ended).
    private func returnFromApplePlayer(_ positionS: Double, _ durationS: Double, _ failed: Bool) {
        let start = applePlayer?.start ?? 0
        applePlayer = nil
        guard let v = current else { return }
        if failed { openVod(v, from: start); show("مشغّل Apple لا يدعم هذا الملف"); return }
        if durationS > 0 { Store.setPosition(v.key, positionS, durationS) }
        if durationS > 0 && EndRule.isComplete(timeMs: Int32(positionS * 1000), lengthMs: Int32(durationS * 1000)) {
            Store.setPosition(v.key, 1, 1)
            if nextUp != nil { playEpisode(index + 1) } else { close() }
            return
        }
        openVod(v, from: positionS)
    }

    // MARK: Small views

    private func iconButton(_ name: String, _ action: @escaping () -> Void) -> some View {
        Button { action(); scheduleHide() } label: { menuIcon(name) }
    }
    private func menuIcon(_ name: String) -> some View {
        Image(systemName: name).font(.title3).frame(width: 42, height: 42).contentShape(Rectangle())
    }
    private func bigButton(_ name: String, _ size: CGFloat, _ action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: name).font(.system(size: size)).frame(width: 64, height: 64).contentShape(Rectangle()) }
    }
    private func pill(_ text: String, _ icon: String, _ action: @escaping () -> Void) -> some View {
        Button { action(); scheduleHide() } label: {
            Label(text, systemImage: icon).font(.caption.bold()).padding(.horizontal, 12).padding(.vertical, 7)
                .background(.white.opacity(0.16), in: Capsule())
        }
    }
    private func centerBadge(_ text: String, _ icon: String) -> some View {
        Label(text, systemImage: icon).font(.title3.bold().monospacedDigit()).padding(.horizontal, 18).padding(.vertical, 12)
            .background(.black.opacity(0.6), in: Capsule()).foregroundStyle(.white)
            .environment(\.layoutDirection, .leftToRight)
            .frame(maxHeight: .infinity, alignment: .top).padding(.top, 90)
            .allowsHitTesting(false)
    }
    private func levelBar(_ icon: String, _ value: Double) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
            ProgressView(value: value).tint(.white).frame(width: 140)
        }
        .padding(.horizontal, 16).padding(.vertical, 11)
        .background(.black.opacity(0.6), in: Capsule()).foregroundStyle(.white)
        .environment(\.layoutDirection, .leftToRight)
        .frame(maxHeight: .infinity, alignment: .top).padding(.top, 90)
        .allowsHitTesting(false)
    }

    // MARK: Actions

    private func start() {
        switch item {
        case .live(_, let i):
            index = i; openLive()
        case .vod(let l, let i):
            index = i; openVod(l[i])
        }
        scheduleHide()
    }

    private func openLive() {
        let ch = channels[index]
        DiagLog.shared.beginSession(ch.name)
        let s = gate.begin(key: "live:" + ch.id)
        session = s
        model.open(ch.url, live: true, session: s.id)
        if fit != .fit { model.apply(fit) }
        epg.load(ch, from: library.xtream)
    }

    /// Opens a film/episode as a new session: older tasks and saves can no longer touch it.
    private func openVod(_ v: VodPlay, from start: Double? = nil) {
        DiagLog.shared.beginSession(v.title)
        let s = gate.begin(key: v.key)
        session = s
        lastSavedAtMs = nil
        stoppedEarlyAt = nil
        nextVisible = false; nextDismissed = false
        let pos = start ?? ResumeRule.startPosition(stored: Store.position(v.key)?.pos) ?? 0
        model.open(v.url, startSeconds: pos, session: s.id)
        if fit != .fit { model.apply(fit) }
        resumeTask?.cancel()
        resumeAt = (start == nil && pos > 0) ? pos : nil
        if resumeAt != nil {
            let id = s.id
            resumeTask = Task { _ = await Delayed.run(after: 8_000_000_000, stillValid: { await MainActor.run { gate.isCurrent(id) } }) {
                await MainActor.run { resumeAt = nil }
            } }
        }
    }

    private func switchChannel(to i: Int) {
        guard !channels.isEmpty else { return }
        index = (i + channels.count) % channels.count
        openLive()
        show(channels[index].name)
        scheduleHide()
    }

    /// Manual move to another episode: saves where this one stopped; marks it watched only if it is
    /// really at its end (EndRule), never just because the viewer skipped.
    private func playEpisode(_ i: Int) {
        guard queue.indices.contains(i) else { return }
        if let c = current, stoppedEarlyAt == nil, EndRule.isComplete(timeMs: model.timeMs, lengthMs: model.lengthMs) {
            Store.setPosition(c.key, 1, 1)
        } else {
            saveResume()
        }
        index = i
        openVod(queue[i])
        show(queue[i].title)
        scheduleHide()
    }

    /// Engine end of a film/episode.
    private func handleEnd(_ d: EndDecision) {
        guard let c = current else { return }
        switch d {
        case .finished:
            Store.setPosition(c.key, 1, 1)
            if nextUp != nil && !nextDismissed { playEpisode(index + 1) } else { close() }
        case .stoppedEarly:
            let at = model.lastPlayingMs
            if let save = ResumeRule.save(screen: session, engineSessionId: model.engineSessionId, timeMs: at, lengthMs: model.lengthMs) {
                Store.setPosition(save.key, save.positionS, save.durationS)
            }
            stoppedEarlyAt = at
            controls = true
        }
    }

    private func downloadSample(_ mb: Int) {
        guard let v = current, let u = URL(string: v.url) else { return }
        SampleStore.shared.download(u, title: v.title, ext: v.container ?? "mkv", megabytes: mb)
    }

    /// Same title from the local sample: only the source (network → local file) changes.
    private func playLocalSample(_ f: URL) {
        guard let v = current else { return }
        let local = VodPlay(title: v.title + " (عينة محلية)", url: f.absoluteString, key: "sample:" + v.key, query: v.query,
                            season: v.season, number: v.number, probe: v.probe, container: v.container)
        saveResume()
        openVod(local, from: 0)
        closePanel()
        show("تشغيل العينة المحلية")
    }

    /// "From the start": reopen without the start-time option. A seek to 0 right after opening could be ignored
    /// (the stream is still opening at the resume point), so the video stayed where it had stopped.
    private func restartFromBeginning() {
        resumeAt = nil
        resumeTask?.cancel()
        guard let v = current else { return }
        openVod(v, from: 0)
        show("من البداية")
        scheduleHide()
    }

    /// One tap: the most downloaded Arabic subtitle for this film/episode from OpenSubtitles, loaded into the player.
    private func autoArabicSubtitle() {
        guard let v = current else { return }
        guard OnlineSubs.hasKey else { show("أضف مفتاح OpenSubtitles من الإعدادات"); return }
        show("أبحث عن ترجمة عربية…")
        let id = session?.id
        Task {
            do {
                let results = try await OnlineSubs.search(v.query)
                guard let best = results.first(where: { $0.language == "ar" }) else {
                    await MainActor.run { show("ما لقيت ترجمة عربية — جرّب البحث اليدوي") }; return
                }
                let file = try await OnlineSubs.download(best)
                await MainActor.run {
                    guard gate.isCurrent(id) else { return }
                    model.addSubtitle(file); show("تمت إضافة الترجمة العربية")
                }
            } catch {
                await MainActor.run { show(error.localizedDescription) }
            }
        }
    }

    private func retryFrom(_ at: Int32) {
        guard let v = current else { return }
        openVod(v, from: Double(at) / 1000)
        scheduleHide()
    }

    /// One manual retry, started by the viewer (no automatic reconnect loop).
    private func retry() {
        if isLive { openLive() }
        else if let v = current { openVod(v, from: Double(model.lastPlayingMs) / 1000) }
        scheduleHide()
    }

    /// Saves the resume point of the session on screen, only with numbers that belong to it.
    private func saveResume() {
        guard !isLive, stoppedEarlyAt == nil,
              let save = ResumeRule.save(screen: session, engineSessionId: model.engineSessionId, timeMs: model.timeMs, lengthMs: model.lengthMs)
        else { return }
        Store.setPosition(save.key, save.positionS, save.durationS)
        lastSavedAtMs = model.timeMs
    }

    private func scheduleHide() {
        hideTask?.cancel()
        guard controls else { return }
        let id = session?.id
        hideTask = Task {
            _ = await Delayed.run(after: 4_500_000_000, stillValid: { await MainActor.run { gate.isCurrent(id) } }) {
                await MainActor.run { if sheet == nil && panel == nil && stoppedEarlyAt == nil && !model.failed { withAnimation { controls = false } } }
            }
        }
    }

    private func flashText(_ text: String) {
        flash = text
        Task { try? await Task.sleep(nanoseconds: 700_000_000); await MainActor.run { if flash == text { flash = nil } } }
    }

    private func show(_ text: String) {
        notice = text
        Task { try? await Task.sleep(nanoseconds: 1_800_000_000); await MainActor.run { if notice == text { notice = nil } } }
    }

    private var delayText: String {
        model.subDelay == 0 ? "توقيت الترجمة الأصلي" : String(format: "تأخير الترجمة %+.1f ث", model.subDelay)
    }

    private var endsAt: String {
        let left = Double(max(0, model.lengthMs - model.timeMs)) / 1000 / Double(max(model.rate, 0.1))
        return timeText(Date().addingTimeInterval(left))
    }

    private func timeText(_ d: Date) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "HH:mm"
        return f.string(from: d)
    }

    private func rateText(_ r: Float) -> String { r == 1 ? "عادية" : String(format: "%gx", r) }

    private func fmt(_ ms: Int32) -> String {
        let s = Int(ms) / 1000
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%02d:%02d", s / 60, s % 60)
    }
}

// MARK: - Sheets

/// Channel list while watching: search, now-playing line, tap to switch.
struct ChannelPickerSheet: View {
    let channels: [Channel]
    let current: Int
    let onPick: (Int) -> Void
    @EnvironmentObject var library: Library
    @EnvironmentObject var epg: EPG
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                List {
                    ForEach(Array(channels.enumerated()), id: \.element.id) { i, ch in
                        if query.isEmpty || ch.name.localizedCaseInsensitiveContains(query) {
                            Button { onPick(i) } label: {
                                HStack(spacing: 12) {
                                    Text("\(i + 1)").font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 32)
                                    Art(url: ch.logo, fit: true).frame(width: 50, height: 32)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(ch.name).lineLimit(1).foregroundStyle(i == current ? Theme.accent : .primary)
                                        if let n = epg.now[ch.id] { Text(n.title).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                                    }
                                    Spacer()
                                    if i == current { Image(systemName: "play.fill").foregroundStyle(Theme.accent) }
                                }
                            }
                            .id(i)
                            .task(id: ch.id) { epg.load(ch, from: library.xtream) }
                        }
                    }
                }
                .searchable(text: $query, prompt: "بحث")
                .onAppear { proxy.scrollTo(current, anchor: .center) }
            }
            .navigationTitle("القنوات").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("إغلاق") { dismiss() } } }
        }
        .environment(\.layoutDirection, .rightToLeft)
    }
}

/// Episodes of the series playing now, with watch progress.
struct EpisodePickerSheet: View {
    let queue: [VodPlay]
    let current: Int
    let onPick: (Int) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                List {
                    ForEach(Array(queue.enumerated()), id: \.element.key) { i, e in
                        Button { onPick(i) } label: {
                            HStack {
                                Text("م\(e.season ?? 0) ح\(e.number ?? 0)").font(.callout.monospacedDigit())
                                    .foregroundStyle(i == current ? Theme.accent : .primary)
                                Spacer()
                                if let p = progress(e.key) { ProgressView(value: p).tint(Theme.accent).frame(width: 70) }
                                if i == current { Image(systemName: "play.fill").foregroundStyle(Theme.accent) }
                            }
                        }
                        .id(i)
                    }
                }
                .onAppear { proxy.scrollTo(current, anchor: .center) }
            }
            .navigationTitle("الحلقات").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("إغلاق") { dismiss() } } }
        }
        .environment(\.layoutDirection, .rightToLeft)
    }
}

/// Landscape while playing (iOS 16 geometry API).
enum Orientation {
    static func landscape() { request(.landscape) }
    static func portrait() { request(.portrait) }
    /// 1.0.6 measurement: the rotation itself happens later; its end is marked so a stall after it is named.
    static func portraitMeasured() {
        guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene else { return }
        let t0 = Perf.now()
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: .portrait)) { _ in }
        func check(_ n: Int) {
            if scene.interfaceOrientation.isPortrait || n > 40 {
                Perf.shared.record("رجوع: اكتمال الدوران", since: t0, span: true)
                Perf.shared.mark("رجوع: إعادة رسم بعد الدوران")
            } else { DispatchQueue.main.asyncAfter(deadline: .now() + 0.025) { check(n + 1) } }
        }
        check(0)
    }
    private static func request(_ m: UIInterfaceOrientationMask) {
        guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene else { return }
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: m)) { _ in }
    }
}
