import SwiftUI

/// 1.0.9: Settings → TMDB key. The status shown is the result of a real call (never "saved" = "working").
struct TmdbSettingsSection: View {
    @AppStorage(MachineTranslate.key) private var translate = true
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
            Toggle("ترجمة الوصف للعربية آليًا (على الجهاز، iOS 18 فأحدث)", isOn: $translate)
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
    /// After a manual correction.
    func reload(_ kind: TmdbTitle.Kind, name: String, providerId: String? = nil) async {
        started = false; title = nil; failed = nil
        await load(kind, name: name, providerId: providerId)
    }
}

/// 1.7.0: "Correct the TMDB match" — search, pick and pin a title, choose "no match", or go back to automatic.
/// Pinned per work (kind + cleaned title + year), so all provider copies of the title use it; a cache refresh
/// keeps it. Only titles of the same kind are offered (a film is never matched to a series).
struct TmdbFixSheet: View {
    let kind: TmdbTitle.Kind
    let providerName: String
    let onDone: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var results: [TmdbTitle] = []
    @State private var error: String?
    @State private var busy = false
    @State private var current: Int?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text(providerName).font(.footnote).foregroundStyle(.secondary)
                    if let c = current { Text(c == 0 ? "التصحيح الحالي: بدون مطابقة" : "التصحيح الحالي: TMDB #\(c)").font(.footnote) }
                }
                Section("نتائج البحث") {
                    if busy { ProgressView() }
                    if let error { Text(error).font(.footnote).foregroundStyle(.red) }
                    ForEach(results) { t in
                        Button { Task { await Tmdb.shared.setOverride(kind, providerName: providerName, id: t.tmdbId); onDone(); dismiss() } } label: {
                            HStack(spacing: 10) {
                                PosterImage(url: t.poster, title: t.name).frame(width: 44, height: 66).clipShape(RoundedRectangle(cornerRadius: 6))
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(t.name).foregroundStyle(.primary)
                                    Text([t.year.map(String.init), t.originalName != t.name ? t.originalName : nil].compactMap { $0 }.joined(separator: " · "))
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
                Section {
                    Button("بدون مطابقة (استخدم بيانات المزوّد فقط)") {
                        Task { await Tmdb.shared.setOverride(kind, providerName: providerName, id: 0); onDone(); dismiss() }
                    }
                    if current != nil {
                        Button("إلغاء التصحيح والرجوع للمطابقة التلقائية", role: .destructive) {
                            Task { await Tmdb.shared.setOverride(kind, providerName: providerName, id: nil); onDone(); dismiss() }
                        }
                    }
                }
            }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: kind == .movie ? "ابحث عن الفيلم" : "ابحث عن المسلسل")
            .onSubmit(of: .search) { Task { await run() } }
            .navigationTitle("تصحيح مطابقة TMDB").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("إغلاق") { dismiss() } } }
            .task {
                current = await Tmdb.shared.override(kind, providerName: providerName)
                if query.isEmpty { query = TmdbRule.split(providerName).title; await run() }
            }
        }
    }

    private func run() async {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return }
        busy = true; defer { busy = false }
        do { results = try await Tmdb.shared.search(q, kind); error = results.isEmpty ? "لا نتائج" : nil }
        catch { self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription }
    }
}

