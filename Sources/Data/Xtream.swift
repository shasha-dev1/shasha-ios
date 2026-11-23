import Foundation

enum LoadError: LocalizedError {
    case badAddress, refused, network(String), empty
    var errorDescription: String? {
        switch self {
        case .badAddress: return "عنوان غير صحيح."
        case .refused: return "الخادم رفض اسم المستخدم أو كلمة المرور."
        case .network(let m): return "تعذّر الاتصال: \(m)"
        case .empty: return "القائمة فارغة."
        }
    }
}

/// Xtream Codes API (player_api.php) — the same calls the TV app makes.
struct Xtream {
    let server: String
    let user: String
    let pass: String

    static func normalize(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if !s.lowercased().hasPrefix("http") { s = "http://" + s }
        while s.hasSuffix("/") { s.removeLast() }
        if let r = s.range(of: "/player_api.php") { s = String(s[..<r.lowerBound]) }
        return s
    }

    private func esc(_ s: String) -> String { s.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/?&=+"))) ?? s }

    func api(_ action: String?, _ extra: [String: String] = [:]) async throws -> Any {
        let (data, name, measured) = try await download(action, extra)
        return try await Task.detached(priority: .userInitiated) {
            let t1 = Perf.now()
            let o = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
            if measured { Perf.shared.record("تحليل JSON \(name)", since: t1) }
            return o
        }.value
    }

    /// 1.0.8: the big lists (channels, movies, series) are parsed AND converted in one step on a serial queue, inside an
    /// autorelease pool: only one JSON tree exists at a time and it is freed as soon as its list is converted.
    /// (1.0.6: memory reached 1,002 MB right after the three lists were parsed together.)
    private static let parseQueue = DispatchQueue(label: "shasha.parse", qos: .userInitiated)

    func bigList<T>(_ action: String, _ what: String, _ convertName: String, _ map: @escaping ([String: Any]) -> T?) async throws -> [T] {
        let (data, name, _) = try await download(action, [:])
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<[T], Error>) in
            Self.parseQueue.async {
                autoreleasepool {
                    do {
                        let t1 = Perf.now()
                        let o = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
                        Perf.shared.record("تحليل JSON \(name)", since: t1)
                        guard let a = o as? [[String: Any]] else { throw LoadError.network("رد غير متوقع من المزوّد (\(what))") }
                        let t2 = Perf.now()
                        let out = a.compactMap(map)
                        Perf.shared.record(convertName, since: t2, "\(out.count)")
                        cont.resume(returning: out)
                    } catch { cont.resume(throwing: error) }
                }
                Perf.shared.memory("بعد تحرير JSON \(name)")
            }
        }
    }

    private func download(_ action: String?, _ extra: [String: String]) async throws -> (Data, String, Bool) {
        var c = URLComponents(string: server + "/player_api.php")
        var q = [URLQueryItem(name: "username", value: user), URLQueryItem(name: "password", value: pass)]
        if let action { q.append(URLQueryItem(name: "action", value: action)) }
        extra.forEach { q.append(URLQueryItem(name: $0.key, value: $0.value)) }
        c?.queryItems = q
        guard let url = c?.url else { throw LoadError.badAddress }
        var req = URLRequest(url: url, timeoutInterval: 60)
        req.setValue("Shasha-iOS", forHTTPHeaderField: "User-Agent")
        let data: Data
        // 1.0.2 measurements: action name and size only (the URL holds the login data).
        let name = action ?? "تسجيل الدخول", measured = action != "get_short_epg"
        let t0 = Perf.now()
        do { (data, _) = try await URLSession.shared.data(for: req) } catch { throw LoadError.network(error.localizedDescription) }
        if measured { Perf.shared.record("شبكة \(name)", since: t0, ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file)) }
        return (data, name, measured)
    }

    /// Login check: user_info.auth == 1.
    func verify() async throws {
        let o = try await api(nil)
        guard let d = o as? [String: Any], let info = d["user_info"] as? [String: Any], J.i(info["auth"]) == 1 else { throw LoadError.refused }
    }

    private func list(_ o: Any) -> [[String: Any]] { o as? [[String: Any]] ?? [] }
    /// 1.0.4: a stream list must be a JSON array (an empty one is a real "none"). Anything else — an error object,
    /// null, text — is a failed request, so the screen doesn't claim "no movies" when the request failed.
    private func strictList(_ o: Any, _ what: String) throws -> [[String: Any]] {
        guard let a = o as? [[String: Any]] else { throw LoadError.network("رد غير متوقع من المزوّد (\(what))") }
        return a
    }

    func categories(_ action: String) async throws -> [Category] {
        list(try await api(action)).compactMap { d in
            guard let id = J.s(d["category_id"]) else { return nil }
            return Category(id: id, name: J.s(d["category_name"]) ?? "—")
        }
    }

    /// Full guide (XMLTV) of the account — match-guide report only.
    var xmltvURL: URL? {
        var c = URLComponents(string: server + "/xmltv.php")
        c?.queryItems = [URLQueryItem(name: "username", value: user), URLQueryItem(name: "password", value: pass)]
        return c?.url
    }

    func liveURL(_ id: String) -> String { "\(server)/live/\(esc(user))/\(esc(pass))/\(id).ts" }
    func movieURL(_ id: String, _ ext: String) -> String { "\(server)/movie/\(esc(user))/\(esc(pass))/\(id).\(ext)" }
    func episodeURL(_ id: String, _ ext: String) -> String { "\(server)/series/\(esc(user))/\(esc(pass))/\(id).\(ext)" }

    func channels() async throws -> [Channel] {
        let me = self
        return try await bigList("get_live_streams", "القنوات", "تحويل القنوات") { d in
            guard let id = J.s(d["stream_id"]) else { return nil }
            let days = J.i(d["tv_archive"]) == 1 ? max(1, J.i(d["tv_archive_duration"])) : 0
            return Channel(id: id, name: J.s(d["name"]) ?? "—", logo: J.s(d["stream_icon"]), categoryId: J.s(d["category_id"]) ?? "", url: me.liveURL(id),
                           archiveDays: days, epgId: J.s(d["epg_channel_id"]).flatMap { $0.isEmpty || $0 == "null" ? nil : $0 })
        }
    }

    func movies() async throws -> [Movie] {
        let me = self
        return try await bigList("get_vod_streams", "الأفلام", "تحويل الأفلام") { d in
            guard let id = J.s(d["stream_id"]) else { return nil }
            let ext = J.s(d["container_extension"]) ?? "mp4"
            return Movie(id: id, name: J.s(d["name"]) ?? "—", poster: J.s(d["stream_icon"]), categoryId: J.s(d["category_id"]) ?? "",
                         rating: J.s(d["rating"]), ext: ext, added: J.i(d["added"]), url: me.movieURL(id, ext))
        }
    }

    func shows() async throws -> [Show] {
        return try await bigList("get_series", "المسلسلات", "تحويل المسلسلات") { d in
            guard let id = J.s(d["series_id"]) else { return nil }
            return Show(id: id, name: J.s(d["name"]) ?? "—", poster: J.s(d["cover"]), categoryId: J.s(d["category_id"]) ?? "",
                        rating: J.s(d["rating"]), plot: J.s(d["plot"]), updated: J.i(d["last_modified"]))
        }
    }

    func episodes(seriesId: String) async throws -> [Episode] {
        guard let d = try await api("get_series_info", ["series_id": seriesId]) as? [String: Any] else { return [] }
        var out: [Episode] = []
        if let bySeason = d["episodes"] as? [String: Any] {
            for (seasonKey, v) in bySeason {
                for e in (v as? [[String: Any]] ?? []) {
                    guard let id = J.s(e["id"]) else { continue }
                    let info = e["info"] as? [String: Any]
                    out.append(Episode(id: id, title: J.s(e["title"]) ?? "", season: J.i(e["season"]) == 0 ? (Int(seasonKey) ?? 1) : J.i(e["season"]),
                                       number: J.i(e["episode_num"]), ext: J.s(e["container_extension"]) ?? "mp4",
                                       plot: J.s(info?["plot"]), image: J.s(info?["movie_image"]),
                                       probe: DiagRule.probeLines(video: info?["video"] as? [String: Any], audio: info?["audio"] as? [String: Any])))
                }
            }
        }
        return out.sorted { ($0.season, $0.number) < ($1.season, $1.number) }
    }

    /// Now / next for one channel. Titles come base64-encoded on most servers.
    func shortEPG(_ streamId: String) async -> EPGNow? {
        guard let d = try? await api("get_short_epg", ["stream_id": streamId, "limit": "3"]) as? [String: Any],
              let rows = d["epg_listings"] as? [[String: Any]] else { return nil }
        func text(_ v: Any?) -> String {
            let raw = J.s(v) ?? ""
            if let data = Data(base64Encoded: raw), let t = String(data: data, encoding: .utf8), !t.isEmpty { return t }
            return raw
        }
        let items: [(title: String, start: Date, end: Date)] = rows.compactMap { e in
            let st = J.i(e["start_timestamp"]), en = J.i(e["stop_timestamp"])
            guard st > 0, en > st else { return nil }
            return (text(e["title"]), Date(timeIntervalSince1970: TimeInterval(st)), Date(timeIntervalSince1970: TimeInterval(en)))
        }.sorted { $0.start < $1.start }
        let now = Date()
        guard let i = items.firstIndex(where: { $0.start <= now && now < $0.end }) else { return nil }
        return EPGNow(title: items[i].title, start: items[i].start, end: items[i].end, next: i + 1 < items.count ? items[i + 1].title : nil)
    }

    func movieInfo(_ id: String) async -> MovieInfo {
        guard let d = try? await api("get_vod_info", ["vod_id": id]) as? [String: Any], let info = d["info"] as? [String: Any] else { return MovieInfo() }
        let backdrop = (info["backdrop_path"] as? [Any])?.first.flatMap { J.s($0) } ?? J.s(info["backdrop_path"])
        return MovieInfo(probe: DiagRule.probeLines(video: info["video"] as? [String: Any], audio: info["audio"] as? [String: Any]),
                         plot: J.s(info["plot"]) ?? J.s(info["description"]), genre: J.s(info["genre"]), year: J.s(info["releasedate"]).map { String($0.prefix(4)) },
                         duration: J.s(info["duration"]), backdrop: backdrop,
                         trailer: J.s(info["youtube_trailer"]) ?? J.s(info["trailer"]),
                         tmdbId: J.s(info["tmdb_id"]) ?? J.s(info["tmdb"]))
    }

    /// Full guide of one channel (get_simple_data_table). Titles/descriptions are base64 on most servers.
    func schedule(_ streamId: String) async -> [Programme] {
        guard let d = try? await api("get_simple_data_table", ["stream_id": streamId]) as? [String: Any],
              let rows = d["epg_listings"] as? [[String: Any]] else { return [] }
        return rows.compactMap { e -> Programme? in
            let st = J.i(e["start_timestamp"]), en = J.i(e["stop_timestamp"])
            guard st > 0, en > st else { return nil }
            return Programme(title: Self.b64(e["title"]), detail: Self.b64(e["description"]).nilIfEmpty,
                             start: Date(timeIntervalSince1970: TimeInterval(st)), end: Date(timeIntervalSince1970: TimeInterval(en)),
                             serverStart: J.s(e["start"]), hasArchive: J.i(e["has_archive"]) == 1)
        }
        .sorted { $0.start < $1.start }
    }

    static func b64(_ v: Any?) -> String {
        let raw = J.s(v) ?? ""
        if let data = Data(base64Encoded: raw), let t = String(data: data, encoding: .utf8), !t.isEmpty { return t }
        return raw
    }

    /// Catch-up link: /timeshift/user/pass/<minutes>/<yyyy-MM-dd:HH-mm>/<stream>.ts (start in server time).
    func catchupURL(_ streamId: String, _ p: Programme) -> String? {
        guard let s = p.serverStart, s.count >= 16 else { return nil }
        let date = String(s.prefix(10)), time = String(s.dropFirst(11).prefix(5)).replacingOccurrences(of: ":", with: "-")
        return "\(server)/timeshift/\(esc(user))/\(esc(pass))/\(p.minutes)/\(date):\(time)/\(streamId).ts"
    }
}

