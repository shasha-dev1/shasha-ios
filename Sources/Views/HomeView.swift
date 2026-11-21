import SwiftUI

/// Home: one search over everything, then Continue watching, favourite channels, my list and what's new.
struct HomeView: View {
    @EnvironmentObject var library: Library
    @EnvironmentObject var epg: EPG
    @Binding var play: PlayItem?
    @State private var query = ""
    @State private var tick = 0

    var body: some View {
        NavigationStack {
            ScrollView {
                LoadingOrError()
                let _ = (tick, library.groupsTick)
                if query.trimmingCharacters(in: .whitespaces).isEmpty { shelves } else { results }
            }
            .searchable(text: $query, prompt: "ابحث في القنوات والأفلام والمسلسلات")
            .navigationTitle("الرئيسية")
            .refreshable { await library.reload() }
            .onAppear { tick += 1; Perf.shared.firstScreen("الرئيسية") }
            .onChange(of: query) { _ in Perf.shared.mark("بحث الرئيسية") }
            .onChange(of: play?.id) { _ in tick += 1 }
        }
    }

    // MARK: Shelves

    @ViewBuilder private var shelves: some View {
        let okM = library.allowedFilter(.movies)
        let okS = library.allowedFilter(.series)
        let okL = library.allowedFilter(.live)
        VStack(alignment: .leading, spacing: 22) {
            let cont = Perf.shared.measure("الرئيسية: متابعة المشاهدة") { continueItems(okM, okS) }
            if !cont.isEmpty {
                Shelf(title: "متابعة المشاهدة") {
                    ForEach(cont) { c in
                        NavigationLink { c.destination } label: { PosterCard(title: c.title, poster: c.poster, progress: c.progress).frame(width: 112) }
                            .buttonStyle(.plain)
                    }
                }
            }

            let favCh = Perf.shared.measure("الرئيسية: القنوات المفضلة") { library.channels.filter { Store.isFavorite($0.id) && okL($0.categoryId) } }
            if !favCh.isEmpty {
                Shelf(title: "قنواتي المفضلة") {
                    ForEach(Array(favCh.prefix(30).enumerated()), id: \.element.id) { i, ch in
                        Button { play = .live(list: favCh, index: i) } label: {
                            VStack(spacing: 6) {
                                Art(url: ch.logo, fit: true).frame(width: 96, height: 60).padding(6)
                                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: 10))
                                Text(ch.name).font(.caption).lineLimit(1).frame(width: 108)
                                if let n = epg.now[ch.id] { Text(n.title).font(.caption2).foregroundStyle(.secondary).lineLimit(1).frame(width: 108) }
                            }
                        }
                        .buttonStyle(.plain)
                        .task { epg.load(ch, from: library.xtream) }
                    }
                }
            }

            let myMovies = Perf.shared.measure("الرئيسية: قائمتي (أفلام)") { library.movies.filter { okM($0.categoryId) && Store.isFavorite("movie:" + $0.id) } }
            let myShows = Perf.shared.measure("الرئيسية: قائمتي (مسلسلات)") { library.shows.filter { okS($0.categoryId) && Store.isFavorite("show:" + $0.id) } }
            if !myMovies.isEmpty || !myShows.isEmpty {
                Shelf(title: "قائمتي") {
                    ForEach(myShows.prefix(20)) { s in
                        NavigationLink { SeriesDetail(show: s, play: $play) } label: { PosterCard(title: s.name, poster: s.poster).frame(width: 112) }.buttonStyle(.plain)
                    }
                    ForEach(myMovies.prefix(20)) { m in
                        NavigationLink { MovieDetail(movie: m, play: $play) } label: { PosterCard(title: m.name, poster: m.poster).frame(width: 112) }.buttonStyle(.plain)
                    }
                }
            }

            let newShows = Perf.shared.measure("الرئيسية: مسلسلات حديثة") { library.shows.filter { okS($0.categoryId) }.sorted { $0.updated > $1.updated }.prefix(20) }
            if !newShows.isEmpty {
                Shelf(title: "مسلسلات حديثة التحديث") {
                    ForEach(newShows) { s in
                        NavigationLink { SeriesDetail(show: s, play: $play) } label: { PosterCard(title: s.name, poster: s.poster).frame(width: 112) }.buttonStyle(.plain)
                    }
                }
            }

