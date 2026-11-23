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
/// 1.8.1 — how the bytes are kept (1.8.0 relied on iOS "resume data", which iOS only makes when the server sends
/// ETag / Last-Modified; the owner's provider apparently doesn't, so a pause lost everything):
/// - App open: a normal request "Range: bytes=<kept>-" whose bytes are written to the file as they arrive (FgLoader).
///   Pause, playback, Wi‑Fi loss, airplane mode or a network error lose nothing: the file holds every byte received.
/// - App going to the background: the open request stops (its bytes are kept) and the rest continues as one
///   background download (iOS goes on with it in the background / screen locked); it is added when it finishes.
///   Stopped before it finishes, only what it fetched in the background may have to be fetched again (iOS hands those
///   bytes back only when the server allows resuming the iOS way); the screen says so.
/// - App swiped away in the app switcher: iOS stops its transfers; what was kept stays; it goes on when opened.
/// Every answer is checked (DownloadRule) before bytes are added; a file is ready only at the announced size.
@MainActor
final class Downloads: NSObject, ObservableObject {
    static let shared = Downloads()

    @Published private(set) var items: [DownloadItem] = []
    /// Live progress (bytes of the whole file) of the download running now.
    @Published private(set) var liveHave: [String: Int64] = [:]
    /// A download waiting for the viewer's OK to use mobile data (shown as an alert while the app is open).
    @Published var cellularAsk: String?

    nonisolated private static let sessionId = "app.shasha.ios.downloads"
    var backgroundCompletion: (() -> Void)?
    private var session: URLSession!
    private let fg = FgLoader()
    private enum Running { case fg(URLSessionDataTask), bg(URLSessionDownloadTask) }
    private var current: (id: String, run: Running)?
    /// The item whose resume check is running (no download runs meanwhile).
    private var probing: String?
    /// Tasks this app stopped itself (pause / playback / Wi‑Fi / going to the background).
    private var stopping: Set<Int> = []
    /// Called once the open request stopped by this app has closed its file.
    private var afterStop: [Int: () -> Void] = [:]
    private var streaming = false
    private var onWifi = true
    private var online = true
    private var active = true
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
    nonisolated static func partURL(_ id: String) -> URL { folder.appendingPathComponent(id + ".part") }
    private func doneURL(_ id: String) -> URL { Self.folder.appendingPathComponent(id) }
    private var stateURL: URL { Self.folder.appendingPathComponent("downloads.json") }

    private func save() {
        guard let d = try? JSONEncoder().encode(items) else { return }
        try? d.write(to: stateURL, options: .atomic)
    }

    private func load() {
        guard let d = try? Data(contentsOf: stateURL), var list = try? JSONDecoder().decode([DownloadItem].self, from: d) else { return }
        // The size of the file itself wins over the saved number (the app may have stopped between the two).
        for i in list.indices {
            let it = list[i]
            if it.state == .done {
                let size = fileSize(doneURL(it.id))
                if !DownloadRule.isComplete(have: size, total: it.total) {
                    list[i].state = .failed; list[i].note = "الملف المحفوظ ناقص — احذفه ونزّله من جديد"; list[i].have = size
                }
            } else {
                list[i].have = fileSize(Self.partURL(it.id))
                if it.state == .downloading || it.state == .waitingPlayback { list[i].state = .queued }
            }
        }
        items = list
    }

    nonisolated static func fileBytes(_ u: URL) -> Int64 {
        ((try? FileManager.default.attributesOfItem(atPath: u.path))?[.size] as? NSNumber)?.int64Value ?? 0
    }
    private func fileSize(_ u: URL) -> Int64 { Self.fileBytes(u) }

    // MARK: Start

