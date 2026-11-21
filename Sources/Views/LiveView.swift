import SwiftUI

/// Live TV: groups (Favourites, All, provider groups in the viewer's order) → channels with search → player.
struct LiveView: View {
    @EnvironmentObject var library: Library
    @Binding var play: PlayItem?
    @State private var open: Category?
    /// 1.1.0: search over all channels from the groups screen.
    @State private var query = ""
    @State private var results: [Channel] = []

    var body: some View {
        NavigationStack {
            List {
                LoadingOrError()
                if !query.trimmingCharacters(in: .whitespaces).isEmpty {
                    if results.isEmpty { Text("لا توجد قناة بهذا الاسم.").foregroundStyle(.secondary) }
                    ForEach(Array(results.prefix(200).enumerated()), id: \.element.id) { i, ch in
                        Button { play = .live(list: Array(results.prefix(200)), index: i) } label: {
                            HStack(spacing: 12) {
                                Art(url: ch.logo, fit: true).frame(width: 56, height: 36).background(Theme.surface, in: RoundedRectangle(cornerRadius: 6))
                                Text(ch.name).lineLimit(1).foregroundStyle(.primary)
                                Spacer()
                                if Store.isFavorite(ch.id) { Image(systemName: "star.fill").foregroundStyle(Theme.accent) }
                            }
                        }
                    }
                } else {
                let _ = library.groupsTick
                let ok = library.allowedFilter(.live)
                NavigationLink { ChannelList(title: "المفضلة", filter: { ok($0.categoryId) }, favoritesOnly: true, play: $play) } label: {
                    Label("المفضلة", systemImage: "star.fill").foregroundStyle(Theme.accent)
                }
                NavigationLink { ChannelList(title: "كل القنوات", filter: { ok($0.categoryId) }, play: $play) } label: {
                    HStack { Text("كل القنوات"); Spacer(); Text("\(library.channels.count)").foregroundStyle(.secondary) }
                }
                ForEach(library.cats(.live)) { c in
                    Button { openGroup(c) } label: {
                        HStack {
                            Text(c.name).lineLimit(2).foregroundStyle(.primary)
                            Spacer()
                            if library.isLocked(c.id, .live) { Image(systemName: library.isUnlocked ? "lock.open" : "lock.fill").foregroundStyle(.secondary) }
                            Image(systemName: "chevron.left").font(.caption).foregroundStyle(.tertiary)
                        }
                    }
                }
                }
            }
            .searchable(text: $query, prompt: "ابحث في كل القنوات")
            .task(id: "\(query)|\(library.version)|\(library.groupsTick)") {
                let q = query.trimmingCharacters(in: .whitespaces)
                guard !q.isEmpty else { results = []; return }
                try? await Task.sleep(nanoseconds: 200_000_000)
                guard !Task.isCancelled else { return }
                let all = library.channels, ix = library.index, bl = library.blocked(.live)
                let r = await Task.detached(priority: .userInitiated) { ListQuery.channels(all, ix, query: q) { !bl.contains($0.categoryId) } }.value
                guard !Task.isCancelled else { return }
                results = r
            }
            .navigationTitle("القنوات")
            .navigationDestination(isPresented: Binding(get: { open != nil }, set: { if !$0 { open = nil } })) {
                if let c = open { ChannelList(title: c.name, filter: { $0.categoryId == c.id }, play: $play) }
            }
            .refreshable { await library.reload() }
        }
    }

    private func openGroup(_ c: Category) {
        if library.isLocked(c.id, .live) && !library.isUnlocked {
            Task { if await library.unlock() { open = c } }
        } else { open = c }
    }
}

struct ChannelList: View {
    @EnvironmentObject var library: Library
    @EnvironmentObject var epg: EPG
    let title: String
    let filter: (Channel) -> Bool
    var favoritesOnly = false
    @Binding var play: PlayItem?
    /// 1.0.3: computed when the search, the library or the favourites change — not on every guide update
    /// (each programme that arrived used to re-filter all 52,989 channels).
    @State private var list: [Channel] = []
    @State private var query = ""
    @State private var favTick = 0
    @State private var guide: Channel?

