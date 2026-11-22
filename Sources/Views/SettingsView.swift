import SwiftUI

/// 1.5.0: Settings as a hub — active-source card, status tiles, short list of sections that open their own pages.
/// Same sections and settings as before (nothing removed), only arranged differently. The server address is no
/// longer shown on screen, so screenshots don't carry it.
struct SettingsView: View {
    /// Credit line injected at build time (SHASHA_CREDIT secret), so it is not stored in the public source.
    private var credit: String {
        let c = (Bundle.main.object(forInfoDictionaryKey: "ShashaCredit") as? String ?? "").trimmingCharacters(in: .whitespaces)
        return c.isEmpty || c.hasPrefix("$(") ? "شاشة" : c
    }
    private var version: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "") + " (" + (Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "") + ")"
    }
    @EnvironmentObject var library: Library
    @State private var adding = false
    @State private var tick = 0            // re-reads link states when coming back to the page
    @AppStorage(MachineTranslate.key) private var translate = true

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    sourceCard
                    statusTiles
                    sectionList
                    VStack(spacing: 2) {
                        Text(credit).font(.subheadline.weight(.semibold)).foregroundStyle(Theme.accent)
                        Text("الإصدار \(version) · mpv وFFmpeg (LGPL)").font(.caption2).foregroundStyle(.secondary)
                    }.padding(.top, 6).padding(.bottom, 24)
                }
                .padding(.horizontal)
                .id(tick)
            }
            .background(Color.black.ignoresSafeArea())
            .navigationTitle("الإعدادات")
            .sheet(isPresented: $adding) { NavigationStack { SetupView() } }
            .onAppear { tick += 1 }
            .onReceive(NotificationCenter.default.publisher(for: .cloudSyncApplied)) { _ in tick += 1 }
        }
    }

    // MARK: Active source

    private var sourceCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Text(String((library.active?.name ?? "؟").prefix(1)).uppercased())
                    .font(.title3.weight(.bold)).foregroundStyle(.black)
                    .frame(width: 46, height: 46).background(Theme.accent, in: RoundedRectangle(cornerRadius: 13))
                VStack(alignment: .leading, spacing: 2) {
                    Text(library.active?.name ?? "لا يوجد مصدر").font(.headline)
                    Text(library.active.map { $0.kind == .xtream ? "Xtream · المصدر النشط" : "M3U · المصدر النشط" } ?? "أضف قائمتك للبدء")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                stateChip
            }
            if library.active != nil {
                HStack(spacing: 8) {
                    countBox("أفلام", library.movies.count)
                    countBox("مسلسلات", library.shows.count)
                    countBox("قنوات", library.channels.count)
                }
            }
            HStack(spacing: 8) {
                Button { Task { await library.reload() } } label: {
                    Label(library.loading ? "جارٍ التحديث…" : "تحديث", systemImage: "arrow.clockwise")
                        .frame(maxWidth: .infinity).padding(.vertical, 10)
                        .background(Theme.accent, in: RoundedRectangle(cornerRadius: 11)).foregroundStyle(.black)
                }
                .disabled(library.loading || library.active == nil)
                NavigationLink { SourcesPage(adding: $adding) } label: {
                    Label("المصادر", systemImage: "arrow.left.arrow.right")
                        .frame(maxWidth: .infinity).padding(.vertical, 10)
                        .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 11)).foregroundStyle(Theme.accent)
                }
            }
            .font(.subheadline.weight(.semibold))
            Text("آخر تحديث ناجح: " + (library.lastSuccess.map(LastUpdate.text) ?? "لم يتم بعد"))
                .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(14)
        .background(Color(red: 0.105, green: 0.10, blue: 0.09), in: RoundedRectangle(cornerRadius: 20))
        .overlay(RoundedRectangle(cornerRadius: 20).stroke(Theme.accent.opacity(0.25), lineWidth: 0.5))
    }

    private var chipState: (text: String, color: Color) {
        if library.loading { return ("يحدّث", Theme.accent) }
        if library.active == nil { return ("بدون مصدر", .secondary) }
        return library.lastSuccess == nil ? ("غير محدّث", .orange) : ("متصل", Theme.teal)
    }

    private var stateChip: some View {
        let st = chipState
        return Text(st.text).font(.caption2.weight(.semibold)).foregroundStyle(st.color)
            .padding(.horizontal, 10).padding(.vertical, 4).background(st.color.opacity(0.15), in: Capsule())
    }

    private func countBox(_ label: String, _ n: Int) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            Text(n.formatted()).font(.subheadline.weight(.bold)).monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
    }

    // MARK: Status tiles

    private var statusTiles: some View {
        let cols = [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)]
        return LazyVGrid(columns: cols, spacing: 10) {
            NavigationLink { SettingsPage(title: "المزامنة") { CloudSyncSection() } } label: {
                tile("icloud.and.arrow.up", "المزامنة", syncLine.0, syncLine.1, .mint)
            }
            NavigationLink { SettingsPage(title: "TMDB") { TmdbSettingsSection() } } label: {
                tile("film.stack", "TMDB", TmdbKey.value != nil ? "مفعّل" : "غير مضاف", TmdbKey.value != nil, .blue)
            }
            NavigationLink { SettingsPage(title: "Trakt") { TraktSettingsSection() } } label: {
                tile("chart.line.uptrend.xyaxis", "Trakt", TraktKeys.isLinked ? "مربوط" : "غير مربوط", TraktKeys.isLinked, .pink)
            }
            NavigationLink { SettingsPage(title: "TMDB") { TmdbSettingsSection() } } label: {
                tile("character.bubble", "الترجمة الآلية", translate ? "تعمل" : "متوقفة", translate, Theme.accent)
            }
        }
        .buttonStyle(.plain)
    }

    private var syncLine: (String, Bool) {
        guard DriveKeys.isLinked else { return ("غير مربوطة", false) }
        if let d = CloudSync.lastSuccess { return ("مربوطة · " + LastUpdate.text(d), true) }
        return ("مربوطة", true)
    }

    private func tile(_ icon: String, _ title: String, _ line: String, _ on: Bool, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Image(systemName: icon).font(.system(size: 18, weight: .semibold)).foregroundStyle(color)
            Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
            HStack(spacing: 4) {
                Circle().fill(on ? color : Color.secondary.opacity(0.5)).frame(width: 6, height: 6)
                Text(line).font(.caption2).foregroundStyle(on ? color : .secondary).lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color(white: 0.09), in: RoundedRectangle(cornerRadius: 16))
        .contentShape(RoundedRectangle(cornerRadius: 16))
    }

    // MARK: Sections

    private var sectionList: some View {
        VStack(spacing: 0) {
            NavigationLink { SettingsPage(title: "التشغيل والصوت والترجمة") { LanguageSettingsSection(); SubsSettingsSection() } } label: {
                row("play.fill", .purple, "التشغيل والصوت والترجمة")
            }
            divider
            NavigationLink { GroupsPage() } label: { row("square.grid.2x2.fill", .orange, "المجموعات", "ترتيب · إخفاء · قفل") }
            divider
            NavigationLink { SettingsPage(title: "الحسابات والربط") { TmdbSettingsSection(); CloudSyncSection(); TraktSettingsSection() } } label: {
                row("link", .teal, "الحسابات والربط", "TMDB · Drive · Trakt")
            }
            divider
            NavigationLink { SettingsPage(title: "المظهر") { AppearanceSection(); HomeRowsSection() } } label: { row("paintpalette.fill", .pink, "المظهر") }
            divider
            NavigationLink { SettingsPage(title: "التخزين") { StorageSection() } } label: { row("internaldrive.fill", .gray, "التخزين") }
            divider
            NavigationLink { DiagnosticsPage() } label: { row("waveform.path.ecg", .gray, "التشخيص والأداء") }
        }
        .buttonStyle(.plain)
        .background(Color(white: 0.09), in: RoundedRectangle(cornerRadius: 16))
    }

    private var divider: some View { Divider().overlay(Color.white.opacity(0.06)).padding(.leading, 54) }

    private func row(_ icon: String, _ color: Color, _ title: String, _ detail: String? = nil) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon).font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
                .frame(width: 30, height: 30).background(color.gradient, in: RoundedRectangle(cornerRadius: 8))
            Text(title).foregroundStyle(.primary)
            Spacer()
            if let detail { Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
            Image(systemName: "chevron.forward").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 12).padding(.vertical, 11)
        .contentShape(Rectangle())
    }

}