/// M3U playlists: #EXTINF lines with tvg-logo and group-title. Links under /movie/ become movies, the rest channels.
enum M3U {
    static func parse(_ text: String) -> (cats: [Category], channels: [Channel], movies: [Movie]) {
        var cats: [String: Category] = [:]
        var channels: [Channel] = []
        var movies: [Movie] = []
        var name = "", logo: String?, group = ""
        func attr(_ line: String, _ key: String) -> String? {
            guard let r = line.range(of: key + "=\"") else { return nil }
            let rest = line[r.upperBound...]
            guard let end = rest.firstIndex(of: "\"") else { return nil }
            let v = String(rest[..<end]); return v.isEmpty ? nil : v
        }
        var n = 0
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#EXTINF") {
                logo = attr(line, "tvg-logo"); group = attr(line, "group-title") ?? "—"
                name = line.split(separator: ",", maxSplits: 1, omittingEmptySubsequences: false).last.map { String($0).trimmingCharacters(in: .whitespaces) } ?? "—"
            } else if !line.isEmpty && !line.hasPrefix("#") {
                n += 1
                let cid = "g:" + group
                if cats[cid] == nil { cats[cid] = Category(id: cid, name: group) }
                if line.contains("/movie/") {
                    movies.append(Movie(id: "m\(n)", name: name, poster: logo, categoryId: cid, rating: nil, ext: (line as NSString).pathExtension, added: n, url: line))
                } else {
                    channels.append(Channel(id: "c\(n)", name: name, logo: logo, categoryId: cid, url: line))
                }
            }
        }
        let order = Array(cats.values).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        return (order, channels, movies)
    }
}
