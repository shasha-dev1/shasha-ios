import SwiftUI

/// Match-guide report (test): football matches found in the provider's programme guide (XMLTV), matched to this
/// phone's channels. Everything is read and computed on the phone; the report holds channel names and guide
/// titles only (no links, no account data). Same rules as the TV (MatchGuideRule / MatchGuideCore).
struct MatchReportView: View {
    @EnvironmentObject var library: Library
    @State private var text = ""
    @State private var status = ""
    @State private var job: Task<Void, Never>?
    @State private var cancel = MatchGuideReport.CancelFlag()

    var body: some View {
        List {
            Section {
                if job == nil {
                    Button("إنشاء التقرير") { start() }
                } else {
                    Button("إلغاء", role: .destructive) { cancel.set(); job?.cancel() }
                }
                if !status.isEmpty { Text(status).font(.footnote).foregroundStyle(.secondary) }
            } footer: {
                Text("ينزّل دليل البرامج الكامل من المزوّد مرة واحدة (حد أقصى \(MatchGuideReport.maxBytes / 1_048_576) MB — يفضّل Wi‑Fi) ويقرأه على الجهاز خارج خيط الواجهة. المصدر: دليل برامج المزوّد. التطابق ترجيح، ليس ضمانًا أن البث مباشر.")
            }
            if !text.isEmpty {
                Section {
                    Button { UIPasteboard.general.string = text } label: { Label("نسخ التقرير", systemImage: "doc.on.doc") }
                    Text(text).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                }
            }
        }
        .navigationTitle("دليل المباريات")
        .onDisappear { cancel.set(); job?.cancel() }
    }

