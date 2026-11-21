import Foundation

/// 1.0.9: TMDB (themoviedb.org) for titles that are in the viewer's own library: backdrop, overview, genres, year,
/// rating. The key is the viewer's own (Settings → TMDB), kept in the Keychain; nothing works without it and no key
/// is built into the app. A v4 read-access token (starts with "eyJ", three parts) is sent as a Bearer header,
/// a v3 key (32 hex characters) as api_key — the same rule as the TV app.
/// Matches (and "no match") are cached on the phone so a title is looked up once.
enum TmdbKey {
    private static let item = "tmdb.key"
    static var value: String? { Keychain.get(item).flatMap { $0.isEmpty ? nil : $0 } }
    static func set(_ v: String?) { Keychain.set(v.map { $0.filter { !$0.isWhitespace } }, for: item) }
    static func isBearer(_ k: String) -> Bool { k.hasPrefix("eyJ") && k.filter { $0 == "." }.count == 2 }
    static func looksValid(_ k: String) -> Bool { isBearer(k) || k.range(of: "^[0-9a-fA-F]{32}$", options: .regularExpression) != nil }
    static func mask(_ k: String?) -> String { k.map { "••••" + $0.suffix(4) } ?? "غير مضاف" }
}

struct TmdbTitle: Codable, Identifiable, Equatable {
    enum Kind: String, Codable { case movie, tv }
    let kind: Kind
    let tmdbId: Int
    var id: String { "\(kind.rawValue):\(tmdbId)" }
    let name: String
    let originalName: String
    let year: Int?
    let overview: String?
    let poster: String?      // full image URL
    let backdrop: String?    // full image URL
    let rating: Double?
    var genres: [String] = []
}

enum TmdbError: LocalizedError {
    case noKey, badKey, rateLimited, http(Int), network(String)
    var errorDescription: String? {
        switch self {
        case .noKey: return "أضف مفتاح TMDB من الإعدادات."
        case .badKey: return "مفتاح TMDB مرفوض."
        case .rateLimited: return "TMDB طلب التمهّل قليلًا. حاول بعد دقيقة."
        case .http(let c): return "TMDB ردّ \(c)."
        case .network(let m): return "تعذّر الاتصال بـ TMDB: \(m)"
        }
    }
}