/// Overview that opens to its full length.
// ExpandableText moved to MachineTranslate.swift (1.4.1: Arabic machine translation).

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
            async let nm = Tmdb.shared.list(.newTop, .movie)
            async let nt = Tmdb.shared.list(.newTop, .tv)
            let (a, b, c, d) = try await (tm, tt, pm, pt)
            let (e, f) = try await (nm, nt)
            let l = await library.lookup()
            func items(_ x: [TmdbTitle]) -> [Item] { x.map { Item(title: $0, hit: library.hit($0, l)) } }
            // Available first, the rest after, each keeping TMDB's order.
            func ordered(_ x: [Item]) -> [Item] { x.filter { $0.hit != nil } + x.filter { $0.hit == nil } }
            // New and highly rated: only what is in the library (the owner's request).
            func available(_ x: [TmdbTitle]) -> [Item] { items(x).filter { $0.hit != nil } }
            let only = UserDefaults.standard.bool(forKey: "tmdb.onlyLibrary")
            func pick(_ x: [TmdbTitle]) -> [Item] { only ? available(x) : ordered(items(x)) }
            let raw = [Row(id: "nm", name: "أفلام جديدة تقييمها عالي", items: available(e)),
                       Row(id: "nt", name: "مسلسلات جديدة تقييمها عالي", items: available(f)),
                       Row(id: "tm", name: "أفلام رائجة هذا الأسبوع", items: pick(a)),
                       Row(id: "tt", name: "مسلسلات رائجة هذا الأسبوع", items: pick(b)),
                       Row(id: "pm", name: "الأفلام الأشهر", items: pick(c)),
                       Row(id: "pt", name: "المسلسلات الأشهر", items: pick(d))]
            // 1.6.0: a title shown in an earlier row isn't repeated in a later one.
            var shown = Set<String>()
            rows = raw.map { r in Row(id: r.id, name: r.name, items: r.items.filter { shown.insert($0.id).inserted }) }.filter { !$0.items.isEmpty }
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
                    // 1.7.0: smaller badge on a near-opaque dark backing, readable over any poster.
                    Badge(text: item.hit != nil ? "في مكتبتك" : "غير متوفر", color: item.hit != nil ? Theme.teal : .white)
                        .font(.caption2)
                        .background(Color.black.opacity(0.85), in: Capsule()).padding(4)
                }
                .opacity(item.hit != nil ? 1 : 0.7)
            Text(item.title.name).font(.caption).lineLimit(2).multilineTextAlignment(.leading)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(item.title.name)، \(item.hit != nil ? "في مكتبتك" : "غير متوفر")")
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

// MARK: - 1.2.0 Trakt settings

struct TraktSettingsSection: View {
    @State private var clientId = ""
    @State private var secret = ""
    @State private var linking = false
    @State private var status: String?
    @State private var linked = TraktKeys.isLinked
    @State private var busy = false

    var body: some View {
        Section {
            if linked {
                Label("مربوط: \(TraktKeys.username ?? "حساب Trakt")", systemImage: "checkmark.seal.fill").foregroundStyle(Theme.teal)
                Button { Task { busy = true; status = await TraktSync.pull(force: true); busy = false } } label: {
                    HStack { Label("مزامنة الآن", systemImage: "arrow.triangle.2.circlepath"); Spacer(); if busy { ProgressView() } }
                }
                if let t = TraktStore.pulledAt { Text("آخر مزامنة: \(LastUpdate.text(t)) · \(TraktStore.pauses.count) نقطة توقف").font(.footnote).foregroundStyle(.secondary) }
                NavigationLink { TraktLogView() } label: { Label("سجل Trakt", systemImage: "list.bullet.rectangle") }
                Button(role: .destructive) { Task { await Trakt.shared.disconnect(); linked = false; status = "تم فصل الربط" } } label: { Label("فصل الربط", systemImage: "link.badge.plus") }
            } else {
                TextField("Client ID", text: $clientId).textInputAutocapitalization(.never).autocorrectionDisabled()
                SecureField("Client Secret", text: $secret)
                Button {
                    Keychain.set(clientId.filter { !$0.isWhitespace }.nilIfEmpty, for: TraktKeys.clientId)
                    Keychain.set(secret.filter { !$0.isWhitespace }.nilIfEmpty, for: TraktKeys.secret)
                    if TraktKeys.id == nil { status = "أدخل Client ID" } else { linking = true }
                } label: { Label("ربط الحساب", systemImage: "link") }
            }
            if let status { Text(status).font(.footnote).foregroundStyle(.secondary) }
        } header: { Text("Trakt (مزامنة مع تطبيق التلفاز)") } footer: {
            Text("استخدم نفس تطبيق Trakt (Client ID و Secret) اللي في تطبيق التلفاز، واربط بنفس الحساب. الأفلام والحلقات فقط، لا تُرسل القنوات المباشرة. المفاتيح والرموز تبقى في سلسلة المفاتيح على هذا الجهاز.")
        }
        .onAppear { clientId = TraktKeys.id ?? ""; secret = TraktKeys.clientSecret ?? ""; linked = TraktKeys.isLinked }
        .sheet(isPresented: $linking, onDismiss: { linked = TraktKeys.isLinked; if linked { Task { status = await TraktSync.pull(force: true) } } }) { TraktLinkSheet() }
    }
}

