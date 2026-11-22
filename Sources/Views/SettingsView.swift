import SwiftUI

struct SettingsView: View {
    /// Credit line injected at build time (SHASHA_CREDIT secret), so it is not stored in the public source.
    private var credit: String {
        let c = (Bundle.main.object(forInfoDictionaryKey: "ShashaCredit") as? String ?? "").trimmingCharacters(in: .whitespaces)
        return c.isEmpty || c.hasPrefix("$(") ? "شاشة" : c
    }
    @EnvironmentObject var library: Library
    @State private var adding = false
    @State private var groupsOpen = false

    var body: some View {
        NavigationStack {
            List {
                Section("المصادر") {
                    ForEach(library.sources) { s in
                        Button { library.select(s) } label: {
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(s.name).foregroundStyle(.primary)
                                    Text(s.kind == .xtream ? "Xtream · \(URL(string: s.server)?.host ?? "")" : "M3U").font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if s.id == library.active?.id { Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.teal) }
                            }
                        }
                        .swipeActions { Button(role: .destructive) { library.remove(s) } label: { Label("حذف", systemImage: "trash") } }
                    }
                    Button { adding = true } label: { Label("إضافة قائمة", systemImage: "plus") }
                    Button { Task { await library.reload() } } label: { Label("تحديث القائمة الآن", systemImage: "arrow.clockwise") }
                    HStack {
                        Text("آخر تحديث ناجح").foregroundStyle(.secondary)
                        Spacer()
                        if library.loading { ProgressView() }
                        else { Text(library.lastSuccess.map(LastUpdate.text) ?? "لم يتم بعد").foregroundStyle(.secondary) }
                    }.font(.footnote)
                }
                GroupsSettingsSection(open: $groupsOpen)
                LanguageSettingsSection()
                SubsSettingsSection()
                TmdbSettingsSection()
                CloudSyncSection()
                TraktSettingsSection()
                AppearanceSection()
                StorageSection()
                Section {
                    NavigationLink { PerfView() } label: { Label("قياسات الأداء", systemImage: "speedometer") }
                } header: { Text("التشخيص") } footer: {
                    Text("تسجّل مدة فتح التطبيق وتحميل المكتبة والبحث وفتح المسلسل والرجوع من المشغّل، بدون أي روابط أو بيانات دخول.")
                }
                Section("حول التطبيق") {
                    HStack { Text("الإصدار"); Spacer(); Text((Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "") + " (" + (Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "") + ")") }
                    Text(credit).foregroundStyle(Theme.accent).bold()
                    Text("يشغّل قوائمك الخاصة فقط. المشغّل مبني على mpv وFFmpeg (رخصة LGPL).").font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("الإعدادات")
            .navigationDestination(isPresented: $groupsOpen) { GroupsManagerView() }
            .sheet(isPresented: $adding) { NavigationStack { SetupView() } }
        }
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
