import Foundation
import Network

/// One live channel as the matches index needs it (copied on the main thread, used off it).
struct GuideChannel: Sendable { let id: String; let name: String; let group: String; let epg: String? }

/// 1.8.5: today's and tomorrow's matches from the provider's guide (XMLTV), matched to this phone's channels.
/// The guide is downloaded to a file (never into memory) and streamed once, off the main thread; only titles that
/// hold a separator, in the two days, are kept. The result is kept in Caches so the screen opens at once; the TV does
/// the same from the guide it already stores (MatchIndex). Each channel version is its own entry (same name ≠ same
/// stream). Channel names and guide titles only: no links or account data in the index or the report.
enum MatchIndexBuilder {
    static let rules = 2

    struct Candidate { let id: String; let start: Int64; let stop: Int64; let title: String; let desc: String?; let cat: String? }

    final class Stats {
        var stages: [String] = []
        var channels = 0, sports = 0, sportsById = 0, sportsByName = 0, sportsUnlinked = 0, sportKeys = 0, sportKeysLinked = 0
        var guideRows = 0, guideIds = 0, guideMin: Int64 = 0, guideMax: Int64 = 0, guideWithCat = 0, guideWithDesc = 0, guideBytes: Int64 = 0
        var sportIds = 0, sportIdsWithProg = 0, sportIdProgs = 0
        var oldPerVersion = 0
        var candRows = 0, withTeams = 0, generalSeen = 0, generalOk = 0
        var generalRejected: [String] = [], missed: [String] = []
        var networkVersions: [String: (Int, Int)] = [:]
        var readError: String?
        var source = ""
    }

    struct Result {
        let built: Int64, from: Int64, to: Int64, entries: [MatchGuideRule.Entry], labels: [String: Set<String>]
        var stats: Stats?
        var guideMB: Int64 = 0
        var groups: [MatchGuideRule.Group] { MatchGuideRule.group(entries) }
        func version(_ e: MatchGuideRule.Entry) -> MatchGuideRule.Version { MatchGuideRule.version(e.channel, labelPrefixes: labels[e.source] ?? []) }
    }

    static func nameKey(_ s: String) -> String {
        let quality: Set<String> = ["hd", "fhd", "uhd", "sd", "4k", "hevc", "h265", "1080p", "720p", "raw"]
        return s.lowercased().folding(options: .diacriticInsensitive, locale: nil)
            .split(whereSeparator: { !($0.isLetter || $0.isNumber) }).map(String.init).filter { !quality.contains($0) }.joined(separator: " ")
    }

    static func dayStart(_ now: Date) -> Date { Calendar.current.startOfDay(for: now) }
    static func ms(_ d: Date) -> Int64 { Int64(d.timeIntervalSince1970 * 1000) }

    /// Streams the guide: display names (for linking by name), per-channel counts, and the candidate programmes.
    final class Parser: NSObject, XMLParserDelegate {
        var wantedNames: Set<String> = []
        var idOfName: [String: String] = [:]
        var perId: [String: Int] = [:]               // programmes per guide id since `since`
        var ids = Set<String>()
        var candidates: [Candidate] = []
        var from: Int64 = 0, to: Int64 = 0, since: Int64 = 0
        var total = 0, withCat = 0, withDesc = 0, minStart: Int64 = .max, maxStop: Int64 = 0
        var cancel: MatchGuideReport.CancelFlag?
        private var chId: String?; private var inName = false; private var text = ""
        private var prog: (ch: String, start: Int64, stop: Int64)?; private var field = ""
        private var title = "", desc = "", cat = ""
        private static let seps = [" v ", " v. ", " vs", " x ", " × ", " ضد ", " - ", " – ", " — "]

