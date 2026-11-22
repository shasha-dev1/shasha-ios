import SwiftUI

/// Poster / logo with a placeholder. 1.0.5: decoded at display size (ImagePipeline) unless switched off for comparison.
struct Art: View {
    let url: String?
    var fit = false
    /// Longest side in pixels to decode (≈ shown size × screen scale).
    var maxPixel: Int? = nil
    var body: some View {
        if ImagePipeline.enabled, let u = url.flatMap(URL.init(string:)) {
            SizedArt(url: u, fit: fit, maxPixel: maxPixel ?? (fit ? 300 : 600))
        } else {
            AsyncImage(url: url.flatMap(URL.init(string:))) { phase in
                switch phase {
                case .success(let img): if fit { img.resizable().scaledToFit() } else { img.resizable().scaledToFill() }
                default: ArtPlaceholder()
                }
            }
        }
    }
}

struct ArtPlaceholder: View {
    var body: some View { ZStack { Theme.surface; Image(systemName: "photo").foregroundStyle(.secondary) } }
}

private struct SizedArt: View {
    let url: URL
    let fit: Bool
    let maxPixel: Int
    @State private var img: UIImage?

    init(url: URL, fit: Bool, maxPixel: Int) {
        self.url = url; self.fit = fit; self.maxPixel = maxPixel
        _img = State(initialValue: ImagePipeline.shared.cached(url, maxPixel: maxPixel))
    }

    var body: some View {
        Group {
            if let img {
                if fit { Image(uiImage: img).resizable().scaledToFit() } else { Image(uiImage: img).resizable().scaledToFill() }
            } else { ArtPlaceholder() }
        }
        .task(id: url) {
            if img == nil { img = await ImagePipeline.shared.load(url, maxPixel: maxPixel) }
        }
    }
}

struct PosterCard: View {
    let title: String
    let poster: String?
    var progress: Double? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Color.clear
                .aspectRatio(2 / 3, contentMode: .fit)
                .frame(maxWidth: .infinity)
                .overlay { PosterImage(url: poster, title: title) }
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(alignment: .bottom) {
                    if let p = progress { GeometryReader { g in Capsule().fill(Theme.accent).frame(width: g.size.width * p, height: 4) }.frame(height: 4).padding(6) }
                }
            Text(TmdbRule.split(title).title).font(.caption).lineLimit(2).multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct SectionTitle: View {
    let text: String
    var body: some View { Text(text).font(.title3.bold()).padding(.horizontal) }
}
struct SubTitle: View {
    let text: String
    var body: some View { Text(text).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary).padding(.horizontal) }
}

/// Horizontal row with a title (Home screen).
struct Shelf<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionTitle(text: title)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 12) { content }.padding(.horizontal)
            }
        }
    }
}

struct LoadingOrError: View {
    @EnvironmentObject var library: Library
    var body: some View {
        if library.loading && !library.hasData { ProgressView("جارٍ التحميل…").padding() }
        else if let e = library.error, !library.hasData {
            VStack(spacing: 12) {
                Text(e).multilineTextAlignment(.center)
                Button("إعادة المحاولة") { Task { await library.reload() } }.buttonStyle(.borderedProminent)
            }.padding()
        } else if library.loading {
            // 1.0.4: the saved lists stay usable while the refresh runs.
            Label("يتم تحديث القائمة…", systemImage: "arrow.triangle.2.circlepath").font(.footnote).foregroundStyle(.secondary).padding(.vertical, 4)
        } else if let e = library.refreshError {
            VStack(spacing: 6) {
                Text("تعذّر التحديث: \(e)").font(.footnote).multilineTextAlignment(.center)
                if let t = library.lastSuccess { Text("المعروض محفوظ من \(LastUpdate.text(t))").font(.caption).foregroundStyle(.secondary) }
                Button("إعادة المحاولة") { Task { await library.reload() } }.font(.footnote).buttonStyle(.bordered)
            }
            .padding(10).frame(maxWidth: .infinity).background(Theme.surface, in: RoundedRectangle(cornerRadius: 10)).padding(.horizontal)
        }
    }
}

enum LastUpdate {
    static func text(_ d: Date) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "ar"); f.doesRelativeDateFormatting = true
        f.dateStyle = .short; f.timeStyle = .short
        return f.string(from: d)
    }
}