    private func start() {
        guard let x = library.xtream, let url = x.xmltvURL else { status = "يحتاج مصدر Xtream"; return }
        let flag = MatchGuideReport.CancelFlag(); cancel = flag
        // What the report needs from the library, copied on the main thread; the rest runs off it.
        let groups = Dictionary(library.liveCats.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
        let chans = library.channels.map { ReportChannel(name: $0.name, group: groups[$0.categoryId] ?? "", epg: $0.epgId) }
        let source = library.active?.name ?? "?"
        text = ""; status = "تنزيل الدليل…"
        job = Task {
            Perf.shared.memory("دليل المباريات: قبل التنزيل")
            let t0 = Perf.now()
            let r = await MatchGuideReport.download(url, cancel: flag) { mb in Task { @MainActor in status = "تنزيل الدليل… \(mb) MB" } }
            switch r {
            case .failure(let why):
                status = why.text; job = nil; return
            case .success(let (file, size)):
                defer { try? FileManager.default.removeItem(at: file) }
                Perf.shared.record("دليل المباريات: تنزيل الدليل", since: t0, "\(size / 1_048_576) MB")
                Perf.shared.memory("دليل المباريات: بعد التنزيل")
                status = "قراءة الدليل…"
                let t1 = Perf.now()
                let out = await Task.detached(priority: .utility) {
                    MatchGuideReport.build(file: file, size: size, channels: chans, source: source, now: Date(), cancel: flag)
                }.value
                Perf.shared.record("دليل المباريات: القراءة والمطابقة", since: t1, "")
                Perf.shared.memory("دليل المباريات: بعد القراءة")
                if flag.isSet { status = "أُلغي"; job = nil; return }
                text = out + String(format: "\nالذاكرة: الآن %.0f MB · أعلى منذ فتح التطبيق %.0f MB (تفاصيل المراحل في قياسات الأداء)\n",
                                    Perf.memoryMB ?? 0, Perf.peakMB ?? 0)
                status = "تم — الدليل \(size / 1_048_576) MB"
            }
            job = nil
        }
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
        var cancel: CancelFlag?
        /// Match titles on channels that are not sports channels (next 48 h): count + a few examples (guide id).
        var otherMatches = 0; var otherExamples: [String] = []; var window: ClosedRange<Int64> = 0...0
        private var otherCh: String?; private var otherStart: Int64 = 0; private var otherTitle = ""
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
                if cancel?.isSet == true { p.abortParsing(); return }
                otherCh = nil
                guard let ch = a["channel"] else { prog = nil; return }
                guard wantedIds.contains(ch.lowercased()) || idOfName[ch] != nil,
                      let st = Self.time(a["start"]), let sp = Self.time(a["stop"]) else {
                    prog = nil
                    if let st = Self.time(a["start"]), window.contains(st) { otherCh = ch; otherStart = st; otherTitle = "" }
                    return
                }
                prog = (ch, st, sp); title = ""; desc = ""
            case "title": field = prog != nil || otherCh != nil ? e : ""
            case "desc": field = prog != nil ? e : ""
            default: break
            }
        }
        func parser(_ p: XMLParser, foundCharacters s: String) {
            if inName { text += s }
            else if field == "title" { if prog != nil { title += s } else { otherTitle += s } } else if field == "desc" { desc += s }
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
                else if let ch = otherCh {
                    let t = otherTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                    // quick filter before the full rule
                    if [" v ", " vs ", " x ", " × ", " ضد "].contains(where: { t.lowercased().contains($0) }), MatchGuideRule.teams(t) != nil {
                        otherMatches += 1; if otherExamples.count < 10 { otherExamples.append("\(ch) · «\(t)»") }
                    }
                }
                prog = nil; otherCh = nil
            default: break
            }
        }
    }

    /// Safe size for the whole guide (bigger files are refused, before or while downloading).
    static let maxBytes: Int64 = 400 * 1_048_576

    final class CancelFlag: @unchecked Sendable {
        private let lock = NSLock(); private var on = false
        func set() { lock.lock(); on = true; lock.unlock() }
        var isSet: Bool { lock.lock(); defer { lock.unlock() }; return on }
    }

    /// Downloads to a file (never into memory), stopping at `maxBytes` or on cancel. No link in any message.
    static func download(_ url: URL, cancel: CancelFlag, progress: @escaping @Sendable (Int64) -> Void) async -> Result<(URL, Int64), Failure> {
        let d = GuideDownload(cancel, progress)
        let s = URLSession(configuration: .ephemeral, delegate: d, delegateQueue: nil)
        defer { s.finishTasksAndInvalidate() }
        return await withCheckedContinuation { c in
            d.done = { c.resume(returning: $0) }
            var r = URLRequest(url: url, timeoutInterval: 120)
            r.setValue("gzip", forHTTPHeaderField: "Accept-Encoding")
            s.downloadTask(with: r).resume()
        }
    }
    struct Failure: Error { let text: String; init(_ t: String) { text = t } }

    static func build(file: URL, size: Int64, channels: [ReportChannel], source: String, now: Date, cancel: CancelFlag) -> String {
        let sports = channels.filter { MatchGuideRule.isSportsChannel(name: $0.name, group: $0.group) }
        let p = Parser()
        p.cancel = cancel
        let nowMs0 = Int64(now.timeIntervalSince1970 * 1000)
        p.window = nowMs0...(nowMs0 + 2 * 86_400_000)
        p.wantedIds = Set(sports.compactMap { $0.epg?.lowercased() })
        p.wantedNames = Set(sports.map { nameKey($0.name) })
        guard let stream = InputStream(url: file) else { return "تعذّر فتح الدليل" }
        let xp = XMLParser(stream: stream); xp.delegate = p
        let parsed = xp.parse()
        let readError: String? = cancel.isSet ? "أُلغي" : parsed ? nil : "توقفت القراءة عند سطر \(xp.lineNumber): \(xp.parserError.map { ($0 as NSError).code } ?? 0)"
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
        var channelsWithGuide = Set<String>()
        for ch in sports {
            let list = (ch.epg.flatMap { byId[$0.lowercased()] } ?? byName[nameKey(ch.name)] ?? []).filter { $0.stop > from }
            guard !list.isEmpty else { continue }
            withGuide += 1; programmes += list.count
            channelsWithGuide.insert(MatchGuideRule.channelKey(ch.name))
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
        let sportKeys = Set(sports.map { MatchGuideRule.channelKey($0.name) })
        func pct(_ a: Int, _ b: Int) -> String { b > 0 ? " (\(a * 100 / b)٪)" : "" }
        let tz = TimeZone.current
        let ver = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        var s = "شاشة — تقرير دليل المباريات · الآيفون \(ver)\n"
        s += "المصدر: دليل برامج المزوّد. التطابق بالفريقين والوقت ترجيح قوي، وليس ضمانًا أن البث مباشر.\n"
        s += "وقت التقرير: \(d(nowMs)) · المنطقة الزمنية: \(tz.identifier) (UTC\(String(format: "%+.1f", Double(tz.secondsFromGMT()) / 3600)))\n"
        s += "المصادر المشمولة: \(source) (المصدر النشط فقط) · \(channels.count) قناة · الدليل نُزّل الآن (\(size / 1_048_576) MB)\n"
        if let e = readError { s += "خطأ قراءة الدليل: \(e) — الأرقام تشمل ما قُرئ قبله\n" }
        s += "\nتحديد القنوات الرياضية: \(MatchGuideRule.sportsRule).\n"
        s += "نسخ القنوات: الرياضية \(sports.count) · لها دليل \(withGuide)\(pct(withGuide, sports.count)) · بمعرّف دليل من المزوّد \(sports.filter { $0.epg != nil }.count)\n"
        s += "القنوات بعد جمع النسخ (بدون HD/FHD/4K/HEVC/RAW): الرياضية \(sportKeys.count) · لها دليل \(channelsWithGuide.count)\(pct(channelsWithGuide.count, sportKeys.count))\n"
        if withGuide > 0 {
            let med = spans.sorted()[spans.count / 2]
            s += "مدى الدليل: من \(d(minStart)) إلى \(d(maxStop)) · وسيط القناة \(String(format: "%.1f", Double(med) / 86_400_000)) يوم\n"
        }
        s += "برامج القنوات الرياضية (من 12 ساعة مضت): \(programmes) · فيها اسما فريقين: \(entries.count)\n"
        s += "التصنيف: " + MatchGuideRule.Kind.allCases.map { "\($0.label) \(kinds[$0] ?? 0)" }.joined(separator: " · ") + "\n"
        s += "مباريات اكتشفناها من الدليل خلال 48 ساعة (بطاقات، بدون الاستوديو): \(upcoming.count) · مكتوب «مباشر» في قناة واحدة على الأقل: \(upcoming.filter(\.live).count) · إعادات: \(upcoming.filter(\.replay).count)\n"
        s += "عناوين مباريات في قنوات غير مصنّفة رياضية (48 ساعة): \(p.otherMatches) — غير داخلة في البطاقات أعلاه\n"
        s += "نسبة تغطية مباريات اليوم: لا يمكن حسابها من هذا التقرير — تحتاج جدول مباريات مستقلًا للمقارنة.\n\n"
        s += "— أمثلة (أول 25 بطاقة)\n"
        for g in upcoming.prefix(25) {
            s += "\(d(g.start)) · \(g.home) × \(g.away) · \(g.entries.count) نسخة قناة" + (g.live ? " · مباشر" : "") + (g.replay ? " · إعادة" : "")
                + (g.entries.compactMap(\.competition).first.map { " · " + $0 } ?? "") + "\n"
            for e in g.entries.sorted(by: { (MatchGuideRule.version($0.channel).res, $0.channel) < (MatchGuideRule.version($1.channel).res, $1.channel) }).prefix(8) {
                s += "   - \(e.channel) [\(MatchGuideRule.version(e.channel).label())] · \(e.kind.label) · \(e.source) · «\(e.title)»\n"
            }
        }
        s += "\n— عناوين مباريات في قنوات غير رياضية (أمثلة، بمعرّف الدليل)\n"
        for x in p.otherExamples { s += "   \(x)\n" }
        s += "\n— عناوين رياضية لم يُستخرج منها فريقان (لتحسين القواعد)\n"
        for m in missed { s += "   «\(m)»\n" }
        return s
    }
}

