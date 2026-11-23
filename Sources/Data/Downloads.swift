import Foundation
import CryptoKit
import Network
import UIKit
import UserNotifications

/// 1.8.0: a film or episode kept on the phone for watching offline.
struct DownloadItem: Codable, Identifiable, Equatable {
    enum State: String, Codable {
        case queued, downloading, paused, waitingPlayback, waitingWifi, noSpace, failed, done
    }
    /// File name (per source + item, see DownloadRule.fileName).
    var id: String
    var sourceId: String
    /// Same key as resume points / subtitles ("movie:ID" / "ep:ID").
    var key: String
    var kind: String          // "movie" / "ep"
    var streamId: String
    var ext: String
    var title: String
    var queryName: String
    var season: Int?
    var number: Int?
    var traktName: String?
    var have: Int64 = 0
    var total: Int64?
    var state: State = .queued
    /// Why it stopped / what the viewer should know (Arabic, no links).
    var note: String?
    /// The viewer allowed mobile data for this download.
    var cellular = false
    /// Resume check result: nil = not checked yet.
    var resumable: Bool?
    var addedAt = Date()
}

/// Downloads for offline viewing. One at a time (the provider may allow a single connection), paused while a video
/// streams from the provider, Wi‑Fi unless the viewer allows mobile data for that download.
///
/// Pieces are fetched with a background URLSession and "Range: bytes=<have>-": iOS goes on with the transfer while
/// the app is in the background or the screen is locked. When the viewer swipes the app away in the app switcher,
/// iOS cancels its background transfers; the bytes already kept stay and the download goes on from there the next
/// time the app is opened (when the server accepts ranges). Every answer is checked (DownloadRule) before its bytes
/// are added; a file is ready only when every byte of the announced size is kept.
@MainActor
final class Downloads: NSObject, ObservableObject {
    static let shared = Downloads()

    @Published private(set) var items: [DownloadItem] = []
    /// Live progress of the piece downloading now (bytes of the whole file).
    @Published private(set) var liveHave: [String: Int64] = [:]
    /// A download waiting for the viewer's OK to use mobile data (shown as an alert while the app is open).
    @Published var cellularAsk: String?

    nonisolated private static let sessionId = "app.shasha.ios.downloads"
    var backgroundCompletion: (() -> Void)?
    private var session: URLSession!
    private var current: (id: String, task: URLSessionDownloadTask)?
    /// The item whose resume check is running (no download runs meanwhile).
    private var probing: String?
    /// Set while this app stops a piece itself (pause / playback), so the error that follows isn't a failure.
    private var stopping: Set<Int> = []
    private var streaming = false
    private var onWifi = true
    private var online = true
    private let monitor = NWPathMonitor()
    private var activated = false

    // MARK: Files

