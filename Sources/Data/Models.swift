import Foundation

/// A playlist the viewer added: an Xtream account or an M3U link. The password lives in the Keychain.
enum SourceKind: String, Codable { case xtream, m3u }

struct Source: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var name: String
    var kind: SourceKind
    /// Xtream: server base (scheme://host:port). M3U: the playlist link.
    var server: String
    var username: String = ""
}

struct Category: Identifiable, Hashable {
    let id: String
    let name: String
}

struct Channel: Identifiable, Hashable {
    let id: String
    let name: String
    let logo: String?
    let categoryId: String
    let url: String
    /// Catch-up days kept by the provider (0 = none).
    var archiveDays: Int = 0
    /// Guide id of the channel (Xtream epg_channel_id), for the match-guide report. nil when the provider sends none.
    var epgId: String? = nil
}

/// One programme of a channel's guide.
struct Programme: Identifiable, Hashable {
    var id: String { "\(start.timeIntervalSince1970)-\(title)" }
    let title: String
    let detail: String?
    let start: Date
    let end: Date
    /// Start time as the server wrote it ("yyyy-MM-dd HH:mm:ss", server time) — used for catch-up links.
    let serverStart: String?
    let hasArchive: Bool
    var isNow: Bool { start <= Date() && Date() < end }
    var isPast: Bool { end <= Date() }
    var minutes: Int { max(1, Int(end.timeIntervalSince(start) / 60)) }
}

struct Movie: Identifiable, Hashable {
    let id: String
    let name: String
    let poster: String?
    let categoryId: String
    let rating: String?
    let ext: String
    let added: Int
    let url: String
}

struct Show: Identifiable, Hashable {
    let id: String
    let name: String
    let poster: String?
    let categoryId: String
    let rating: String?
    let plot: String?
    let updated: Int
}

struct Episode: Identifiable, Hashable {
    let id: String
    let title: String
    let season: Int
    let number: Int
    let ext: String
    let plot: String?
    let image: String?
    /// Provider's ffprobe summary for this file (empty when the provider sends none).
    var probe: [String] = []
}

struct MovieInfo {
    /// Provider's ffprobe summary (empty when the provider sends none).
    var probe: [String] = []
    var plot: String?
    var genre: String?
    var year: String?
    var duration: String?
    var backdrop: String?
    /// YouTube video id or link of the trailer, if the provider gives one.
    var trailer: String?
    /// TMDB id the provider sent with the film, if any (1.0.9: used before a name search).
    var tmdbId: String?

    /// Link that opens the trailer in YouTube (app or web).
    var trailerURL: URL? {
        guard let t = trailer?.trimmingCharacters(in: .whitespaces), !t.isEmpty else { return nil }
        if t.hasPrefix("http") { return URL(string: t) }
        return URL(string: "https://www.youtube.com/watch?v=" + t)
    }
}

/// What is on a live channel now (Xtream short EPG).
struct EPGNow {
    let title: String
    let start: Date
    let end: Date
    let next: String?
    var progress: Double {
        let total = max(1, end.timeIntervalSince(start))
        return max(0, min(1, Date().timeIntervalSince(start) / total))
    }
}

/// Sort order for movies and series.
enum VodSort: String, CaseIterable {
    case newest = "الأحدث"
    case rating = "الأعلى تقييمًا"
    case name = "أبجدي"
}

func ratingValue(_ s: String?) -> Double { Double(s ?? "") ?? 0 }

/// Loose JSON helpers: Xtream servers send numbers as strings and strings as numbers.
enum J {
    static func s(_ v: Any?) -> String? {
        switch v {
        case let x as String: return x.isEmpty ? nil : x
        case let x as NSNumber: return x.stringValue
        default: return nil
        }
    }
    static func i(_ v: Any?) -> Int { Int(s(v) ?? "") ?? Int(Double(s(v) ?? "") ?? 0) }
}