        func parser(_ p: XMLParser, didStartElement e: String, namespaceURI: String?, qualifiedName: String?, attributes a: [String: String] = [:]) {
            switch e {
            case "channel": chId = a["id"]
            case "display-name": inName = chId != nil; text = ""
            case "programme":
                if cancel?.isSet == true { p.abortParsing(); return }
                guard let ch = a["channel"], let st = MatchGuideReport.Parser.time(a["start"]) else { prog = nil; return }
                let sp = MatchGuideReport.Parser.time(a["stop"]).flatMap { $0 > st ? $0 : nil } ?? (st + 30 * 60_000)
                prog = (ch, st, sp); title = ""; desc = ""; cat = ""
            // the first title / description only (guides repeat them per language); every category is kept
            case "title": field = prog != nil && title.isEmpty ? e : ""
            case "desc": field = prog != nil && desc.isEmpty ? e : ""
            case "category": field = prog != nil ? e : ""
            default: break
            }
        }
        func parser(_ p: XMLParser, foundCharacters s: String) {
            if inName { text += s; return }
            switch field {
            case "title": title += s
            case "desc": if desc.count < 300 { desc += s }
            case "category": if cat.count < 200 { cat += s }
            default: break
            }
        }
        func parser(_ p: XMLParser, didEndElement e: String, namespaceURI: String?, qualifiedName: String?) {
            switch e {
            case "display-name":
                if inName, let id = chId { let k = MatchIndexBuilder.nameKey(text); if wantedNames.contains(k), idOfName[k] == nil { idOfName[k] = id } }
                inName = false
            case "channel": chId = nil
            case "category": field = ""; if prog != nil && !cat.isEmpty && !cat.hasSuffix(" / ") { cat += " / " }
            case "title", "desc": field = ""
            case "programme":
                guard let pr = prog else { break }
                prog = nil
                total += 1; ids.insert(pr.ch)
                minStart = min(minStart, pr.start); maxStop = max(maxStop, pr.stop)
                let c = cat.hasSuffix(" / ") ? String(cat.dropLast(3)) : cat
                if !c.isEmpty { withCat += 1 }
                if !desc.isEmpty { withDesc += 1 }
                if pr.stop > since { perId[pr.ch, default: 0] += 1 }
                guard pr.stop > from && pr.start < to else { break }
                let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
                let low = t.lowercased()
                guard Self.seps.contains(where: { low.contains($0) }) else { break }
                let d = desc.trimmingCharacters(in: .whitespacesAndNewlines)
                candidates.append(Candidate(id: pr.ch, start: pr.start, stop: pr.stop, title: t, desc: d.isEmpty ? nil : String(d.prefix(300)),
                                            cat: c.isEmpty ? nil : c.trimmingCharacters(in: .whitespacesAndNewlines)))
            default: break
            }
        }
    }

    static func memLine() -> String { String(format: "ذاكرة: الآن %.0f MB · أعلى منذ فتح التطبيق %.0f MB", Perf.memoryMB ?? 0, Perf.peakMB ?? 0) }

