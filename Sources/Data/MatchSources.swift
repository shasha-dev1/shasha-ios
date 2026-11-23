import Foundation

/// 1.8.6: imported fixtures / broadcaster files and the owner's manual links, kept on this phone only
/// (Application Support, not sent anywhere). Same format and limits as the TV (docs/MATCH-SOURCES.md).
enum MatchSourceFiles {
    static let maxFiles = 6
    static let maxBytes = 5 * 1_048_576

    struct Item { let file: String; let source: MatchSourcesRule.ExtSource }

    private static var base: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
    }
    private static var dir: URL? {
        guard let b = base?.appendingPathComponent("match-sources", isDirectory: true) else { return nil }
        try? FileManager.default.createDirectory(at: b, withIntermediateDirectories: true)
        return b
    }
    private static var manualURL: URL? { base?.appendingPathComponent("match-manual.json") }

    /// Every kept file that still reads (a broken one is skipped, never deleted silently).
    static func list() -> [Item] {
        guard let d = dir, let names = try? FileManager.default.contentsOfDirectory(atPath: d.path) else { return [] }
        return names.filter { $0.hasSuffix(".json") }.sorted().compactMap { n in
            guard let data = try? Data(contentsOf: d.appendingPathComponent(n)),
                  let at = (try? FileManager.default.attributesOfItem(atPath: d.appendingPathComponent(n).path))?[.modificationDate] as? Date,
                  let s = try? MatchSourcesRule.parse(data, now: Int64(at.timeIntervalSince1970 * 1000)) else { return nil }
            return Item(file: n, source: s)
        }
    }

    enum Failure: Error { case tooBig, tooMany, bad(String), io(String)
        var text: String {
            switch self {
            case .tooBig: return "الملف أكبر من 5 MB"
            case .tooMany: return "الحد \(MatchSourceFiles.maxFiles) ملفات — احذف ملفًا أولًا"
            case .bad(let r): return "الملف غير صالح: " + r
            case .io(let r): return r
            }
        }
    }

    /// Checks the file, then keeps it under its source name (the same source again replaces the older file).
    static func importFile(_ url: URL) -> Result<MatchSourcesRule.ExtSource, Failure> {
        let ok = url.startAccessingSecurityScopedResource()
        defer { if ok { url.stopAccessingSecurityScopedResource() } }
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        guard size <= maxBytes else { return .failure(.tooBig) }
        guard let data = try? Data(contentsOf: url), data.count <= maxBytes else { return .failure(.io("تعذّرت قراءة الملف")) }
        let src: MatchSourcesRule.ExtSource
        do { src = try MatchSourcesRule.parse(data, now: Int64(Date().timeIntervalSince1970 * 1000)) }
        catch let e as MatchSourcesRule.BadFile { return .failure(.bad(e.reason)) }
        catch { return .failure(.bad(error.localizedDescription)) }
        guard let d = dir else { return .failure(.io("لا مكان للحفظ")) }
        let name = fileName(src.name)
        let existing = list()
        if !existing.contains(where: { $0.file == name }) && existing.count >= maxFiles { return .failure(.tooMany) }
        do { try data.write(to: d.appendingPathComponent(name), options: .atomic) } catch { return .failure(.io(error.localizedDescription)) }
        return .success(src)
    }

    static func remove(_ file: String) {
        guard let d = dir, !file.contains("/") else { return }
        try? FileManager.default.removeItem(at: d.appendingPathComponent(file))
    }

    static func fileName(_ source: String) -> String {
        let safe = source.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" }
        return String(String(safe).prefix(60)) + ".json"
    }

    // ---------- manual links ----------

    static func manual() -> [MatchSourcesRule.Manual] {
        guard let u = manualURL, let d = try? Data(contentsOf: u) else { return [] }
        return (try? JSONDecoder().decode([MatchSourcesRule.Manual].self, from: d)) ?? []
    }

    @discardableResult
    static func saveManual(_ list: [MatchSourcesRule.Manual]) -> Bool {
        guard let u = manualURL, let d = try? JSONEncoder().encode(list) else { return false }
        return (try? d.write(to: u, options: .atomic)) != nil
    }
}