/// A plain settings page holding one or more of the existing sections.
struct SettingsPage<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content
    var body: some View {
        List { content }
            .navigationTitle(title).navigationBarTitleDisplayMode(.inline)
    }
}

/// Sources: switch, add, delete (swipe), refresh, last success — the old first section, on its own page.
struct SourcesPage: View {
    @EnvironmentObject var library: Library
    @Binding var adding: Bool
    var body: some View {
        List {
            Section {
                ForEach(library.sources) { s in
                    Button { library.select(s) } label: {
                        HStack {
                            VStack(alignment: .leading) {
                                Text(s.name).foregroundStyle(.primary)
                                Text(s.kind == .xtream ? "Xtream" : "M3U").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if s.id == library.active?.id { Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.teal) }
                        }
                    }
                    .swipeActions { Button(role: .destructive) { library.remove(s) } label: { Label("حذف", systemImage: "trash") } }
                }
            } footer: { Text("اضغط على مصدر للتبديل إليه، واسحب لليسار للحذف.") }
            Section {
                Button { adding = true } label: { Label("إضافة قائمة", systemImage: "plus") }
                Button { Task { await library.reload() } } label: { Label("تحديث القائمة الآن", systemImage: "arrow.clockwise") }
                HStack {
                    Text("آخر تحديث ناجح").foregroundStyle(.secondary)
                    Spacer()
                    if library.loading { ProgressView() }
                    else { Text(library.lastSuccess.map(LastUpdate.text) ?? "لم يتم بعد").foregroundStyle(.secondary) }
                }.font(.footnote)
            }
        }
        .navigationTitle("المصادر").navigationBarTitleDisplayMode(.inline)
    }
}

