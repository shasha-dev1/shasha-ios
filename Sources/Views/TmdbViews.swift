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
