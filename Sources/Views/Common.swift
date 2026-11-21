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
            Art(url: poster)
                .aspectRatio(2 / 3, contentMode: .fill)
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(alignment: .bottom) {
                    if let p = progress { GeometryReader { g in Capsule().fill(Theme.accent).frame(width: g.size.width * p, height: 4) }.frame(height: 4).padding(6) }
                }
            Text(title).font(.caption).lineLimit(2).multilineTextAlignment(.leading)
        }
    }
}

/// Horizontal row with a title (Home screen).
struct Shelf<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.title3.bold()).padding(.horizontal)
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