    /// Reads the downloaded guide file (call off the main thread). `withStats` adds the report's counts.
    static func build(file: URL, size: Int64, channels: [GuideChannel], source: String, now: Date, cancel: MatchGuideReport.CancelFlag, withStats: Bool) -> Result {
        let st: Stats? = withStats ? Stats() : nil
        var tl = Date()
        func mark(_ name: String) { st?.stages.append("\(name): \(Int(Date().timeIntervalSince(tl) * 1000))ms · \(memLine())"); tl = Date() }
        st?.stages.append("البداية · \(memLine())")
        st?.source = source
        let fromD = dayStart(now)
        let from = ms(fromD), to = ms(Calendar.current.date(byAdding: .day, value: 2, to: fromD) ?? fromD.addingTimeInterval(172_800))
        let nowMs = ms(now)
        let p = Parser()
        p.cancel = cancel; p.from = from; p.to = to; p.since = nowMs - 12 * 3_600_000
        p.wantedNames = Set(channels.map { nameKey($0.name) })
        var readError: String?
        if let stream = InputStream(url: file) {
            let xp = XMLParser(stream: stream); xp.delegate = p
            if !xp.parse() { readError = cancel.isSet ? "أُلغي" : "توقفت القراءة عند سطر \(xp.lineNumber): \(xp.parserError.map { ($0 as NSError).code } ?? 0)" }
        } else { readError = "تعذّر فتح الدليل" }
        mark("قراءة الدليل (\(size / 1_048_576) MB، \(p.total) برنامج)")
        // channels → guide id: the provider's guide id first, then the name (as the report did)
        var lowerIds: [String: String] = [:]
        for id in p.ids { if lowerIds[id.lowercased()] == nil { lowerIds[id.lowercased()] = id } }
        for id in p.idOfName.values where lowerIds[id.lowercased()] == nil { lowerIds[id.lowercased()] = id }
        var onId: [String: [GuideChannel]] = [:]
        var isSports: [String: Bool] = [:]
        var sportIds = Set<String>(), sportKeys = Set<String>(), sportKeysLinked = Set<String>()
        for ch in channels {
            var how = 0
            var id: String?
            if let e = ch.epg?.lowercased(), let g = lowerIds[e] { id = g; how = 1 }
            if id == nil, let g = p.idOfName[nameKey(ch.name)] { id = g; how = 2 }
            let sp = MatchGuideRule.isSportsChannel(name: ch.name, group: ch.group)
            isSports[ch.id] = sp
            if let id { onId[id, default: []].append(ch) }
            if sp, let st {
                st.sports += 1
                switch how { case 1: st.sportsById += 1; case 2: st.sportsByName += 1; default: st.sportsUnlinked += 1 }
                let k = MatchGuideRule.channelKey(ch.name); sportKeys.insert(k)
                let net = MatchGuideRule.network(ch.name)
                var v = st.networkVersions[net] ?? (0, 0); v.0 += 1
                if let id { sportIds.insert(id); sportKeysLinked.insert(k); if (p.perId[id] ?? 0) > 0 { v.1 += 1; st.oldPerVersion += p.perId[id] ?? 0 } }
                st.networkVersions[net] = v
            }
        }
        if let st {
            st.channels = channels.count; st.sportKeys = sportKeys.count; st.sportKeysLinked = sportKeysLinked.count; st.sportIds = sportIds.count
            for id in sportIds { if let n = p.perId[id] { st.sportIdsWithProg += 1; st.sportIdProgs += n } }
            st.guideRows = p.total; st.guideIds = p.ids.count; st.guideMin = p.minStart == .max ? 0 : p.minStart; st.guideMax = p.maxStop
            st.guideWithCat = p.withCat; st.guideWithDesc = p.withDesc; st.guideBytes = size; st.readError = readError
        }
        mark("ربط القنوات بالدليل")
        let labels = [source: MatchGuideRule.prefixLabels(channels.map(\.name))]
        var entries: [MatchGuideRule.Entry] = []
        for c in p.candidates {
            guard let list = onId[c.id] else { continue }
            st?.candRows += 1
            let anySports = list.contains { isSports[$0.id] == true }
            guard let tm = MatchGuideRule.teams(c.title) else {
                if anySports, let st, st.missed.count < 20, c.title.count > 8, !st.missed.contains(c.title) { st.missed.append(c.title) }
                continue
            }
            st?.withTeams += 1
            let kind = MatchGuideRule.kind(title: c.title, description: c.desc, minutes: (c.stop - c.start) / 60_000)
            let comp = MatchGuideRule.competition(c.title), aud = MatchGuideRule.audience(c.title)
            let own = MatchGuideRule.sport(title: c.title, description: c.desc, category: c.cat, channel: nil)
            if let st, let g = list.first(where: { isSports[$0.id] != true }) {
                st.generalSeen += 1
                if own.sport == .football { st.generalOk += 1 } else if st.generalRejected.count < 12 { st.generalRejected.append("\(g.name) · «\(c.title)»") }
            }
            for ch in list {
                let general = isSports[ch.id] != true
                if general && own.sport != .football { continue }   // a general channel needs football named in the entry itself
                let sport = own.sport == .unknown && !general ? MatchGuideRule.sport(title: c.title, description: c.desc, category: c.cat, channel: ch.name) : own
                entries.append(MatchGuideRule.Entry(channel: ch.name, source: source, start: c.start, stop: c.stop, title: c.title, teams: tm, kind: kind,
                                                    description: c.desc, category: c.cat, channelId: ch.id, general: general,
                                                    competition: comp, sport: sport, audience: aud))
            }
        }
        mark("استخراج المباريات (\(entries.count) نسخة)")
        var res = Result(built: ms(Date()), from: from, to: to, entries: entries, labels: labels, stats: st)
        res.guideMB = size / 1_048_576
        if st != nil { let n = res.groups.count; mark("جمع البطاقات (\(n))") }
        return res
    }

