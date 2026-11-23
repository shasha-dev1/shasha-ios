import SwiftUI

/// Match-guide report (test): football matches found in the provider's programme guide (XMLTV), matched to this
/// phone's channels. Everything is read and computed on the phone; the report holds channel names and guide
/// titles only (no links, no account data). Same rules as the TV (MatchGuideRule / MatchGuideCore).
struct MatchReportView: View {
    @EnvironmentObject var library: Library
    @State private var text = ""
    @State private var running = false
    @State private var status = ""

    var body: some View {
        List {
            Section {
                Button(running ? "جارٍ…" : "إنشاء التقرير") { Task { await run() } }.disabled(running)
                if !status.isEmpty { Text(status).font(.footnote).foregroundStyle(.secondary) }
            } footer: {
                Text("ينزّل دليل البرامج الكامل من المزوّد مرة واحدة (قد يكون كبيرًا — يفضّل Wi‑Fi) ويقرأه على الجهاز. المصدر: دليل برامج المزوّد. التطابق ترجيح، ليس ضمانًا أن البث مباشر.")
            }
            if !text.isEmpty {
                Section {
                    Button { UIPasteboard.general.string = text } label: { Label("نسخ التقرير", systemImage: "doc.on.doc") }
                    Text(text).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                }
            }
        }
        .navigationTitle("دليل المباريات")
    }

    private func run() async {
        guard let x = library.xtream, let url = x.xmltvURL else { status = "يحتاج مصدر Xtream"; return }
        running = true; defer { running = false }
        status = "تنزيل الدليل…"
        let t0 = Perf.now()
        let file: URL
        do {
            var r = URLRequest(url: url, timeoutInterval: 120)
            r.setValue("gzip", forHTTPHeaderField: "Accept-Encoding")
            let (tmp, resp) = try await URLSession.shared.download(for: r)
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
                status = "المزوّد ردّ \((resp as? HTTPURLResponse)?.statusCode ?? 0)"; return
            }
            file = FileManager.default.temporaryDirectory.appendingPathComponent("guide-\(UUID().uuidString).xml")
            try FileManager.default.moveItem(at: tmp, to: file)
        } catch {
            status = "تعذّر تنزيل الدليل (\((error as NSError).code))"; return   // no link in the message
        }
        defer { try? FileManager.default.removeItem(at: file) }
        let size = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.int64Value ?? 0
        Perf.shared.record("دليل المباريات: تنزيل الدليل", since: t0, ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
        status = "قراءة الدليل…"
        // What the report needs from the library, copied before leaving the main thread.
        let groups = Dictionary(library.liveCats.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
        let chans = library.channels.map { ReportChannel(name: $0.name, group: groups[$0.categoryId] ?? "", epg: $0.epgId) }
        let source = library.active?.name ?? "?"
        let t1 = Perf.now()
        let out = await Task.detached(priority: .userInitiated) {
            MatchGuideReport.build(file: file, channels: chans, source: source, now: Date())
        }.value
        Perf.shared.record("دليل المباريات: القراءة والمطابقة", since: t1, "")
        text = out
        status = "الدليل \(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))"
    }
}

struct ReportChannel: Sendable { let name: String; let group: String; let epg: String? }

/// Streams the XMLTV file (only programmes of sports channels are kept) and writes the report.
enum MatchGuideReport {
    static func nameKey(_ s: String) -> String {
        let quality: Set<String> = ["hd", "fhd", "uhd", "sd", "4k", "hevc", "h265", "1080p", "720p", "raw"]
        return s.lowercased().folding(options: .diacriticInsensitive, locale: nil)
            .split(whereSeparator: { !($0.isLetter || $0.isNumber) }).map(String.init).filter { !quality.contains($0) }.joined(separator: " ")
    }

    final class Parser: NSObject, XMLParserDelegate {
        var wantedIds: Set<String> = []          // lower-cased guide ids of sports channels
        var wantedNames: Set<String> = []        // name keys of sports channels
        var idOfName: [String: String] = [:]     // guide channel id → matched name key (via display-name)
        var programmes: [String: [(start: Int64, stop: Int64, title: String, desc: String?)]] = [:]
        private var chId: String?; private var inName = false; private var text = ""
        private var prog: (ch: String, start: Int64, stop: Int64)?; private var title = ""; private var desc = ""; private var field = ""

        // One parse runs on one thread: the formatters are made once.
        private static let withZone: DateFormatter = {
            let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyyMMddHHmmss Z"; return f
        }()
        private static let utc: DateFormatter = {
            let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyyMMddHHmmss"
            f.timeZone = TimeZone(identifier: "UTC"); return f
        }()
        static func time(_ s: String?) -> Int64? {
            guard let s, s.count >= 14 else { return nil }
            let d = s.count >= 20 ? withZone.date(from: String(s.prefix(20))) : utc.date(from: String(s.prefix(14)))
            return d.map { Int64($0.timeIntervalSince1970 * 1000) }
        }

        func parser(_ p: XMLParser, didStartElement e: String, namespaceURI: String?, qualifiedName: String?, attributes a: [String: String] = [:]) {
            switch e {
            case "channel": chId = a["id"]
            case "display-name": inName = chId != nil; text = ""
            case "programme":
                guard let ch = a["channel"], wantedIds.contains(ch.lowercased()) || idOfName[ch] != nil,
                      let st = Self.time(a["start"]), let sp = Self.time(a["stop"]) else { prog = nil; return }
                prog = (ch, st, sp); title = ""; desc = ""
            case "title", "desc": field = prog != nil ? e : ""
            default: break
            }
        }
        func parser(_ p: XMLParser, foundCharacters s: String) {
            if inName { text += s }
            else if field == "title" { title += s } else if field == "desc" { desc += s }
        }
        func parser(_ p: XMLParser, didEndElement e: String, namespaceURI: String?, qualifiedName: String?) {
            switch e {
            case "display-name":
                if inName, let id = chId { let k = MatchGuideReport.nameKey(text); if wantedNames.contains(k) { idOfName[id] = k } }
                inName = false
            case "channel": chId = nil
            case "title", "desc": field = ""
            case "programme":
                if let pr = prog { programmes[pr.ch, default: []].append((pr.start, pr.stop, title.trimmingCharacters(in: .whitespacesAndNewlines), desc.isEmpty ? nil : desc)) }
                prog = nil
            default: break
            }
        }
    }