/// Device sign-in: shows the code, opens trakt.tv/activate, polls until approved, denied or expired.
struct TraktLinkSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var code: Trakt.DeviceCode?
    @State private var message = "جارٍ طلب رمز الربط…"
    @State private var done = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 18) {
                if let code {
                    Text("افتح الرابط واكتب هذا الرمز").font(.headline)
                    Text(code.userCode).font(.system(size: 40, weight: .bold, design: .monospaced)).foregroundStyle(Theme.accent)
                        .textSelection(.enabled)
                    HStack {
                        Button { UIPasteboard.general.string = code.userCode } label: { Label("نسخ الرمز", systemImage: "doc.on.doc") }.buttonStyle(.bordered)
                        Button { if let u = URL(string: code.url) { openURL(u) } } label: { Label("فتح trakt.tv/activate", systemImage: "safari") }.buttonStyle(.borderedProminent)
                    }
                }
                Text(message).font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                if done { Button("تم") { dismiss() }.buttonStyle(.borderedProminent) }
            }
            .padding()
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("إغلاق") { dismiss() } } }
        }
        .task { await run() }
    }

    private func run() async {
        do {
            let c = try await Trakt.shared.deviceCode()
            code = c; message = "بانتظار موافقتك في Trakt…"
            var interval = c.interval
            let end = Date().addingTimeInterval(TimeInterval(c.expiresIn))
            while Date() < end && !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(interval) * 1_000_000_000)
                guard !Task.isCancelled else { return }
                switch try await Trakt.shared.poll(c.deviceCode) {
                case .success: message = "تم الربط: \(TraktKeys.username ?? "")"; done = true; return
                case .pending: continue
                case .slowDown: interval += 5
                case .denied: message = "رفضت الربط في Trakt."; done = true; return
                case .expired: message = "انتهت صلاحية الرمز. حاول من جديد."; done = true; return
                case .alreadyUsed: message = "الرمز مستخدم. حاول من جديد."; done = true; return
                case .invalidCode: message = "الرمز غير صالح."; done = true; return
                case .failed(let h): message = "Trakt ردّ \(h)."; done = true; return
                }
            }
            if !done { message = "انتهت المهلة."; done = true }
        } catch {
            message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription; done = true
        }
    }
}

struct TraktLogView: View {
    var body: some View {
        List(TraktLog.lines.reversed(), id: \.self) { Text($0).font(.system(size: 12, design: .monospaced)) }
            .navigationTitle("سجل Trakt")
    }
}

// MARK: - 1.3.0 Sync with the TV app (Google Drive)

struct CloudSyncSection: View {
    @EnvironmentObject var library: Library
    @State private var clientId = ""
    @State private var secret = ""
    @State private var linking = false
    @State private var linked = DriveKeys.isLinked
    @State private var busy = false
    @State private var status: String?
    @State private var guide = false
    @State private var confirmUnlink = false

