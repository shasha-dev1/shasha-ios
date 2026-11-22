import Foundation

/// 1.2.0: Trakt, so the iPhone and the TV app share progress through the viewer's own Trakt account.
/// Same design as the TV app: the viewer's own Client ID / Secret (Settings), device-code sign-in, tokens in the
/// Keychain only (never exported, never logged), scrobbling of films and episodes only (never live TV),
/// and reading the saved pauses (/sync/playback) to continue on this phone what was paused on the TV.
enum TraktKeys {
    static let clientId = "trakt.clientId", secret = "trakt.clientSecret"
    static let access = "trakt.access", refresh = "trakt.refresh", expires = "trakt.expires"
    static var id: String? { Keychain.get(clientId).flatMap { $0.isEmpty ? nil : $0 } }
    static var clientSecret: String? { Keychain.get(secret).flatMap { $0.isEmpty ? nil : $0 } }
    static var accessToken: String? { Keychain.get(access).flatMap { $0.isEmpty ? nil : $0 } }
    static var isLinked: Bool { accessToken != nil }
    static var username: String? {
        get { UserDefaults.standard.string(forKey: "trakt.username") }
        set { UserDefaults.standard.set(newValue, forKey: "trakt.username") }
    }
    static func saveTokens(_ a: String, _ r: String, _ expiresAt: Date) {
        Keychain.set(a, for: access); Keychain.set(r, for: refresh); Keychain.set(String(expiresAt.timeIntervalSince1970), for: expires)
    }
    static func clearTokens() {
        Keychain.set(nil, for: access); Keychain.set(nil, for: refresh); Keychain.set(nil, for: expires); username = nil
    }
}

/// Recent Trakt results for the diagnostics (action, title, progress, HTTP status) — never a token.
enum TraktLog {
    private static let key = "trakt.log"
    static var lines: [String] { UserDefaults.standard.stringArray(forKey: key) ?? [] }
    static func add(_ s: String) {
        let f = DateFormatter(); f.dateFormat = "MM-dd HH:mm:ss"; f.locale = Locale(identifier: "en_US_POSIX")
        var l = lines; l.append(f.string(from: Date()) + " " + s)
        UserDefaults.standard.set(Array(l.suffix(40)), forKey: key)
    }
}

/// A pause saved at Trakt (by this phone or another device).
struct TraktPause: Codable, Equatable {
    let kind: String          // "movie" | "episode"
    let title: String         // movie title or show title
    let year: Int?
    let tmdb: Int?            // movie or show TMDB id
    let season: Int?
    let number: Int?
    let progress: Double      // 0–100
    let pausedAt: Date
}

enum TraktError: LocalizedError {
    case notConfigured, http(Int), network(String)
    var errorDescription: String? {
        switch self {
        case .notConfigured: return "أضف Client ID من الإعدادات أولًا."
        case .http(let c): return "Trakt ردّ \(c)."
        case .network(let m): return "تعذّر الاتصال بـ Trakt: \(m)"
        }
    }
}

