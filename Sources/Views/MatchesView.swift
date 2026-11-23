import SwiftUI
import UniformTypeIdentifiers

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
    /// 1.8.6: the merged rows (guide + imported files + manual links) and what they come from.
    @Published private(set) var rows: [MatchSourcesRule.Row] = []
    @Published private(set) var files: [MatchSourceFiles.Item] = MatchSourceFiles.list()
    @Published private(set) var manual: [MatchSourcesRule.Manual] = MatchSourceFiles.manual()
    private var libIdx: MatchSourcesRule.LibIndex?
    private var libStamp = ""
    private var mergeGen = 0

    /// The index is rebuilt after this long (the guide changes during the day).
    static let maxAge: Int64 = 6 * 3_600_000

    /// The live channels as the builder needs them (copied on the main thread).
    static func channels(_ library: Library) -> [GuideChannel] {
        let groups = Dictionary(library.liveCats.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
        return library.channels.map { GuideChannel(id: $0.id, name: $0.name, group: groups[$0.categoryId] ?? "", epg: $0.epgId) }
    }

    static func key(_ g: MatchGuideRule.Group) -> String { g.key + "@\(g.start)" }
    static func key(_ r: MatchSourcesRule.Row) -> String { r.key + "@\(r.start)" }

    func adopt(_ r: MatchIndexBuilder.Result, source: String) {
        result = r; groups = r.groups; self.source = source; pool = MatchGuideRule.ExtraPool(r.unguided)
        remerge()
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
        remerge(library)
        fetchSchedules(force: false)
        guard isStale, !busy else { return }
        if PathCost.shared.isExpensive {
            status = result == nil ? "الدليل يُنزَّل من المزوّد (قرابة \(result?.guideMB ?? 80) MB). أنت على بيانات الجوال: اضغط «تحديث» للتنزيل."
                : "القائمة من آخر تحديث. على بيانات الجوال لا نحدّث تلقائيًا — اضغط «تحديث»."
        } else { refresh(library) }
    }

    /// 1.8.8: the schedule sites in the background (when due, or on Refresh); the rows are merged again when one changed.
    func fetchSchedules(force: Bool) {
        guard MatchFetch.shared.due(force: force) else { return }
        Task {
            let changed = await MatchFetch.shared.run(force: force) { msg in Task { @MainActor in MatchStore.shared.fetchStatus = msg } }
            fetchStatus = ""
            if changed { files = MatchSourceFiles.list(); remerge() }
        }
    }
    @Published var fetchStatus = ""

    func refresh(_ library: Library) {
        fetchSchedules(force: true)
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

    // ---------- 1.8.6: sources and manual links ----------

    private weak var lastLibrary: Library?

    /// Window of the rows: the guide's (today + tomorrow), or the same two local days with no guide.
    private var window: (Int64, Int64) {
        if let r = result { return (r.from, r.to) }
        let d = MatchIndexBuilder.dayStart(Date())
        return (MatchIndexBuilder.ms(d), MatchIndexBuilder.ms(Calendar.current.date(byAdding: .day, value: 2, to: d) ?? d.addingTimeInterval(172_800)))
    }

    /// Recomputes the rows off the main thread (the library index is rebuilt only when the channels change).
    func remerge(_ library: Library? = nil) {
        if let library { lastLibrary = library }
        guard let lib = lastLibrary else { return }
        let chans = lib.channels
        let stamp = "\(lib.active?.name ?? "")#\(chans.count)#\(chans.first?.id ?? "")#\(chans.last?.id ?? "")"
        // the library index is needed only to match imported schedules: not built at all without one
        let needIdx = !files.isEmpty && (libIdx == nil || stamp != libStamp)
        let libList = needIdx ? chans.map { MatchSourcesRule.LibCh(id: $0.id, name: $0.name) } : []
        let oldIdx = libIdx
        let gs = groups, srcs = files.map(\.source), man = manual, pl = pool
        let (from, to) = window
        let guideSource = result != nil ? "EPG المزوّد (\(source))" : "EPG المزوّد"
        let guideAt = result?.built ?? 0
        mergeGen += 1; let gen = mergeGen
        let t0 = Perf.now()
        Task {
            let (idx, out) = await Task.detached(priority: .userInitiated) { () -> (MatchSourcesRule.LibIndex, [MatchSourcesRule.Row]) in
                let idx = needIdx ? MatchSourcesRule.LibIndex(libList) : (srcs.isEmpty ? MatchSourcesRule.LibIndex([]) : oldIdx!)
                return (idx, MatchSourcesRule.merge(gs, sources: srcs, idx: idx, pool: pl, manual: man, guideSource: guideSource, guideAt: guideAt, from: from, to: to))
            }.value
            guard gen == mergeGen else { return }
            if needIdx { libIdx = idx; libStamp = stamp }
            Perf.shared.record("مباريات اليوم: الدمج", since: t0, "\(out.count) مباراة · فهرس المكتبة \(needIdx ? "بُني" : "محفوظ أو غير لازم")")
            rows = out
        }
    }

    /// The full comparison for the report (same rows as the screen, computed now).
    func compareText(_ library: Library) async -> String {
        let libList = library.channels.map { MatchSourcesRule.LibCh(id: $0.id, name: $0.name) }
        let gs = groups, srcs = files.map(\.source), man = manual, pl = pool
        let (from, to) = window
        let guideSource = result != nil ? "EPG المزوّد (\(source))" : "EPG المزوّد", guideAt = result?.built ?? 0
        let names = files.map { "   - \($0.source.name) · \($0.source.kind.label) · حُدّث \(MatchIndexBuilder.fmt($0.source.fetchedAt)) · \($0.source.matches.count) مباراة" + ($0.source.url.map { " · " + $0 } ?? "") }
        return await Task.detached(priority: .userInitiated) {
            if srcs.isEmpty { return "\n— الجداول المستوردة: لا شيء. استورد ملف shasha-matches من شاشة المباريات لتظهر المقارنة الكاملة.\n" }
            let rows = MatchSourcesRule.merge(gs, sources: srcs, idx: MatchSourcesRule.LibIndex(libList), pool: pl, manual: man,
                                              guideSource: guideSource, guideAt: guideAt, from: from, to: to)
            return "\n— الجداول المستوردة\n" + names.joined(separator: "\n") + "\n\n" + MatchSourcesRule.compare(rows, fmt: MatchIndexBuilder.fmt)
        }.value
    }

    func importFile(_ url: URL) {
        switch MatchSourceFiles.importFile(url) {
        case .success(let r):
            let s = r.new, cov = MatchSourcesRule.coverage(s, now: MatchIndexBuilder.ms(Date())).text(MatchIndexBuilder.fmt)
            if let old = r.replaced {
                status = "حُدّث «\(s.name)»: \(s.matches.count) مباراة (كانت \(old.matches.count)، بيانات \(MatchIndexBuilder.fmt(old.fetchedAt))) — الربط اليدوي باقٍ · " + cov
            } else {
                status = "استُورد «\(s.name)»: \(s.matches.count) مباراة · \(s.matches.reduce(0) { $0 + $1.channels.count }) قناة · " + cov
            }
        case .failure(let f): status = "لم يُستورد (لم يتغيّر شيء): " + f.text
        }
        files = MatchSourceFiles.list(); remerge()
    }

    func removeFile(_ file: String) { MatchSourceFiles.remove(file); files = MatchSourceFiles.list(); remerge() }

    func setManual(row: MatchSourcesRule.Row, channelId: String, name: String, add: Bool) {
        saveManual(MatchSourcesRule.manualSetFor(manual, row: row, channelId: channelId, name: name, add: add, at: MatchIndexBuilder.ms(Date())))
    }
    func clearManual(row: MatchSourcesRule.Row, channelId: String) { saveManual(MatchSourcesRule.manualClearFor(manual, row: row, channelId: channelId)) }

    /// Imported schedules whose coverage has ended.
    var endedSources: [String] {
        let now = MatchIndexBuilder.ms(Date())
        return files.filter { MatchSourcesRule.coverage($0.source, now: now).ended }.map(\.source.name)
    }
    private func saveManual(_ list: [MatchSourcesRule.Manual]) {
        manual = list
        if !MatchSourceFiles.saveManual(list) { status = "تعذّر حفظ الربط اليدوي" }
        remerge()
    }
}

/// 1.8.6: «مباريات اليوم» — one row per match from the provider's guide AND the imported schedules, then every
/// channel of the library under it with where each fact came from. From the Channels tab it opens the player;
/// inside the player (sheet) the video keeps playing behind it.
struct MatchesView: View {
    @EnvironmentObject var library: Library
    @ObservedObject private var store = MatchStore.shared
    let onPlay: ([Channel], Int) -> Void
    @AppStorage("match.hideHd") private var hideHd = false
    @AppStorage("match.hideSd") private var hideSd = false
    @State private var importing = false
    @State private var showFiles = false

    private var shown: [MatchSourcesRule.Row] {
        // "today" is the device's today, also while yesterday's kept index is shown after midnight
        let from = MatchIndexBuilder.ms(MatchIndexBuilder.dayStart(Date()))
        let tomorrow = MatchIndexBuilder.ms(Calendar.current.date(byAdding: .day, value: 1, to: Date(timeIntervalSince1970: Double(from) / 1000)) ?? Date())
        let end = max(store.result?.to ?? 0, tomorrow + 86_400_000)
        return MatchSourcesRule.rowsFor(store.rows, now: MatchIndexBuilder.ms(Date()), dayStart: from, tomorrow: tomorrow, end: end,
                                        day: store.day, nowOnly: store.nowOnly, sport: store.sport)
    }

    private var footerText: String {
        var t = "التغطية جزئية: دليل برامج المزوّد"
        if !store.files.isEmpty { t += " + \(store.files.count) جدول مستورد" }
        t += ". الأوقات بتوقيت هذا الجهاز (\(TimeZone.current.identifier))."
        if let r = store.result {
            t += " آخر تحديث للدليل " + MatchIndexBuilder.fmt(r.built) + "."
            if r.from != MatchIndexBuilder.ms(MatchIndexBuilder.dayStart(Date())) { t += " (قائمة أمس، وتغطي اليوم، لين تجهز قائمة اليوم)" }
        }
        for n in store.endedSources { t += " ⚠︎ «\(n)» انتهت تغطيته: استورد تحديثًا." }
        return t
    }

    private var emptyNote: Bool { (store.result != nil || !store.files.isEmpty) && shown.isEmpty }

    var body: some View {
        list
            .navigationTitle("مباريات اليوم")
            .toolbar { toolbar }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.json, .item], allowsMultipleSelection: false) { r in
                if case .success(let urls) = r, let u = urls.first { store.importFile(u) }
            }
            .sheet(isPresented: $showFiles) { NavigationStack { MatchFilesView() } }
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Menu {
                Toggle("إخفاء HD (720p)", isOn: $hideHd)
                Toggle("إخفاء SD", isOn: $hideSd)
                Text("4K و1080p والنسخ مجهولة الجودة تبقى دائمًا. الجودة مأخوذة من اسم القناة.")
                Divider()
                Button { importing = true } label: { Label("استيراد جدول مباريات…", systemImage: "square.and.arrow.down") }
                Button { showFiles = true } label: { Label("الجداول المستوردة (\(store.files.count))", systemImage: "doc.text") }
            } label: { Image(systemName: hideHd || hideSd ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle") }
        }
        ToolbarItem(placement: .primaryAction) {
            Button { store.refresh(library) } label: { Image(systemName: "arrow.clockwise") }.disabled(store.busy)
        }
    }

    private var list: some View {
        ScrollViewReader { proxy in
            List {
                Section {
                    Picker("اليوم", selection: $store.day) { Text("اليوم").tag(0); Text("غدًا").tag(1) }
                        .pickerStyle(.segmented).disabled(store.nowOnly)
                    Toggle("تلعب الآن حسب الدليل أو الجدول", isOn: $store.nowOnly)
                    Picker("الرياضة", selection: $store.sport) {
                        ForEach(MatchScreenRule.SportFilter.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                } footer: { Text(footerText) }
                if store.busy || !store.status.isEmpty {
                    Section { HStack { if store.busy { ProgressView() }; Text(store.status).font(.footnote).foregroundStyle(.secondary) } }
                }
                if !store.fetchStatus.isEmpty {
                    Section { HStack { ProgressView(); Text(store.fetchStatus).font(.footnote).foregroundStyle(.secondary) } }
                }
                if emptyNote {
                    Text("ما وجدنا مباريات لهذا الاختيار.").foregroundStyle(.secondary)
                }
                ForEach(Array(shown.enumerated()), id: \.offset) { _, r in
                    NavigationLink {
                        MatchRowView(key: MatchStore.key(r), onPlay: onPlay)
                    } label: { rowLabel(r) }
                    .id(MatchStore.key(r))
                }
            }
            .onAppear {
                store.appear(library)
                if let k = store.selectedKey { DispatchQueue.main.async { proxy.scrollTo(k, anchor: .center) } }
            }
            .onChange(of: library.channels.count) { _ in store.remerge(library) }
        }
    }

    private func rowLabel(_ r: MatchSourcesRule.Row) -> some View {
        let now = MatchIndexBuilder.ms(Date())
        let f = DateFormatter(); f.locale = Locale(identifier: "ar"); f.dateFormat = "HH:mm"
        let time = f.string(from: Date(timeIntervalSince1970: Double(r.start) / 1000))
        let confirmed = r.links.filter(\.confirmed).count
        let state: String? = r.group.map { MatchScreenRule.state($0, now: now) } ?? (r.airingAt(now) ? "بدأت حسب الجدول" : nil)
        var parts: [String] = []
        if let t = r.group.flatMap(MatchScreenRule.subtitle) ?? r.competition { parts.append(t) }
        if r.sport.sport != .unknown, let n = r.sport.name { parts.append(n) }
        if let state { parts.append(state) }
        var c = "\(confirmed) قناة مؤكدة"
        if r.links.count > confirmed { c += " · \(r.links.count - confirmed) أخرى" }
        parts.append(c)
        if r.group == nil { parts.append("من الجدول فقط (ليست في EPG)") }
        if r.timeConflict { parts.append("⚠︎ تعارض في الموعد") }
        return VStack(alignment: .leading, spacing: 3) {
            Text("\(time) · \(r.home) × \(r.away)").lineLimit(1)
            Text(parts.joined(separator: " · "))
                .font(.caption).foregroundStyle(r.group?.live == true ? Theme.teal : .secondary).lineLimit(3)
        }
    }
}

/// The imported files: name, kind, when the facts were taken, how many matches; remove.
struct MatchFilesView: View {
    @ObservedObject private var store = MatchStore.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            if store.files.isEmpty { Text("لا توجد جداول مستوردة.").foregroundStyle(.secondary) }
            ForEach(store.files, id: \.file) { it in
                VStack(alignment: .leading, spacing: 3) {
                    Text(it.source.name)
                    Text("\(it.source.kind.label) · \(it.source.matches.count) مباراة · "
                         + MatchSourcesRule.coverage(it.source, now: MatchIndexBuilder.ms(Date())).text(MatchIndexBuilder.fmt))
                        .font(.caption).foregroundStyle(.secondary)
                }
                .swipeActions { Button(role: .destructive) { store.removeFile(it.file) } label: { Label("حذف", systemImage: "trash") } }
            }
            Section {
                Text(MatchFetch.shared.lastRun == nil ? "لم يُجلب بعد" : "آخر جلب: " + MatchFetch.shared.lastResult).font(.caption)
                Button("جلب الآن") { store.fetchSchedules(force: true) }.disabled(!MatchFetch.shared.due(force: true))
            } header: { Text("الجلب التلقائي (Live-FootballOnTV و LiveSoccerTV)") } footer: { Text("يجلب تلقائيًا كل 6 ساعات على الأكثر عند فتح شاشة المباريات، أو عند «تحديث» (مرة كل 15 دقيقة).") }
            Section { } footer: {
                Text("الملفات محفوظة على هذا الجهاز فقط (حد \(MatchSourceFiles.maxFiles) ملفات، 5 MB لكل ملف). الصيغة في docs/MATCH-SOURCES.md. روابط التشغيل وبيانات اشتراكك لا تُرسل لأي مصدر.")
            }
        }
        .navigationTitle("الجداول المستوردة")
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("تم") { dismiss() } } }
    }
}