    var body: some View {
        Section {
            if linked {
                Label("مربوط بحساب Google", systemImage: "checkmark.icloud.fill").foregroundStyle(Theme.teal)
                Button { Task { busy = true; status = await CloudSync.sync(library, force: true); busy = false } } label: {
                    HStack { Label("مزامنة الآن", systemImage: "arrow.triangle.2.circlepath"); Spacer(); if busy { ProgressView() } }
                }
                Text("آخر مزامنة ناجحة: " + (CloudSync.lastSuccess.map(LastUpdate.text) ?? "لم تتم بعد"))
                    .font(.footnote).foregroundStyle(CloudSync.lastSuccess == nil ? Color.orange : Color.secondary)
                let pending = CloudSync.pendingCount(library)
                if pending > 0 { Text("بانتظار الإرسال: \(pending)").font(.footnote).foregroundStyle(.secondary) }
                if let n = CloudSync.nextAutoTry, n > Date() {
                    Text("المحاولة التلقائية التالية: \(LastUpdate.text(n))").font(.footnote).foregroundStyle(.secondary)
                }
                Button(role: .destructive) { confirmUnlink = true } label: { Label("فصل الربط", systemImage: "xmark.icloud") }
                    .confirmationDialog("فصل حساب Google؟", isPresented: $confirmUnlink, titleVisibility: .visible) {
                        Button("فصل الربط", role: .destructive) { Task { await GoogleDrive.shared.disconnect(); linked = false; status = "تم فصل الربط" } }
                    } message: { Text("يتوقف هذا الجهاز عن المزامنة. ملف المزامنة في Drive وبياناتك على الجهاز يبقيان كما هما.") }
            } else {
                TextField("Client ID (Google)", text: $clientId).textInputAutocapitalization(.never).autocorrectionDisabled()
                SecureField("Client Secret", text: $secret)
                Button {
                    Keychain.set(clientId.filter { !$0.isWhitespace }.nilIfEmpty, for: DriveKeys.clientId)
                    Keychain.set(secret.filter { !$0.isWhitespace }.nilIfEmpty, for: DriveKeys.secret)
                    if DriveKeys.id == nil || DriveKeys.clientSecret == nil { status = "أدخل Client ID و Client Secret" } else { linking = true }
                } label: { Label("ربط حساب Google", systemImage: "link") }
                Button { guide = true } label: { Label("طريقة إنشاء Client ID", systemImage: "questionmark.circle") }
            }
            if let s = status ?? CloudSync.lastResult {
                Text(s).font(.footnote).foregroundStyle(s.hasPrefix("تعذّرت") ? Color.red : Color.secondary)
            }
        } header: { Text("المزامنة مع تطبيق التلفاز") } footer: {
            Text("يحفظ نقاط التوقف في ملف واحد (shasha-sync-v1.json) في Google Drive حقك؛ التطبيق يشوف الملفات اللي أنشأها فقط. لا تحذف الملف. استخدم نفس Client ID في التلفاز والجوال ونفس حساب Google، ونفس اشتراك Xtream. المفاتيح تبقى في سلسلة المفاتيح على هذا الجهاز.")
        }
        .onAppear { clientId = DriveKeys.id ?? ""; secret = DriveKeys.clientSecret ?? ""; linked = DriveKeys.isLinked }
        .sheet(isPresented: $linking, onDismiss: {
            linked = DriveKeys.isLinked
            if linked { Task { status = await CloudSync.sync(library, force: true) } }
        }) { DriveLinkSheet() }
        .sheet(isPresented: $guide) { DriveGuideSheet() }
    }
}

struct DriveLinkSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var phase
    @State private var code: GoogleDrive.DeviceCode?
    @State private var message = "جارٍ طلب رمز الربط…"
    @State private var done = false
    @State private var checking = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 18) {
                if let code {
                    Text("افتح الرابط واكتب هذا الرمز").font(.headline)
                    Text(code.userCode).font(.system(size: 36, weight: .bold, design: .monospaced)).foregroundStyle(Theme.accent).textSelection(.enabled)
                    HStack {
                        Button { UIPasteboard.general.string = code.userCode } label: { Label("نسخ الرمز", systemImage: "doc.on.doc") }.buttonStyle(.bordered)
                        Button { if let u = URL(string: code.url) { openURL(u) } } label: { Label("فتح google.com/device", systemImage: "safari") }.buttonStyle(.borderedProminent)
                    }
                    if !done {
                        Button { Task { await check() } } label: { Label("وافقت؟ تحقق الآن", systemImage: "arrow.clockwise") }
                            .disabled(checking)
                    }
                }
                Text(message).font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                if done { Button("تم") { dismiss() }.buttonStyle(.borderedProminent) }
            }
            .padding()
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("إغلاق") { dismiss() } } }
        }
        .task { await run() }
        // 1.4.5: back from Safari → ask Google at once (the timer loop may have been paused in the background).
        .onChange(of: phase) { p in if p == .active { Task { await check() } } }
    }

    private func run() async {
        do {
            // 1.4.6: the sheet can be rebuilt when the app goes to the background (owner: "the code changes every
            // time I leave the app"). Keep the pending code outside the view and reuse it until it expires, so the
            // code typed in the browser is still the one this sheet waits for.
            let c: GoogleDrive.DeviceCode
            if let p = PendingDriveCode.code, Date() < PendingDriveCode.until { c = p }
            else {
                c = try await GoogleDrive.shared.deviceCode()
                PendingDriveCode.code = c
                PendingDriveCode.until = Date().addingTimeInterval(TimeInterval(c.expiresIn - 30))
            }
            code = c; message = "بانتظار موافقتك في Google…"
            var interval = c.interval
            let end = Date().addingTimeInterval(TimeInterval(c.expiresIn))
            while Date() < end && !Task.isCancelled && !done {
                try? await Task.sleep(nanoseconds: UInt64(interval) * 1_000_000_000)
                guard !Task.isCancelled, !done else { return }
                if await check() == .slowDown { interval += 5 }
            }
            if !done { message = "انتهت المهلة. اضغط ربط من جديد."; done = true }
        } catch { message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription; done = true }
    }

    /// One question to Google. A network error (common right after returning from Safari) is not the end:
    /// the next round asks again.
    @discardableResult
    private func check() async -> GoogleDrive.Poll? {
        guard let c = code, !done, !checking else { return nil }
        checking = true; defer { checking = false }
        do {
            let r = try await GoogleDrive.shared.poll(c.deviceCode)
            switch r {
            case .success: message = "تم الربط ✓"; done = true; PendingDriveCode.code = nil
                NotificationCenter.default.post(name: .cloudSyncApplied, object: nil)
            case .pending: message = "بانتظار موافقتك في Google…"
            case .slowDown: break
            case .denied: message = "رفضت الربط في Google."; done = true; PendingDriveCode.code = nil
            case .expired: message = "انتهت صلاحية الرمز. اضغط ربط من جديد."; done = true; PendingDriveCode.code = nil
            case .failed(let e) where e.hasPrefix("invalid_grant"):
                // Google: "has already been claimed" — an earlier check (another copy of this sheet, or the run
                // loop) already received the tokens. If they are here, the link worked.
                PendingDriveCode.code = nil
                if DriveKeys.isLinked {
                    message = "تم الربط ✓"; done = true
                    NotificationCenter.default.post(name: .cloudSyncApplied, object: nil)
                } else {
                    message = "انتهى هذا الرمز. أغلق النافذة واضغط ربط لرمز جديد."; done = true
                }
            case .failed(let e): message = "Google ردّ: \(e)"; done = true; PendingDriveCode.code = nil
            }
            return r
        } catch {
            message = "تعذّر الاتصال بـGoogle، سأحاول مرة أخرى…"
            return nil
        }
    }
}

