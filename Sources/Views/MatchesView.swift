import SwiftUI

/// 1.8.5: what the matches screen shows, kept for the app's life (the list keeps its day, filters and place).
@MainActor
final class MatchStore: ObservableObject {
    static let shared = MatchStore()

    @Published private(set) var result: MatchIndexBuilder.Result?
    @Published private(set) var groups: [MatchGuideRule.Group] = []
    /// Sports channels without a guide, read once per index.
    private(set) var pool = MatchGuideRule.ExtraPool([])
    @Published private(set) var busy = false
    @Published var status = ""
    @Published var day = 0
    @Published var nowOnly = false
    @Published var sport: MatchScreenRule.SportFilter = .football
    /// The card last opened (key@start), to land on it again.
    var selectedKey: String?
    private var source = ""
    private var job: Task<Void, Never>?
    private var cancel = MatchGuideReport.CancelFlag()
    /// The index is rebuilt after this long (the guide changes during the day).
    static let maxAge: Int64 = 6 * 3_600_000

    /// The live channels as the builder needs them (copied on the main thread).
    static func channels(_ library: Library) -> [GuideChannel] {
        let groups = Dictionary(library.liveCats.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
        return library.channels.map { GuideChannel(id: $0.id, name: $0.name, group: groups[$0.categoryId] ?? "", epg: $0.epgId) }
    }

    static func key(_ g: MatchGuideRule.Group) -> String { g.key + "@\(g.start)" }

    func adopt(_ r: MatchIndexBuilder.Result, source: String) {
        result = r; groups = r.groups; self.source = source; pool = MatchGuideRule.ExtraPool(r.unguided)
        let copy = r
        Task.detached(priority: .utility) { MatchIndexBuilder.save(copy, source: source) }
    }

    var isStale: Bool {
        guard let r = result else { return true }
        let now = Date()
        return r.from != MatchIndexBuilder.ms(MatchIndexBuilder.dayStart(now)) || MatchIndexBuilder.ms(now) - r.built > Self.maxAge
    }

    /// On opening: the kept index first; a stale one is rebuilt on Wi‑Fi, and only on request over mobile data.
    func appear(_ library: Library) {
        let src = library.active?.name ?? "?"
        if result == nil || source != src {
            let now = Date()
            if let r = MatchIndexBuilder.load(source: src, now: now) { result = r; groups = r.groups; source = src; pool = MatchGuideRule.ExtraPool(r.unguided) }
            else { result = nil; groups = [] }
        }
        guard isStale, !busy else { return }
        if PathCost.shared.isExpensive {
            status = result == nil ? "الدليل يُنزَّل من المزوّد (قرابة \(result?.guideMB ?? 80) MB). أنت على بيانات الجوال: اضغط «تحديث» للتنزيل."
                : "القائمة من آخر تحديث. على بيانات الجوال لا نحدّث تلقائيًا — اضغط «تحديث»."
        } else { refresh(library) }
    }

    func refresh(_ library: Library) {
        guard !busy else { return }
        guard let x = library.xtream, let url = x.xmltvURL else { status = "يحتاج مصدر Xtream (دليل البرامج يأتي منه)"; return }
        let chans = Self.channels(library), src = library.active?.name ?? "?"
        let flag = MatchGuideReport.CancelFlag(); cancel = flag
        busy = true; status = "تنزيل الدليل…"
        job = Task {
            let r = await MatchGuideReport.download(url, cancel: flag) { mb in Task { @MainActor in MatchStore.shared.status = "تنزيل الدليل… \(mb) MB" } }
            switch r {
            case .failure(let why):
                status = why.text + (result != nil ? " — نعرض آخر قائمة محفوظة" : "")
            case .success(let (file, size)):
                defer { try? FileManager.default.removeItem(at: file) }
                status = "قراءة الدليل…"
                let now = Date()
                let res = await Task.detached(priority: .utility) {
                    MatchIndexBuilder.build(file: file, size: size, channels: chans, source: src, now: now, cancel: flag, withStats: false)
                }.value
                if flag.isSet { status = "أُلغي"; break }
                Perf.shared.memory("مباريات اليوم: بعد قراءة الدليل")
                adopt(res, source: src)
                status = ""
            }
            busy = false; job = nil
        }
    }

    func stop() { cancel.set(); job?.cancel() }
}

/// 1.8.5: «مباريات اليوم» — matches from the provider's guide, then the channel versions of the chosen one.
/// From the Channels tab it opens the player; inside the player (sheet) the video keeps playing behind it.
struct MatchesView: View {
    @EnvironmentObject var library: Library
    @ObservedObject private var store = MatchStore.shared
    let onPlay: ([Channel], Int) -> Void
    @AppStorage("match.hideHd") private var hideHd = false
    @AppStorage("match.hideSd") private var hideSd = false

