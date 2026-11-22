import SwiftUI
import Network
import AVFoundation

enum Theme {
    static let bg = Color(red: 14 / 255, green: 20 / 255, blue: 27 / 255)
    static let surface = Color(red: 27 / 255, green: 38 / 255, blue: 52 / 255)
    static let accent = Color(red: 242 / 255, green: 179 / 255, blue: 61 / 255)
    static let teal = Color(red: 43 / 255, green: 179 / 255, blue: 163 / 255)
    /// 1.0.9: one step above `surface` (placeholders, pressed rows).
    static let surface2 = Color(red: 36 / 255, green: 49 / 255, blue: 63 / 255)
}

@main
struct ShashaApp: App {
    @StateObject private var library = Library()
    @StateObject private var epg = EPG()

    init() {
        // Sound even with the silent switch on, and keep audio when the screen locks.
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        // 0.9.2: tell iOS the app can send multichannel audio (iOS 15+), so routes that take more than two
        // channels (spatial audio on AirPods, AirPlay, HDMI) are offered them; mpv then asks for up to the file's channels.
        if #available(iOS 15.0, *) { try? AVAudioSession.sharedInstance().setSupportsMultichannelContent(true) }
        try? AVAudioSession.sharedInstance().setActive(true)
        // 1.0.3: posters/logos (AsyncImage → URLSession.shared → URLCache.shared) kept in a bounded cache, so
        // scrolling back or returning to a screen doesn't download them again. iOS evicts it under pressure.
        URLCache.shared = URLCache(memoryCapacity: 40 * 1024 * 1024, diskCapacity: 200 * 1024 * 1024)
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(library)
                .environmentObject(epg)
                .environment(\.layoutDirection, .rightToLeft)
                .environment(\.locale, Locale(identifier: "ar"))
                .preferredColorScheme(.dark)
                .tint(Theme.accent)
        }
    }
}

struct RootView: View {
    @EnvironmentObject var library: Library
    @EnvironmentObject var epg: EPG
    @State private var play: PlayItem?
    @State private var minimized = false

    @AppStorage(FreezeBehindPlayer.key) private var freezeBehind = false

    var body: some View {
        ZStack {
            content
                // 1.7.1 A/B (off by default, Settings → diagnostics): while the full-screen player is up, the
                // screens behind it keep their portrait size, so the rotations on opening and closing the player
                // don't re-lay out Home / the posters grid. Measure "رجوع: …" and "فتح المشغّل" with it off and on.
                .modifier(FreezeBehindPlayer(on: freezeBehind && play != nil && !minimized))
            // The player is an overlay (not a full-screen cover) so it can stay alive, hidden, while the video
            // plays in the picture-in-picture window and the viewer browses the app.
            if let item = play {
                PlayerScreen(item: item, close: {
                    Perf.shared.untilNextFrame("رجوع من المشغّل"); minimized = false; play = nil
                    Task { try? await Task.sleep(nanoseconds: 1_500_000_000); await CloudSync.sync(library, force: true) }
                }, minimized: $minimized)
                    .id(item.id)
                    .environmentObject(library).environmentObject(epg)
                    .opacity(minimized ? 0 : 1)
                    .allowsHitTesting(!minimized)
                    .accessibilityHidden(minimized)
                    .transition(.opacity)
            }
        }
        .onChange(of: library.activeId) { _ in epg.clear() }
        .onAppear { Perf.shared.startMonitor() }
        .task {
            if !library.sources.isEmpty && !library.hasData { await library.start() }
            await TraktSync.pull()
            await CloudSync.sync(library)
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            Task { await TraktSync.pull(); await CloudSync.sync(library) }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)) { _ in
            // Leaving the app: try to send this phone's progress. Not relied on (iOS may stop it) — the progress is
            // already saved on the phone and goes out with the next sync. 1.7.0: asks iOS for a little time.
            let id = UIApplication.shared.beginBackgroundTask(withName: "shasha.sync")
            Task {
                await CloudSync.sync(library, force: true)
                UIApplication.shared.endBackgroundTask(id)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NetworkWatch.backOnline)) { _ in
            // 1.7.0: the connection came back — send what was saved while offline.
            Task { if CloudSync.pendingCount(library) > 0 { await CloudSync.sync(library, force: true) } }
        }
        .onAppear { NetworkWatch.shared.start() }
    }

    @ViewBuilder private var content: some View {
        Group {
            if library.sources.isEmpty {
                NavigationStack { SetupView() }
            } else {
                TabView {
                    HomeView(play: $play).tabItem { Label("الرئيسية", systemImage: "house") }
                    LiveView(play: $play).tabItem { Label("القنوات", systemImage: "tv") }
                    MoviesView(play: $play).tabItem { Label("الأفلام", systemImage: "film") }
                    SeriesView(play: $play).tabItem { Label("المسلسلات", systemImage: "play.rectangle.on.rectangle") }
                    SettingsView().tabItem { Label("الإعدادات", systemImage: "gearshape") }
                }
            }
        }
    }
}

/// 1.7.0: tells the app when the network comes back after being offline (no polling, no reconnect loop).
final class NetworkWatch: @unchecked Sendable {
    static let shared = NetworkWatch()
    static let backOnline = Notification.Name("shasha.backOnline")
    private let monitor = NWPathMonitor()
    private var started = false
    private var wasOffline = false

    func start() {
        guard !started else { return }
        started = true
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            let online = path.status == .satisfied
            if online && self.wasOffline {
                DispatchQueue.main.async { NotificationCenter.default.post(name: NetworkWatch.backOnline, object: nil) }
            }
            self.wasOffline = !online
        }
        monitor.start(queue: DispatchQueue(label: "shasha.network"))
    }
}

/// 1.7.1: see RootView — keeps the content's portrait size while the full-screen player covers it.
struct FreezeBehindPlayer: ViewModifier {
    static let key = "perf.freezeBehind"
    let on: Bool
    private var portrait: CGSize {
        let b = UIScreen.main.bounds.size
        return CGSize(width: min(b.width, b.height), height: max(b.width, b.height))
    }
    // 1.7.2: one view structure whether on or off. The 1.7.1 version switched between two branches (if/else), which
    // gives the screens a new identity each time the player opened or closed with the switch on — their scroll
    // position, search text, chosen group and navigation would have been reset. Now only the frame values change:
    // the screens stay in the view tree, keep their state and keep updating; only their size is held while the
    // full-screen player covers them.
    func body(content: Content) -> some View {
        content
            .frame(width: on ? portrait.width : nil, height: on ? portrait.height : nil, alignment: .topLeading)
            .allowsHitTesting(!on)
            .accessibilityHidden(on)
    }
}
