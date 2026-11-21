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
struct Chips: View {
    let cats: [Category]
    @Binding var selected: String?
    var locked: Set<String> = []
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack {
                chip("الكل", nil)
                ForEach(cats) { chip(locked.contains($0.id) ? "🔒 " + $0.name : $0.name, $0.id) }
            }.padding(.horizontal)
        }
    }
    private func chip(_ t: String, _ id: String?) -> some View {
        Button(t) { selected = id }
            .font(.subheadline.weight(.semibold))
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(selected == id ? Theme.accent : Theme.surface, in: Capsule())
            .foregroundStyle(selected == id ? Color.black : Color.white)
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
                if let group, !group.isEmpty { Text(group).font(.caption).foregroundStyle(.secondary) }
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

    private var title: String {
        let t = episode.title.trimmingCharacters(in: .whitespaces)
        let series = TmdbRule.split(showName).title
        if t.isEmpty || TmdbRule.key(t) == TmdbRule.key(series) || TmdbRule.key(t).hasPrefix(TmdbRule.key(series)) && t.count < series.count + 12 {
            return "الحلقة \(episode.number)"
        }
        return t
    }

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                if let img = episode.image, !img.isEmpty { Art(url: img, maxPixel: 400) } else { Theme.surface2 }
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
                if let plot = episode.plot, !plot.isEmpty { Text(plot).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
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