    private var cards: [MatchGuideRule.Group] {
        guard let r = store.result else { return [] }
        let tomorrow = MatchIndexBuilder.ms(Calendar.current.date(byAdding: .day, value: 1, to: Date(timeIntervalSince1970: Double(r.from) / 1000)) ?? Date())
        return MatchScreenRule.cards(store.groups, now: MatchIndexBuilder.ms(Date()), dayStart: r.from, tomorrow: tomorrow, end: r.to,
                                     day: store.day, nowOnly: store.nowOnly, sport: store.sport)
    }

    var body: some View {
        ScrollViewReader { proxy in
            List {
                Section {
                    Picker("اليوم", selection: $store.day) { Text("اليوم").tag(0); Text("غدًا").tag(1) }
                        .pickerStyle(.segmented).disabled(store.nowOnly)
                    Toggle("تلعب الآن حسب الدليل", isOn: $store.nowOnly)
                    Picker("الرياضة", selection: $store.sport) {
                        ForEach(MatchScreenRule.SportFilter.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                } footer: {
                    Text("التغطية جزئية: من دليل برامج المزوّد، وللقنوات التي لها دليل فقط. «موسوم مباشر» من الدليل نفسه؛ «غير محدد» ليس تأكيدًا أنه مباشر."
                         + (store.result.map { " آخر تحديث " + MatchIndexBuilder.fmt($0.built) + "." } ?? ""))
                }
                if store.busy || !store.status.isEmpty {
                    Section { HStack { if store.busy { ProgressView() }; Text(store.status).font(.footnote).foregroundStyle(.secondary) } }
                }
                if store.result != nil && cards.isEmpty {
                    Text(store.result?.entries.isEmpty == true ? "الدليل ما فيه مباريات لقنواتك في هذين اليومين." : "ما وجدنا مباريات في الدليل لهذا الاختيار.")
                        .foregroundStyle(.secondary)
                }
                ForEach(Array(cards.enumerated()), id: \.offset) { _, g in
                    NavigationLink {
                        MatchVersionsView(group: g, onPlay: onPlay)
                    } label: { row(g) }
                    .id(MatchStore.key(g))
                }
            }
            .onAppear {
                store.appear(library)
                if let k = store.selectedKey { DispatchQueue.main.async { proxy.scrollTo(k, anchor: .center) } }
            }
        }
        .navigationTitle("مباريات اليوم")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Toggle("إخفاء HD (720p)", isOn: $hideHd)
                    Toggle("إخفاء SD", isOn: $hideSd)
                    Text("4K و1080p والنسخ مجهولة الجودة تبقى دائمًا. الجودة مأخوذة من اسم القناة.")
                } label: { Image(systemName: hideHd || hideSd ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle") }
            }
            ToolbarItem(placement: .primaryAction) {
                Button { store.refresh(library) } label: { Image(systemName: "arrow.clockwise") }.disabled(store.busy)
            }
        }
    }

    private func row(_ g: MatchGuideRule.Group) -> some View {
        let now = MatchIndexBuilder.ms(Date())
        let f = DateFormatter(); f.locale = Locale(identifier: "ar"); f.dateFormat = "HH:mm"
        let time = f.string(from: Date(timeIntervalSince1970: Double(g.start) / 1000))
        return VStack(alignment: .leading, spacing: 3) {
            Text("\(time) · \(g.home) × \(g.away)").lineLimit(1)
            Text([MatchScreenRule.subtitle(g), g.sport.name, MatchScreenRule.state(g, now: now), "\(g.entries.count) نسخة"].compactMap { $0 }.joined(separator: " · "))
                .font(.caption).foregroundStyle(g.live ? Theme.teal : .secondary).lineLimit(2)
        }
    }
}

/// The versions of one match, best first; each is its own channel (same name ≠ same stream).
struct MatchVersionsView: View {
    @EnvironmentObject var library: Library
    let group: MatchGuideRule.Group
    let onPlay: ([Channel], Int) -> Void
    @AppStorage("match.hideHd") private var hideHd = false
    @AppStorage("match.hideSd") private var hideSd = false
    @State private var showAll = false

