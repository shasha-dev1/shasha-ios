import XCTest
@testable import PlaybackLogic
#if canImport(Darwin)
import Darwin

/// 1.10.8 (owner's report 23:04, 1.10.5: «قراءة الدليل» 748 → 1656 → 3159 MB, then the system's memory warning and the app closed).
/// Measures, on the same machine, what each suspect costs: reading a large guide with one XMLParser over the stream (as 1.10.5 did)
/// versus in pieces, and the rights facts held by 3484 matches as copies versus shared.
final class MemoryDiagnosisTests: XCTestCase {
    static func footprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) { $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) } }
        return kr == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : 0
    }

    /// Highest footprint seen while `work` runs (sampled every 20 ms), minus the footprint before it.
    static func peakGrowth(_ work: () -> Void) -> Double {
        let base = footprintMB()
        let lock = NSLock(); var peak = base; var stop = false
        let t = Thread { while true { lock.lock(); let s = stop; lock.unlock(); if s { break }
                                      let f = footprintMB(); lock.lock(); peak = max(peak, f); lock.unlock(); usleep(20_000) } }
        t.start()
        work()
        let end = footprintMB()
        lock.lock(); stop = true; peak = max(peak, end); lock.unlock()
        usleep(50_000)
        return peak - base
    }

    /// The same work the app's guide parser does per element (title, description, categories, a few kept candidates).
    final class Mirror: NSObject, XMLParserDelegate {
        var total = 0, kept = 0, names = 0
        private var inProg = false, field = "", title = "", desc = "", cat = ""
        func parser(_ p: XMLParser, didStartElement e: String, namespaceURI: String?, qualifiedName: String?, attributes a: [String: String] = [:]) {
            switch e {
            case "programme": inProg = a["channel"] != nil && a["start"] != nil; title = ""; desc = ""; cat = ""
            case "title", "desc", "category": field = inProg ? e : ""
            case "display-name": names += 1
            default: break
            }
        }
        func parser(_ p: XMLParser, foundCharacters s: String) {
            switch field { case "title": title += s; case "desc": if desc.count < 300 { desc += s }; case "category": cat += s; default: break }
        }
        func parser(_ p: XMLParser, didEndElement e: String, namespaceURI: String?, qualifiedName: String?) {
            if e == "programme" { total += 1; if title.lowercased().contains(" v ") { kept += 1 }; inProg = false }
            if e == "title" || e == "desc" || e == "category" { field = "" }
        }
    }

    /// A provider-sized guide: `n` programmes over 3000 channels, ~260 bytes each, some of them matches.
    static func makeGuide(programmes n: Int) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("mem-guide-\(n).xml")
        if FileManager.default.fileExists(atPath: url.path) { return url }
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let fh = try FileHandle(forWritingTo: url)
        fh.write(Data("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<!DOCTYPE tv SYSTEM \"xmltv.dtd\">\n<tv generator-info-name=\"test\">\n".utf8))
        var s = ""
        for c in 0..<3000 { s += "<channel id=\"ch\(c).uk\"><display-name>UK: Channel \(c) FHD</display-name></channel>\n" }
        fh.write(Data(s.utf8)); s = ""
        for i in 0..<n {
            let t = i % 7 == 0 ? "Team\(i % 500) v Other\(i % 300) &amp; more" : "Programme \(i) — مباشر"
            s += "<programme start=\"20261124\(String(format: "%02d", i % 24))0000 +0000\" stop=\"20261124\(String(format: "%02d", i % 24))4500 +0000\" channel=\"ch\(i % 3000).uk\">"
                + "<title lang=\"en\">\(t)</title><desc lang=\"en\">Live coverage of the game number \(i) with the studio before and after.</desc><category>Sport</category></programme>\n"
            if i % 5000 == 4999 { fh.write(Data(s.utf8)); s = "" }
        }
        fh.write(Data((s + "</tv>\n").utf8))
        try fh.close()
        return url
    }

    /// Measured (CI, 212 MB guide, 800 000 programmes): one XMLParser over the stream grew +0 MB — the guide read is not what filled
    /// the phone's memory; kept as a guard.
    func testReadingALargeGuideDoesNotGrowWithTheFile() throws {
        let n = 800_000
        let url = try Self.makeGuide(programmes: n)
        let mb = ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.doubleValue ?? 0) / 1_048_576
        let m = Mirror()
        let before = Self.footprintMB()
        let g = Self.peakGrowth { let xp = XMLParser(stream: InputStream(url: url)!); xp.delegate = m; _ = xp.parse() }
        print(String(format: "MEMORY guide %.0f MB, %d programmes: one XMLParser over the stream +%.0f MB (footprint before %.0f MB)", mb, n, g, before))
        XCTAssertEqual(m.total, n); XCTAssertEqual(m.names, 3000)
        XCTAssertLessThan(g, 200)
    }

    /// The owner's day at its size: 3484 guide cards on a 56 000-channel library, merged then given the rights — the merge in 1.10.5
    /// never reached «بعد الدمج» before the phone ran out.
    func testAFullDayMergeAtTheOwnersSize() throws {
        typealias R = MatchGuideRule; typealias S = MatchSourcesRule
        let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../../docs/samples/rights").standardizedFileURL
        let all = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil).filter { $0.pathExtension == "json" }
            .map { try RightsRule.parse(Data(contentsOf: $0)) }
        let nets = ["beIN SPORTS", "SKY SPORTS", "CANAL+ SPORT", "DAZN", "ZIGGO SPORT", "TNT SPORTS", "ARENA SPORT", "ESPN", "MOVISTAR LIGA", "SPORT TV",
                    "SPORT KLUB", "ELEVEN SPORTS", "SUPERSPORT", "STARZPLAY SPORTS", "SSC", "AD SPORTS", "NOVA SPORTS", "CYTAVISION SPORTS"]
        let prefixes = ["AR", "UK", "FR", "NL", "DE", "ES", "IT", "PT", "TR", "US", "8K", "4K", "HR", "RS", "GR", "CY", "PL", "SA"]
        let res = ["HD", "FHD", "4K", "SD", "RAW", "HEVC"]
        let lib = (0..<56_103).map { i in S.LibCh(id: "\(i)", name: "\(prefixes[i % prefixes.count]): \(nets[i % nets.count]) \(i % 9 + 1) \(res[i % res.count])") }
        let comps = ["UEFA Champions League", "England - Premier League", "Spain - LaLiga", "Italy - Serie A", "Turkey - Süper Lig", "Saudi Pro League",
                     "UEFA Europa League", "Germany - Bundesliga", "France - Ligue 1", "Italy - Coppa Italia"]
        let ko: Int64 = 1_795_542_300_000, m: Int64 = 60_000
        let entries = (0..<3484).map { i -> R.Entry in
            let match = i % 1200
            let t = "Team\(match) vs Other\(match) - \(comps[match % comps.count])"
            let ch = lib[(i * 37) % lib.count]
            return R.Entry(channel: ch.name, source: "S1", start: ko + Int64(match % 40) * 15 * m, stop: ko + Int64(match % 40) * 15 * m + 120 * m, title: t,
                           teams: R.teams(t)!, kind: R.kind(title: t, description: nil, minutes: 120), channelId: ch.id)
        }
        let q = { (n: String) in S.quality(R.version(n)) }
        var idx: S.LibIndex!, groups: [R.Group] = [], rows: [S.Row] = [], out: [S.Row] = []
        let pool = R.ExtraPool(lib.prefix(5000).map { .init(id: $0.id, name: $0.name, source: "S1") })
        let gIdx = Self.peakGrowth { idx = S.LibIndex(lib) }
        let gGroup = Self.peakGrowth { groups = R.group(entries) }
        let t0 = Date()
        let gMerge = Self.peakGrowth { rows = S.merge(groups, sources: [], idx: idx, pool: pool, manual: [], guideSource: "EPG", guideAt: 1,
                                                      from: ko - 20 * 3_600_000, to: ko + 28 * 3_600_000) }
        let tMerge = Date().timeIntervalSince(t0)
        let gRights = Self.peakGrowth { out = RightsRule.annotate(rows, all, idx: idx, quality: q) }
        var copied: [S.Row] = []
        let gCopy = Self.peakGrowth { copied = out.map { var x = $0; x.rights = $0.rights.map { $0 }; return x } }
        let facts = out.reduce(0) { $0 + $1.rights.count }
        print(String(format: "MEMORY full day (%d cards, %d groups, %d rows, %d facts): library index +%.0f MB · groups +%.0f MB · merge +%.0f MB (%.1f s) · rights shared +%.0f MB · rights copied per match (1.10.5) +%.0f MB",
                     entries.count, groups.count, rows.count, facts, gIdx, gGroup, gMerge, tMerge, gRights, gCopy))
        XCTAssertEqual(copied.count, out.count)
        XCTAssertLessThan(gRights, 150, "rows must share the rights facts")
    }

    func testRightsFactsOfAFullDay() throws {
        let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../../docs/samples/rights").standardizedFileURL
        let all = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil).filter { $0.pathExtension == "json" }
            .map { try RightsRule.parse(Data(contentsOf: $0)) }
        let nets = ["beIN SPORTS", "SKY SPORTS", "CANAL+ SPORT", "DAZN", "ZIGGO SPORT", "TNT SPORTS", "ARENA SPORT", "ESPN", "MOVISTAR LIGA", "SPORT TV"]
        let prefixes = ["AR", "UK", "FR", "NL", "DE", "ES", "IT", "PT", "TR", "US", "8K", "4K", "HR", "RS"]
        let lib = (0..<56_000).map { i in MatchSourcesRule.LibCh(id: "\(i)", name: "\(prefixes[i % prefixes.count]): \(nets[i % nets.count]) \(i % 9 + 1) FHD") }
        let idx = MatchSourcesRule.LibIndex(lib)
        let comps = ["UEFA Champions League", "England - Premier League", "Spain - LaLiga", "Italy - Serie A"]
        let ko: Int64 = 1_795_542_300_000
        let rows = (0..<3484).map { i in
            MatchSourcesRule.Row(key: "k\(i)", home: "T\(i)", away: "O\(i)", competition: comps[i % comps.count], audience: [], kickoff: ko, kickoffFrom: "x", group: nil,
                                 timeConflict: false, links: [], missing: [], removed: [], sources: [])
        }
        let q = { (n: String) in MatchSourcesRule.quality(MatchGuideRule.version(n)) }
        var shared: [MatchSourcesRule.Row] = []
        let gShared = Self.peakGrowth { shared = RightsRule.annotate(rows, all, idx: idx, quality: q) }
        var copied: [MatchSourcesRule.Row] = []
        let gCopy = Self.peakGrowth {              // what 1.10.5 held: each match its own array of facts
            copied = shared.map { var x = $0; x.rights = $0.rights.map { var f = $0; f.outsideSeason = f.outsideSeason; return f }; return x }
        }
        let facts = shared.reduce(0) { $0 + $1.rights.count }
        print(String(format: "MEMORY rights for 3484 matches (%d facts in all): shared +%.0f MB · copied per match +%.0f MB", facts, gShared, gCopy))
        XCTAssertEqual(copied.count, shared.count)
    }
}
#endif
