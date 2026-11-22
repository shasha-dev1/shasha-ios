import Foundation
import CryptoKit

/// 1.3.0: progress shared with the TV app through one file in the viewer's own Google Drive.
/// 1.4.4: scope drive.file (the app sees only files it created, nothing else in the Drive). drive.appdata was the
/// first choice, but Google's device flow refuses it in practice ("Invalid device flow scope", seen on the owner's
/// phone 2026-11-22 and reported by other projects), so the file now sits in My Drive as shasha-sync-v1.json. Sign-in with Google's device flow
/// using the viewer's own OAuth client ("TVs and Limited Input devices") — the SAME client in both apps, so both see
/// the same app-data folder. Keys and tokens stay in the Keychain. Format: CloudSyncRule / docs/CLOUD-SYNC.md.
enum DriveKeys {
    static let clientId = "gdrive.clientId", secret = "gdrive.secret"
    static let access = "gdrive.access", refresh = "gdrive.refresh", expires = "gdrive.expires"
    static var id: String? { Keychain.get(clientId).flatMap { $0.isEmpty ? nil : $0 } }
    static var clientSecret: String? { Keychain.get(secret).flatMap { $0.isEmpty ? nil : $0 } }
    static var isLinked: Bool { Keychain.get(refresh) != nil }
    static func clearTokens() { Keychain.set(nil, for: access); Keychain.set(nil, for: refresh); Keychain.set(nil, for: expires) }
}

enum DriveError: LocalizedError {
    case notConfigured, notLinked, http(Int, String?), network(String), file(String), changedMeanwhile
    var errorDescription: String? {
        switch self {
        case .notConfigured: return "أدخل Client ID و Client Secret أولًا."
        case .notLinked: return "اربط حساب Google أولًا."
        case .http(let c, let m): return "Google ردّ \(c)\(m.map { " (\($0))" } ?? "")."
        case .network(let m): return "تعذّر الاتصال بـ Google: \(m)"
        case .file(let m): return m
        case .changedMeanwhile: return "الجهاز الآخر غيّر الملف في نفس اللحظة — أعد المحاولة"
        }
    }
}