    /// Called at launch (AppDelegate): restores the list, reconnects to a background transfer iOS kept going,
    /// watches the network and the app going to / coming back from the background.
    func activate() {
        guard !activated else { return }
        activated = true
        active = UIApplication.shared.applicationState != .background
        load()
        let c = URLSessionConfiguration.background(withIdentifier: Self.sessionId)
        c.sessionSendsLaunchEvents = true
        c.isDiscretionary = false
        c.allowsCellularAccess = true            // decided per request
        c.httpMaximumConnectionsPerHost = 1
        session = URLSession(configuration: c, delegate: self, delegateQueue: nil)
        fg.onProgress = { id, have in Task { @MainActor in Downloads.shared.liveHave[id] = have } }
        fg.onDone = { id, taskId, reply, error in Task { @MainActor in Downloads.shared.fgDone(id: id, taskId: taskId, reply: reply, error: error) } }
        session.getAllTasks { tasks in
            Task { @MainActor in Downloads.shared.reattach(tasks.compactMap { $0 as? URLSessionDownloadTask }) }
        }
        monitor.pathUpdateHandler = { path in
            let wifi = path.status == .satisfied && (path.usesInterfaceType(.wifi) || path.usesInterfaceType(.wiredEthernet))
            let up = path.status == .satisfied
            Task { @MainActor in Downloads.shared.network(wifi: wifi, online: up) }
        }
        monitor.start(queue: DispatchQueue(label: "shasha.downloads.net"))
        let nc = NotificationCenter.default
        nc.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in Downloads.shared.wentToBackground() }
        }
        nc.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in Downloads.shared.active = true; Downloads.shared.startNext() }
        }
    }

    private func reattach(_ tasks: [URLSessionDownloadTask]) {
        for t in tasks {
            if current == nil, let id = t.taskDescription, let i = index(id), items[i].state != .done {
                current = (id, .bg(t)); items[i].state = .downloading
                items[i].note = "يكمل في الخلفية (iOS)"
            } else {
                stopping.insert(t.taskIdentifier); t.cancel()     // an old transfer nobody follows any more
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
        stopCurrent(if: id)      // a request waiting for Wi‑Fi is replaced by one allowed on mobile data
        save(); startNext()
    }

    func delete(_ id: String) {
        guard let i = index(id) else { return }
        if let c = current, c.id == id {
            switch c.run {
            case .fg(let t): stopping.insert(t.taskIdentifier); t.cancel()
            case .bg(let t): stopping.insert(t.taskIdentifier); t.cancel()
            }
            current = nil
        }
        try? FileManager.default.removeItem(at: Self.partURL(id))
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

    // MARK: Network / app state

    private func network(wifi: Bool, online: Bool) {
        let wasWifi = onWifi, wasOnline = self.online
        onWifi = wifi; self.online = online
        if (wifi && !wasWifi) || (online && !wasOnline) {
            for i in items.indices where items[i].state == .waitingWifi && (wifi || items[i].cellular) {
                items[i].state = .queued; items[i].note = nil
            }
            for i in items.indices where items[i].state == .queued && items[i].note == "ينتظر الاتصال" { items[i].note = nil }
            save(); startNext()
        } else if !wifi && online, let c = current, let i = index(c.id), !items[i].cellular {
            items[i].state = .waitingWifi
            stopCurrent(if: c.id)
            ask(items[i]); save()
        }
    }

    /// Going to the background: the open request stops (bytes kept) and the rest goes on as a background download.
    private func wentToBackground() {
        active = false
        guard let c = current, case .fg = c.run else { return }
        let id = c.id
        let bgTask = UIApplication.shared.beginBackgroundTask(withName: "shasha.download.handover")
        stopCurrent(if: id, then: {
            if let i = self.index(id), self.items[i].state == .downloading { self.items[i].state = .queued }
            self.startNext()
            UIApplication.shared.endBackgroundTask(bgTask)
        })
    }

    // MARK: Requests

    private func startNext() {
        guard current == nil, probing == nil, !streaming, session != nil else { return }
        guard let i = items.firstIndex(where: { $0.state == .queued || $0.state == .downloading }) else { return }
        var it = items[i]
        if !online { items[i].note = "ينتظر الاتصال"; save(); return }
        if !onWifi && !it.cellular {
            items[i].state = .waitingWifi; items[i].note = "ينتظر Wi‑Fi"
            ask(items[i]); save(); return
        }
        guard let url = streamURL(it) else {
            items[i].state = .failed; items[i].note = "المصدر غير موجود في التطبيق"; save(); startNext(); return
        }
        it.have = fileSize(Self.partURL(it.id))       // what is really on disk
        let free = (try? Self.folder.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage ?? Int64.max
        if !DownloadRule.enoughSpace(free: free, have: it.have, total: it.total) {
            items[i].state = .noSpace
            let need = (it.total ?? 0) - it.have + DownloadRule.spareBytes
            items[i].note = "يحتاج \(Self.size(need)) (الباقي + 1 GB احتياط)، والمتاح \(Self.size(free))"
            save(); return
        }
        if it.resumable == nil {
            // First: check from the middle of the file that the server really resumes (206 + Content-Range).
            items[i].state = .downloading; items[i].note = "فحص دعم الاستكمال…"
            let id = it.id, cell = it.cellular
            probing = id
            Task {
                let r = await Downloads.probe(url, cellular: cell)
                await MainActor.run { Downloads.shared.probed(id, r) }
            }
            save(); return
        }
        var r = URLRequest(url: url)
        r.setValue("bytes=\(it.have)-", forHTTPHeaderField: "Range")
        r.allowsCellularAccess = it.cellular
        it.state = .downloading
        if active {
            // App open: bytes are written as they arrive (nothing lost on any stop).
            let t = fg.start(id: it.id, have: it.have, total: it.total, request: r)
            current = (it.id, .fg(t)); it.note = nil
        } else {
            let t = session.downloadTask(with: r)
            t.taskDescription = it.id
            current = (it.id, .bg(t)); it.note = "يكمل في الخلفية (iOS)"
            t.resume()
        }
        items[i] = it
        save()
    }

    private func probed(_ id: String, _ r: DownloadRule.Probe) {
        probing = nil
        guard let j = index(id) else { startNext(); return }
        switch r {
        case .resumable(let total):
            items[j].resumable = true; items[j].total = items[j].total ?? total; items[j].note = nil
            Perf.shared.add("تنزيل: فحص الاستكمال", ms: 0, "206 · Content-Range صحيح من وسط الملف · \(total / 1_048_576) MB")
        case .notResumable(let why):
            items[j].resumable = false
            items[j].note = "المزوّد لا يدعم الإكمال من نفس المكان (\(why)) — أي انقطاع يعيد التحميل من البداية"
            Perf.shared.add("تنزيل: فحص الاستكمال", ms: 0, why)
        }
        if items[j].state == .downloading { items[j].state = .queued }
        save(); startNext()
    }

    /// Stops the request of this item. An open request's bytes are already in the file; a background download's
    /// bytes are added only if iOS hands them back.
    private func stopCurrent(if id: String, then: (() -> Void)? = nil) {
        guard let c = current, c.id == id else { then?(); return }
        current = nil
        switch c.run {
        case .fg(let t):
            stopping.insert(t.taskIdentifier)
            if let then { afterStop[t.taskIdentifier] = then }
            t.cancel()
        case .bg(let task):
            stopping.insert(task.taskIdentifier)
            let response = task.response as? HTTPURLResponse
            let gotten = task.countOfBytesReceived
            task.cancel(byProducingResumeData: { data in
                Task { @MainActor in
                    Downloads.shared.salvage(id: id, resumeData: data, response: response, received: gotten)
                    then?()
                    Downloads.shared.startNext()
                }
            })
        }
    }

    /// An open request ended (stopped, failed, or finished). The file already holds its bytes.
    private func fgDone(id: String, taskId: Int, reply: DownloadRule.Reply?, error: Error?) {
        let ours = stopping.remove(taskId) != nil
        if let c = current, c.id == id, case .fg(let t) = c.run, t.taskIdentifier == taskId { current = nil }
        liveHave[id] = nil
        let then = afterStop.removeValue(forKey: taskId)
        defer { then?() }
        guard let i = index(id) else { startNext(); return }
        items[i].have = fileSize(Self.partURL(id))
        switch reply {
        case .append(let t)?: items[i].total = t
        case .restart(let t, let ignored)?:
            items[i].total = t
            if ignored {
                items[i].resumable = false
                items[i].note = "المزوّد تجاهل طلب الإكمال وأرسل الملف من البداية — حُفظ بدون تكرار"
            }
        case .stop(let s)?:
            stopped(i, s); save(); startNext(); return
        default: break
        }
        if finishIfComplete(i) { save(); startNext(); return }
        if ours {
            Perf.shared.add("تنزيل: إيقاف — المحفوظ في الملف", ms: 0, "\(items[i].have / 1_048_576) MB")
        } else if let e = error as NSError? {
            // Network error / airplane mode: nothing is lost; it goes on when the connection is back.
            items[i].state = .queued
            items[i].note = "انقطع الاتصال (\(e.code)) — المحفوظ \(Self.size(items[i].have))، يكمل لما يرجع الاتصال"
            Perf.shared.add("تنزيل: انقطع — المحفوظ في الملف", ms: 0, "\(items[i].have / 1_048_576) MB")
            save()
            if online { DispatchQueue.main.asyncAfter(deadline: .now() + 5) { Downloads.shared.startNext() } }
            return
        } else if items[i].state == .downloading {
            items[i].state = .queued              // ended early: go on from here
        }
        save(); startNext()
    }

    private func stopped(_ i: Int, _ s: DownloadRule.Stop) {
        items[i].state = .failed
        switch s {
        case .changed: items[i].note = "الملف تغيّر عند المزوّد — احذفه ونزّله من جديد"
        case .wrongStart: items[i].note = "المزوّد ردّ بجزء من موضع مختلف — لم يُضف شيء"
        case .http(let c): items[i].note = c == 401 || c == 403 ? "المزوّد رفض الطلب (\(c)) — قد يكون الحساب مستخدمًا الآن" : "المزوّد ردّ \(c)"
        case .noTotal: items[i].note = "حجم الملف غير معروف"
        }
    }

    private func finishIfComplete(_ i: Int) -> Bool {
        guard DownloadRule.isComplete(have: items[i].have, total: items[i].total) else { return false }
        let id = items[i].id
        do {
            try? FileManager.default.removeItem(at: doneURL(id))
            try FileManager.default.moveItem(at: Self.partURL(id), to: doneURL(id))
            items[i].state = .done; items[i].note = nil
            Perf.shared.add("تنزيل: اكتمل وتحقق الحجم", ms: 0, "\(items[i].have) بايت = الحجم المعلن")
            notify("اكتمل التحميل", items[i].title)
        } catch {
            items[i].state = .failed; items[i].note = "تعذّر حفظ الملف"
        }
        return true
    }

    /// Adds the bytes a stopped background download received, when iOS hands them back (resume data + its
    /// temporary file) — only after checking the answer started exactly at the kept size.
    private func salvage(id: String, resumeData: Data?, response: HTTPURLResponse?, received: Int64) {
        guard let i = index(id) else { return }
        liveHave[id] = nil
        guard let data = resumeData, let info = DownloadRule.resumeInfo(data), let resp = response,
              let tmp = Self.findTemp(info.file) else {
            if received > 0 {
                items[i].note = "ما نزل في الخلفية (\(Self.size(received))) لم يُسترجع وسيُعاد — المحفوظ \(Self.size(items[i].have))"
                Perf.shared.add("تنزيل: إيقاف تنزيل الخلفية — لم يُسترجع", ms: 0,
                                "\(received / 1_048_576) MB · resumeData=\(resumeData == nil ? "لا" : "نعم")")
            }
            save(); return
        }
        defer { try? FileManager.default.removeItem(at: tmp) }
        let it = items[i]
        let reply = DownloadRule.reply(status: resp.statusCode, contentRange: resp.value(forHTTPHeaderField: "Content-Range"),
                                       contentLength: resp.expectedContentLength > 0 ? resp.expectedContentLength : nil,
                                       have: it.have, knownTotal: it.total)
        let base: Int64
        switch reply {
        case .append(let t): items[i].total = t; base = it.have
        case .restart(let t, _): items[i].total = t; base = 0
        default: Perf.shared.add("تنزيل: الجزء المسترجع لم يطابق", ms: 0, ""); return
        }
        let n = DownloadRule.salvage(received: min(info.bytes, fileSize(tmp)), have: base, total: items[i].total)
        if n > 0, Self.append(from: tmp, count: n, to: Self.partURL(id), truncateTo: base) {
            items[i].have = base + n
            Perf.shared.add("تنزيل: استُرجع ما نزل في الخلفية", ms: 0, "\(n / 1_048_576) MB")
        }
        save()
    }

    /// Writes the first `count` bytes of `src` after the first `truncateTo` bytes of `dst` (the rest of dst is cut).
    nonisolated static func append(from src: URL, count: Int64, to dst: URL, truncateTo: Int64) -> Bool {
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

    /// A background download finished (moved out of URLSession's folder before this runs).
    private func bgDone(id: String, file: URL, status: Int, contentRange: String?, length: Int64?) {
        defer { try? FileManager.default.removeItem(at: file) }
        if let c = current, c.id == id, case .bg = c.run { current = nil }
        liveHave[id] = nil
        guard let i = index(id) else { startNext(); return }
        let it = items[i]
        let size = fileSize(file)
        switch DownloadRule.reply(status: status, contentRange: contentRange, contentLength: length, have: it.have, knownTotal: it.total) {
        case .append(let t):
            items[i].total = t
            let n = DownloadRule.salvage(received: size, have: it.have, total: t)
            if Self.append(from: file, count: n, to: Self.partURL(id), truncateTo: it.have) { items[i].have = it.have + n }
        case .restart(let t, let ignored):
            items[i].total = t
            if Self.append(from: file, count: DownloadRule.salvage(received: size, have: 0, total: t), to: Self.partURL(id), truncateTo: 0) {
                items[i].have = min(size, t ?? size)
            }
            if ignored { items[i].resumable = false; items[i].note = "المزوّد تجاهل طلب الإكمال وأرسل الملف من البداية — حُفظ بدون تكرار" }
        case .complete: break
        case .stop(let s): stopped(i, s); save(); startNext(); return
        }
        if !finishIfComplete(i), items[i].state == .downloading { items[i].state = .queued; items[i].note = nil }
        save(); startNext()
    }

    private func bgFailed(id: String, taskId: Int, error: Error, response: HTTPURLResponse?, received: Int64) {
        if stopping.remove(taskId) != nil { return }    // stopped by this app (pause / playback / Wi‑Fi)
        if let c = current, c.id == id, case .bg = c.run { current = nil }
        let ns = error as NSError
        salvage(id: id, resumeData: ns.userInfo[NSURLSessionDownloadTaskResumeData] as? Data, response: response, received: received)
        if let i = index(id) {
            // Swiped away / network error: the kept bytes stay; it goes on when possible.
            items[i].state = .queued
            if items[i].note == nil { items[i].note = "توقف تنزيل الخلفية (\(ns.code)) — يكمل من المحفوظ" }
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

    /// Sizes for the screen: "0 KB" instead of "Zero KB".
    nonisolated static func size(_ n: Int64) -> String {
        let f = ByteCountFormatter(); f.countStyle = .file; f.allowsNonnumericFormatting = false
        return f.string(fromByteCount: max(0, n))
    }

    nonisolated static func sha(_ s: String) -> String { SHA256.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined() }

    /// URLSession's temporary file of a stopped background download: in tmp or in the background daemon's folder.
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
}

/// 1.8.1: the open request used while the app is on screen. Its bytes go to the file as they arrive, after the
/// answer was checked (206 at exactly the kept size, or 200 = the whole file from byte 0). One at a time; all of its
/// state lives on its own serial queue.
final class FgLoader: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    var onProgress: (String, Int64) -> Void = { _, _ in }
    var onDone: (String, Int, DownloadRule.Reply?, Error?) -> Void = { _, _, _, _ in }

    private struct Job { let id: String; let have: Int64; let total: Int64? }
    private var jobs: [Int: Job] = [:]
    private var handle: FileHandle?
    private var base: Int64 = 0
    private var written: Int64 = 0
    private var limit: Int64?
    private var reply: DownloadRule.Reply?
    private var lastReport = Date.distantPast
    private let queue: OperationQueue = { let q = OperationQueue(); q.maxConcurrentOperationCount = 1; return q }()
    private lazy var session: URLSession = {
        let c = URLSessionConfiguration.default
        c.httpMaximumConnectionsPerHost = 1
        c.timeoutIntervalForRequest = 30
        c.allowsCellularAccess = true
        return URLSession(configuration: c, delegate: self, delegateQueue: queue)
    }()

    func start(id: String, have: Int64, total: Int64?, request: URLRequest) -> URLSessionDataTask {
        let t = session.dataTask(with: request)
        let job = Job(id: id, have: have, total: total)
        queue.addOperation {
            self.jobs[t.taskIdentifier] = job
            t.resume()
        }
        return t
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let job = jobs[dataTask.taskIdentifier], let h = response as? HTTPURLResponse else { completionHandler(.cancel); return }
        let r = DownloadRule.reply(status: h.statusCode, contentRange: h.value(forHTTPHeaderField: "Content-Range"),
                                   contentLength: h.expectedContentLength > 0 ? h.expectedContentLength : nil,
                                   have: job.have, knownTotal: job.total)
        reply = r; written = 0; handle = nil
        let file = Downloads.partURL(job.id)
        switch r {
        case .append(let t): base = job.have; limit = t
        case .restart(let t, _): base = 0; limit = t
        case .complete, .stop: completionHandler(.cancel); return
        }
        if !FileManager.default.fileExists(atPath: file.path) { FileManager.default.createFile(atPath: file.path, contents: nil) }
        do {
            let w = try FileHandle(forWritingTo: file)
            try w.truncate(atOffset: UInt64(base))        // nothing after the kept bytes: no duplicate, no gap
            try w.seek(toOffset: UInt64(base))
            handle = w
            completionHandler(.allow)
        } catch {
            reply = .stop(.http(0)); completionHandler(.cancel)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let w = handle, let job = jobs[dataTask.taskIdentifier] else { return }
        var d = data
        if let t = limit {
            let room = t - base - written
            if room <= 0 { return }
            if Int64(d.count) > room { d = d.prefix(Int(room)) }
        }
        do { try w.write(contentsOf: d); written += Int64(d.count) } catch { dataTask.cancel(); return }
        if Date().timeIntervalSince(lastReport) > 0.5 {
            lastReport = Date()
            onProgress(job.id, base + written)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let job = jobs.removeValue(forKey: task.taskIdentifier)
        if let w = handle { try? w.synchronize(); try? w.close() }
        handle = nil
        let r = reply; reply = nil
        if let job { onDone(job.id, task.taskIdentifier, r, error) }
    }
}

// MARK: URLSession (background downloads; callbacks come on a background queue)

extension Downloads: URLSessionDownloadDelegate {
    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                                totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard let id = downloadTask.taskDescription else { return }
        Task { @MainActor in
            guard let it = Downloads.shared.items.first(where: { $0.id == id }) else { return }
            Downloads.shared.liveHave[id] = it.have + totalBytesWritten
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
        Task { @MainActor in Downloads.shared.bgDone(id: id, file: hold, status: status, contentRange: cr, length: len) }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error, let id = task.taskDescription else { return }
        let taskId = task.taskIdentifier
        let resp = task.response as? HTTPURLResponse
        let got = task.countOfBytesReceived
        Task { @MainActor in Downloads.shared.bgFailed(id: id, taskId: taskId, error: error, response: resp, received: got) }
    }

    nonisolated func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        Task { @MainActor in
            Downloads.shared.backgroundCompletion?()
            Downloads.shared.backgroundCompletion = nil
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