    var body: some View {
        let r = MatchStore.shared.result
        let v = MatchScreenRule.versions(group, versionOf: { r?.version($0) ?? MatchGuideRule.version($0.channel) },
                                         hideHd: hideHd && !showAll, hideSd: hideSd && !showAll)
        let x = MatchScreenRule.extras(group, pool: MatchStore.shared.pool,
                                       versionOf: { n, src in MatchGuideRule.version(n, labelPrefixes: r?.labels[src] ?? []) },
                                       hideHd: hideHd && !showAll, hideSd: hideSd && !showAll)
        List {
            Section {
                if v.rows.isEmpty { Text("لا توجد نسخة تطابق تفضيلاتك (مخفية \(v.hidden)).").foregroundStyle(.secondary) }
                ForEach(Array(v.rows.enumerated()), id: \.offset) { i, row in
                    Button { play(v.rows.map(\.entry.channelId) + x.map(\.id), i) } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(row.entry.channel + (row.copy > 0 ? " · نسخة \(row.copy)" : "")).lineLimit(1).foregroundStyle(.primary)
                            Text([row.version.label(), row.entry.kind.label, row.entry.general ? "قناة عامة" : nil, "«\(row.entry.title)»"].compactMap { $0 }.joined(separator: " · "))
                                .font(.caption).foregroundStyle(.secondary).lineLimit(3)
                        }
                    }
                }
                if v.hidden > 0 { Button("إظهار باقي الجودات (\(v.hidden))") { showAll = true } }
            } footer: {
                Text("الدقة من اسم القناة فقط. لا نشغّل جودة أقل بدل المخفية تلقائيًا.")
            }
            if !x.isEmpty {
                Section {
                    ForEach(Array(x.enumerated()), id: \.offset) { k, c in
                        Button { play(v.rows.map(\.entry.channelId) + x.map(\.id), v.rows.count + k) } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(c.name).lineLimit(1).foregroundStyle(.primary)
                                Text("\(c.version.label()) · غير مؤكد").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                } header: { Text("قنوات بلا دليل قد تنقلها") } footer: {
                    Text("من نفس الشبكة واسمها يطابق قناة ناقلة؛ الدليل لا يؤكد أنها تعرض هذه المباراة.")
                }
            }
        }
        .navigationTitle("\(group.home) × \(group.away)")
        .onAppear { MatchStore.shared.selectedKey = MatchStore.key(group) }
    }

    /// Plays the chosen version; the player then switches only between the versions shown here.
    private func play(_ ids: [String], _ i: Int) {
        let byId = Dictionary(library.channels.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var list: [Channel] = []; var at = 0
        for (k, id) in ids.enumerated() {
            guard let ch = byId[id] else { continue }
            if k == i { at = list.count }
            list.append(ch)
        }
        guard !list.isEmpty, ids.indices.contains(i), byId[ids[i]] != nil else { return }
        onPlay(list, at)
    }
}