actor GoogleDrive {
    static let shared = GoogleDrive()
    static let fileName = "shasha-sync-v1.json"
    private let scope = "https://www.googleapis.com/auth/drive.file"

    private func form(_ url: String, _ fields: [String: String]) -> URLRequest {
        var r = URLRequest(url: URL(string: url)!, timeoutInterval: 25)
        r.httpMethod = "POST"
        r.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var c = URLComponents(); c.queryItems = fields.map { URLQueryItem(name: $0.key, value: $0.value) }
        r.httpBody = (c.percentEncodedQuery ?? "").replacingOccurrences(of: "+", with: "%2B").data(using: .utf8)
        return r
    }
    private func send(_ r: URLRequest) async throws -> (Int, Data) {
        do {
            let (d, resp) = try await URLSession.shared.data(for: r)
            let h = resp as? HTTPURLResponse
            // 1.7.0: Google's clock (Date header) vs this phone's, to warn when the phone's clock is wrong.
            if let ds = h?.value(forHTTPHeaderField: "Date"), let server = Self.httpDate.date(from: ds) {
                clockSkew = Date().timeIntervalSince(server)
            }
            return (h?.statusCode ?? 0, d)
        }
        catch { throw DriveError.network(error.localizedDescription) }
    }
    /// Seconds this phone's clock is ahead of Google's (negative = behind); nil until a reply was seen.
    private(set) var clockSkew: TimeInterval?
    private static let httpDate: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(identifier: "GMT")
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"; return f
    }()
    private func json(_ d: Data) -> [String: Any] { (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] ?? [:] }

    // MARK: Device sign-in

    struct DeviceCode { let deviceCode: String; let userCode: String; let url: String; let expiresIn: Int; let interval: Int }
    enum Poll: Equatable { case success, pending, slowDown, denied, expired, failed(String) }

    func deviceCode() async throws -> DeviceCode {
        guard let id = DriveKeys.id else { throw DriveError.notConfigured }
        let (code, d) = try await send(form("https://oauth2.googleapis.com/device/code", ["client_id": id, "scope": scope]))
        let o = json(d)
        guard code == 200, let dc = o["device_code"] as? String, let uc = o["user_code"] as? String else {
            throw DriveError.http(code, o["error_description"] as? String ?? o["error"] as? String)
        }
        return DeviceCode(deviceCode: dc, userCode: uc, url: o["verification_url"] as? String ?? "https://www.google.com/device",
                          expiresIn: o["expires_in"] as? Int ?? 1800, interval: max(1, o["interval"] as? Int ?? 5))
    }

    func poll(_ deviceCode: String) async throws -> Poll {
        guard let id = DriveKeys.id else { throw DriveError.notConfigured }
        let (code, d) = try await send(form("https://oauth2.googleapis.com/token", [
            "client_id": id, "client_secret": DriveKeys.clientSecret ?? "", "device_code": deviceCode,
            "grant_type": "urn:ietf:params:oauth:grant-type:device_code"]))
        let o = json(d)
        let gotRefresh = o["refresh_token"] != nil
        await MainActor.run { Perf.shared.add("ربط Google: ردّ", ms: 0, "HTTP \(code) \(o["error"] as? String ?? (gotRefresh ? "tokens+refresh" : "tokens"))") }
        if code == 200, saveTokens(o) { return .success }
        let err = o["error"] as? String ?? ""
        switch err {
        case "authorization_pending": return .pending
        case "slow_down": return .slowDown
        case "access_denied": return .denied
        case "expired_token": return .expired
        default:
            // 1.5.2: keep Google's own explanation (no secrets in it) to tell causes apart.
            let why = (o["error_description"] as? String).map { " — \($0)" } ?? ""
            return .failed(err.isEmpty ? "HTTP \(code)\(why)" : err + why)
        }
    }

    @discardableResult
    private func saveTokens(_ o: [String: Any]) -> Bool {
        guard let a = o["access_token"] as? String else { return false }
        Keychain.set(a, for: DriveKeys.access)
        if let r = o["refresh_token"] as? String { Keychain.set(r, for: DriveKeys.refresh) }
        let exp = Date().timeIntervalSince1970 + ((o["expires_in"] as? Double) ?? 3600)
        Keychain.set(String(exp), for: DriveKeys.expires)
        return true
    }

    private func token() async throws -> String {
        guard let refresh = Keychain.get(DriveKeys.refresh), let id = DriveKeys.id else { throw DriveError.notLinked }
        if let a = Keychain.get(DriveKeys.access), (Double(Keychain.get(DriveKeys.expires) ?? "") ?? 0) - Date().timeIntervalSince1970 > 120 { return a }
        let (code, d) = try await send(form("https://oauth2.googleapis.com/token", [
            "client_id": id, "client_secret": DriveKeys.clientSecret ?? "", "refresh_token": refresh, "grant_type": "refresh_token"]))
        let o = json(d)
        if code == 400 || code == 401, (o["error"] as? String) == "invalid_grant" {
            DriveKeys.clearTokens()
            throw DriveError.http(code, "انتهى الربط — اربط من جديد (إذا كان مشروع Google في وضع Testing ينتهي كل 7 أيام)")
        }
        guard code == 200, saveTokens(o), let a = Keychain.get(DriveKeys.access) else { throw DriveError.http(code, o["error"] as? String) }
        return a
    }

    func disconnect() async {
        if let t = Keychain.get(DriveKeys.refresh) ?? Keychain.get(DriveKeys.access) {
            _ = try? await send(form("https://oauth2.googleapis.com/revoke", ["token": t]))
        }
        DriveKeys.clearTokens()
    }

    // MARK: The sync file

    private func authed(_ url: String, method: String = "GET") async throws -> URLRequest {
        var r = URLRequest(url: URL(string: url)!, timeoutInterval: 25)
        r.httpMethod = method
        r.setValue("Bearer \(try await token())", forHTTPHeaderField: "Authorization")
        return r
    }

    struct Remote { let id: String; let file: CloudSyncRule.File; let version: String?; let raw: Data }

    /// The sync file — nil when it doesn't exist yet. 1.6.0: an unreadable / too big / newer-format file throws
    /// (it used to be read as empty, and the next upload would have replaced the other device's entries).
    func read() async throws -> Remote? {
        guard let meta = try await find(Self.fileName) else { return nil }
        let (c2, body) = try await send(try await authed("https://www.googleapis.com/drive/v3/files/\(meta.id)?alt=media"))
        guard c2 == 200 else { throw DriveError.http(c2, nil) }
        do {
            return Remote(id: meta.id, file: try CloudSyncRule.decode(body), version: meta.version, raw: body)
        } catch let e as CloudSyncRule.FileError {
            switch e {
            case .tooBig(let n): throw DriveError.file("ملف المزامنة أكبر من المتوقع (\(n / 1024) KB) — لم يُطبّق شيء")
            case .unreadable: throw DriveError.file("ملف المزامنة غير مقروء — بياناتك المحلية لم تتغير")
            case .newerFormat(let v): throw DriveError.file("ملف المزامنة من إصدار أحدث (v\(v)) — حدّث التطبيق")
            }
        }
    }

    /// Newest file with this name (not in the bin): id and version (Drive's own counter, bumped on each change).
    private func find(_ name: String) async throws -> (id: String, version: String?)? {
        var c = URLComponents(string: "https://www.googleapis.com/drive/v3/files")!
        c.queryItems = [URLQueryItem(name: "q", value: "name = '\(name)' and trashed = false"),
                        URLQueryItem(name: "fields", value: "files(id,modifiedTime,version)"),
                        URLQueryItem(name: "orderBy", value: "modifiedTime desc")]
        let (code, d) = try await send(try await authed(c.url!.absoluteString))
        guard code == 200 else { throw DriveError.http(code, (json(d)["error"] as? [String: Any])?["message"] as? String) }
        guard let f = (json(d)["files"] as? [[String: Any]])?.first, let id = f["id"] as? String else { return nil }
        return (id, f["version"] as? String)
    }

    /// Current version of the file, to see whether the other device wrote since we read it.
    func version(of id: String) async throws -> String? {
        let (code, d) = try await send(try await authed("https://www.googleapis.com/drive/v3/files/\(id)?fields=version"))
        guard code == 200 else { throw DriveError.http(code, nil) }
        return json(d)["version"] as? String
    }

    func write(_ f: CloudSyncRule.File, id: String?) async throws {
        try await put(JSONEncoder().encode(f), name: Self.fileName, id: id,
                      description: "Shasha: watch progress shared between your devices")
    }

    /// 1.6.0: before the first change of a day, the file as it was is kept as shasha-sync-v1.backup.json
    /// (one copy, replaced at most once a day) so a bad merge can be undone by hand.
    func backupIfDue(_ raw: Data) async {
        let k = "cloud.backupAt"
        guard Date().timeIntervalSince1970 - UserDefaults.standard.double(forKey: k) > 24 * 3600 else { return }
        let name = "shasha-sync-v1.backup.json"
        let existingId: String?
        do { existingId = try await find(name)?.id } catch { return }
        if (try? await put(raw, name: name, id: existingId, description: "Shasha: copy of the sync file before changes")) != nil {
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: k)
        }
    }

    private func put(_ data: Data, name: String, id: String?, description: String) async throws {
        if let id {
            var r = try await authed("https://www.googleapis.com/upload/drive/v3/files/\(id)?uploadType=media", method: "PATCH")
            r.setValue("application/json", forHTTPHeaderField: "Content-Type"); r.httpBody = data
            let (code, _) = try await send(r)
            guard code == 200 else { throw DriveError.http(code, nil) }
        } else {
            let boundary = "shasha-\(UUID().uuidString)"
            var body = Data()
            let meta = #"{"name":"\#(name)","description":"\#(description)"}"#
            body.append("--\(boundary)\r\nContent-Type: application/json; charset=UTF-8\r\n\r\n\(meta)\r\n".data(using: .utf8)!)
            body.append("--\(boundary)\r\nContent-Type: application/json\r\n\r\n".data(using: .utf8)!)
            body.append(data)
            body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
            var r = try await authed("https://www.googleapis.com/upload/drive/v3/files?uploadType=multipart", method: "POST")
            r.setValue("multipart/related; boundary=\(boundary)", forHTTPHeaderField: "Content-Type"); r.httpBody = body
            let (code, _) = try await send(r)
            guard code == 200 else { throw DriveError.http(code, nil) }
        }
    }
}