/// One match: confirmed channels, possible ones, suggestions without a guide, removed, listed but not in the library,
/// platforms; each channel with the source and time of every fact. Long press: remove / put back / delete a manual link.
struct MatchRowView: View {
    @EnvironmentObject var library: Library
    @ObservedObject private var store = MatchStore.shared
    let key: String
    let onPlay: ([Channel], Int) -> Void
    @AppStorage("match.hideHd") private var hideHd = false
    @AppStorage("match.hideSd") private var hideSd = false
    @State private var showAll = false
    @State private var adding = false
    /// "" = all. Channels of unknown country / language always stay.
    @AppStorage("match.country") private var country = ""
    @AppStorage("match.lang") private var lang = ""

    private var row: MatchSourcesRule.Row? { store.rows.first { MatchStore.key($0) == key } }

    private func versionOf(_ name: String) -> MatchGuideRule.Version {
        MatchGuideRule.version(name, labelPrefixes: store.result?.labels.values.reduce(Set<String>()) { $0.union($1) } ?? [])
    }

    var body: some View {
        SwiftUI.Group {
            if let r = row { content(r) } else { Text("المباراة لم تعد في القائمة (تغيّر الدليل أو الجداول).").foregroundStyle(.secondary) }
        }
        .navigationTitle(row.map { "\($0.home) × \($0.away)" } ?? "")
        .onAppear { store.selectedKey = key }
        .sheet(isPresented: $adding) { if let r = row { NavigationStack { MatchAddChannelView(row: r) } } }
    }

