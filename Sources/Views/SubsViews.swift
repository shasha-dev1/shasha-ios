import SwiftUI

/// Search OpenSubtitles for the title playing now; tap a result to load it into the player.
struct SubSearchSheet: View {
    @State var query: SubQuery
    let onLoaded: (URL, SubResult) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var results: [SubResult] = []
    @State private var loading = false
    @State private var error: String?
    @State private var busyId: Int?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    TextField("اسم العمل", text: $query.name).autocorrectionDisabled().onSubmit { Task { await search() } }
                    if query.season != nil {
                        Stepper("الموسم \(query.season ?? 1)", value: Binding(get: { query.season ?? 1 }, set: { query.season = $0 }), in: 1...60)
                        Stepper("الحلقة \(query.episode ?? 1)", value: Binding(get: { query.episode ?? 1 }, set: { query.episode = $0 }), in: 1...500)
                    }
                    Button { Task { await search() } } label: { Label("بحث", systemImage: "magnifyingglass") }
                }
                if loading { HStack { Spacer(); ProgressView(); Spacer() } }
                if let error { Text(error).foregroundStyle(.red) }
                if !loading && error == nil && results.isEmpty { Text("لا توجد نتائج — جرّب كتابة الاسم بالإنجليزي كما في الفيلم الأصلي.").foregroundStyle(.secondary) }
                ForEach(groups) { g in
                    Section(g.id == "ar" ? "عربي" : g.id == "en" ? "إنجليزي" : g.id) {
                        ForEach(g.items) { r in
                            Button { Task { await pick(r) } } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(r.release.isEmpty ? "ترجمة" : r.release).lineLimit(2).foregroundStyle(.primary)
                                        Text("تنزيلات: \(r.downloads)").font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    if busyId == r.id { ProgressView() }
                                }
                            }
                            .disabled(busyId != nil)
                        }
                    }
                }
            }
            .navigationTitle("ترجمة من الإنترنت").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("إغلاق") { dismiss() } } }
            .task { await search() }
        }
        .environment(\.layoutDirection, .rightToLeft)
    }

    private struct LangGroup: Identifiable { let id: String; let items: [SubResult] }

    private var groups: [LangGroup] {
        var order: [String] = []
        var map: [String: [SubResult]] = [:]
        for r in results { if map[r.language] == nil { order.append(r.language) }; map[r.language, default: []].append(r) }
        return order.map { LangGroup(id: $0, items: map[$0] ?? []) }
    }

    private func search() async {
        guard OnlineSubs.hasKey else { error = OnlineSubs.Failure.noKey.errorDescription; return }
        loading = true; error = nil
        defer { loading = false }
        do { results = try await OnlineSubs.search(query) } catch { self.error = error.localizedDescription; results = [] }
    }

    private func pick(_ r: SubResult) async {
        busyId = r.id
        defer { busyId = nil }
        do { onLoaded(try await OnlineSubs.download(r), r); dismiss() } catch { self.error = error.localizedDescription }
    }
}

/// Settings rows for the viewer's own OpenSubtitles key and optional account (Keychain only).
struct SubsSettingsSection: View {
    @State private var key = ""
    @State private var user = ""
    @State private var pass = ""
    @State private var saved = false

    var body: some View {
        Section {
            SecureField("مفتاح API", text: $key).textInputAutocapitalization(.never).autocorrectionDisabled()
            TextField("اسم المستخدم (اختياري)", text: $user).textInputAutocapitalization(.never).autocorrectionDisabled()
            SecureField("كلمة المرور (اختياري)", text: $pass)
            Button {
                Keychain.set(key.trimmingCharacters(in: .whitespaces).nilIfEmpty, for: OnlineSubs.keyAPI)
                Keychain.set(user.trimmingCharacters(in: .whitespaces).nilIfEmpty, for: OnlineSubs.keyUser)
                Keychain.set(pass.nilIfEmpty, for: OnlineSubs.keyPass)
                OnlineSubs.resetLogin()
                saved = true
            } label: { Label(saved ? "تم الحفظ" : "حفظ", systemImage: saved ? "checkmark.circle.fill" : "square.and.arrow.down") }
        } header: {
            Text("الترجمة من الإنترنت (OpenSubtitles)")
        } footer: {
            Text("المفتاح من opensubtitles.com ← حسابك ← API Consumers. الحساب يرفع حد التنزيل اليومي. يُحفظ في سلسلة المفاتيح على هذا الجهاز فقط.")
        }
        .onAppear {
            key = Keychain.get(OnlineSubs.keyAPI) ?? ""
            user = Keychain.get(OnlineSubs.keyUser) ?? ""
            pass = Keychain.get(OnlineSubs.keyPass) ?? ""
        }
        .onChange(of: key) { _ in saved = false }
        .onChange(of: user) { _ in saved = false }
        .onChange(of: pass) { _ in saved = false }
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