/// Builds this phone's part of the file, merges with the Drive file, applies what's newer, uploads the result.
@MainActor
enum CloudSync {
    private static var last: Date?
    private static var running = false
    static var lastResult: String? {
        get { UserDefaults.standard.string(forKey: "cloud.lastResult") }
        set { UserDefaults.standard.set(newValue, forKey: "cloud.lastResult") }
    }
    static var lastSuccess: Date? {
        let t = UserDefaults.standard.double(forKey: "cloud.lastSuccess"); return t > 0 ? Date(timeIntervalSince1970: t) : nil
    }

    static func account(_ s: Source) -> String? {
        CloudSyncRule.account(server: s.server, user: s.username, sha256: { SHA256.hash(data: Data($0.utf8)).map { String(format: "%02x", $0) }.joined() })
    }

    /// This phone's progress for the active playlist, in the shared format.
    /// 1.6.0: watched = no resume point and not marked "start over"; removed from Continue watching = `x` with the
    /// removal time (so an older copy elsewhere can't bring it back).
    static func localFile(_ acct: String) -> CloudSyncRule.File {
        var f = CloudSyncRule.File()
        for key in Store.recent {
            let kind: String, id: String
            if key.hasPrefix("movie:") { kind = "movie"; id = String(key.dropFirst(6)) }
            else if key.hasPrefix("ep:") { kind = "ep"; id = String(key.dropFirst(3)) }
            else { continue }
            guard let saved = Store.positionTime(key) else { continue }      // saved before 1.2.0: no time to compare
            let p = Store.position(key)
            let hidden = Store.hiddenAt(key).flatMap { $0 >= saved ? $0 : nil }
            // 1.7.1: in Google's clock, and never in the future (see CloudSyncRule.stamp).
            let at = Date(timeIntervalSince1970: Double(CloudSyncRule.stamp(Int64((hidden ?? saved).timeIntervalSince1970 * 1000), skewMs: skewMs)) / 1000)
            f.progress[CloudSyncRule.key(account: acct, kind: kind, id: id)] =
                .init(pos: p?.pos ?? 0, dur: p?.dur ?? 0, w: p == nil && !Store.isUnwatched(key), at: Int64(at.timeIntervalSince1970 * 1000),
                      show: kind == "ep" ? Store.show(forEpisode: key) : nil, x: hidden == nil ? nil : true)
        }
        return f
    }