    nonisolated static var folder: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        var d = base.appendingPathComponent("Downloads", isDirectory: true)
        if !FileManager.default.fileExists(atPath: d.path) {
            try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
            var v = URLResourceValues(); v.isExcludedFromBackup = true
            try? d.setResourceValues(v)
        }
        return d
    }
    private func partURL(_ id: String) -> URL { Self.folder.appendingPathComponent(id + ".part") }
    private func doneURL(_ id: String) -> URL { Self.folder.appendingPathComponent(id) }
    private var stateURL: URL { Self.folder.appendingPathComponent("downloads.json") }

    private func save() {
        guard let d = try? JSONEncoder().encode(items) else { return }
        try? d.write(to: stateURL, options: .atomic)
    }

    private func load() {
        guard let d = try? Data(contentsOf: stateURL), var list = try? JSONDecoder().decode([DownloadItem].self, from: d) else { return }
        // The real size of what is kept wins over the saved number (the app may have stopped between the two).
        for i in list.indices {
            let it = list[i]
            if it.state == .done {
                let size = fileSize(doneURL(it.id))
                if !DownloadRule.isComplete(have: size, total: it.total) {
                    list[i].state = .failed; list[i].note = "الملف المحفوظ ناقص — احذفه ونزّله من جديد"; list[i].have = size
                }
            } else {
                list[i].have = fileSize(partURL(it.id))
                if it.state == .downloading || it.state == .waitingPlayback { list[i].state = .queued }
            }
        }
        items = list
    }

    private func fileSize(_ u: URL) -> Int64 {
        ((try? FileManager.default.attributesOfItem(atPath: u.path))?[.size] as? NSNumber)?.int64Value ?? 0
    }

    // MARK: Start

    /// Called at launch (AppDelegate): restores the list, reconnects to transfers iOS kept going, watches the network.
    func activate() {
        guard !activated else { return }
        activated = true
        load()
        let c = URLSessionConfiguration.background(withIdentifier: Self.sessionId)
        c.sessionSendsLaunchEvents = true
        c.isDiscretionary = false
        c.allowsCellularAccess = true            // decided per request (allowsCellularAccess on each piece)
        c.httpMaximumConnectionsPerHost = 1
        session = URLSession(configuration: c, delegate: self, delegateQueue: nil)
        session.getAllTasks { tasks in
            Task { @MainActor in self.reattach(tasks.compactMap { $0 as? URLSessionDownloadTask }) }
        }
        monitor.pathUpdateHandler = { path in
            let wifi = path.status == .satisfied && (path.usesInterfaceType(.wifi) || path.usesInterfaceType(.wiredEthernet))
            let up = path.status == .satisfied
            Task { @MainActor in self.network(wifi: wifi, online: up) }
        }
        monitor.start(queue: DispatchQueue(label: "shasha.downloads.net"))
    }

    private func reattach(_ tasks: [URLSessionDownloadTask]) {
        for t in tasks {
            if current == nil, let id = t.taskDescription, let i = index(id), items[i].state != .done {
                current = (id, t); items[i].state = .downloading
            } else {
                stopping.insert(t.taskIdentifier); t.cancel()     // an old piece nobody follows any more
            }
        }
        save()
        startNext()
    }

    private func index(_ id: String) -> Int? { items.firstIndex { $0.id == id } }

    func item(source: UUID?, key: String) -> DownloadItem? {
        guard let s = source?.uuidString else { return nil }
        return items.first { $0.sourceId == s && $0.key == key }
    }

    /// The finished file for this film/episode of this source, when it is complete on the phone.
    func localFile(source: UUID?, key: String) -> URL? {
        guard let it = item(source: source, key: key), it.state == .done else { return nil }
        let u = doneURL(it.id)
        return DownloadRule.isComplete(have: fileSize(u), total: it.total) ? u : nil
    }

    // MARK: Viewer actions

    func add(source: Source, key: String, kind: String, streamId: String, ext: String, title: String,
             queryName: String, season: Int?, number: Int?, traktName: String?) {
        let id = DownloadRule.fileName(source: source.id.uuidString, key: key, ext: ext, sha256: Self.sha)
        guard index(id) == nil else { return }
        items.append(DownloadItem(id: id, sourceId: source.id.uuidString, key: key, kind: kind, streamId: streamId, ext: ext,
                                  title: title, queryName: queryName, season: season, number: number, traktName: traktName))
        save()
        askNotifications()
        // The subtitle kept for this item comes onto the phone now (from Drive), so it is there offline.
        let src = source
        Task { _ = await SubShare.saved(storeKey: key, source: src) }
        startNext()
    }

    func pause(_ id: String) {
        guard let i = index(id) else { return }
        items[i].state = .paused; items[i].note = nil
        stopCurrent(if: id)
        save()
    }

    func resume(_ id: String) {
        guard let i = index(id), items[i].state != .done else { return }
        items[i].state = .queued; items[i].note = nil
        save(); startNext()
    }

    func allowCellular(_ id: String) {
        guard let i = index(id) else { return }
        items[i].cellular = true
        if items[i].state == .waitingWifi { items[i].state = .queued }
        items[i].note = nil
        cellularAsk = nil
        // A piece waiting for Wi‑Fi is replaced by one allowed on mobile data.
        stopCurrent(if: id)
        save(); startNext()
    }

    func delete(_ id: String) {
        guard let i = index(id) else { return }
        if let c = current, c.id == id { stopping.insert(c.task.taskIdentifier); c.task.cancel(); current = nil }
        try? FileManager.default.removeItem(at: partURL(id))
        try? FileManager.default.removeItem(at: doneURL(id))
        items.remove(at: i); liveHave[id] = nil
        save(); startNext()
    }

    /// The player opened (network = streams from the provider) or closed (nil). Streaming pauses the download.
    func playing(network: Bool?) {
        let now = network == true
        guard now != streaming else { return }
        streaming = now
        if now {
            if let c = current, let i = index(c.id) {
                items[i].state = .waitingPlayback
                stopCurrent(if: c.id)
                Perf.shared.add("تنزيل: توقف أثناء المشاهدة", ms: 0, "")
            }
        } else {
            for i in items.indices where items[i].state == .waitingPlayback { items[i].state = .queued }
            startNext()
        }
        save()
    }

    // MARK: Network

    private func network(wifi: Bool, online: Bool) {
        let wasWifi = onWifi
        onWifi = wifi; self.online = online
        if wifi && !wasWifi {
            for i in items.indices where items[i].state == .waitingWifi { items[i].state = .queued; items[i].note = nil }
            save(); startNext()
        } else if !wifi && online, let c = current, let i = index(c.id), !items[i].cellular {
            // Wi‑Fi gone while downloading: the piece waits (it isn't allowed on mobile data); ask the viewer.
            items[i].state = .waitingWifi
            stopCurrent(if: c.id)
            ask(items[i]); save()
        }
    }

    // MARK: Pieces

    private func startNext() {
        guard current == nil, probing == nil, !streaming, session != nil else { return }
        guard let i = items.firstIndex(where: { $0.state == .queued || $0.state == .downloading }) else { return }
        var it = items[i]
        if online && !onWifi && !it.cellular {
            items[i].state = .waitingWifi
            items[i].note = "ينتظر Wi‑Fi"
            ask(items[i]); save(); return
        }
        guard let url = streamURL(it) else {
            items[i].state = .failed; items[i].note = "المصدر غير موجود في التطبيق"; save(); startNext(); return
        }
        let free = (try? Self.folder.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage ?? Int64.max
        if !DownloadRule.enoughSpace(free: free, have: it.have, total: it.total) {
            items[i].state = .noSpace
            items[i].note = "المساحة لا تكفي (المتاح \(ByteCountFormatter.string(fromByteCount: free, countStyle: .file)))"
            save(); return
        }
        if it.resumable == nil {
            // First piece: check from the middle of the file that the server really resumes (206 + Content-Range).
            items[i].state = .downloading; items[i].note = "فحص دعم الاستكمال…"
            let id = it.id, cell = it.cellular
            probing = id
            Task {
                let r = await Self.probe(url, cellular: cell)
                await MainActor.run {
                    self.probing = nil
                    guard let j = self.index(id) else { self.startNext(); return }
                    switch r {
                    case .resumable(let total):
                        self.items[j].resumable = true; self.items[j].total = self.items[j].total ?? total; self.items[j].note = nil
                        Perf.shared.add("تنزيل: فحص الاستكمال", ms: 0, "206 · Content-Range صحيح · \(total / 1_048_576) MB")
                    case .notResumable(let why):
                        self.items[j].resumable = false
                        self.items[j].note = "المزوّد لا يدعم الإكمال من نفس المكان (\(why)) — أي انقطاع يعيد التحميل من البداية"
                        Perf.shared.add("تنزيل: فحص الاستكمال", ms: 0, why)
                    }
                    if self.items[j].state == .downloading { self.items[j].state = .queued }
                    self.save(); self.startNext()
                }
            }
            save(); return
        }
        var r = URLRequest(url: url)
        r.setValue("bytes=\(it.have)-", forHTTPHeaderField: "Range")
        r.allowsCellularAccess = it.cellular
        let t = session.downloadTask(with: r)
        t.taskDescription = it.id
        current = (it.id, t)
        it.state = .downloading; it.note = nil
        items[i] = it
        save()
        t.resume()
    }

    /// Stops the piece of this item (keeping what URLSession received, when it can be recovered).
    private func stopCurrent(if id: String) {
        guard let c = current, c.id == id else { return }
        current = nil
        let task = c.task
        stopping.insert(task.taskIdentifier)
        let response = task.response as? HTTPURLResponse
        task.cancel(byProducingResumeData: { data in
            Task { @MainActor in
                self.salvage(id: id, resumeData: data, response: response)
                self.startNext()
            }
        })
    }

    /// Adds the bytes an interrupted piece received (from URLSession's kept temporary file) — only after checking
    /// that the answer started exactly at the kept size. Otherwise nothing is added and the loss is logged.
    private func salvage(id: String, resumeData: Data?, response: HTTPURLResponse?) {
        guard let i = index(id) else { return }
        liveHave[id] = nil
        guard let data = resumeData, let info = DownloadRule.resumeInfo(data), let resp = response,
              let tmp = Self.findTemp(info.file) else {
            if resumeData != nil { Perf.shared.add("تنزيل: انقطع — لم يُسترجع الجزء الأخير", ms: 0, "") }
            return
        }
        defer { try? FileManager.default.removeItem(at: tmp) }
        let it = items[i]
        let reply = DownloadRule.reply(status: resp.statusCode, contentRange: resp.value(forHTTPHeaderField: "Content-Range"),
                                       contentLength: resp.expectedContentLength > 0 ? resp.expectedContentLength : nil,
                                       have: it.have, knownTotal: it.total)
        let fromZero: Bool
        switch reply {
        case .append(let t): items[i].total = t; fromZero = false
        case .restart(let t, _): items[i].total = t; fromZero = true
        default: Perf.shared.add("تنزيل: انقطع — الجزء الأخير لم يطابق", ms: 0, ""); return
        }
        let base = fromZero ? 0 : it.have
        let n = DownloadRule.salvage(received: min(info.bytes, fileSize(tmp)), have: base, total: items[i].total)
        guard n > 0 else { return }
        if append(from: tmp, count: n, to: partURL(id), truncateTo: base) {
            items[i].have = base + n
            Perf.shared.add("تنزيل: انقطع — حُفظ ما وصل", ms: 0, "\(n / 1_048_576) MB · المجموع \(items[i].have / 1_048_576) MB")
        }
        save()
    }

    /// Writes the first `count` bytes of `src` after the first `truncateTo` bytes of `dst` (the rest of dst is cut).
    private func append(from src: URL, count: Int64, to dst: URL, truncateTo: Int64) -> Bool {
        if !FileManager.default.fileExists(atPath: dst.path) { FileManager.default.createFile(atPath: dst.path, contents: nil) }
        guard let r = try? FileHandle(forReadingFrom: src), let w = try? FileHandle(forWritingTo: dst) else { return false }
        defer { try? r.close(); try? w.close() }
        do {
            try w.truncate(atOffset: UInt64(truncateTo))
            try w.seek(toOffset: UInt64(truncateTo))
            var left = count
            while left > 0 {
                let chunk = try r.read(upToCount: Int(min(left, 4_194_304))) ?? Data()
                if chunk.isEmpty { break }
                try w.write(contentsOf: chunk)
                left -= Int64(chunk.count)
            }
            try w.synchronize()
            return left == 0
        } catch { return false }
    }

    /// A finished piece (moved out of URLSession's folder before this runs).
    private func pieceDone(id: String, file: URL, status: Int, contentRange: String?, length: Int64?) {
        defer { try? FileManager.default.removeItem(at: file) }
        if current?.id == id { current = nil }
        liveHave[id] = nil
        guard let i = index(id) else { startNext(); return }
        let it = items[i]
        let size = fileSize(file)
        switch DownloadRule.reply(status: status, contentRange: contentRange, contentLength: length, have: it.have, knownTotal: it.total) {
        case .append(let t):
            items[i].total = t
            let n = DownloadRule.salvage(received: size, have: it.have, total: t)
            if append(from: file, count: n, to: partURL(id), truncateTo: it.have) { items[i].have = it.have + n }
        case .restart(let t, let ignored):
            items[i].total = t
            if append(from: file, count: DownloadRule.salvage(received: size, have: 0, total: t), to: partURL(id), truncateTo: 0) {
                items[i].have = min(size, t ?? size)
            }
            if ignored {
                items[i].resumable = false
                items[i].note = "المزوّد تجاهل طلب الإكمال وأرسل الملف من البداية — حُفظ بدون تكرار"
            }
        case .complete:
            break
        case .stop(let s):
            items[i].state = .failed
            switch s {
            case .changed: items[i].note = "الملف تغيّر عند المزوّد — احذفه ونزّله من جديد"
            case .wrongStart: items[i].note = "المزوّد ردّ بجزء من موضع مختلف — لم يُضف شيء"
            case .http(let c): items[i].note = c == 401 || c == 403 ? "المزوّد رفض الطلب (\(c)) — قد يكون الحساب مستخدمًا الآن" : "المزوّد ردّ \(c)"
            case .noTotal: items[i].note = "حجم الملف غير معروف"
            }
            save(); startNext(); return
        }
        if DownloadRule.isComplete(have: items[i].have, total: items[i].total) {
            do {
                try? FileManager.default.removeItem(at: doneURL(id))
                try FileManager.default.moveItem(at: partURL(id), to: doneURL(id))
                items[i].state = .done; items[i].note = nil
                Perf.shared.add("تنزيل: اكتمل وتحقق الحجم", ms: 0, "\(items[i].have / 1_048_576) MB")
                notify("اكتمل التحميل", items[i].title)
            } catch {
                items[i].state = .failed; items[i].note = "تعذّر حفظ الملف"
            }
        } else if items[i].state == .downloading {
            items[i].state = .queued              // the piece ended early: the next one goes on from here
        }
        save(); startNext()
    }

    private func pieceFailed(id: String, taskId: Int, error: Error, response: HTTPURLResponse?) {
        if stopping.remove(taskId) != nil { return }    // stopped by this app (pause / playback / Wi‑Fi)
        if current?.id == id { current = nil }
        let ns = error as NSError
        let data = ns.userInfo[NSURLSessionDownloadTaskResumeData] as? Data
        salvage(id: id, resumeData: data, response: response)
        if let i = index(id) {
            if ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled {
                // iOS cancelled it (app swiped away / relaunched): the kept bytes stay; it goes on when possible.
                items[i].state = .queued
            } else {
                items[i].state = .paused
                items[i].note = "انقطع التحميل (\(ns.code)) — اضغط استكمال"
            }
        }
        save(); startNext()
    }

    private func streamURL(_ it: DownloadItem) -> URL? {
        guard let d = UserDefaults.standard.data(forKey: "sources.v1"),
              let s = (try? JSONDecoder().decode([Source].self, from: d))?.first(where: { $0.id.uuidString == it.sourceId }),
              s.kind == .xtream else { return nil }
        let x = Xtream(server: s.server, user: s.username, pass: Keychain.get(s.id.uuidString) ?? "")
        return URL(string: it.kind == "ep" ? x.episodeURL(it.streamId, it.ext) : x.movieURL(it.streamId, it.ext))
    }

    // MARK: Resume check

    /// Asks for 1 MiB from the middle of the file. The total comes from a first 1-byte request.
    nonisolated static func probe(_ url: URL, cellular: Bool) async -> DownloadRule.Probe {
        let c = URLSessionConfiguration.ephemeral
        c.allowsCellularAccess = cellular
        c.httpMaximumConnectionsPerHost = 1
        let s = URLSession(configuration: c)
        defer { s.finishTasksAndInvalidate() }
        func get(_ a: Int64, _ b: Int64) async throws -> (HTTPURLResponse, Int64) {
            var r = URLRequest(url: url, timeoutInterval: 30)
            r.setValue("bytes=\(a)-\(b)", forHTTPHeaderField: "Range")
            let (data, resp) = try await s.data(for: r)
            guard let h = resp as? HTTPURLResponse else { throw URLError(.badServerResponse) }
            return (h, Int64(data.count))
        }
        do {
            let (h0, n0) = try await get(0, 0)
            guard case .resumable(let total) = DownloadRule.probe(status: h0.statusCode, contentRange: h0.value(forHTTPHeaderField: "Content-Range"),
                                                                start: 0, end: 0, receivedBytes: n0) else {
                return .notResumable("ردّ \(h0.statusCode) على طلب البداية")
            }
            guard total > 2_097_152 else { return .resumable(total: total) }
            let mid = total / 2, end = mid + 1_048_575
            let (h, n) = try await get(mid, end)
            return DownloadRule.probe(status: h.statusCode, contentRange: h.value(forHTTPHeaderField: "Content-Range"),
                                      start: mid, end: end, receivedBytes: n)
        } catch {
            return .notResumable("تعذّر الفحص: \((error as NSError).code)")
        }
    }

    // MARK: Asking / telling

    private func askNotifications() {
        UNUserNotificationCenter.current().getNotificationSettings { s in
            guard s.authorizationStatus == .notDetermined else { return }
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }
    }

    nonisolated static let cellularCategory = "shasha.dl.cellular"
    nonisolated static let cellularAction = "shasha.dl.allowCellular"

    nonisolated static func registerCategories() {
        let ok = UNNotificationAction(identifier: cellularAction, title: "موافق — كمّل ببيانات الجوال", options: [])
        let cat = UNNotificationCategory(identifier: cellularCategory, actions: [ok], intentIdentifiers: [], options: [])
        UNUserNotificationCenter.current().setNotificationCategories([cat])
    }

    private func ask(_ it: DownloadItem) {
        if UIApplication.shared.applicationState == .active {
            cellularAsk = it.id
        } else {
            let c = UNMutableNotificationContent()
            c.title = "التحميل ينتظر Wi‑Fi"
            c.body = "«\(it.title)» — اضغط «موافق» للمتابعة ببيانات الجوال"
            c.categoryIdentifier = Self.cellularCategory
            c.userInfo = ["dl": it.id]
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "dl.cell." + it.id, content: c, trigger: nil))
        }
    }

    private func notify(_ title: String, _ body: String) {
        guard UIApplication.shared.applicationState != .active else { return }
        let c = UNMutableNotificationContent(); c.title = title; c.body = body
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil))
    }

    // MARK: Helpers

    nonisolated static func sha(_ s: String) -> String { SHA256.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined() }

    /// URLSession's temporary file of an interrupted piece: in tmp or in the background daemon's folder of this app.
    nonisolated static func findTemp(_ name: String) -> URL? {
        let fm = FileManager.default
        var roots = [fm.temporaryDirectory]
        if let caches = fm.urls(for: .cachesDirectory, in: .userDomainMask).first {
            roots.append(caches.appendingPathComponent("com.apple.nsurlsessiond", isDirectory: true))
            roots.append(caches)
        }
        for r in roots {
            let direct = r.appendingPathComponent(name)
            if fm.fileExists(atPath: direct.path) { return direct }
            if let e = fm.enumerator(at: r, includingPropertiesForKeys: nil) {
                var seen = 0
                while let u = e.nextObject() as? URL, seen < 5_000 {
                    seen += 1
                    if u.lastPathComponent == name { return u }
                }
            }
        }
        return nil
    }

    var anyActive: Bool { items.contains { $0.state != .done && $0.state != .failed && $0.state != .paused } }
}

