import Foundation

/// 1.0.4: the last good library of each playlist, saved on this phone, so the app shows it at once and refreshes in
/// the background. One file per playlist (Application Support/LibraryCache/<playlist id>.json), not backed up,
/// protected until the phone's first unlock. Xtream stream links are NOT stored (they contain the password):
/// they are rebuilt from the Keychain password when the file is read.
struct LibraryCache: Codable {
    static let format = 1
    var format = LibraryCache.format
    var savedAt: Date
    var liveCats: [C] = [], vodCats: [C] = [], seriesCats: [C] = []
    var channels: [Ch] = [], movies: [M] = [], shows: [S] = []
    /// Movies / series lists that were really received (not failed) when this copy was saved.
    var moviesReceived = true, showsReceived = true

    struct C: Codable { let id: String; let name: String }
    struct Ch: Codable { let id: String; let name: String; let logo: String?; let cat: String; let url: String?; let arch: Int }
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
    static func file(_ source: UUID) -> URL? { dir?.appendingPathComponent(source.uuidString + ".json") }

    /// Called off the main thread.
    static func save(_ c: LibraryCache, for source: UUID) throws {
        guard let f = file(source) else { return }
        let data = try JSONEncoder().encode(c)
        try data.write(to: f, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    /// Called off the main thread. nil when missing, unreadable or of another format.
    static func load(for source: UUID) -> LibraryCache? {
        guard let f = file(source), let d = try? Data(contentsOf: f),
              let c = try? JSONDecoder().decode(LibraryCache.self, from: d), c.format == format else { return nil }
        return c
    }

    static func remove(_ source: UUID) { if let f = file(source) { try? FileManager.default.removeItem(at: f) } }

    // MARK: Conversion

    init(savedAt: Date, xtream: Bool, liveCats: [Category], vodCats: [Category], seriesCats: [Category],
         channels: [Channel], movies: [Movie], shows: [Show], moviesReceived: Bool, showsReceived: Bool) {
        self.savedAt = savedAt
        self.liveCats = liveCats.map { C(id: $0.id, name: $0.name) }
        self.vodCats = vodCats.map { C(id: $0.id, name: $0.name) }
        self.seriesCats = seriesCats.map { C(id: $0.id, name: $0.name) }
        self.channels = channels.map { Ch(id: $0.id, name: $0.name, logo: $0.logo, cat: $0.categoryId, url: xtream ? nil : $0.url, arch: $0.archiveDays) }
        self.movies = movies.map { M(id: $0.id, name: $0.name, poster: $0.poster, cat: $0.categoryId, rating: $0.rating, ext: $0.ext, added: $0.added, url: xtream ? nil : $0.url) }
        self.shows = shows.map { S(id: $0.id, name: $0.name, poster: $0.poster, cat: $0.categoryId, rating: $0.rating, plot: $0.plot, updated: $0.updated) }
        self.moviesReceived = moviesReceived; self.showsReceived = showsReceived
    }

    /// Back to the app's models; `x` rebuilds Xtream links.
    func restore(_ x: Xtream?) -> (lc: [Category], vc: [Category], sc: [Category], ch: [Channel], mv: [Movie], sh: [Show]) {
        let cat = { (c: C) in Category(id: c.id, name: c.name) }
        let ch = channels.map { c in
            Channel(id: c.id, name: c.name, logo: c.logo, categoryId: c.cat, url: x?.liveURL(c.id) ?? c.url ?? "", archiveDays: c.arch)
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
