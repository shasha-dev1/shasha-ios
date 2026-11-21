import Foundation

/// 1.0.3: everything the lists need that used to be recomputed on the main thread on every redraw
/// (measured on the owner's iPhone with 52,989 channels and 24,103 series). Built once per library load,
/// off the main thread; screens only read it.
struct LibraryIndex {
    /// Folded names for search (SearchRule.fold), same order as the library arrays.
    var channelSearch: [String] = []
    var movieSearch: [String] = []
    var showSearch: [String] = []
    /// Positions in the library arrays, already sorted.
    var moviesNewest: [Int] = [], moviesRating: [Int] = [], moviesName: [Int] = []
    var showsNewest: [Int] = [], showsRating: [Int] = [], showsName: [Int] = []
    /// Copies of the same title in other provider groups (CopyRule.key → positions).
    var movieCopies: [String: [Int]] = [:], showCopies: [String: [Int]] = [:]
    var movieKey: [String] = [], showKey: [String] = []
    /// Id → position.
    var channelPos: [String: Int] = [:], moviePos: [String: Int] = [:], showPos: [String: Int] = [:]

    static func build(channels: [Channel], movies: [Movie], shows: [Show]) -> LibraryIndex {
        var x = LibraryIndex()
        x.channelSearch = channels.map { SearchRule.fold($0.name) }
        x.movieSearch = movies.map { SearchRule.fold($0.name) }
        x.showSearch = shows.map { SearchRule.fold($0.name) }

        let mi = Array(movies.indices), si = Array(shows.indices)
        x.moviesNewest = mi.sorted { movies[$0].added > movies[$1].added }
        x.moviesRating = mi.sorted { ratingValue(movies[$0].rating) > ratingValue(movies[$1].rating) }
        x.moviesName = mi.sorted { movies[$0].name.localizedStandardCompare(movies[$1].name) == .orderedAscending }
        x.showsNewest = si.sorted { shows[$0].updated > shows[$1].updated }
        x.showsRating = si.sorted { ratingValue(shows[$0].rating) > ratingValue(shows[$1].rating) }
        x.showsName = si.sorted { shows[$0].name.localizedStandardCompare(shows[$1].name) == .orderedAscending }

        x.movieKey = movies.map { CopyRule.key($0.name) }
        x.showKey = shows.map { CopyRule.key($0.name) }
        for (i, k) in x.movieKey.enumerated() where !k.isEmpty { x.movieCopies[k, default: []].append(i) }
        for (i, k) in x.showKey.enumerated() where !k.isEmpty { x.showCopies[k, default: []].append(i) }

        x.channelPos = Dictionary(channels.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { a, _ in a })
        x.moviePos = Dictionary(movies.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { a, _ in a })
        x.showPos = Dictionary(shows.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { a, _ in a })
        return x
    }

    func movieOrder(_ s: VodSort) -> [Int] { s == .newest ? moviesNewest : s == .rating ? moviesRating : moviesName }
    func showOrder(_ s: VodSort) -> [Int] { s == .newest ? showsNewest : s == .rating ? showsRating : showsName }
}

/// One list request (search text, group, sort, "my list"). Run off the main thread; the screen keeps showing the
/// previous result until the new one is ready, and a newer request cancels the older one so it can never overwrite it.
enum ListQuery {
    static func movies(_ all: [Movie], _ ix: LibraryIndex, query: String, cat: String?, sort: VodSort,
                       favorites: Set<String>?, blocked: Set<String>) -> [Movie] {
        let q = SearchRule.fold(query.trimmingCharacters(in: .whitespaces))
        var out: [Movie] = []
        for i in ix.movieOrder(sort) {
            let m = all[i]
            if blocked.contains(m.categoryId) { continue }
            if let cat, m.categoryId != cat { continue }
            if let favorites, !favorites.contains("movie:" + m.id) { continue }
            if !q.isEmpty && !ix.movieSearch[i].contains(q) { continue }
            out.append(m)
            if out.count % 4000 == 0 && Task.isCancelled { return [] }
        }
        return out
    }

    static func shows(_ all: [Show], _ ix: LibraryIndex, query: String, cat: String?, sort: VodSort,
                      favorites: Set<String>?, blocked: Set<String>) -> [Show] {
        let q = SearchRule.fold(query.trimmingCharacters(in: .whitespaces))
        var out: [Show] = []
        for i in ix.showOrder(sort) {
            let s = all[i]
            if blocked.contains(s.categoryId) { continue }
            if let cat, s.categoryId != cat { continue }
            if let favorites, !favorites.contains("show:" + s.id) { continue }
            if !q.isEmpty && !ix.showSearch[i].contains(q) { continue }
            out.append(s)
            if out.count % 4000 == 0 && Task.isCancelled { return [] }
        }
        return out
    }

    /// Positions of channels matching (group filter already applied by `keep`).
    static func channels(_ all: [Channel], _ ix: LibraryIndex, query: String, keep: (Channel) -> Bool) -> [Channel] {
        let q = SearchRule.fold(query.trimmingCharacters(in: .whitespaces))
        var out: [Channel] = []
        for (i, c) in all.enumerated() where keep(c) && (q.isEmpty || ix.channelSearch[i].contains(q)) {
            out.append(c)
        }
        return out
    }
}
