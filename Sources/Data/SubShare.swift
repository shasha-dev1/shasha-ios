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
    /// 1.7.6: the Drive name stays `….srt` (the identity both apps look up); the copy kept here has the extension of
    /// its real format, so mpv reads ASS as ASS.
    private static func local(_ name: String, _ f: SubFileCheck.Format) -> URL? {
        local(f == .ass ? String(name.dropLast(4)) + ".ass" : name)
    }

    /// 1.7.6: a checked subtitle written as UTF-8 to a temporary file with the right extension, to add to mpv.
    static func tempFile(_ c: SubFileCheck.Checked, name: String) -> URL? {
        let base = (name as NSString).deletingPathExtension.replacingOccurrences(of: "/", with: "_")
        let u = FileManager.default.temporaryDirectory.appendingPathComponent((base.isEmpty ? "subtitle" : base) + "." + c.format.rawValue)
        do { try Data(c.text.utf8).write(to: u, options: .atomic); return u } catch { return nil }
    }

    private static func hex<D: Sequence>(_ d: D) -> String where D.Element == UInt8 { d.map { String(format: "%02x", $0) }.joined() }
    static func md5(_ data: Data) -> String { hex(Insecure.MD5.hash(data: data)) }
    static func sha256(_ data: Data) -> String { hex(SHA256.hash(data: data)) }

    /// 1.7.9: language of a kept subtitle: what the source says (OpenSubtitles "ar"/"en"…), else the guess from
    /// the text ("ar" or "und").
    static func language(_ hint: String?, _ c: SubFileCheck.Checked) -> String {
        let h = SubIdentityRule.lang(hint ?? "")
        return h != "und" ? h : SubIdentityRule.lang(c.lang)
    }

    /// After a subtitle was downloaded, imported or chosen from the kept ones, checked, and confirmed added in the
    /// player: it becomes the selected one for this film/episode (v1, shared with the TV) and is kept as the copy of
    /// its language (v2). 1.7.9: other languages are never removed; the one it replaces is kept first when needed,
    /// and `note` tells the viewer which language was replaced. Same content on Drive → nothing uploaded.
    static func keep(_ c: SubFileCheck.Checked, storeKey: String, source: Source?, label: String, lang hint: String? = nil,
                     note: @escaping (String) -> Void = { _ in }) {
        guard let k = key(storeKey: storeKey, source: source) else { return }
        let name = SubSyncRule.fileName(key: k, sha256: sha)
        let lang = language(hint, c)
        let nameV2 = SubIdentityRule.fileName(key: k, lang: lang, format: c.format.rawValue, sha256: sha)
        let item = SubIdentityRule.itemHash(key: k, sha256: sha)
        let data = Data(c.text.utf8)
        let digest = md5(data), contentSha = sha256(data)
        keepLocal(data, name: name, nameV2: nameV2, item: item, format: c.format)
        pruneLocal()
        guard DriveKeys.isLinked else { return }
        let t0 = Perf.now()
        Task {
            do {
                async let v1Find = GoogleDrive.shared.findSub(name)
                async let v2Find = GoogleDrive.shared.findSubsV2(item: item)
                let v1 = try await v1Find, v2s = try await v2Find
                var have: [String: String?] = [:]
                for f in v2s { let l = SubIdentityRule.parse(f.name)?.lang ?? SubIdentityRule.lang(f.lang); if have[l] == nil { have[l] = .some(f.md5) } }
                let plan = SubIdentityRule.plan(lang: lang, md5: digest, v1: v1.map { SubIdentityRule.Remote(lang: $0.lang, md5: $0.md5) }, v2: have)
                let now = String(CloudSyncRule.ms(Date().timeIntervalSince1970))
                // 1) The selected subtitle being replaced is kept as its language's copy first; if that fails, the
                //    selection is not replaced (nothing is lost).
                var canReplace = true
                if let old = plan.preserveOldAs, let v1 {
                    let target = SubIdentityRule.fileName(key: k, lang: old, format: v1.fmt == "ass" ? "ass" : "srt", sha256: sha)
                    do {
                        try await GoogleDrive.shared.copySub(v1.id, name: target, props: [
                            "shashaSub": "2", "item": item, "lang": old, "fmt": v1.fmt == "ass" ? "ass" : "srt",
                            "label": SubSyncRule.clip(v1.label), "off": "0", "used": now])
                        for dup in v2s where dup.name == target { try? await GoogleDrive.shared.delete(dup.id) }
                        Perf.shared.add("ترجمة: حُفظت المختارة السابقة كنسخة لغتها", ms: 0, old)
                    } catch {
                        canReplace = false
                        Perf.shared.add("ترجمة: تعذّر حفظ المختارة السابقة — لم تُستبدل", ms: 0, error.localizedDescription)
                    }
                }
                // 2) This language's copy.
                if plan.putV2 {
                    try await GoogleDrive.shared.putSub(data, name: nameV2, lang: lang, label: label, format: c.format.rawValue,
                                                        extra: ["shashaSub": "2", "item": item, "sha": contentSha],
                                                        existingId: .some(v2s.first { $0.name == nameV2 }?.id))
                }
                // 3) The selected subtitle (what the TV and older builds read).
                if plan.putV1 && canReplace {
                    try await GoogleDrive.shared.putSub(data, name: name, lang: lang, label: label, format: c.format.rawValue,
                                                        existingId: .some(v1?.id))
                } else if !plan.putV1, let v1, v1.off {
                    try? await GoogleDrive.shared.touchSub(v1.id, off: false)     // chosen again → no longer "off"
                }
                if !plan.putV1 && !plan.putV2 {
                    Perf.shared.add("ترجمة: نفس الملف موجود في Drive — لم يُرفع", ms: 0, lang)
                } else {
                    Perf.shared.record("ترجمة: رفع إلى Drive", since: t0, "\(data.count / 1024) KB · \(lang)")
                }
                if let r = plan.replacedLang, canReplace {
                    note("بدّلت الترجمة المختارة من \(SubIdentityRule.display(r)) إلى \(SubIdentityRule.display(lang)) — ترجمة \(SubIdentityRule.display(r)) باقية في المحفوظة")
                } else if plan.replacedSameLang {
                    note("استُبدلت ترجمة \(SubIdentityRule.display(lang)) السابقة لهذا العمل")
                }
                await pruneDriveIfDue()
            } catch {
                Perf.shared.add("ترجمة: تعذّر الرفع إلى Drive", ms: 0, error.localizedDescription)
            }
        }
    }

    /// On this phone: the selected copy (v1 name) and this language's copy (v2 name). A selected copy with other
    /// content that has no copy of its own yet (kept by an older build) is kept under its guessed language first.
    private static func keepLocal(_ data: Data, name: String, nameV2: String, item: String, format: SubFileCheck.Format) {
        let old = [SubFileCheck.Format.srt, .ass].compactMap { local(name, $0) }.first { FileManager.default.fileExists(atPath: $0.path) }
        if let old, let oldData = try? Data(contentsOf: old), oldData != data {
            let mine = localV2(item: item)
            if !mine.contains(where: { (try? Data(contentsOf: $0)) == oldData }),
               case .success(let oc) = SubFileCheck.check(oldData) {
                let n = SubIdentityRule.prefix + item + "-" + SubIdentityRule.lang(oc.lang) + "." + oc.format.rawValue
                if !mine.contains(where: { $0.lastPathComponent == n }), let dest = local(n) { try? oldData.write(to: dest, options: .atomic) }
            }
        }
        for f in [SubFileCheck.Format.srt, .ass] { if let u = local(name, f) { try? FileManager.default.removeItem(at: u) } }
        if let dest = local(name, format) { try? data.write(to: dest, options: .atomic) }
        if let dest = local(nameV2) { try? data.write(to: dest, options: .atomic) }
    }

    private static func localV2(item: String) -> [URL] {
        guard let d = dir, let urls = try? FileManager.default.contentsOfDirectory(at: d, includingPropertiesForKeys: nil) else { return [] }
        return urls.filter { SubIdentityRule.parse($0.lastPathComponent)?.item == item }
    }

    /// 1.7.9: the subtitles kept for this film/episode, one per language (this phone and Drive), for the player's list.
    struct Kept: Identifiable, Equatable {
        var id: String { name }
        let name: String; let lang: String; let format: String
        var local: URL?; var driveId: String?; var selected = false
    }

    static func keptList(storeKey: String, source: Source?) async -> [Kept] {
        guard let k = key(storeKey: storeKey, source: source) else { return [] }
        let item = SubIdentityRule.itemHash(key: k, sha256: sha)
        let name = SubSyncRule.fileName(key: k, sha256: sha)
        var out: [String: Kept] = [:]
        let selectedLocal = [SubFileCheck.Format.srt, .ass].compactMap { local(name, $0) }
            .first { FileManager.default.fileExists(atPath: $0.path) }.flatMap { try? Data(contentsOf: $0) }
        for u in localV2(item: item) {
            guard let p = SubIdentityRule.parse(u.lastPathComponent) else { continue }
            let sel = selectedLocal != nil && (try? Data(contentsOf: u)) == selectedLocal
            out[u.lastPathComponent] = Kept(name: u.lastPathComponent, lang: p.lang, format: p.format, local: u, selected: sel)
        }
        if DriveKeys.isLinked {
            do {
                async let v1Find = GoogleDrive.shared.findSub(name)
                async let v2Find = GoogleDrive.shared.findSubsV2(item: item)
                let v1 = try await v1Find, v2s = try await v2Find
                for f in v2s {
                    guard let p = SubIdentityRule.parse(f.name) else { continue }
                    var e = out[f.name] ?? Kept(name: f.name, lang: p.lang, format: p.format)
                    e.driveId = f.id
                    if let a = f.md5, a == v1?.md5 { e.selected = true }
                    out[f.name] = e
                }
                // A selected subtitle from the TV / an older build with no copy of its own yet.
                if let v1, !v2s.contains(where: { $0.md5 != nil && $0.md5 == v1.md5 }), !out.values.contains(where: \.selected) {
                    out[v1.name] = Kept(name: v1.name, lang: SubIdentityRule.lang(v1.lang), format: v1.fmt == "ass" ? "ass" : "srt",
                                        driveId: v1.id, selected: true)
                }
            } catch {
                Perf.shared.add("ترجمة: تعذّر قراءة المحفوظة من Drive", ms: 0, error.localizedDescription)
            }
        }
        return out.values.sorted { ($0.selected ? 0 : 1, $0.lang) < ($1.selected ? 0 : 1, $1.lang) }
    }

    /// Content of a kept subtitle (this phone first, else Drive). Checked again by the caller before use.
    static func load(_ e: Kept) async -> Data? {
        if let u = e.local, let d = try? Data(contentsOf: u) {
            try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: u.path)
            return d
        }
        guard let id = e.driveId else { return nil }
        do { return try await GoogleDrive.shared.downloadSub(id) } catch {
            Perf.shared.add("ترجمة: تعذّر الجلب من Drive", ms: 0, error.localizedDescription)
            return nil
        }
    }

    /// The subtitle kept for this film/episode: from this phone, or else from Drive (saved here for next time).
    /// 1.8.0: `preferLocal` (playing a download): only the copy on this phone is used — Drive isn't asked at all, so
    /// offline playback never waits for Google.
    static func saved(storeKey: String, source: Source?, preferLocal: Bool = false) async -> URL? {
        guard let k = key(storeKey: storeKey, source: source) else { return nil }
        let name = SubSyncRule.fileName(key: k, sha256: sha)
        let kept = [SubFileCheck.Format.srt, .ass].compactMap { local(name, $0) }.first { FileManager.default.fileExists(atPath: $0.path) }
        // 1.8.3: playing a download never asks Drive (offline or on a bad network it would wait up to 25 s).
        guard DriveKeys.isLinked, !preferLocal else {
            if let kept { try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: kept.path) }
            return kept
        }
        let t0 = Perf.now()
        // 1.7.7: Drive first (one small request): "off" chosen on the other device is respected, and use here is
        // recorded so the daily clean-up doesn't delete a subtitle still in use. If Drive can't be reached, the
        // copy kept here is used as before.
        let remote: GoogleDrive.SubFile?
        do { remote = try await GoogleDrive.shared.findSub(name) } catch {
            Perf.shared.add("ترجمة: تعذّر الوصول إلى Drive — استُخدمت النسخة المحفوظة", ms: 0, error.localizedDescription)
            return kept
        }
        if let r = remote, r.off {
            Perf.shared.add("ترجمة: موقوفة من جهاز آخر لهذا العمل — لم تُفعَّل", ms: 0, "")
            return nil
        }
        if let r = remote, SubSyncRule.needsTouch(usedMs: r.usedMs, modifiedMs: r.modifiedMs, nowMs: CloudSyncRule.ms(Date().timeIntervalSince1970)) {
            Task { try? await GoogleDrive.shared.touchSub(r.id, off: nil) }
        }
        if let kept {
            try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: kept.path)
            return kept
        }
        do {
            guard let f = remote else { return nil }
            let data = try await GoogleDrive.shared.downloadSub(f.id)
            // 1.7.6: checked like an imported file before it is kept or used.
            let c: SubFileCheck.Checked
            switch SubFileCheck.check(data) {
            case .success(let ok): c = ok
            case .failure(let p):
                Perf.shared.add("ترجمة: ملف Drive مرفوض", ms: 0, SubFileCheck.text(p))
                return nil
            }
            guard let dest = local(name, c.format) else { return nil }
            try Data(c.text.utf8).write(to: dest, options: .atomic)
            Perf.shared.record("ترجمة: من الجهاز الآخر", since: t0, "\(data.count / 1024) KB · \(c.format.rawValue) · \(f.lang)")
            pruneLocal()
            return dest
        } catch {
            Perf.shared.add("ترجمة: تعذّر الجلب من Drive", ms: 0, error.localizedDescription)
            return nil
        }
    }

    /// 1.7.7: "no subtitles" for this film/episode: recorded on the shared file too, so the other device doesn't turn
    /// it on. A new download or import (putSub) clears it.
    static func markOff(storeKey: String, source: Source?) {
        guard DriveKeys.isLinked, let k = key(storeKey: storeKey, source: source) else { return }
        let name = SubSyncRule.fileName(key: k, sha256: sha)
        Task {
            do {
                if let f = try await GoogleDrive.shared.findSub(name) { try await GoogleDrive.shared.touchSub(f.id, off: true) }
            } catch { Perf.shared.add("ترجمة: تعذّر تسجيل الإيقاف في Drive", ms: 0, error.localizedDescription) }
        }
    }

    /// Same limits on this phone: older than 30 days (by last use) or beyond the count. 1.7.9: the selected copies
    /// (v1 names) and the language copies (v2) are counted apart; a language copy with the same content as its item's
    /// selected copy counts as used with it.
    static func pruneLocal() {
        guard let d = dir, let urls = try? FileManager.default.contentsOfDirectory(at: d, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey]) else { return }
        func mtime(_ u: URL) -> Int64 {
            ((try? u.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate).map { CloudSyncRule.ms($0.timeIntervalSince1970) } ?? 0
        }
        let v2urls = urls.filter { SubIdentityRule.parse($0.lastPathComponent) != nil }
        let v1urls = urls.filter { SubIdentityRule.parse($0.lastPathComponent) == nil }
        let v1 = v1urls.map { u -> SubIdentityRule.Listed in
            // the selected copy may be .ass locally; its identity name ends in .srt
            let n = u.lastPathComponent.hasSuffix(".ass") ? String(u.lastPathComponent.dropLast(4)) + ".srt" : u.lastPathComponent
            return SubIdentityRule.Listed(id: u.lastPathComponent, name: n, stampMs: mtime(u), md5: nil)
        }
        var gone = SubSyncRule.prune(v1.map { SubSyncRule.Stored(id: $0.id, modifiedMs: $0.stampMs) }, nowMs: CloudSyncRule.ms(Date().timeIntervalSince1970))
        // md5 only where it can matter: a language copy whose item still has a selected copy of the same size.
        let v1ByName = Dictionary(v1urls.map { u -> (String, URL) in
            let n = u.lastPathComponent.hasSuffix(".ass") ? String(u.lastPathComponent.dropLast(4)) + ".srt" : u.lastPathComponent
            return (n, u) }, uniquingKeysWith: { a, _ in a })
        func size(_ u: URL) -> Int { (try? u.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? -1 }
        var v1md5: [String: String] = [:]
        let v2 = v2urls.map { u -> SubIdentityRule.Listed in
            var m: String?
            if let p = SubIdentityRule.parse(u.lastPathComponent), let sel = v1ByName[SubSyncRule.prefix + p.item + ".srt"],
               size(sel) == size(u), let a = try? Data(contentsOf: u) {
                m = md5(a)
                if v1md5[sel.lastPathComponent] == nil, let b = try? Data(contentsOf: sel) { v1md5[sel.lastPathComponent] = md5(b) }
            }
            return SubIdentityRule.Listed(id: u.lastPathComponent, name: u.lastPathComponent, stampMs: mtime(u), md5: m)
        }
        let v1WithMd5 = v1.map { SubIdentityRule.Listed(id: $0.id, name: $0.name, stampMs: $0.stampMs, md5: v1md5[$0.id]) }
            .filter { !gone.contains($0.id) }
        gone += SubIdentityRule.prune(v2: v2, v1: v1WithMd5, nowMs: CloudSyncRule.ms(Date().timeIntervalSince1970))
        for name in gone { try? FileManager.default.removeItem(at: d.appendingPathComponent(name)) }
    }

    /// Drive: at most once a day, after an upload. v1 files by the rule the TV shares; v2 files (iPhone only) apart.
    static func pruneDriveIfDue() async {
        let k = "subs.pruneAt"
        let now = CloudSyncRule.ms(Date().timeIntervalSince1970)
        guard now - Int64(UserDefaults.standard.double(forKey: k)) > SubSyncRule.pruneEveryMs else { return }
        do {
            var gone: [String] = []
            let v1 = try await GoogleDrive.shared.listSubs(kind: "1")
            let v2 = try await GoogleDrive.shared.listSubs(kind: "2")
            let seen = Dictionary((v1 + v2).map { ($0.id, $0.stampMs) }, uniquingKeysWith: { a, _ in a })
            let goV1 = SubSyncRule.prune(v1.map { SubSyncRule.Stored(id: $0.id, modifiedMs: $0.stampMs) }, nowMs: now)
            let keptV1 = v1.filter { !goV1.contains($0.id) }.map { SubIdentityRule.Listed(id: $0.id, name: $0.name, stampMs: $0.stampMs, md5: $0.md5) }
            let goV2 = SubIdentityRule.prune(v2: v2.map { SubIdentityRule.Listed(id: $0.id, name: $0.name, stampMs: $0.stampMs, md5: $0.md5) },
                                             v1: keptV1, nowMs: now)
            for id in goV1 + goV2 {
                // 1.7.7: read again right before deleting; skip it if it was used or replaced since the list.
                guard let st = try await GoogleDrive.shared.subStamp(id) else { continue }
                if st > (seen[id] ?? 0) { continue }
                try await GoogleDrive.shared.delete(id); gone.append(id)
            }
            UserDefaults.standard.set(Double(now), forKey: k)
            if !gone.isEmpty { Perf.shared.add("ترجمة: حُذف القديم من Drive", ms: 0, "\(gone.count)") }
        } catch {
            Perf.shared.add("ترجمة: تعذّر تنظيف Drive", ms: 0, error.localizedDescription)
        }
    }
}