    static func build(file: URL, channels: [ReportChannel], source: String, now: Date) -> String {
        let sports = channels.filter { MatchGuideRule.isSportsChannel(name: $0.name, group: $0.group) }
        let p = Parser()
        p.wantedIds = Set(sports.compactMap { $0.epg?.lowercased() })
        p.wantedNames = Set(sports.map { nameKey($0.name) })
        guard let stream = InputStream(url: file) else { return "تعذّر فتح الدليل" }
        let xp = XMLParser(stream: stream); xp.delegate = p
        _ = xp.parse()
        // guide channel id (lower-cased) → programmes; channels find theirs by guide id, else by name.
        var byId: [String: [(start: Int64, stop: Int64, title: String, desc: String?)]] = [:]
        var byName: [String: [(start: Int64, stop: Int64, title: String, desc: String?)]] = [:]
        for (id, list) in p.programmes {
            byId[id.lowercased(), default: []] += list
            if let k = p.idOfName[id] { byName[k, default: []] += list }
        }
        let nowMs = Int64(now.timeIntervalSince1970 * 1000), from = nowMs - 12 * 3_600_000
        var withGuide = 0, programmes = 0, minStart = Int64.max, maxStop: Int64 = 0
        var spans: [Int64] = [], entries: [MatchGuideRule.Entry] = [], missed: [String] = [], kinds: [MatchGuideRule.Kind: Int] = [:]
        for ch in sports {
            let list = (ch.epg.flatMap { byId[$0.lowercased()] } ?? byName[nameKey(ch.name)] ?? []).filter { $0.stop > from }
            guard !list.isEmpty else { continue }
            withGuide += 1; programmes += list.count
            let first = list.map(\.start).min()!, last = list.map(\.stop).max()!
            minStart = min(minStart, first); maxStop = max(maxStop, last); spans.append(last - first)
            for pr in list {
                if let t = MatchGuideRule.teams(pr.title) {
                    let k = MatchGuideRule.kind(title: pr.title, description: pr.desc, minutes: (pr.stop - pr.start) / 60_000)
                    kinds[k, default: 0] += 1
                    entries.append(.init(channel: ch.name, source: source, start: pr.start, stop: pr.stop, title: pr.title, teams: t, kind: k))
                } else if missed.count < 15 && pr.title.count > 8 && !missed.contains(pr.title) { missed.append(pr.title) }
            }
        }
        let f = DateFormatter(); f.locale = Locale(identifier: "ar"); f.dateFormat = "EEE d/M HH:mm"
        func d(_ ms: Int64) -> String { f.string(from: Date(timeIntervalSince1970: Double(ms) / 1000)) }
        let upcoming = MatchGuideRule.group(entries.filter { $0.stop > nowMs && $0.start < nowMs + 2 * 86_400_000 })
        var s = "شاشة — تقرير دليل المباريات (المصدر: دليل برامج المزوّد)\n"
        s += "التطابق بالفريقين والوقت ترجيح قوي، وليس ضمانًا أن البث مباشر. التغطية جزئية: ما لم يُكتشف قد يكون موجودًا.\n\n"
        s += "القنوات: \(channels.count) · الرياضية (حسب الاسم/المجموعة): \(sports.count) · الرياضية التي لها دليل: \(withGuide)"
        s += sports.isEmpty ? "\n" : " (\(withGuide * 100 / sports.count)٪)\n"
        s += "قنوات رياضية بمعرّف دليل من المزوّد: \(sports.filter { $0.epg != nil }.count)\n"
        if withGuide > 0 {
            let med = spans.sorted()[spans.count / 2]
            s += "مدى الدليل: من \(d(minStart)) إلى \(d(maxStop)) · وسيط القناة \(String(format: "%.1f", Double(med) / 86_400_000)) يوم\n"
        }
        s += "برامج القنوات الرياضية: \(programmes) · فيها اسما فريقين: \(entries.count)\n"
        s += "التصنيف: " + MatchGuideRule.Kind.allCases.map { "\($0.label) \(kinds[$0] ?? 0)" }.joined(separator: " · ") + "\n"
        s += "مباريات (بطاقات) خلال 48 ساعة: \(upcoming.count) · منها مكتوب «مباشر» في دليل قناة واحدة على الأقل: \(upcoming.filter(\.live).count)\n\n"
        s += "— أمثلة (أول 25 بطاقة)\n"
        for g in upcoming.prefix(25) {
            s += "\(d(g.start)) · \(g.home) × \(g.away) · \(g.entries.count) قناة" + (g.live ? " · مباشر" : "") + "\n"
            for e in g.entries.sorted(by: { (MatchGuideRule.version($0.channel).res, $0.channel) < (MatchGuideRule.version($1.channel).res, $1.channel) }).prefix(8) {
                s += "   - \(e.channel) [\(MatchGuideRule.version(e.channel).label())] · \(e.kind.label) · \(e.source) · «\(e.title)»\n"
            }
        }
        s += "\n— عناوين رياضية لم يُستخرج منها فريقان (لتحسين القواعد)\n"
        for m in missed { s += "   «\(m)»\n" }
        return s
    }
}
