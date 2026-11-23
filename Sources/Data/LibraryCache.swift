import Foundation
import CryptoKit

/// 1.0.4: the last good library of each playlist, saved on this phone, so the app shows it at once and refreshes in
/// the background. One file per playlist (Application Support/LibraryCache/<playlist id>.json), not backed up,
/// protected until the phone's first unlock. Xtream stream links are NOT stored (they contain the password):
/// they are rebuilt from the Keychain password when the file is read.
struct LibraryCache: Codable {
    /// 2 (1.1.1): written and read section by section (see save/load) — format 1 files are ignored (one refresh).
    static let format = 2
    var format = LibraryCache.format
    var savedAt: Date
    var liveCats: [C] = [], vodCats: [C] = [], seriesCats: [C] = []
    var channels: [Ch] = [], movies: [M] = [], shows: [S] = []
    /// Movies / series lists that were really received (not failed) when this copy was saved.
    var moviesReceived = true, showsReceived = true

    struct C: Codable { let id: String; let name: String }
    struct Ch: Codable { let id: String; let name: String; let logo: String?; let cat: String; let url: String?; let arch: Int
        /// match-guide: guide id (absent in files written before; decodes as nil)
        var epg: String? = nil }
    struct M: Codable { let id: String; let name: String; let poster: String?; let cat: String; let rating: String?; let ext: String; let added: Int; let url: String? }
    struct S: Codable { let id: String; let name: String; let poster: String?; let cat: String; let rating: String?; let plot: String?; let updated: Int }

    private static var dir: URL? {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        let d = base.appendingPathComponent("LibraryCache", isDirectory: true)
        if !FileManager.default.fileExists(atPath: d.path) {
            try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
            var v = URLResourceValues(); v.isExcludedFromBackup = true
            var dd = d; try? dd.setResourceValues(v)
        }
        return d
    }
    /// 1.0.5: the file belongs to the playlist AND its account (type, server, user name): a copy saved for one
    /// account is never shown for another, even under the same playlist entry. No password goes into the key.
    static func key(for s: Source) -> String {
        let id = "\(s.kind.rawValue)|\(s.server.lowercased())|\(s.username)"
        let h = SHA256.hash(data: Data(id.utf8)).map { String(format: "%02x", $0) }.joined().prefix(16)
        return s.id.uuidString + "-" + h
    }
    static func file(_ key: String) -> URL? { dir?.appendingPathComponent(key + ".json") }