    /// 1.7.1: phone clock minus Google's, ms, measured on the last sync (kept between launches).
    static var skewMs: Int64? {
        get { UserDefaults.standard.object(forKey: "cloud.skewMs") as? Int64 }
        set { UserDefaults.standard.set(newValue, forKey: "cloud.skewMs") }
    }

    // MARK: status (1.6.0)

    /// Local entries saved after the last successful sync (they go out with the next one; nothing is lost if it
    /// fails, the phone's own data is the queue).
    static func pendingCount(_ library: Library) -> Int {
        guard let s = library.active, let acct = account(s) else { return 0 }
        let since = lastSuccess.map { CloudSyncRule.stamp(Int64($0.timeIntervalSince1970 * 1000), skewMs: skewMs) } ?? Int64.min
        return localFile(acct).progress.values.filter { $0.at > since }.count
    }
    private static var fails: Int {
        get { UserDefaults.standard.integer(forKey: "cloud.fails") }
        set { UserDefaults.standard.set(newValue, forKey: "cloud.fails") }
    }
    /// After a failure, automatic syncs wait 1, 2, 4 … up to 30 minutes. "Sync now" always tries.
    static var nextAutoTry: Date? {
        let t = UserDefaults.standard.double(forKey: "cloud.nextTry"); return t > 0 ? Date(timeIntervalSince1970: t) : nil
    }