actor Tmdb {
    static let shared = Tmdb()
    private let api = "https://api.themoviedb.org/3"
    static let imageBase = "https://image.tmdb.org/t/p/"

    /// Arabic first (the app's language); English when TMDB has no Arabic overview.
    private let lang = "ar"

    // MARK: Cache (library title → match or "none"), one file for the phone

    private struct Entry: Codable { let title: TmdbTitle?; let at: Date }
    private var cache: [String: Entry] = [:]
    private var loaded = false
    private var dirty = false
    private var inFlight: [String: Task<TmdbTitle?, Error>] = [:]

    private var file: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?.appendingPathComponent("tmdb-matches.json")
    }
    private func load() {
        guard !loaded else { return }
        loaded = true
        if let f = file, let d = try? Data(contentsOf: f), let c = try? JSONDecoder().decode([String: Entry].self, from: d) { cache = c }
    }
    private func persistSoon() {
        guard !dirty else { return }
        dirty = true
        Task { try? await Task.sleep(nanoseconds: 2_000_000_000); self.persist() }
    }
    private func persist() {
        dirty = false
        guard let f = file, let d = try? JSONEncoder().encode(cache) else { return }
        try? d.write(to: f, options: [.atomic])
    }
    func clearCache() { cache = [:]; persist() }

    // MARK: HTTP

    private func get(_ path: String, _ q: [String: String]) async throws -> [String: Any]? {
        guard let key = TmdbKey.value else { throw TmdbError.noKey }
        var c = URLComponents(string: api + path)
        var items = q.map { URLQueryItem(name: $0.key, value: $0.value) }
        if !TmdbKey.isBearer(key) { items.append(URLQueryItem(name: "api_key", value: key)) }
        c?.queryItems = items
        guard let url = c?.url else { return nil }
        var req = URLRequest(url: url, timeoutInterval: 20)
        if TmdbKey.isBearer(key) { req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        let data: Data, resp: URLResponse
        do { (data, resp) = try await URLSession.shared.data(for: req) } catch { throw TmdbError.network(error.localizedDescription) }
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        switch code {
        case 200: return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        case 404: return nil
        case 401: throw TmdbError.badKey
        case 429: throw TmdbError.rateLimited
        default: throw TmdbError.http(code)
        }
    }

    /// Settings "test key": one cheap authenticated call.
    func testKey() async throws { _ = try await get("/configuration", [:]) }

    // MARK: Parsing

    private static func image(_ p: Any?, _ size: String) -> String? {
        guard let s = p as? String, s.hasPrefix("/") else { return nil }
        return imageBase + size + s
    }
    private static func title(_ o: [String: Any], _ kind: TmdbTitle.Kind) -> TmdbTitle? {
        guard let id = o["id"] as? Int else { return nil }
        let name = (kind == .movie ? o["title"] : o["name"]) as? String ?? ""
        let orig = (kind == .movie ? o["original_title"] : o["original_name"]) as? String ?? name
        let date = (kind == .movie ? o["release_date"] : o["first_air_date"]) as? String ?? ""
        let ov = (o["overview"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return TmdbTitle(kind: kind, tmdbId: id, name: name, originalName: orig, year: Int(date.prefix(4)),
                         overview: (ov?.isEmpty ?? true) ? nil : ov, poster: image(o["poster_path"], "w342"),
                         backdrop: image(o["backdrop_path"], "w780"), rating: o["vote_average"] as? Double,
                         genres: (o["genres"] as? [[String: Any]])?.compactMap { $0["name"] as? String } ?? [])
    }

    // MARK: Library matching

    /// TMDB title for a library item. `providerId`: TMDB id the provider sent, if any (used first).
    /// nil = no confident match (cached; tried again after 7 days).
    func match(kind: TmdbTitle.Kind, providerName: String, providerId: String? = nil) async throws -> TmdbTitle? {
        load()
        let clean = TmdbRule.split(providerName).title
        let year = TmdbRule.year(clean)
        let ck = "\(kind.rawValue)|\(TmdbRule.libraryKey(providerName))|\(year ?? 0)"
        if let e = cache[ck], e.title != nil || Date().timeIntervalSince(e.at) < 7 * 86400 { return e.title }
        if let t = inFlight[ck] { return try await t.value }
        let task = Task<TmdbTitle?, Error> {
            var id = providerId.flatMap { Int($0.trimmingCharacters(in: .whitespaces)) }.flatMap { $0 > 0 ? $0 : nil }
            if id == nil {
                for term in TmdbRule.searchTerms(clean) {
                    guard let json = try await get("/search/\(kind.rawValue)", ["query": term, "language": lang]) else { continue }
                    let cands = (json["results"] as? [[String: Any]] ?? []).compactMap { Self.title($0, kind) }
                        .map { TmdbRule.Candidate(id: $0.tmdbId, name: $0.name, originalName: $0.originalName, year: $0.year) }
                    if let found = TmdbRule.choose(cands, term: term, year: year) { id = found; break }
                }
            }
            guard let id else { return nil }
            return try await details(kind: kind, id: id)
        }
        inFlight[ck] = task
        defer { inFlight[ck] = nil }
        do {
            let r = try await task.value
            cache[ck] = Entry(title: r, at: Date()); persistSoon()
            return r
        } catch {
            throw error          // network / key errors are not cached as "no match"
        }
    }

    /// Details in Arabic, overview in English when there is no Arabic one.
    func details(kind: TmdbTitle.Kind, id: Int) async throws -> TmdbTitle? {
        guard let ar = try await get("/\(kind.rawValue)/\(id)", ["language": lang]), var t = Self.title(ar, kind) else { return nil }
        if t.overview == nil, let en = try? await get("/\(kind.rawValue)/\(id)", ["language": "en-US"]), let te = Self.title(en, kind), let ov = te.overview {
            t = TmdbTitle(kind: t.kind, tmdbId: t.tmdbId, name: t.name, originalName: t.originalName, year: t.year, overview: ov,
                          poster: t.poster, backdrop: t.backdrop, rating: t.rating, genres: t.genres)
        }
        return t
    }

    // MARK: Lists (trending / popular)

    enum ListKind: String { case trending, popular }
    private var lists: [String: (at: Date, items: [TmdbTitle])] = [:]

    /// Trending this week or popular, movies or series, in Arabic. Cached for 6 hours.
    func list(_ l: ListKind, _ kind: TmdbTitle.Kind) async throws -> [TmdbTitle] {
        let k = "\(l.rawValue)|\(kind.rawValue)"
        if let c = lists[k], Date().timeIntervalSince(c.at) < 6 * 3600 { return c.items }
        let path = l == .trending ? "/trending/\(kind.rawValue)/week" : "/\(kind.rawValue)/popular"
        guard let json = try await get(path, ["language": lang]) else { return [] }
        let items = (json["results"] as? [[String: Any]] ?? []).compactMap { Self.title($0, kind) }
        lists[k] = (Date(), items)
        return items
    }
}