    /// Called off the main thread. 1.1.1: each list is encoded on its own and appended to the file, so only one
    /// list's JSON exists in memory at a time (1.1.0: memory peaked 792 → 997 MB while the whole library was encoded).
    /// File: for each part, a 4-byte big-endian length then that part's JSON. Parts: header, 3 category lists,
    /// channels, movies, shows.
    static func save(_ c: LibraryCache, for key: String) throws {
        guard let f = file(key) else { return }
        let tmp = f.appendingPathExtension("tmp")
        FileManager.default.createFile(atPath: tmp.path, contents: nil, attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        let h = try FileHandle(forWritingTo: tmp)
        func part<T: Encodable>(_ v: T) throws {
            try autoreleasepool {
                let d = try JSONEncoder().encode(v)
                var n = UInt32(d.count).bigEndian
                h.write(Data(bytes: &n, count: 4)); h.write(d)
            }
        }
        do {
            try part(Header(format: c.format, savedAt: c.savedAt, moviesReceived: c.moviesReceived, showsReceived: c.showsReceived))
            try part(c.liveCats); try part(c.vodCats); try part(c.seriesCats)
            try part(c.channels); try part(c.movies); try part(c.shows)
            try h.close()
        } catch { try? h.close(); try? FileManager.default.removeItem(at: tmp); throw error }
        _ = try? FileManager.default.replaceItemAt(f, withItemAt: tmp)
        if FileManager.default.fileExists(atPath: tmp.path) { try FileManager.default.moveItem(at: tmp, to: f) }
    }

    private struct Header: Codable { let format: Int; let savedAt: Date; let moviesReceived: Bool; let showsReceived: Bool }

    /// Called off the main thread. nil when missing, unreadable or of another format.
    static func load(for key: String) -> LibraryCache? {
        let t0 = Perf.now()
        guard let f = file(key), let d = try? Data(contentsOf: f, options: .alwaysMapped) else { return nil }
        Perf.shared.record("المحفوظ: قراءة الملف", since: t0, ByteCountFormatter.string(fromByteCount: Int64(d.count), countStyle: .file))
        let t1 = Perf.now()
        var at = 0
        func part<T: Decodable>(_ t: T.Type) throws -> T {
            try autoreleasepool {
                guard at + 4 <= d.count else { throw CocoaError(.fileReadCorruptFile) }
                let n = d[d.startIndex + at ..< d.startIndex + at + 4].reduce(0) { ($0 << 8) | Int($1) }
                at += 4
                guard n >= 0, at + n <= d.count else { throw CocoaError(.fileReadCorruptFile) }
                let v = try JSONDecoder().decode(T.self, from: d[d.startIndex + at ..< d.startIndex + at + n])
                at += n
                return v
            }
        }
        do {
            let h = try part(Header.self)
            guard h.format == format else { return nil }
            var c = LibraryCache(savedAt: h.savedAt)
            c.moviesReceived = h.moviesReceived; c.showsReceived = h.showsReceived
            c.liveCats = try part([C].self); c.vodCats = try part([C].self); c.seriesCats = try part([C].self)
            c.channels = try part([Ch].self); c.movies = try part([M].self); c.shows = try part([S].self)
            Perf.shared.record("المحفوظ: تحليل JSON", since: t1)
            return c
        } catch { return nil }
    }

    private init(savedAt: Date) { self.savedAt = savedAt }

    /// Every saved copy of this playlist entry (all accounts it ever had).
    static func remove(_ source: UUID) {
        guard let d = dir, let names = try? FileManager.default.contentsOfDirectory(atPath: d.path) else { return }
        for n in names where n.hasPrefix(source.uuidString) { try? FileManager.default.removeItem(at: d.appendingPathComponent(n)) }
    }

    // MARK: Conversion

    init(savedAt: Date, xtream: Bool, liveCats: [Category], vodCats: [Category], seriesCats: [Category],
         channels: [Channel], movies: [Movie], shows: [Show], moviesReceived: Bool, showsReceived: Bool) {
        self.savedAt = savedAt
        self.liveCats = liveCats.map { C(id: $0.id, name: $0.name) }
        self.vodCats = vodCats.map { C(id: $0.id, name: $0.name) }
        self.seriesCats = seriesCats.map { C(id: $0.id, name: $0.name) }
        self.channels = channels.map { Ch(id: $0.id, name: $0.name, logo: $0.logo, cat: $0.categoryId, url: xtream ? nil : $0.url, arch: $0.archiveDays, epg: $0.epgId) }
        self.movies = movies.map { M(id: $0.id, name: $0.name, poster: $0.poster, cat: $0.categoryId, rating: $0.rating, ext: $0.ext, added: $0.added, url: xtream ? nil : $0.url) }
        self.shows = shows.map { S(id: $0.id, name: $0.name, poster: $0.poster, cat: $0.categoryId, rating: $0.rating, plot: $0.plot, updated: $0.updated) }
        self.moviesReceived = moviesReceived; self.showsReceived = showsReceived
    }

    /// Back to the app's models; `x` rebuilds Xtream links.
    func restore(_ x: Xtream?) -> (lc: [Category], vc: [Category], sc: [Category], ch: [Channel], mv: [Movie], sh: [Show]) {
        let cat = { (c: C) in Category(id: c.id, name: c.name) }
        let ch = channels.map { c in
            Channel(id: c.id, name: c.name, logo: c.logo, categoryId: c.cat, url: x?.liveURL(c.id) ?? c.url ?? "", archiveDays: c.arch, epgId: c.epg)
        }
        let mv = movies.map { m in
            Movie(id: m.id, name: m.name, poster: m.poster, categoryId: m.cat, rating: m.rating, ext: m.ext, added: m.added,
                  url: x?.movieURL(m.id, m.ext) ?? m.url ?? "")
        }
        let sh = shows.map { s in
            Show(id: s.id, name: s.name, poster: s.poster, categoryId: s.cat, rating: s.rating, plot: s.plot, updated: s.updated)
        }
        return (liveCats.map(cat), vodCats.map(cat), seriesCats.map(cat), ch, mv, sh)
    }
}