    // ---------- cache (Caches/match-index.json) ----------

    private struct Stored: Codable {
        struct E: Codable {
            let i: String, c: String, s: String, a: Int64, b: Int64, t: String, h: String, w: String, l: String?, k: Int
            let d: String?, g: String?, x: Bool, m: String?, p: String, pn: String?, pe: String?, u: [String]
        }
        let rules: Int, built: Int64, from: Int64, to: Int64, source: String, guideMB: Int64, labels: [String: [String]], e: [E]
    }

    static var cacheURL: URL {
        (FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory)
            .appendingPathComponent("match-index.json")
    }

    static func save(_ r: Result, source: String) {
        let e = r.entries.map { x in
            Stored.E(i: x.channelId, c: x.channel, s: x.source, a: x.start, b: x.stop, t: x.title, h: x.teams.home, w: x.teams.away, l: x.teams.lead,
                     k: x.kind.rawValue, d: x.description, g: x.category, x: x.general, m: x.competition, p: x.sport.sport.rawValue,
                     pn: x.sport.name, pe: x.sport.evidence, u: x.audience.sorted())
        }
        let s = Stored(rules: rules, built: r.built, from: r.from, to: r.to, source: source, guideMB: r.guideMB,
                       labels: r.labels.mapValues { $0.sorted() }, e: e)
        if let data = try? JSONEncoder().encode(s) { try? data.write(to: cacheURL, options: .atomic) }
    }

    /// The kept index of this source and day, or nil (missing, damaged, other rules, other source, another day).
    static func load(source: String, now: Date) -> Result? {
        guard let data = try? Data(contentsOf: cacheURL), let s = try? JSONDecoder().decode(Stored.self, from: data),
              s.rules == rules, s.source == source, s.from == ms(dayStart(now)) else { return nil }
        let entries = s.e.map { x in
            MatchGuideRule.Entry(channel: x.c, source: x.s, start: x.a, stop: x.b, title: x.t,
                                 teams: MatchGuideRule.Teams(home: x.h, away: x.w, lead: x.l), kind: MatchGuideRule.Kind(rawValue: x.k) ?? .unknown,
                                 description: x.d, category: x.g, channelId: x.i, general: x.x, competition: x.m,
                                 sport: MatchGuideRule.SportGuess(sport: MatchGuideRule.Sport(rawValue: x.p) ?? .unknown, name: x.pn, evidence: x.pe),
                                 audience: Set(x.u))
        }
        var r = Result(built: s.built, from: s.from, to: s.to, entries: entries, labels: s.labels.mapValues { Set($0) }, stats: nil)
        r.guideMB = s.guideMB
        return r
    }

    // ---------- report ----------

