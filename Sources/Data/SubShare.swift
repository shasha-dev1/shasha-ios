import Foundation
import CryptoKit

/// 1.7.5: subtitles downloaded from the internet are kept per film/episode on this phone and shared with the TV
/// through Google Drive (one file each, see SubSyncRule). Opening the same film/episode on the other device brings
/// the subtitle back and turns it on (owner's choice), unless subtitles are off for that series.
/// No call to the subtitle sites here: only Drive, and only when it is linked.
@MainActor
enum SubShare {
    private static func sha(_ s: String) -> String { SHA256.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined() }

    /// Sync key for a film/episode ("movie:ID" / "ep:ID") of an Xtream playlist; nil for anything else.
    static func key(storeKey: String, source: Source?) -> String? {
        guard let s = source, s.kind == .xtream, let acct = CloudSync.account(s) else { return nil }
        let parts = storeKey.split(separator: ":", maxSplits: 1)
        guard parts.count == 2, parts[0] == "movie" || parts[0] == "ep" else { return nil }
        return CloudSyncRule.key(account: acct, kind: String(parts[0]), id: String(parts[1]))
    }

    private static var dir: URL? {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        let d = base.appendingPathComponent("subs-shared", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }
    private static func local(_ name: String) -> URL? { dir?.appendingPathComponent(name) }

    /// After a download from the internet: keep it for this film/episode and send it to Drive (in the background).
    static func keep(_ file: URL, storeKey: String, source: Source?, lang: String, label: String) {
        guard let k = key(storeKey: storeKey, source: source), let data = try? Data(contentsOf: file) else { return }
        let name = SubSyncRule.fileName(key: k, sha256: sha)
        if let dest = local(name) { try? data.write(to: dest, options: .atomic) }
        pruneLocal()
        guard DriveKeys.isLinked else { return }
        let t0 = Perf.now()
        Task {
            do {
                try await GoogleDrive.shared.putSub(data, name: name, lang: lang, label: label)
                Perf.shared.record("ترجمة: رفع إلى Drive", since: t0, "\(data.count / 1024) KB")
                await pruneDriveIfDue()
            } catch {
                Perf.shared.add("ترجمة: تعذّر الرفع إلى Drive", ms: 0, error.localizedDescription)
            }
        }
    }

    /// The subtitle kept for this film/episode: from this phone, or else from Drive (saved here for next time).
    static func saved(storeKey: String, source: Source?) async -> URL? {
        guard let k = key(storeKey: storeKey, source: source) else { return nil }
        let name = SubSyncRule.fileName(key: k, sha256: sha)
        guard let dest = local(name) else { return nil }
        if FileManager.default.fileExists(atPath: dest.path) {
            try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: dest.path)
            return dest
        }
        guard DriveKeys.isLinked else { return nil }
        let t0 = Perf.now()
        do {
            guard let f = try await GoogleDrive.shared.findSub(name) else { return nil }
            let data = try await GoogleDrive.shared.downloadSub(f.id)
            guard !data.isEmpty else { return nil }
            try data.write(to: dest, options: .atomic)
            Perf.shared.record("ترجمة: من الجهاز الآخر", since: t0, "\(data.count / 1024) KB · \(f.lang)")
            pruneLocal()
            return dest
        } catch {
            Perf.shared.add("ترجمة: تعذّر الجلب من Drive", ms: 0, error.localizedDescription)
            return nil
        }
    }

    /// Same limits on this phone: older than 30 days (by last use) or beyond 150 files.
    static func pruneLocal() {
        guard let d = dir, let urls = try? FileManager.default.contentsOfDirectory(at: d, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        let files = urls.map { u in
            SubSyncRule.Stored(id: u.lastPathComponent,
                               modifiedMs: ((try? u.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate).map { CloudSyncRule.ms($0.timeIntervalSince1970) } ?? 0)
        }
        for name in SubSyncRule.prune(files, nowMs: CloudSyncRule.ms(Date().timeIntervalSince1970)) {
            try? FileManager.default.removeItem(at: d.appendingPathComponent(name))
        }
    }

    /// Drive: at most once a day, after an upload.
    static func pruneDriveIfDue() async {
        let k = "subs.pruneAt"
        let now = CloudSyncRule.ms(Date().timeIntervalSince1970)
        guard now - Int64(UserDefaults.standard.double(forKey: k)) > SubSyncRule.pruneEveryMs else { return }
        do {
            let gone = SubSyncRule.prune(try await GoogleDrive.shared.listSubs(), nowMs: now)
            for id in gone { try await GoogleDrive.shared.delete(id) }
            UserDefaults.standard.set(Double(now), forKey: k)
            if !gone.isEmpty { Perf.shared.add("ترجمة: حُذف القديم من Drive", ms: 0, "\(gone.count)") }
        } catch {
            Perf.shared.add("ترجمة: تعذّر تنظيف Drive", ms: 0, error.localizedDescription)
        }
    }
}