// MARK: URLSession (callbacks come on a background queue)

extension Downloads: URLSessionDownloadDelegate {
    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                                totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard let id = downloadTask.taskDescription else { return }
        Task { @MainActor in
            guard let it = self.items.first(where: { $0.id == id }) else { return }
            self.liveHave[id] = it.have + totalBytesWritten
        }
    }

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let id = downloadTask.taskDescription else { return }
        // The file must leave URLSession's folder before this returns.
        let hold = Downloads.folder.appendingPathComponent(id + ".piece-" + UUID().uuidString)
        do { try FileManager.default.moveItem(at: location, to: hold) } catch { return }
        let h = downloadTask.response as? HTTPURLResponse
        let status = h?.statusCode ?? 0
        let cr = h?.value(forHTTPHeaderField: "Content-Range")
        let len = (h?.expectedContentLength ?? -1) > 0 ? h?.expectedContentLength : nil
        Task { @MainActor in self.pieceDone(id: id, file: hold, status: status, contentRange: cr, length: len) }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error, let id = task.taskDescription else { return }
        let taskId = task.taskIdentifier
        let resp = task.response as? HTTPURLResponse
        Task { @MainActor in self.pieceFailed(id: id, taskId: taskId, error: error, response: resp) }
    }

    nonisolated func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        Task { @MainActor in
            self.backgroundCompletion?()
            self.backgroundCompletion = nil
        }
    }
}

// MARK: Notification action ("OK — continue on mobile data")

extension Downloads: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let id = response.notification.request.content.userInfo["dl"] as? String
        let allow = response.actionIdentifier == Downloads.cellularAction
        Task { @MainActor in
            if let id, allow { self.allowCellular(id) } else if let id { self.cellularAsk = id }
            completionHandler()
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}

/// 1.8.0: background transfers need the app delegate (iOS hands over a completion handler when it wakes the app).
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = Downloads.shared
        Downloads.registerCategories()
        Downloads.shared.activate()
        return true
    }

    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String, completionHandler: @escaping () -> Void) {
        Downloads.shared.backgroundCompletion = completionHandler
        Downloads.shared.activate()
    }
}