    static func fmt(_ ms: Int64) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "ar"); f.dateFormat = "EEE d/M HH:mm"
        return f.string(from: Date(timeIntervalSince1970: Double(ms) / 1000))
    }

    /// The report text (channel names and guide titles only). Same sections and order as the TV's MatchIndex.report.
    static func report(_ r: Result, now: Date) -> String {
        guard let st = r.stats else { return "" }
        let nowMs = ms(now)
        var s = ""
        func line(_ x: String = "") { s += x + "\n" }
        func pct(_ a: Int, _ b: Int) -> String { b > 0 ? " (\(a * 100 / b)٪)" : "" }
        let tz = TimeZone.current
        let ver = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        line("شاشة — تقرير دليل المباريات · الآيفون \(ver) · القواعد v\(rules)")
        line("المصدر: دليل برامج المزوّد. التطابق بالفريقين والوقت ترجيح قوي، وليس ضمانًا أن البث مباشر.")
        line("وقت التقرير: \(fmt(nowMs)) · المنطقة الزمنية: \(tz.identifier) (UTC\(String(format: "%+.1f", Double(tz.secondsFromGMT()) / 3600)))")
        line("المصادر المشمولة:"); line("   - \(st.source) (المصدر النشط فقط) · الدليل نُزّل الآن (\(st.guideBytes / 1_048_576) MB)")
        if let e = st.readError { line("خطأ قراءة الدليل: \(e) — الأرقام تشمل ما قُرئ قبله") }
        line("الفترة: من \(fmt(r.from)) إلى \(fmt(r.to)) (اليوم وغدًا بالتوقيت المحلي)")
        line()
        line("— الدليل والربط (للمقارنة بين الجهازين)")
        line("الدليل كما نزل من المزوّد: \(st.guideRows) برنامج · \(st.guideIds) معرّف قناة · من \(st.guideMin > 0 ? fmt(st.guideMin) : "-") إلى \(st.guideMax > 0 ? fmt(st.guideMax) : "-")")
        line("   الآيفون يقرأ الملف كاملًا (كل القنوات وكل الأيام فيه)، والتلفزيون يحفظ قنوات قائمتك فقط من 12 ساعة قبل التحديث إلى 4 أيام بعده.")
        line("   برامج لها وصف: \(st.guideWithDesc)\(pct(st.guideWithDesc, st.guideRows)) · لها تصنيف: \(st.guideWithCat)\(pct(st.guideWithCat, st.guideRows))")
        line("تحديد القنوات الرياضية: \(MatchGuideRule.sportsRule).")
        line("نسخ القنوات: الكل \(st.channels) · الرياضية \(st.sports) · مربوطة بالدليل بمعرّف القناة \(st.sportsById) · بالاسم \(st.sportsByName) · بدون ربط \(st.sportsUnlinked)")
        line("القنوات الرياضية بعد جمع النسخ: \(st.sportKeys) · مربوطة \(st.sportKeysLinked)\(pct(st.sportKeysLinked, st.sportKeys))")
        line("معرّفات الدليل المربوطة بقنوات رياضية: \(st.sportIds) · لها برامج: \(st.sportIdsWithProg) · برامجها من 12 ساعة مضت (كل برنامج مرة): \(st.sportIdProgs)")
        line("طريقة العدّ القديمة (1.7.11، لكل نسخة قناة، بلا حد): \(st.oldPerVersion)")
        line()
        let gs = r.groups
        let football = gs.filter { $0.sport.sport == .football }, other = gs.filter { $0.sport.sport == .other }, unknown = gs.filter { $0.sport.sport == .unknown }
        let tomorrow = ms(Calendar.current.date(byAdding: .day, value: 1, to: Date(timeIntervalSince1970: Double(r.from) / 1000)) ?? Date())
        line("— المباريات (اليوم وغدًا)")
        line("برامج في الفترة عناوينها فيها فاصل (v / vs / x / - / ضد) على قنوات مربوطة: \(st.candRows) · فيها اسما فريقين: \(st.withTeams)")
        line("بطاقات (المباراة الواحدة بكل نسخها، بدون الاستوديو): كرة القدم \(football.count) (اليوم \(football.filter { $0.start < tomorrow }.count) · غدًا \(football.filter { $0.start >= tomorrow }.count))"
             + " · رياضات أخرى \(other.count) · غير محدد \(unknown.count)")
        line("كرة القدم — حالة العرض حسب الدليل: موسوم مباشر في نسخة واحدة على الأقل \(football.filter(\.live).count) · إعادة/ملخص \(football.filter(\.replay).count)"
             + " · نوع العرض غير محدد \(football.filter { !$0.live && !$0.replay }.count). «غير محدد» لا يُعرض على أنه مباشر.")
        line("تلعب الآن حسب الدليل: كرة القدم \(football.filter { $0.airingAt(nowMs) }.count) · غير محدد \(unknown.filter { $0.airingAt(nowMs) }.count)")
        var os: [String: Int] = [:]; for g in other { os[g.sport.name ?? "?", default: 0] += 1 }
        line("الرياضات الأخرى: " + os.sorted { $0.value > $1.value }.map { "\($0.key) \($0.value)" }.joined(separator: " · "))
        line("القنوات العامة (غير الرياضية): مباريات مرشحة \(st.generalSeen) · قُبلت لأن الدليل نفسه يذكر كرة القدم \(st.generalOk)")
        let fv = football.flatMap(\.entries)
        var byRes: [MatchGuideRule.Res: Int] = [:]; for e in fv { byRes[r.version(e).res, default: 0] += 1 }
        line("نسخ كرة القدم: \(fv.count) · " + MatchGuideRule.Res.allCases.map { "\($0.label) \(byRes[$0] ?? 0)" }.joined(separator: " · ")
             + " · HEVC \(fv.filter { r.version($0).hevc }.count) · RAW \(fv.filter { r.version($0).raw }.count) (الدقة من الاسم فقط)")
        let dup = football.reduce(0) { acc, g in
            var c: [String: Int] = [:]; for e in g.entries { c[e.channel, default: 0] += 1 }
            return acc + c.values.filter { $0 > 1 }.reduce(0, +)
        }
        line("نسخ بنفس الاسم داخل نفس البطاقة: \(dup) — تُعرض كنسخ مستقلة (نسخة 1، نسخة 2…) لأن الاسم وحده لا يثبت أنها نفس البث")
        for (src, l) in r.labels where !l.isEmpty { line("بادئات اعتُبرت تسمية مجموعة (لا دقة) في «\(src)» بعد فحص أسماء قنواته: \(l.sorted().joined(separator: ", "))") }
        line("نسبة تغطية مباريات اليوم: لا يمكن حسابها — تحتاج جدول مباريات مستقلًا للمقارنة. الأرقام أعلاه هي ما وجدناه في الدليل فقط.")
        line()
        line("— الشبكات (القنوات الرياضية: نسخ · مربوطة بالدليل ولها برامج · بطاقات كرة القدم · نسخها)")
        var netCards: [String: Int] = [:], netVers: [String: Int] = [:]
        for g in football {
            for n in Set(g.entries.map { MatchGuideRule.network($0.channel) }) { netCards[n, default: 0] += 1 }
            for e in g.entries { netVers[MatchGuideRule.network(e.channel), default: 0] += 1 }
        }
        for (n, v) in st.networkVersions.sorted(by: { $0.value.0 > $1.value.0 }).prefix(45) {
            line("   \(n): \(v.0) · \(v.1)\(pct(v.1, v.0)) · \(netCards[n] ?? 0) · \(netVers[n] ?? 0)")
        }
        line("— الدول/البادئات (كما يكتبها المزوّد قبل «:»؛ بعضها تسمية مثل GOLD أو 8K) — بطاقات كرة القدم · نسخها")
        var cc: [String: Int] = [:], cv: [String: Int] = [:]
        for g in football {
            for n in Set(g.entries.map { MatchGuideRule.country($0.channel) }) { cc[n, default: 0] += 1 }
            for e in g.entries { cv[MatchGuideRule.country(e.channel), default: 0] += 1 }
        }
        for (n, v) in cc.sorted(by: { $0.value > $1.value }).prefix(40) { line("   \(n): \(v) · \(cv[n] ?? 0)") }
        line()
        line("— عينة متنوعة (العنوان الأصلي من الدليل لكل نسخة)")
        for (label, g) in sample(gs, now: nowMs) {
            line("[\(label)] \(fmt(g.start)) · \(g.home) × \(g.away) · \(g.sport.sport.label)\(g.sport.name.map { " (\($0))" } ?? "")"
                 + (g.sport.evidence.map { " ← " + $0 } ?? "") + (g.competition.map { " · البطولة: " + $0 } ?? "") + " · \(g.entries.count) نسخة")
            var names: [String: Int] = [:]
            let sorted = g.entries.sorted { (r.version($0).res.rawValue, $0.channel) < (r.version($1).res.rawValue, $1.channel) }
            for e in sorted.prefix(6) {
                names[e.channel, default: 0] += 1
                let copies = g.entries.filter { $0.channel == e.channel }.count
                line("   - \(e.channel)\(copies > 1 ? " (نسخة \(names[e.channel]!))" : "") [\(r.version(e).label())] · \(e.kind.label)"
                     + (e.general ? " · قناة عامة" : "") + " · \(e.source) · «\(e.title)»" + (e.category.map { " · تصنيف: " + $0 } ?? ""))
            }
        }
        line()
        line("— قنوات عامة: عناوين رُفضت (لا يذكر الدليل كرة القدم)")
        for x in st.generalRejected { line("   " + x) }
        line("— عناوين على قنوات رياضية لم يُستخرج منها فريقان")
        for m in st.missed { line("   «\(m)»") }
        line()
        line("— المراحل والذاكرة")
        for x in st.stages { line("   " + x) }
        return s
    }

    /// A varied sample, same picks and order as the TV.
    static func sample(_ gs: [MatchGuideRule.Group], now: Int64) -> [(String, MatchGuideRule.Group)] {
        let arabic: Set<String> = ["beIN", "SSC", "الكأس", "أبوظبي الرياضية", "دبي الرياضية", "الشارقة الرياضية", "السعودية الرياضية", "ثمانية", "شاهد (منصة)", "MBC", "أون تايم سبورتس"]
        typealias G = MatchGuideRule.Group
        let picks: [(String, (G) -> Bool)] = [
            ("كرة قدم · موسوم مباشر", { $0.sport.sport == .football && $0.live }),
            ("كرة قدم · تلعب الآن", { $0.sport.sport == .football && $0.airingAt(now) }),
            ("كرة قدم · نوع العرض غير محدد", { $0.sport.sport == .football && !$0.live && !$0.replay }),
            ("كرة قدم · إعادة", { $0.sport.sport == .football && $0.replay }),
            ("سيدات/فئة عمرية", { g in g.entries.contains { !$0.audience.isEmpty } || g.key.contains("#") }),
            ("قناة عامة قُبلت", { g in g.entries.contains { $0.general } }),
            ("شبكة عربية", { g in g.sport.sport == .football && g.entries.contains { let n = MatchGuideRule.network($0.channel); return arabic.contains(n) && n != "beIN" } }),
            ("beIN", { g in g.sport.sport == .football && g.entries.contains { MatchGuideRule.network($0.channel) == "beIN" } }),
            ("عدة شبكات", { g in g.sport.sport == .football && Set(g.entries.map { MatchGuideRule.network($0.channel) }).count >= 3 }),
            ("رياضة أخرى", { $0.sport.sport == .other }),
            ("غير محدد", { $0.sport.sport == .unknown }),
        ]
        var out: [(String, G)] = []; var used = Set<Int>()
        for (label, f) in picks {
            let c = gs.indices.filter { !used.contains($0) && f(gs[$0]) }
            let chosen = c.count <= 4 ? c : [c[0], c[c.count / 3], c[2 * c.count / 3], c[c.count - 1]]
            for i in chosen { out.append((label, gs[i])); used.insert(i) }
        }
        return out
    }
}

/// Whether the phone is on an expensive (mobile data / hotspot) connection right now.
final class PathCost: @unchecked Sendable {
    static let shared = PathCost()
    private let monitor = NWPathMonitor()
    private let lock = NSLock()
    private var expensiveNow = false
    private init() {
        monitor.pathUpdateHandler = { [weak self] p in self?.lock.lock(); self?.expensiveNow = p.isExpensive; self?.lock.unlock() }
        monitor.start(queue: DispatchQueue(label: "shasha.pathcost"))
    }
    var isExpensive: Bool { lock.lock(); defer { lock.unlock() }; return expensiveNow }
}