/// Groups: the existing section (manager, lock now), with its own push to the manager.
struct GroupsPage: View {
    @State private var open = false
    var body: some View {
        List { GroupsSettingsSection(open: $open) }
            .navigationTitle("المجموعات").navigationBarTitleDisplayMode(.inline)
            .navigationDestination(isPresented: $open) { GroupsManagerView() }
    }
}

struct DiagnosticsPage: View {
    var body: some View {
        List {
            Section {
                NavigationLink { PerfView() } label: { Label("قياسات الأداء", systemImage: "speedometer") }
            } footer: {
                Text("تسجّل مدة فتح التطبيق وتحميل المكتبة والبحث وفتح المسلسل والرجوع من المشغّل، بدون أي روابط أو بيانات دخول.")
            }
            Section("حول التطبيق") {
                Text("يشغّل قوائمك الخاصة فقط. المشغّل مبني على mpv وFFmpeg (رخصة LGPL).").font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("التشخيص والأداء").navigationBarTitleDisplayMode(.inline)
    }
}

/// 1.0.2: the measurements report, to copy and send.
struct PerfView: View {
    @EnvironmentObject var library: Library
    @AppStorage(ImagePipeline.key) private var downsample = true
    @State private var text = ""
    @State private var copied = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Button { UIPasteboard.general.string = text; copied = true } label: { Label(copied ? "تم النسخ" : "نسخ", systemImage: "doc.on.doc") }
                        .buttonStyle(.borderedProminent)
                    Button { text = Perf.shared.report(library: library.sizeText) } label: { Label("تحديث", systemImage: "arrow.clockwise") }
                        .buttonStyle(.bordered)
                    Button(role: .destructive) { Perf.shared.clear(); text = Perf.shared.report(library: library.sizeText) } label: { Label("مسح", systemImage: "trash") }
                        .buttonStyle(.bordered)
                }
                Toggle("صور بحجم العرض (للمقارنة أطفئه)", isOn: $downsample)
                    .font(.footnote)
                    .onChange(of: downsample) { v in Perf.shared.add("تبديل الصور", ms: 0, v ? "بحجم العرض" : "أصلية") }
                Text("للقياس: افتح التطبيق من جديد، انتظر المكتبة، ابحث في الرئيسية والأفلام، افتح مسلسلًا، شغّل حلقة وارجع، ثم اضغط «تحديث» و«نسخ».")
                    .font(.footnote).foregroundStyle(.secondary)
                Text(text).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
            }
            .padding()
        }
        .navigationTitle("قياسات الأداء")
        .onAppear { text = Perf.shared.report(library: library.sizeText); copied = false }
    }
}

