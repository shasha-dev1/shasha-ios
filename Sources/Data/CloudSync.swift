import Foundation
import CryptoKit

/// 1.3.0: progress shared with the TV app through one file in the viewer's own Google Drive (hidden app-data folder,
/// scope drive.appdata: the app sees only its own file, nothing else in the Drive). Sign-in with Google's device flow
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
    case notConfigured, notLinked, http(Int, String?), network(String)
    var errorDescription: String? {
        switch self {
        case .notConfigured: return "أدخل Client ID و Client Secret أولًا."
        case .notLinked: return "اربط حساب Google أولًا."
        case .http(let c, let m): return "Google ردّ \(c)\(m.map { " (\($0))" } ?? "")."
        case .network(let m): return "تعذّر الاتصال بـ Google: \(m)"
        }
    }
}

actor GoogleDrive {
    static let shared = GoogleDrive()
    static let fileName = "shasha-sync-v1.json"
    private let scope = "https://www.googleapis.com/auth/drive.appdata"

    private func form(_ url: String, _ fields: [String: String]) -> URLRequest {
        var r = URLRequest(url: URL(string: url)!, timeoutInterval: 25)
        r.httpMethod = "POST"
        r.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var c = URLComponents(); c.queryItems = fields.map { URLQueryItem(name: $0.key, value: $0.value) }
        r.httpBody = (c.percentEncodedQuery ?? "").replacingOccurrences(of: "+", with: "%2B").data(using: .utf8)
        return r
    }
    private func send(_ r: URLRequest) async throws -> (Int, Data) {
        do { let (d, resp) = try await URLSession.shared.data(for: r); return ((resp as? HTTPURLResponse)?.statusCode ?? 0, d) }
        catch { throw DriveError.network(error.localizedDescription) }
    }
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
        if code == 200, saveTokens(o) { return .success }
        let err = o["error"] as? String ?? ""
        switch err {
        case "authorization_pending": return .pending
        case "slow_down": return .slowDown
        case "access_denied": return .denied
        case "expired_token": return .expired
        default: return .failed(err.isEmpty ? "HTTP \(code)" : err)
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

    /// (file id, contents) — nil when the file doesn't exist yet.
    func read() async throws -> (id: String, file: CloudSyncRule.File)? {
        var c = URLComponents(string: "https://www.googleapis.com/drive/v3/files")!
        c.queryItems = [URLQueryItem(name: "spaces", value: "appDataFolder"),
                        URLQueryItem(name: "q", value: "name = '\(Self.fileName)' and trashed = false"),
                        URLQueryItem(name: "fields", value: "files(id,modifiedTime)"),
                        URLQueryItem(name: "orderBy", value: "modifiedTime desc")]
        let (code, d) = try await send(try await authed(c.url!.absoluteString))
        guard code == 200 else { throw DriveError.http(code, (json(d)["error"] as? [String: Any])?["message"] as? String) }
        guard let id = (json(d)["files"] as? [[String: Any]])?.first?["id"] as? String else { return nil }
        let (c2, body) = try await send(try await authed("https://www.googleapis.com/drive/v3/files/\(id)?alt=media"))
        guard c2 == 200 else { throw DriveError.http(c2, nil) }
        let f = (try? JSONDecoder().decode(CloudSyncRule.File.self, from: body)) ?? CloudSyncRule.File()
        return (id, f)
    }

    func write(_ f: CloudSyncRule.File, id: String?) async throws {
        let data = try JSONEncoder().encode(f)
        if let id {
            var r = try await authed("https://www.googleapis.com/upload/drive/v3/files/\(id)?uploadType=media", method: "PATCH")
            r.setValue("application/json", forHTTPHeaderField: "Content-Type"); r.httpBody = data
            let (code, _) = try await send(r)
            guard code == 200 else { throw DriveError.http(code, nil) }
        } else {
            let boundary = "shasha-\(UUID().uuidString)"
            var body = Data()
            let meta = #"{"name":"\#(Self.fileName)","parents":["appDataFolder"]}"#
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
    static func localFile(_ acct: String) -> CloudSyncRule.File {
        var f = CloudSyncRule.File()
        for key in Store.recent {
            let kind: String, id: String
            if key.hasPrefix("movie:") { kind = "movie"; id = String(key.dropFirst(6)) }
            else if key.hasPrefix("ep:") { kind = "ep"; id = String(key.dropFirst(3)) }
            else { continue }
            guard let at = Store.positionTime(key) else { continue }      // saved before 1.2.0: no time to compare
            let p = Store.position(key)
            f.progress[CloudSyncRule.key(account: acct, kind: kind, id: id)] =
                .init(pos: p?.pos ?? 0, dur: p?.dur ?? 0, w: p == nil, at: Int64(at.timeIntervalSince1970 * 1000),
                      show: kind == "ep" ? Store.show(forEpisode: key) : nil)
        }
        return f
    }

    @discardableResult
    static func sync(_ library: Library, force: Bool = false) async -> String {
        guard DriveKeys.isLinked else { return "غير مربوط" }
        guard let s = library.active, s.kind == .xtream, let acct = account(s) else { return "المزامنة للقوائم من نوع Xtream فقط" }
        if running { return lastResult ?? "" }
        if !force, let last, Date().timeIntervalSince(last) < 30 { return lastResult ?? "" }
        running = true; last = Date(); defer { running = false }
        do {
            let remote = try await GoogleDrive.shared.read()
            let local = localFile(acct)
            let theirs = remote?.file ?? CloudSyncRule.File()
            var applied = 0
            let prefix = acct + "|"
            for (k, e) in CloudSyncRule.newer(theirs, than: local) where k.hasPrefix(prefix) {
                let parts = k.split(separator: "|", maxSplits: 2)
                guard parts.count == 3 else { continue }
                let key = parts[1] == "movie" ? "movie:" + parts[2] : parts[1] == "ep" ? "ep:" + parts[2] : nil
                guard let key else { continue }
                Store.applyRemote(key, pos: e.pos, dur: e.dur, watched: e.w, at: Date(timeIntervalSince1970: Double(e.at) / 1000))
                if let show = e.show, key.hasPrefix("ep:") { Store.remember(episodes: [key], show: show) }
                applied += 1
            }
            let merged = CloudSyncRule.merge(theirs, local)
            if merged != theirs { try await GoogleDrive.shared.write(merged, id: remote?.id) }
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "cloud.lastSuccess")
            let r = applied > 0 ? "تمت المزامنة: \(applied) من الجهاز الآخر" : "تمت المزامنة: لا جديد من الجهاز الآخر"
            lastResult = r
            if applied > 0 { NotificationCenter.default.post(name: .cloudSyncApplied, object: nil) }
            return r
        } catch {
            let r = "تعذّرت المزامنة: " + ((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
            lastResult = r
            return r
        }
    }
}

extension Notification.Name { static let cloudSyncApplied = Notification.Name("shasha.cloudSyncApplied") }
