import SwiftUI

/// 1.0.9: Settings → TMDB key. The status shown is the result of a real call (never "saved" = "working").
struct TmdbSettingsSection: View {
    @State private var key = ""
    @State private var status: String?
    @State private var ok = false
    @State private var busy = false

    var body: some View {
        Section {
            SecureField("مفتاح API (v3) أو رمز القراءة (v4)", text: $key).textInputAutocapitalization(.never).autocorrectionDisabled()
            HStack {
                Button {
                    Task { await saveAndTest() }
                } label: { Label("حفظ واختبار", systemImage: "checkmark.shield") }
                .disabled(busy)
                Spacer()
                if busy { ProgressView() }
            }
            if let status {
                Label(status, systemImage: ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .font(.footnote).foregroundStyle(ok ? Theme.teal : .orange)
            }
            if TmdbKey.value != nil {
                Button(role: .destructive) { TmdbKey.set(nil); key = ""; status = "تم حذف المفتاح"; ok = false } label: { Label("حذف المفتاح", systemImage: "trash") }
                Button { Task { await Tmdb.shared.clearCache(); status = "تم مسح مطابقات TMDB المحفوظة"; ok = true } } label: { Label("إعادة المطابقة من جديد", systemImage: "arrow.clockwise") }
            }
        } header: { Text("TMDB (الخلفيات والملخصات والترند)") } footer: {
            Text("المفتاح من themoviedb.org ← الإعدادات ← API. يُحفظ في سلسلة المفاتيح على هذا الجهاز فقط. المحفوظ الآن: \(TmdbKey.mask(TmdbKey.value)).\nThis product uses the TMDB API but is not endorsed or certified by TMDB.")
        }
        .onAppear { key = TmdbKey.value ?? "" }
    }

    private func saveAndTest() async {
        let k = key.filter { !$0.isWhitespace }
        guard TmdbKey.looksValid(k) else { status = "شكل المفتاح غير معروف: 32 حرفًا (v3) أو رمز يبدأ بـ eyJ (v4)"; ok = false; return }
        busy = true; defer { busy = false }
        let old = TmdbKey.value
        TmdbKey.set(k)
        do { try await Tmdb.shared.testKey(); status = "المفتاح يعمل"; ok = true }
        catch {
            status = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription; ok = false
            if case TmdbError.badKey = error { TmdbKey.set(old) }       // keep the last working key
        }
    }
}

/// TMDB text and pictures for one library title, loaded once per screen.
@MainActor
final class TmdbLoader: ObservableObject {
    @Published var title: TmdbTitle?
    @Published var failed: String?
    private var started = false

    func load(_ kind: TmdbTitle.Kind, name: String, providerId: String? = nil) async {
        guard !started, TmdbKey.value != nil else { return }
        started = true
        do { title = try await Tmdb.shared.match(kind: kind, providerName: name, providerId: providerId) }
        catch { failed = (error as? LocalizedError)?.errorDescription }
    }
}

/// Overview that opens to its full length.
struct ExpandableText: View {
    let text: String
    var lines = 4
    @State private var open = false
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(text).font(.subheadline).lineLimit(open ? nil : lines).fixedSize(horizontal: false, vertical: true)
            Button(open ? "أقل" : "المزيد") { withAnimation(.easeInOut(duration: 0.2)) { open.toggle() } }
                .font(.footnote.weight(.semibold)).foregroundStyle(Theme.accent)
        }
    }
}

/// 1.0.9: TMDB rows on Home. Every card says whether the title is in the viewer's library; only titles that are
/// there open a page with a play button. The others open an information sheet (no play button).
@MainActor
final class TmdbRows: ObservableObject {
    struct Item: Identifiable { let title: TmdbTitle; let hit: Library.Hit?; var id: String { title.id } }
    struct Row: Identifiable { let id: String; let name: String; let items: [Item] }
    @Published var rows: [Row] = []
    @Published var error: String?
    @Published var loading = false
    private var loadedFor = -1

    func load(_ library: Library) async {
        guard TmdbKey.value != nil, library.hasData, loadedFor != library.version else { return }
        loading = true; defer { loading = false }
        do {
            async let tm = Tmdb.shared.list(.trending, .movie)
            async let tt = Tmdb.shared.list(.trending, .tv)
            async let pm = Tmdb.shared.list(.popular, .movie)
            async let pt = Tmdb.shared.list(.popular, .tv)
            let (a, b, c, d) = try await (tm, tt, pm, pt)
            let l = await library.lookup()
            func items(_ x: [TmdbTitle]) -> [Item] { x.map { Item(title: $0, hit: library.hit($0, l)) } }
            // Available first, the rest after, each keeping TMDB's order.
            func ordered(_ x: [Item]) -> [Item] { x.filter { $0.hit != nil } + x.filter { $0.hit == nil } }
            rows = [Row(id: "tm", name: "أفلام رائجة هذا الأسبوع", items: ordered(items(a))),
                    Row(id: "tt", name: "مسلسلات رائجة هذا الأسبوع", items: ordered(items(b))),
                    Row(id: "pm", name: "الأفلام الأشهر", items: ordered(items(c))),
                    Row(id: "pt", name: "المسلسلات الأشهر", items: ordered(items(d)))].filter { !$0.items.isEmpty }
            error = nil
            loadedFor = library.version
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}

struct TmdbCard: View {
    let item: TmdbRows.Item
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            PosterImage(url: item.title.poster, title: item.title.name)
                .aspectRatio(2 / 3, contentMode: .fit)
                .overlay(alignment: .topLeading) {
                    Badge(text: item.hit != nil ? "في مكتبتك" : "غير متوفر", color: item.hit != nil ? Theme.teal : .gray)
                        .background(Theme.bg.opacity(0.6), in: Capsule()).padding(5)
                }
                .opacity(item.hit != nil ? 1 : 0.7)
            Text(item.title.name).font(.caption).lineLimit(2).multilineTextAlignment(.leading)
        }
    }
}

/// A TMDB title that isn't in the library: information only.
struct TmdbInfoSheet: View {
    let title: TmdbTitle
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    DetailHeader(backdrop: title.backdrop, poster: title.poster, title: title.name,
                                 meta: [title.year.map(String.init), title.rating.flatMap { $0 > 0 ? String(format: "★ %.1f", $0) : nil }].compactMap { $0 }.joined(separator: " · "))
                    Label("غير متوفر في مكتبتك", systemImage: "xmark.circle").font(.headline).foregroundStyle(.secondary).padding(.horizontal)
                    if let o = title.overview { ExpandableText(text: o, lines: 8).padding(.horizontal) }
                    Text("المعلومات من TMDB").font(.caption2).foregroundStyle(.secondary).padding(.horizontal)
                }
                .padding(.bottom, 24)
            }
            .background(Theme.bg)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("إغلاق") { dismiss() } } }
        }
    }
}