    @ViewBuilder private func content(_ r: MatchSourcesRule.Row) -> some View {
        let sec = MatchSourcesRule.sections(r, versionOf: versionOf, hideHd: hideHd && !showAll, hideSd: hideSd && !showAll,
                                            country: showAll || country.isEmpty ? nil : country, lang: showAll || lang.isEmpty ? nil : lang)
        List {
            Section { info(r) }
            filters(r)
            linkSection("مؤكدة", sec.confirmed, zap: true, r,
                        footer: "مؤكدة بدليل: EPG المزوّد، أو اسم مطابق في جدول ناقل/دليل نقل، أو أضفتها يدويًا. 4K أولًا ثم 1080p. التنقل بين القنوات داخل هذه القائمة فقط.")
            linkSection("بدائل 4K محتملة (قد لا تكون نفس البث)", sec.alternatives, zap: false, r,
                        footer: "جدول يذكر قناة 4K (مثل Sky Sports Ultra HDR أو TNT Sports Ultimate)؛ هذه نسخ 4K لقنوات مذكورة معها. غير مؤكدة، وتُشغَّل فقط إذا اخترتها.")
            linkSection("محتملة", sec.possible, zap: false, r,
                        footer: "اسم قريب أو بلد آخر — غير مؤكدة، وتُشغَّل فقط إذا اخترتها.")
            linkSection("قنوات بلا دليل قد تنقلها", sec.suggested, zap: false, r,
                        footer: "من نفس الشبكة واسمها قريب؛ لا مصدر يؤكد أنها تعرض المباراة، ولا تُعدّ ضمن المؤكدة.")
            if sec.hidden > 0 { Section { Button("إظهار المخفي بالجودة أو الدولة أو اللغة (\(sec.hidden))") { showAll = true } } }
            Section { Button { adding = true } label: { Label("إضافة قناة لهذه المباراة يدويًا", systemImage: "plus") } } footer: {
                Text("الربط اليدوي يُحفظ على الجهاز ويبقى بعد إعادة التشغيل، لهذه المباراة فقط.")
            }
            if !r.removed.isEmpty {
                Section("أزلتها من هذه المباراة") {
                    ForEach(r.removed, id: \.channelId) { m in
                        HStack { Text(m.name).lineLimit(1); Spacer(); Button("إرجاع") { store.clearManual(row: r, channelId: m.channelId) } }
                    }
                }
            }
            if !r.missing.isEmpty {
                Section {
                    ForEach(Array(r.missing.enumerated()), id: \.offset) { _, x in
                        Text("\(x.0) · \(x.1)").font(.footnote)
                    }
                } header: { Text("مذكورة في الجداول وليست في مكتبتك (\(r.missing.count))") }
            }
            if !r.platforms.isEmpty {
                Section {
                    ForEach(Array(r.platforms.enumerated()), id: \.offset) { _, x in
                        Text("\(x.0) · \(MatchSourcesRule.channelType(x.0).label) · \(x.1)").font(.footnote)
                    }
                } header: { Text("متاحة أيضًا على منصات وشبكات") } footer: {
                    Text("منصة أو شبكة كاملة، لا تُربط بقناة من مكتبتك تخمينًا.")
                }
            }
        }
    }

