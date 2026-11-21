import SwiftUI
import AVFoundation

enum Theme {
    static let bg = Color(red: 14 / 255, green: 20 / 255, blue: 27 / 255)
    static let surface = Color(red: 27 / 255, green: 38 / 255, blue: 52 / 255)
    static let accent = Color(red: 242 / 255, green: 179 / 255, blue: 61 / 255)
    static let teal = Color(red: 43 / 255, green: 179 / 255, blue: 163 / 255)
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

    var body: some View {
        ZStack {
            content
            // The player is an overlay (not a full-screen cover) so it can stay alive, hidden, while the video
            // plays in the picture-in-picture window and the viewer browses the app.
            if let item = play {
                PlayerScreen(item: item, close: { Perf.shared.untilNextFrame("رجوع من المشغّل"); minimized = false; play = nil }, minimized: $minimized)
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
        .task { if !library.sources.isEmpty && library.channels.isEmpty && library.movies.isEmpty { await library.reload() } }
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