    var body: some View {
        List(Array(list.enumerated()), id: \.element.id) { i, ch in
            Button { play = .live(list: list, index: i) } label: {
                HStack(spacing: 12) {
                    Art(url: ch.logo, fit: true).frame(width: 56, height: 36).background(Theme.surface, in: RoundedRectangle(cornerRadius: 6))
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 4) {
                            Text(ch.name).lineLimit(1).foregroundStyle(.primary)
                            if ch.archiveDays > 0 { Image(systemName: "clock.arrow.circlepath").font(.caption2).foregroundStyle(Theme.teal) }
                        }
                        if let n = epg.now[ch.id] {
                            Text(n.title).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            ProgressView(value: n.progress).tint(Theme.teal).frame(maxWidth: 160)
                        }
                    }
                    Spacer()
                    if Store.isFavorite(ch.id) { Image(systemName: "star.fill").foregroundStyle(Theme.accent) }
                }
            }
            .task(id: ch.id) { epg.load(ch, from: library.xtream) }
            .swipeActions { Button { Store.toggleFavorite(ch.id); favTick += 1 } label: { Label("مفضلة", systemImage: "star") }.tint(Theme.accent) }
            .swipeActions(edge: .leading) {
                if library.xtream != nil { Button { guide = ch } label: { Label("الدليل", systemImage: "calendar") }.tint(Theme.teal) }
            }
            .contextMenu {
                Button { Store.toggleFavorite(ch.id); favTick += 1 } label: { Label(Store.isFavorite(ch.id) ? "إزالة من المفضلة" : "إضافة للمفضلة", systemImage: "star") }
                if library.xtream != nil { Button { guide = ch } label: { Label("دليل البرامج" + (ch.archiveDays > 0 ? " والإعادة" : ""), systemImage: "calendar") } }
            }
        }
        .id(favTick)
        .task(id: "\(query)|\(library.version)|\(library.groupsTick)|\(favTick)") {
            if !query.isEmpty { try? await Task.sleep(nanoseconds: 150_000_000) }
            guard !Task.isCancelled else { return }
            let fav: Set<String>? = favoritesOnly ? Set(Store.favorites) : nil
            list = Perf.shared.measure("قائمة القنوات", "بحث \(query.count) حرف") {
                ListQuery.channels(library.channels, library.index, query: query) { c in (fav?.contains(c.id) ?? true) && filter(c) }
            }
        }
        .searchable(text: $query, prompt: "بحث في القنوات")
        .navigationTitle(title)
        .sheet(item: $guide) { ch in
            ChannelGuideView(channel: ch) { item in
                guide = nil
                // Let the sheet close before the full-screen player opens.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { play = item }
            }
            .environmentObject(library)
        }
    }
}

/// A channel's programme guide by day; past programmes with catch-up can be played from the provider's archive.
struct ChannelGuideView: View {
    @EnvironmentObject var library: Library
    let channel: Channel
    let onPlay: (PlayItem) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var items: [Programme] = []
    @State private var loading = true
    @State private var expanded: String?

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                List {
                    if loading { HStack { Spacer(); ProgressView(); Spacer() } }
                    if !loading && items.isEmpty { Text("لا يوجد دليل برامج لهذه القناة عند المزوّد.").foregroundStyle(.secondary) }
                    ForEach(days, id: \.self) { day in
                        Section(dayTitle(day)) {
                            ForEach(items.filter { Calendar.current.isDate($0.start, inSameDayAs: day) }) { p in row(p).id(p.id) }
                        }
                    }
                }
                .onChange(of: items) { _ in
                    if let now = items.first(where: \.isNow) { DispatchQueue.main.async { proxy.scrollTo(now.id, anchor: .center) } }
                }
            }
            .navigationTitle(channel.name).navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("إغلاق") { dismiss() } } }
            .task {
                if let x = library.xtream { items = await x.schedule(channel.id) }
                loading = false
            }
        }
        .environment(\.layoutDirection, .rightToLeft)
    }

    private var days: [Date] {
        Array(Set(items.map { Calendar.current.startOfDay(for: $0.start) })).sorted()
    }

    private func canReplay(_ p: Programme) -> Bool {
        guard channel.archiveDays > 0, p.isPast || p.isNow, p.serverStart != nil else { return false }
        return p.hasArchive || p.start > Date().addingTimeInterval(-Double(channel.archiveDays) * 86_400)
    }

    @ViewBuilder private func row(_ p: Programme) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(time(p.start)).font(.callout.monospacedDigit()).foregroundStyle(p.isNow ? Theme.accent : .secondary)
                VStack(alignment: .leading, spacing: 3) {
                    Text(p.title).foregroundStyle(p.isPast && !canReplay(p) ? .secondary : .primary).lineLimit(expanded == p.id ? nil : 2)
                    if p.isNow { ProgressView(value: Date().timeIntervalSince(p.start) / p.end.timeIntervalSince(p.start)).tint(Theme.teal) }
                }
                Spacer()
                if p.isNow { Text("الآن").font(.caption.bold()).foregroundStyle(Theme.accent) }
            }
            if expanded == p.id, let d = p.detail { Text(d).font(.footnote).foregroundStyle(.secondary) }
            HStack {
                if p.isNow {
                    Button { live() } label: { Label("مباشر", systemImage: "dot.radiowaves.left.and.right") }.buttonStyle(.bordered)
                }
                if canReplay(p) {
                    Button { replay(p) } label: { Label(p.isNow ? "من البداية" : "مشاهدة", systemImage: "clock.arrow.circlepath") }
                        .buttonStyle(.borderedProminent)
                }
            }
            .font(.caption)
        }
        .contentShape(Rectangle())
        .onTapGesture { expanded = expanded == p.id ? nil : p.id }
    }

    private func live() {
        onPlay(.live(list: [channel], index: 0))
    }

    private func replay(_ p: Programme) {
        guard let x = library.xtream, let url = x.catchupURL(channel.id, p) else { return }
        let v = VodPlay(title: "\(channel.name) · \(p.title)", url: url, key: "cu:\(channel.id):\(Int(p.start.timeIntervalSince1970))",
                        query: SubQuery(name: p.title))
        onPlay(.vod(list: [v], index: 0))
    }

    private func time(_ d: Date) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "HH:mm"; return f.string(from: d)
    }

    private func dayTitle(_ d: Date) -> String {
        if Calendar.current.isDateInToday(d) { return "اليوم" }
        if Calendar.current.isDateInYesterday(d) { return "أمس" }
        if Calendar.current.isDateInTomorrow(d) { return "غدًا" }
        let f = DateFormatter(); f.locale = Locale(identifier: "ar"); f.dateFormat = "EEEE d MMMM"; return f.string(from: d)
    }
}