/// Category chips (horizontal) used by Movies and Series.
/// 1.4.3: names shown without the provider's decoration, a «كل المجموعات» list with search and counts, and the
/// row scrolls to the selected group.
struct Chips: View {
    let cats: [Category]
    @Binding var selected: String?
    var locked: Set<String> = []
    /// 1.6.0: section for pinning in the list (nil = no pinning).
    var section: GroupSection? = nil
    /// Titles per group id, counted off the main thread when the list opens.
    var counts: (() async -> [String: Int])? = nil
    @EnvironmentObject private var library: Library
    @State private var listOpen = false
    private var pinnedIds: Set<String> { section.map { Set(library.pinned($0)) } ?? [] }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack {
                    if cats.count > 6 {
                        // 1.6.0: a named button (the icon alone wasn't recognisable).
                        Button { listOpen = true } label: {
                            Label("المجموعات", systemImage: "square.grid.2x2")
                                .font(.subheadline.weight(.semibold)).padding(.horizontal, 12).padding(.vertical, 8)
                                .background(Theme.surface, in: Capsule()).foregroundStyle(Theme.accent)
                        }
                    }
                    chip("الكل", nil).id("all")
                    ForEach(cats) { c in
                        let pin = pinnedIds.contains(c.id) ? "📌 " : ""
                        chip(pin + (locked.contains(c.id) ? "🔒 " : "") + Self.short(Self.name(c)), c.id).id(c.id)
                    }
                }.padding(.horizontal)
            }
            .onAppear { scroll(proxy, animated: false) }
            .onChange(of: selected) { _ in scroll(proxy, animated: true) }
        }
        .sheet(isPresented: $listOpen) {
            CategoryListSheet(cats: cats, selected: $selected, locked: locked, counts: counts, section: section)
        }
    }

    static func name(_ c: Category) -> String { CategoryNameRule.display(c.name) }
    /// Long names are shortened in the row only; the list shows them in full.
    static func short(_ n: String) -> String { n.count > 26 ? String(n.prefix(24)) + "…" : n }

    private func scroll(_ proxy: ScrollViewProxy, animated: Bool) {
        let target: String = selected ?? "all"
        if animated { withAnimation(.easeInOut(duration: 0.25)) { proxy.scrollTo(target, anchor: .center) } }
        else { proxy.scrollTo(target, anchor: .center) }
    }

    private func chip(_ t: String, _ id: String?) -> some View {
        Button(t) { selected = id }
            .font(.subheadline.weight(.semibold)).lineLimit(1)
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(selected == id ? Theme.accent : Theme.surface, in: Capsule())
            .foregroundStyle(selected == id ? Color.black : Color.white)
    }
}

/// All groups in one list: search (Arabic letters folded the same way as title search), count per group.
struct CategoryListSheet: View {
    let cats: [Category]
    @Binding var selected: String?
    let locked: Set<String>
    let counts: (() async -> [String: Int])?
    var section: GroupSection? = nil
    @EnvironmentObject private var library: Library
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var n: [String: Int] = [:]

    private var shown: [Category] {
        let q = SearchRule.fold(query.trimmingCharacters(in: .whitespaces))
        guard !q.isEmpty else { return cats }
        return cats.filter { SearchRule.matches(SearchRule.fold(Chips.name($0) + " " + $0.name), q) }
    }

    var body: some View {
        NavigationStack {
            List {
                if query.isEmpty { row("الكل", nil, n.values.reduce(0, +)) }
                if query.isEmpty, let section {
                    let pins = library.pinned(section).compactMap { id in cats.first { $0.id == id } }
                    if !pins.isEmpty {
                        Section("المثبتة") { ForEach(pins) { c in row("📌 " + Chips.name(c), c.id, n[c.id]) } }
                    }
                }
                Section(query.isEmpty ? "كل المجموعات — اسحب أي مجموعة لتثبيتها" : "النتائج") {
                    ForEach(shown) { c in row(Chips.name(c), c.id, n[c.id]) }
                }
                if shown.isEmpty { Text("لا توجد مجموعة بهذا الاسم").foregroundStyle(.secondary) }
            }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "ابحث عن مجموعة")
            .navigationTitle("المجموعات (\(cats.count))").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("إغلاق") { dismiss() } } }
            .task { if let counts { n = await counts() } }
        }
        .presentationDetents([.medium, .large])
    }

    private func row(_ title: String, _ id: String?, _ count: Int?) -> some View {
        Button { selected = id; dismiss() } label: {
            HStack {
                if let id, locked.contains(id) { Image(systemName: "lock.fill").foregroundStyle(.secondary) }
                Text(title).foregroundStyle(.primary).lineLimit(2)
                Spacer()
                if let count, count > 0 { Text(count.formatted()).font(.caption.monospacedDigit()).foregroundStyle(.secondary) }
                if selected == id { Image(systemName: "checkmark").foregroundStyle(Theme.accent) }
            }
        }
        .swipeActions(edge: .leading) {
            if let id, let section {
                let on = library.pinned(section).contains(id)
                Button { library.togglePin(id, section) } label: { Label(on ? "إلغاء التثبيت" : "تثبيت", systemImage: on ? "pin.slash" : "pin") }
                    .tint(Theme.accent)
            }
        }
    }
}

// MARK: - 1.0.9 shared detail components

/// "1:02:15" / "42:07" for resume points.
enum Clock {
    static func text(_ seconds: Double) -> String {
        let s = Int(max(0, seconds)), h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
    }
}