actor Trakt {
    static let shared = Trakt()
    private let api = "https://api.trakt.tv"

    private func request(_ path: String, token: String? = nil, body: Any? = nil, rawBody: Data? = nil) throws -> URLRequest {
        guard let id = TraktKeys.id, let url = URL(string: api + path) else { throw TraktError.notConfigured }
        var r = URLRequest(url: url, timeoutInterval: 20)
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.setValue(id, forHTTPHeaderField: "trakt-api-key")
        r.setValue("2", forHTTPHeaderField: "trakt-api-version")
        if let token { r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let rawBody { r.httpMethod = "POST"; r.httpBody = rawBody }
        else if let body { r.httpMethod = "POST"; r.httpBody = try JSONSerialization.data(withJSONObject: body) }
        return r
    }

    private func send(_ r: URLRequest) async throws -> (Int, Data) {
        do {
            let (d, resp) = try await URLSession.shared.data(for: r)
            return ((resp as? HTTPURLResponse)?.statusCode ?? 0, d)
        } catch { throw TraktError.network(error.localizedDescription) }
    }

    // MARK: Device sign-in

    struct DeviceCode { let deviceCode: String; let userCode: String; let url: String; let expiresIn: Int; let interval: Int }

    func deviceCode() async throws -> DeviceCode {
        let (code, d) = try await send(try request("/oauth/device/code", body: ["client_id": TraktKeys.id ?? ""]))
        guard code == 200, let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let dc = o["device_code"] as? String, let uc = o["user_code"] as? String else { throw TraktError.http(code) }
        return DeviceCode(deviceCode: dc, userCode: uc, url: o["verification_url"] as? String ?? "https://trakt.tv/activate",
                          expiresIn: o["expires_in"] as? Int ?? 600, interval: max(1, o["interval"] as? Int ?? 5))
    }

    func poll(_ deviceCode: String) async throws -> TraktRule.Poll {
        var b: [String: String] = ["code": deviceCode, "client_id": TraktKeys.id ?? ""]
        if let s = TraktKeys.clientSecret { b["client_secret"] = s }
        let (code, d) = try await send(try request("/oauth/device/token", body: b))
        let p = TraktRule.poll(code)
        if p == .success { try saveTokens(d); await fetchUsername() }
        return p
    }

    private func saveTokens(_ d: Data) throws {
        guard let o = try JSONSerialization.jsonObject(with: d) as? [String: Any],
              let a = o["access_token"] as? String, let r = o["refresh_token"] as? String else { throw TraktError.http(200) }
        let created = (o["created_at"] as? Double) ?? Date().timeIntervalSince1970
        let exp = (o["expires_in"] as? Double) ?? 7 * 86400
        TraktKeys.saveTokens(a, r, Date(timeIntervalSince1970: created + exp))
    }

    private func fetchUsername() async {
        guard let t = TraktKeys.accessToken, let r = try? request("/users/settings", token: t),
              let res = try? await send(r), res.0 == 200,
              let o = try? JSONSerialization.jsonObject(with: res.1) as? [String: Any] else { return }
        TraktKeys.username = (o["user"] as? [String: Any])?["username"] as? String
    }

    /// A usable access token, refreshed when it expires within a day (refresh tokens are single-use: stored first).
    func token() async -> String? {
        guard let access = TraktKeys.accessToken else { return nil }
        let exp = Double(Keychain.get(TraktKeys.expires) ?? "") ?? 0
        if exp - Date().timeIntervalSince1970 > 86400 { return access }
        guard let refresh = Keychain.get(TraktKeys.refresh) else { return access }
        var b: [String: String] = ["refresh_token": refresh, "client_id": TraktKeys.id ?? "", "redirect_uri": "urn:ietf:wg:oauth:2.0:oob",
                                   "grant_type": "refresh_token"]
        if let s = TraktKeys.clientSecret { b["client_secret"] = s }
        guard let r = try? request("/oauth/token", body: b), let res = try? await send(r) else { return access }
        let (code, d) = res
        if code == 401 { TraktKeys.clearTokens(); TraktLog.add("تجديد الدخول رُفض — اربط من جديد"); return nil }
        guard code == 200, (try? saveTokens(d)) != nil else { return access }
        return TraktKeys.accessToken
    }

    func disconnect() async {
        if let t = TraktKeys.accessToken {
            var b: [String: String] = ["token": t, "client_id": TraktKeys.id ?? ""]
            if let s = TraktKeys.clientSecret { b["client_secret"] = s }
            if let r = try? request("/oauth/revoke", body: b) { _ = try? await send(r) }
        }
        TraktKeys.clearTokens()
        TraktStore.clear()
    }

    // MARK: Scrobble

    /// Returns the HTTP status (-1 not linked, -2 network). Logged without tokens.
    @discardableResult
    func scrobble(_ action: TraktRule.Action, _ identity: [String: Any], progress: Double, label: String) async -> Int {
        guard let t = await token() else { TraktLog.add("\(action.rawValue) \(label) → غير مربوط"); return -1 }
        guard let body = TraktRule.body(identity, progress: progress), let r = try? request("/scrobble/\(action.rawValue)", token: t, rawBody: body) else { return -1 }
        do {
            let (code, _) = try await send(r)
            let note: String = { switch code {
                case 201: return "تم"
                case 404: return "غير موجود في Trakt (الاسم أو رقم TMDB)"
                case 409: return "مسجّل قبل قليل"
                case 401, 403: return "غير مصرّح — اربط من جديد"
                case 429: return "طلبات كثيرة"
                default: return ""
            } }()
            TraktLog.add(String(format: "%@ %@ %.1f%% → %d %@", action.rawValue, label, progress, code, note))
            return code
        } catch {
            TraktLog.add("\(action.rawValue) \(label) → خطأ شبكة")
            return -2
        }
    }

    // MARK: Pull (other devices)

    /// GET /sync/playback: pauses saved at Trakt (films and episodes), newest first.
    func playback() async throws -> [TraktPause] {
        guard let t = await token() else { return [] }
        let (code, d) = try await send(try request("/sync/playback?limit=50", token: t))
        guard code == 200, let arr = try JSONSerialization.jsonObject(with: d) as? [[String: Any]] else { throw TraktError.http(code) }
        let iso = ISO8601DateFormatter(); iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let iso2 = ISO8601DateFormatter()
        return arr.compactMap { o in
            guard let type = o["type"] as? String, let p = o["progress"] as? Double,
                  let ps = o["paused_at"] as? String, let at = iso.date(from: ps) ?? iso2.date(from: ps) else { return nil }
            if type == "movie", let m = o["movie"] as? [String: Any] {
                return TraktPause(kind: "movie", title: m["title"] as? String ?? "", year: m["year"] as? Int,
                                  tmdb: (m["ids"] as? [String: Any])?["tmdb"] as? Int, season: nil, number: nil, progress: p, pausedAt: at)
            }
            if type == "episode", let e = o["episode"] as? [String: Any], let s = o["show"] as? [String: Any] {
                return TraktPause(kind: "episode", title: s["title"] as? String ?? "", year: s["year"] as? Int,
                                  tmdb: (s["ids"] as? [String: Any])?["tmdb"] as? Int, season: e["season"] as? Int, number: e["number"] as? Int,
                                  progress: p, pausedAt: at)
            }
            return nil
        }.sorted { $0.pausedAt > $1.pausedAt }
    }
}

/// The pauses last read from Trakt, kept for the linked account only.
enum TraktStore {
    private static let key = "trakt.pauses"
    private static let accountKey = "trakt.pauses.account"
    static var pauses: [TraktPause] {
        guard UserDefaults.standard.string(forKey: accountKey) == TraktKeys.username,
              let d = UserDefaults.standard.data(forKey: key), let p = try? JSONDecoder().decode([TraktPause].self, from: d) else { return [] }
        return p
    }
    static func save(_ p: [TraktPause]) {
        UserDefaults.standard.set(try? JSONEncoder().encode(p), forKey: key)
        UserDefaults.standard.set(TraktKeys.username, forKey: accountKey)
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "trakt.pulledAt")
    }
    static var pulledAt: Date? {
        let t = UserDefaults.standard.double(forKey: "trakt.pulledAt"); return t > 0 ? Date(timeIntervalSince1970: t) : nil
    }
    static func clear() { UserDefaults.standard.removeObject(forKey: key); UserDefaults.standard.removeObject(forKey: accountKey) }

    static func movie(title: String, year: Int?, tmdb: Int?) -> TraktPause? {
        let k = TmdbRule.key(title)
        return pauses.first { $0.kind == "movie" && (tmdb != nil && $0.tmdb == tmdb || TmdbRule.key($0.title) == k && (year == nil || $0.year == nil || abs($0.year! - year!) <= 1)) }
    }
    static func episode(show: String, year: Int?, tmdb: Int?, season: Int, number: Int) -> TraktPause? {
        let k = TmdbRule.key(show)
        return pauses.first { $0.kind == "episode" && $0.season == season && $0.number == number &&
            (tmdb != nil && $0.tmdb == tmdb || TmdbRule.key($0.title) == k && (year == nil || $0.year == nil || abs($0.year! - year!) <= 1)) }
    }
}