/// The device code being waited for, kept across rebuilds of the link sheet — and across the app being closed by
/// iOS while the viewer is in the browser (big library = big memory). Kept in the Keychain until it expires.
@MainActor enum PendingDriveCode {
    private static let k = "gdrive.pendingCode"
    static var code: GoogleDrive.DeviceCode? {
        get {
            guard let s = Keychain.get(k), let d = s.data(using: .utf8),
                  let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                  let dc = o["dc"] as? String, let uc = o["uc"] as? String else { return nil }
            return GoogleDrive.DeviceCode(deviceCode: dc, userCode: uc, url: o["url"] as? String ?? "https://www.google.com/device",
                                          expiresIn: o["exp"] as? Int ?? 1800, interval: o["int"] as? Int ?? 5)
        }
        set {
            guard let c = newValue else { Keychain.set(nil, for: k); return }
            let o: [String: Any] = ["dc": c.deviceCode, "uc": c.userCode, "url": c.url, "exp": c.expiresIn, "int": c.interval]
            if let d = try? JSONSerialization.data(withJSONObject: o), let s = String(data: d, encoding: .utf8) { Keychain.set(s, for: k) }
        }
    }
    static var until: Date {
        get { Date(timeIntervalSince1970: UserDefaults.standard.double(forKey: "gdrive.pendingUntil")) }
        set { UserDefaults.standard.set(newValue.timeIntervalSince1970, forKey: "gdrive.pendingUntil") }
    }
}

struct DriveGuideSheet: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text("مرة وحدة، من الكمبيوتر أو الجوال:").font(.headline)
                    Group {
                        Text("1. افتح console.cloud.google.com وسوّ مشروع جديد (مثلًا Shasha).")
                        Text("2. APIs & Services ← Library ← فعّل Google Drive API.")
                        Text("3. OAuth consent screen (Google Auth Platform): نوع External، اسم التطبيق، بريدك. في Data Access أضف النطاق ‎.../auth/drive.file فقط.")
                        Text("4. في Audience اضغط Publish app (In production). لو تركته Testing ينتهي الربط كل 7 أيام.")
                        Text("5. Clients ← Create client ← النوع: TVs and Limited Input devices. انسخ Client ID و Client Secret.")
                        Text("6. حطهم هنا وفي تطبيق التلفاز، واربط بنفس حساب Google في الجهازين.")
                    }.font(.subheadline)
                    Text("Google قد يعرض «التطبيق لم يتم التحقق منه» لأنك صاحب المشروع: اضغط Advanced ← Continue.").font(.footnote).foregroundStyle(.secondary)
                }.padding()
            }
            .navigationTitle("إعداد Google Drive")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("إغلاق") { dismiss() } } }
        }
    }
}