/// Backdrop (when there is one) with the poster and the title over its lower edge.
struct DetailHeader: View {
    let backdrop: String?
    let poster: String?
    let title: String
    let meta: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .bottom) {
                Group {
                    if let b = backdrop { Art(url: b, maxPixel: 1400) } else { LinearGradient(colors: [Theme.surface, Theme.bg], startPoint: .top, endPoint: .bottom) }
                }
                .frame(height: 210).frame(maxWidth: .infinity).clipped()
                LinearGradient(colors: [.clear, Theme.bg.opacity(0.85), Theme.bg], startPoint: .top, endPoint: .bottom).frame(height: 120)
            }
            HStack(alignment: .bottom, spacing: 14) {
                PosterImage(url: poster, title: title).frame(width: 96, height: 144)
                    .shadow(color: .black.opacity(0.4), radius: 8, y: 4)
                VStack(alignment: .leading, spacing: 6) {
                    Text(title).font(.title2.bold()).lineLimit(3).minimumScaleFactor(0.75).multilineTextAlignment(.leading)
                    if !meta.isEmpty { Text(meta).font(.subheadline).foregroundStyle(Theme.accent).lineLimit(2) }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal).padding(.top, -64)
        }
    }
}

/// Poster with a tidy placeholder (first letter of the title) when there is no picture.
struct PosterImage: View {
    let url: String?
    let title: String
    var body: some View {
        Group {
            if let url, !url.isEmpty { Art(url: url) } else { LetterPlaceholder(title: title) }
        }
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

struct LetterPlaceholder: View {
    let title: String
    var body: some View {
        ZStack {
            Theme.surface2
            Text(String(TmdbRule.split(title).title.trimmingCharacters(in: .whitespaces).prefix(1)).uppercased())
                .font(.system(size: 34, weight: .bold, design: .rounded)).foregroundStyle(Theme.accent.opacity(0.85))
        }
    }
}

struct CopyRow: View {
    let name: String
    let group: String?
    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(name).lineLimit(2).foregroundStyle(.primary).multilineTextAlignment(.leading)
                if let group, !group.isEmpty { Text(CategoryNameRule.display(group)).font(.caption).foregroundStyle(.secondary) }
            }
            Spacer()
            Image(systemName: "chevron.left").font(.caption).foregroundStyle(.tertiary)
        }
        .padding(12).background(Theme.surface, in: RoundedRectangle(cornerRadius: 12))
    }
}

struct EpisodeRow: View {
    let episode: Episode
    let showName: String
    let progress: Double?
    let current: Bool
    let watched: Bool
    /// 1.4.2: TMDB name / overview / still for this episode, used when the provider sends none.
    var tmdb: Tmdb.EpisodeText? = nil
    /// Arabic machine translations (original → Arabic) for the season.
    var translated: [String: String] = [:]

    private var title: String {
        let t = episode.title.trimmingCharacters(in: .whitespaces)
        let series = TmdbRule.split(showName).title
        if t.isEmpty || TmdbRule.key(t) == TmdbRule.key(series) || TmdbRule.key(t).hasPrefix(TmdbRule.key(series)) && t.count < series.count + 12 {
            if let n = tmdb?.name, !n.isEmpty, TmdbRule.key(n) != TmdbRule.key("الحلقة \(episode.number)"),
               TmdbRule.key(n) != TmdbRule.key("Episode \(episode.number)") {
                return "\(episode.number). \(translated[n] ?? n)"
            }
            return "الحلقة \(episode.number)"
        }
        return t
    }

    /// Provider's plot first, TMDB's when the provider has none; the Arabic translation when there is one.
    private var plot: (text: String, machine: Bool)? {
        guard let p = episode.plot?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? tmdb?.overview else { return nil }
        if let a = translated[p] { return (a, true) }
        return (p, false)
    }

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                if let img = episode.image?.nilIfEmpty ?? tmdb?.still { Art(url: img, maxPixel: 400) } else { Theme.surface2 }
                Text("\(episode.number)").font(.headline.monospacedDigit()).foregroundStyle(.white)
                    .padding(6).background(.black.opacity(0.45), in: Circle())
            }
            .frame(width: 112, height: 63).clipShape(RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(title).font(.subheadline.weight(.semibold)).lineLimit(2).foregroundStyle(.primary).multilineTextAlignment(.leading)
                    if current { Badge(text: "الحالية", color: Theme.accent) }
                    else if watched { Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.teal).font(.caption) }
                }
                if let p = progress { ProgressView(value: p).tint(Theme.accent) }
                if let p = plot {
                    Text(p.text).font(.caption).foregroundStyle(.secondary).lineLimit(3).multilineTextAlignment(.leading)
                    if p.machine { Text("ترجمة آلية").font(.caption2).foregroundStyle(.tertiary) }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(current ? Theme.accent.opacity(0.12) : Theme.surface, in: RoundedRectangle(cornerRadius: 12))
    }
}

struct Badge: View {
    let text: String
    let color: Color
    var body: some View {
        Text(text).font(.caption2.weight(.bold)).padding(.horizontal, 7).padding(.vertical, 3)
            .background(color.opacity(0.2), in: Capsule()).foregroundStyle(color)
    }
}
