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
                Section("قوائم التشغيل") {
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
                }
                GroupsSettingsSection(open: $groupsOpen)
                LanguageSettingsSection()
                SubsSettingsSection()
                Section {
                    NavigationLink { PerfView() } label: { Label("قياسات الأداء", systemImage: "speedometer") }
                } header: { Text("الأداء") } footer: {
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