    @ViewBuilder private func info(_ r: MatchSourcesRule.Row) -> some View {
        let tz = TimeZone.current
        let off: String = String(format: "%+.1f", Double(tz.secondsFromGMT()) / 3600)
        let zone: String = tz.identifier + " (UTC" + off + ")"
        VStack(alignment: .leading, spacing: 4) {
            if let c = r.competition { Text(c).font(.subheadline) }
            if let k = r.kickoff { Text("موعد الانطلاق: \(MatchIndexBuilder.fmt(k)) — من \(r.kickoffFrom ?? "")").font(.caption) }
            if let g = r.group { Text("برامج EPG: " + epgTimes(g)).font(.caption) }
            if r.timeConflict { Text("⚠︎ موعد الجدول لا يطابق وقت برنامج EPG (أو جدولان مختلفان) — الاثنان معروضان كما هما.").font(.caption).foregroundStyle(.orange) }
            Text("الأوقات بتوقيت الجهاز: \(zone) · المصادر: \(r.sources.joined(separator: "، "))").font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func epgTimes(_ g: MatchGuideRule.Group) -> String {
        var out: [String] = []
        for e in g.entries.prefix(6) {
            let x = MatchIndexBuilder.fmt(e.start) + "–" + String(MatchIndexBuilder.fmt(e.stop).suffix(5))
            if !out.contains(x) { out.append(x) }
        }
        return out.joined(separator: " / ")
    }

    /// Country and commentary-language filters (all by default; unknown country / language always stay).
    @ViewBuilder private func filters(_ r: MatchSourcesRule.Row) -> some View {
        let o = MatchSourcesRule.filterOptions(r)
        let cs = Array(NSOrderedSet(array: o.countries + (country.isEmpty ? [] : [country]) + [MatchSourcesRule.unknownCountry])) as? [String] ?? []
        let ls = Array(NSOrderedSet(array: o.languages + (lang.isEmpty ? [] : [lang]) + [MatchSourcesRule.unknownLang])) as? [String] ?? []
        Section {
            Picker("الدولة", selection: $country) {
                Text("كل الدول").tag("")
                ForEach(cs, id: \.self) { Text($0).tag($0) }
            }
            Picker("لغة التعليق", selection: $lang) {
                Text("كل اللغات").tag("")
                ForEach(ls, id: \.self) { Text($0).tag($0) }
            }
        } footer: { Text("اختيار دولة أو لغة يُبقي القنوات مجهولة الدولة أو اللغة. اللغة من اسم القناة فقط، لا تُخمَّن.") }
    }

    @ViewBuilder private func linkSection(_ title: String, _ links: [MatchSourcesRule.Link], zap: Bool,
                                          _ r: MatchSourcesRule.Row, footer: String) -> some View {
        if !links.isEmpty {
            Section {
                ForEach(links, id: \.channelId) { l in
                    // confirmed: zapping between the confirmed ones; anything else plays alone, only when chosen
                    Button { zap ? play(links.map(\.channelId), links.firstIndex { $0.channelId == l.channelId } ?? 0) : play([l.channelId], 0) } label: { linkLabel(l) }
                        .contextMenu {
                            if l.proofs.contains(where: { $0.kind == .manual }) {
                                Button(role: .destructive) { store.clearManual(row: r, channelId: l.channelId) } label: { Label("حذف الربط اليدوي", systemImage: "link.badge.plus") }
                            }
                            Button(role: .destructive) {
                                store.setManual(row: r, channelId: l.channelId, name: l.name, add: false)
                            } label: { Label("إزالة من هذه المباراة", systemImage: "minus.circle") }
                            if !l.proofs.contains(where: { $0.kind == .manual }) {
                                Button {
                                    store.setManual(row: r, channelId: l.channelId, name: l.name, add: true)
                                } label: { Label("تأكيدها يدويًا", systemImage: "checkmark.circle") }
                            }
                        }
                }
            } header: { Text("\(title) (\(links.count))") } footer: { Text(footer) }
        }
    }

    private func linkLabel(_ l: MatchSourcesRule.Link) -> some View {
        let v = versionOf(l.name)
        let country = MatchGuideRule.country(l.name)
        let lang = MatchSourcesRule.language(l.name) ?? l.proofs.lazy.compactMap { MatchSourcesRule.language($0.detail ?? "") }.first
        var meta: [String] = [v.label()]
        if country != "بدون بادئة" { meta.append(country) }
        if let lang { meta.append("تعليق " + lang) }
        return VStack(alignment: .leading, spacing: 3) {
            Text(l.name).lineLimit(1).foregroundStyle(.primary)
            Text(meta.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
            Text(MatchSourcesRule.proofText(l, fmt: MatchIndexBuilder.fmt)).font(.caption2).foregroundStyle(.secondary).lineLimit(4)
        }
    }

    /// Plays the chosen channel; the player then switches only between the channels shown here.
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

/// Search the library and link a channel to this match by hand (kept on the device).
struct MatchAddChannelView: View {
    @EnvironmentObject var library: Library
    @Environment(\.dismiss) private var dismiss
    let row: MatchSourcesRule.Row
    @State private var q = ""

    private var found: [Channel] {
        let k = MatchGuideRule.words(q)
        guard k.count >= 2 else { return [] }
        let have = Set(row.links.map(\.channelId))
        return Array(library.channels.lazy.filter { !have.contains($0.id) && MatchGuideRule.words($0.name).contains(k) }.prefix(60))
    }

    var body: some View {
        List {
            if MatchGuideRule.words(q).count < 2 { Text("اكتب حرفين على الأقل من اسم القناة (مثل sky ultra أو tnt 1).").foregroundStyle(.secondary) }
            ForEach(found, id: \.id) { ch in
                Button {
                    MatchStore.shared.setManual(row: row, channelId: ch.id, name: ch.name, add: true)
                    dismiss()
                } label: { Text(ch.name).foregroundStyle(.primary) }
            }
        }
        .searchable(text: $q, placement: .navigationBarDrawer(displayMode: .always), prompt: "اسم القناة")
        .navigationTitle("\(row.home) × \(row.away)")
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("إلغاء") { dismiss() } } }
    }
}