/// 1.1.0: poster size in the Movies / Series grids.
enum GridSize: String, CaseIterable {
    case normal, large
    static let key = "grid.size"
    var minWidth: CGFloat { self == .large ? 150 : 108 }
    var label: String { self == .large ? "كبيرة" : "عادية" }
}

struct AppearanceSection: View {
    @AppStorage(GridSize.key) private var grid: GridSize = .normal
    var body: some View {
        Section("المظهر") {
            Picker("حجم البوسترات", selection: $grid) { ForEach(GridSize.allCases, id: \.self) { Text($0.label).tag($0) } }
        }
    }
}

/// 1.1.0: what the app keeps on this phone, with sizes, and how to clear each part.
struct StorageSection: View {
    @EnvironmentObject var library: Library
    @State private var imageMB = 0.0
    @State private var libraryMB = 0.0
    @State private var tmdbMB = 0.0
    @State private var confirmLibrary = false
    @State private var done: String?

    var body: some View {
        Section {
            row("المكتبة المحفوظة (القائمة الحالية)", libraryMB)
            row("الصور المؤقتة", imageMB)
            row("مطابقات TMDB", tmdbMB)
            Button { URLCache.shared.removeAllCachedResponses(); ImagePipeline.shared.clearMemory(); measure(); done = "تم مسح الصور المؤقتة" } label: { Label("مسح الصور المؤقتة", systemImage: "photo.on.rectangle") }
            Button(role: .destructive) { confirmLibrary = true } label: { Label("حذف المكتبة المحفوظة للقائمة الحالية", systemImage: "trash") }
            if let done { Text(done).font(.footnote).foregroundStyle(Theme.teal) }
        } header: { Text("التخزين") } footer: {
            Text("الاستكمال والمفضلة وترتيب المجموعات لا تتأثر بهذا المسح.")
        }
        .onAppear { measure() }
        .confirmationDialog("حذف المكتبة المحفوظة؟", isPresented: $confirmLibrary, titleVisibility: .visible) {
            Button("حذف", role: .destructive) {
                if let s = library.active { LibraryCache.remove(s.id) }
                measure(); done = "تم الحذف — ستُنزَّل المكتبة من المزوّد عند الفتح القادم"
            }
        } message: { Text("المعروض الآن يبقى حتى إغلاق التطبيق.") }
    }

    private func row(_ t: String, _ mb: Double) -> some View {
        HStack { Text(t); Spacer(); Text(String(format: "%.1f MB", mb)).foregroundStyle(.secondary).monospacedDigit() }
    }

    private func measure() {
        imageMB = Double(URLCache.shared.currentDiskUsage) / 1_048_576
        let fm = FileManager.default
        func size(_ u: URL?) -> Double { (u.flatMap { try? fm.attributesOfItem(atPath: $0.path)[.size] as? NSNumber })?.doubleValue ?? 0 }
        libraryMB = library.active.map { size(LibraryCache.file(LibraryCache.key(for: $0))) / 1_048_576 } ?? 0
        tmdbMB = size(fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?.appendingPathComponent("tmdb-matches.json")) / 1_048_576
    }
}

/// 1.6.0: order and visibility of Home rows; discovery rows limited to the library if wanted.
struct HomeRowsSection: View {
    @State private var order = HomeRowsPrefs.order()
    @State private var hidden = HomeRowsPrefs.hidden()
    @AppStorage("tmdb.onlyLibrary") private var onlyLibrary = false
    var body: some View {
        Section {
            ForEach(order) { r in
                Toggle(r.title, isOn: Binding(get: { !hidden.contains(r) }, set: { on in
                    if on { hidden.remove(r) } else { hidden.insert(r) }
                    HomeRowsPrefs.save(order: order, hidden: hidden)
                }))
            }
            .onMove { from, to in order.move(fromOffsets: from, toOffset: to); HomeRowsPrefs.save(order: order, hidden: hidden) }
            Toggle("الاكتشاف: أعمال مكتبتي فقط", isOn: $onlyLibrary)
        } header: { Text("صفوف الرئيسية") } footer: {
            Text("«متابعة المشاهدة» تبقى أولًا دائمًا. اضغط مطولًا على صف واسحبه لتغيير الترتيب.")
        }
    }
}
