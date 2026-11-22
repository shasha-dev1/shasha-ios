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
            rows = [Row(id: "nm", name: "أفلام جديدة تقييمها عالي", items: available(e)),
                    Row(id: "nt", name: "مسلسلات جديدة تقييمها عالي", items: available(f)),
                    Row(id: "tm", name: "أفلام رائجة هذا الأسبوع", items: ordered(items(a))),
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

    var body: some View {
        Section {
            if linked {
                Label("مربوط بحساب Google", systemImage: "checkmark.icloud.fill").foregroundStyle(Theme.teal)
                Button { Task { busy = true; status = await CloudSync.sync(library, force: true); busy = false } } label: {
                    HStack { Label("مزامنة الآن", systemImage: "arrow.triangle.2.circlepath"); Spacer(); if busy { ProgressView() } }
                }
                if let t = CloudSync.lastSuccess { Text("آخر مزامنة ناجحة: \(LastUpdate.text(t))").font(.footnote).foregroundStyle(.secondary) }
                Button(role: .destructive) { Task { await GoogleDrive.shared.disconnect(); linked = false; status = "تم فصل الربط" } } label: { Label("فصل الربط", systemImage: "xmark.icloud") }
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
            if let s = status ?? CloudSync.lastResult { Text(s).font(.footnote).foregroundStyle(.secondary) }
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
    @State private var code: GoogleDrive.DeviceCode?
    @State private var message = "جارٍ طلب رمز الربط…"
    @State private var done = false

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
            let c = try await GoogleDrive.shared.deviceCode()
            code = c; message = "بانتظار موافقتك في Google…"
            var interval = c.interval
            let end = Date().addingTimeInterval(TimeInterval(c.expiresIn))
            while Date() < end && !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(interval) * 1_000_000_000)
                guard !Task.isCancelled else { return }
                switch try await GoogleDrive.shared.poll(c.deviceCode) {
                case .success: message = "تم الربط"; done = true; return
                case .pending: continue
                case .slowDown: interval += 5
                case .denied: message = "رفضت الربط في Google."; done = true; return
                case .expired: message = "انتهت صلاحية الرمز. حاول من جديد."; done = true; return
                case .failed(let e): message = "Google ردّ: \(e)"; done = true; return
                }
            }
            if !done { message = "انتهت المهلة."; done = true }
        } catch { message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription; done = true }
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