            let newMovies = Perf.shared.measure("الرئيسية: أفلام حديثة") { library.movies.filter { okM($0.categoryId) }.sorted { $0.added > $1.added }.prefix(20) }
            if !newMovies.isEmpty {
                Shelf(title: "أفلام أضيفت حديثًا") {
                    ForEach(newMovies) { m in
                        NavigationLink { MovieDetail(movie: m, play: $play) } label: { PosterCard(title: m.name, poster: m.poster).frame(width: 112) }.buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(.vertical, 8)
    }

    struct ContinueItem: Identifiable {
        let id: String
        let title: String
        let poster: String?
        let progress: Double?
        let destination: AnyView
    }

    /// Recently played films (with a resume point) and series (any episode played), newest first.
    private func continueItems(_ okM: (String) -> Bool, _ okS: (String) -> Bool) -> [ContinueItem] {
        let moviesById = Dictionary(library.movies.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let showsById = Dictionary(library.shows.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var out: [ContinueItem] = []
        var seenShows = Set<String>()
        for key in Store.recent {
            if key.hasPrefix("movie:") {
                guard let m = moviesById[String(key.dropFirst(6))], okM(m.categoryId), Store.position(key) != nil else { continue }
                out.append(ContinueItem(id: key, title: m.name, poster: m.poster, progress: progress(key),
                                        destination: AnyView(MovieDetail(movie: m, play: $play))))
            } else if key.hasPrefix("ep:"), let sid = Store.show(forEpisode: key), let s = showsById[sid],
                      okS(s.categoryId), seenShows.insert(sid).inserted {
                out.append(ContinueItem(id: "show:" + sid, title: s.name, poster: s.poster, progress: progress(key),
                                        destination: AnyView(SeriesDetail(show: s, play: $play))))
            }
            if out.count >= 20 { break }
        }
        return out
    }

    // MARK: Search

    @ViewBuilder private var results: some View {
        let q = query.trimmingCharacters(in: .whitespaces)
        let okM = library.allowedFilter(.movies)
        let okS = library.allowedFilter(.series)
        let okL = library.allowedFilter(.live)
        let (ch, mv, sh) = Perf.shared.measure("بحث الرئيسية", "\(q.count) حرف") { (
            Array(library.channels.lazy.filter { okL($0.categoryId) && $0.name.localizedCaseInsensitiveContains(q) }.prefix(40)),
            Array(library.movies.lazy.filter { okM($0.categoryId) && $0.name.localizedCaseInsensitiveContains(q) }.prefix(40)),
            Array(library.shows.lazy.filter { okS($0.categoryId) && $0.name.localizedCaseInsensitiveContains(q) }.prefix(40))
        ) }
        VStack(alignment: .leading, spacing: 22) {
            if ch.isEmpty && mv.isEmpty && sh.isEmpty {
                Text("لا توجد نتائج لـ «\(q)».").foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(.top, 40)
            }
            if !sh.isEmpty {
                Shelf(title: "مسلسلات (\(sh.count))") {
                    ForEach(sh) { s in
                        NavigationLink { SeriesDetail(show: s, play: $play) } label: { PosterCard(title: s.name, poster: s.poster).frame(width: 112) }.buttonStyle(.plain)
                    }
                }
            }
            if !mv.isEmpty {
                Shelf(title: "أفلام (\(mv.count))") {
                    ForEach(mv) { m in
                        NavigationLink { MovieDetail(movie: m, play: $play) } label: { PosterCard(title: m.name, poster: m.poster).frame(width: 112) }.buttonStyle(.plain)
                    }
                }
            }
            if !ch.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("قنوات (\(ch.count))").font(.title3.bold()).padding(.horizontal)
                    ForEach(Array(ch.enumerated()), id: \.element.id) { i, c in
                        Button { play = .live(list: ch, index: i) } label: {
                            HStack(spacing: 12) {
                                Art(url: c.logo, fit: true).frame(width: 56, height: 36).background(Theme.surface, in: RoundedRectangle(cornerRadius: 6))
                                Text(c.name).lineLimit(1).foregroundStyle(.primary)
                                Spacer()
                            }
                            .padding(.horizontal)
                        }
                    }
                }
            }
        }
        .padding(.vertical, 8)
    }
}