    @discardableResult
    static func sync(_ library: Library, force: Bool = false) async -> String {
        guard DriveKeys.isLinked else { return "غير مربوط" }
        guard let s = library.active, s.kind == .xtream, let acct = account(s) else { return "المزامنة للقوائم من نوع Xtream فقط" }
        if running { return lastResult ?? "" }
        if !force, let last, Date().timeIntervalSince(last) < 30 { return lastResult ?? "" }
        if !force, let n = nextAutoTry, Date() < n { return lastResult ?? "" }
        running = true; last = Date(); defer { running = false }
        let t0 = Perf.now()
        do {
            var applied = 0, repaired = 0, future = 0, withheld = 0
            for attempt in 0..<2 {
                let remote = try await GoogleDrive.shared.read()
                if let sk = await GoogleDrive.shared.clockSkew { skewMs = Int64(sk * 1000) }
                // A reply that arrives after the playlist changed must not touch the new account.
                guard library.active?.id == s.id else { return "تغيّر المصدر أثناء المزامنة — لم يُطبّق شيء" }
                let theirs = remote?.file ?? CloudSyncRule.File()
                // 1.7.2: entries saved while this phone's clock was wrong are withheld when the TV has a valid one.
                let prepared = CloudSyncRule.prepareOwn(localFile(acct), file: theirs)
                withheld = prepared.withheld.count
                let local = prepared.send
                let prefix = acct + "|"
                for (k, e) in CloudSyncRule.newer(theirs, than: local) where k.hasPrefix(prefix) {
                    let parts = k.split(separator: "|", maxSplits: 2)
                    guard parts.count == 3 else { continue }
                    let key = parts[1] == "movie" ? "movie:" + parts[2] : parts[1] == "ep" ? "ep:" + parts[2] : nil
                    guard let key else { continue }
                    let localAt = CloudSyncRule.toLocal(e.at, skewMs: skewMs)       // stored in this phone's clock
                    Store.applyRemote(key, pos: e.pos, dur: e.dur, watched: e.w, at: Date(timeIntervalSince1970: Double(localAt) / 1000), removed: e.x == true)
                    if let show = e.show, key.hasPrefix("ep:") { Store.remember(episodes: [key], show: show) }
                    applied += 1
                }
                future = CloudSyncRule.futureCount(theirs)
                let mine = CloudSyncRule.prepareOwn(localFile(acct), file: theirs).send
                let merged = CloudSyncRule.merge(theirs, mine)
                if merged == theirs { break }
                if let remote {
                    await GoogleDrive.shared.backupIfDue(remote.raw)
                    // The other device may have written since we read: then read and merge again (once).
                    if try await GoogleDrive.shared.version(of: remote.id) != remote.version {
                        if attempt == 0 { continue } else { throw DriveError.changedMeanwhile }
                    }
                }
                try await GoogleDrive.shared.write(merged, id: remote?.id)
                // 1.7.0: the version check narrows the window but can't close it (Drive v3 has no conditional
                // upload). Read again: if the TV wrote between our check and our upload, our entries are missing —
                // merge with what is there now and upload again (twice at most). The TV app does the same.
                var verified = false
                for _ in 0..<3 {
                    guard let now = try await GoogleDrive.shared.read() else { break }
                    if CloudSyncRule.covers(now.file, mine) { verified = true; break }
                    repaired += 1
                    try await GoogleDrive.shared.write(CloudSyncRule.merge(now.file, mine), id: now.id)
                }
                if !verified { throw DriveError.changedMeanwhile }
                break
            }
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "cloud.lastSuccess")
            fails = 0; UserDefaults.standard.removeObject(forKey: "cloud.nextTry")
            Perf.shared.record("مزامنة Google", since: t0, "طُبّق \(applied) · إعادة رفع \(repaired) · مستقبلي \(future)")
            var r = applied > 0 ? "تمت المزامنة: \(applied) من الجهاز الآخر" : "تمت المزامنة: لا جديد من الجهاز الآخر"
            if repaired > 0 { r += "\nالجهاز الآخر كتب في نفس اللحظة — أُعيد الدمج والرفع" }
            if future > 0 { r += "\nلم يُطبَّق \(future) تحديث من جهاز ساعته متقدمة أكثر من يوم (بقيت في الملف)" }
            if withheld > 0 { r += "\nلم يُرسل \(withheld) تحديث حُفظ هنا والساعة غير مضبوطة: للجهاز الآخر تحديث صالح لنفس العناوين واعتُمد هو" }
            if let sk = await GoogleDrive.shared.clockSkew, abs(sk) > 300 {
                r += "\nساعة هذا الجهاز مختلفة عن ساعة Google بـ \(Int(abs(sk) / 60)) دقيقة — المزامنة تصحح ذلك، لكن اضبط التاريخ والوقت تلقائيًا"
            }
            lastResult = r
            if applied > 0 { NotificationCenter.default.post(name: .cloudSyncApplied, object: nil) }
            return r
        } catch {
            fails += 1
            let wait = min(30 * 60, 60 * (1 << min(fails - 1, 5)))
            UserDefaults.standard.set(Date().timeIntervalSince1970 + Double(wait), forKey: "cloud.nextTry")
            let why = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            Perf.shared.add("مزامنة Google فشلت", ms: 0, why)
            let r = "تعذّرت المزامنة: " + why
            lastResult = r
            return r
        }
    }
}

extension Notification.Name { static let cloudSyncApplied = Notification.Name("shasha.cloudSyncApplied") }