/// Guide download for the report: to a file, stopped at the size limit or on cancel.
final class GuideDownload: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    var done: ((Result<(URL, Int64), MatchGuideReport.Failure>) -> Void)?
    let cancel: MatchGuideReport.CancelFlag; let progress: @Sendable (Int64) -> Void
    var lastMB: Int64 = -1
    init(_ c: MatchGuideReport.CancelFlag, _ p: @escaping @Sendable (Int64) -> Void) { cancel = c; progress = p }
    func urlSession(_ s: URLSession, downloadTask t: URLSessionDownloadTask, didWriteData w: Int64, totalBytesWritten n: Int64, totalBytesExpectedToWrite e: Int64) {
        if cancel.isSet || n > MatchGuideReport.maxBytes || e > MatchGuideReport.maxBytes { t.cancel(); return }
        if n / 1_048_576 != lastMB { lastMB = n / 1_048_576; progress(lastMB) }
    }
    func urlSession(_ s: URLSession, downloadTask t: URLSessionDownloadTask, didFinishDownloadingTo loc: URL) {
        let code = (t.response as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else { finish(.failure(MatchGuideReport.Failure("المزوّد ردّ \(code)"))); return }
        let dest = FileManager.default.temporaryDirectory.appendingPathComponent("guide-\(UUID().uuidString).xml")
        do { try FileManager.default.moveItem(at: loc, to: dest) } catch { finish(.failure(MatchGuideReport.Failure("تعذّر حفظ الدليل"))); return }
        let size = (try? FileManager.default.attributesOfItem(atPath: dest.path)[.size] as? NSNumber)?.int64Value ?? 0
        finish(.success((dest, size)))
    }
    func urlSession(_ s: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }
        let big = task.countOfBytesReceived > MatchGuideReport.maxBytes || task.countOfBytesExpectedToReceive > MatchGuideReport.maxBytes
        finish(.failure(MatchGuideReport.Failure(cancel.isSet ? "أُلغي" : big ? "الدليل أكبر من \(MatchGuideReport.maxBytes / 1_048_576) MB — أوقف للحماية"
                                : "تعذّر تنزيل الدليل (\((error as NSError).code))")))
    }
    func finish(_ r: Result<(URL, Int64), MatchGuideReport.Failure>) { if let d = done { done = nil; d(r) } }
}