/// Follows one film/episode in the player and sends start / pause / stop (or pause on leaving).
@MainActor
final class TraktScrobbler {
    static let shared = TraktScrobbler()
    private var identity: [String: Any]?
    private var label = ""
    private var started = false
    private var item: String?

    /// A new film/episode opened. `name`: provider name of the film or of the series.
    func begin(key: String, name: String, season: Int?, number: Int?) {
        identity = nil; started = false; item = key
        guard TraktKeys.isLinked else { return }
        let clean = TmdbRule.split(name).title
        let st = TraktRule.searchTitle(clean, fallbackYear: TmdbRule.year(clean))
        label = season.map { String(format: "%@ S%02dE%02d", st.title, $0, number ?? 0) } ?? st.title
        Task {
            var tmdb: Int?
            if TmdbKey.value != nil, let t = try? await Tmdb.shared.match(kind: season == nil ? .movie : .tv, providerName: name) { tmdb = t.tmdbId }
            guard self.item == key else { return }
            self.identity = TraktRule.identity(title: st.title, year: st.year, tmdb: tmdb, season: season, number: number)
        }
    }

    func playing(progress: Double?) {
        guard let identity, !started, let p = progress else { return }
        started = true
        let l = label
        Task { await Trakt.shared.scrobble(.start, identity, progress: p, label: l) }
    }

    func paused(progress: Double?) {
        guard let identity, started, let p = progress, TraktRule.worthSending(p) else { return }
        started = false
        let l = label
        Task { await Trakt.shared.scrobble(.pause, identity, progress: p, label: l) }
    }

    /// Leaving the film/episode (another one, or the player closed).
    func leave(progress: Double?) {
        defer { identity = nil; started = false; item = nil }
        guard let identity, let p = progress, TraktRule.worthSending(p) else { return }
        let l = label
        Task { await Trakt.shared.scrobble(TraktRule.exitAction(p), identity, progress: p, label: l) }
    }
}

/// Reads the pauses from Trakt: at launch, when the app comes back to the front, and on demand (at most every 2 minutes
/// unless forced). The result says what really happened.
@MainActor
enum TraktSync {
    private static var last: Date?
    static var lastResult: String?

    @discardableResult
    static func pull(force: Bool = false) async -> String {
        guard TraktKeys.isLinked else { return "غير مربوط" }
        if !force, let last, Date().timeIntervalSince(last) < 120 { return lastResult ?? "" }
        last = Date()
        do {
            let p = try await Trakt.shared.playback()
            TraktStore.save(p)
            let r = p.isEmpty ? "لا توجد نقاط توقف في Trakt" : "تمت المزامنة: \(p.count) نقطة توقف من Trakt"
            lastResult = r; TraktLog.add("sync/playback → \(p.count)")
            return r
        } catch {
            let r = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            lastResult = "تعذّرت المزامنة: " + r; TraktLog.add("sync/playback → فشل")
            return lastResult!
        }
    }
}
