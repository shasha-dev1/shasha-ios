import Foundation
import MetricKit
import MessageUI
import SwiftUI
import UIKit

/// 1.9.7 (owner 13:46 / 13:49: «find the certain cause … a crash report that goes to Gmail so you can take it»):
/// two records, both kept on the phone until the owner sends or deletes them — nothing is sent by itself.
/// 1. Apple's own crash report (MetricKit: exception, signal, the call stack of each thread), delivered by iOS on a later launch.
/// 2. An unclean exit seen by the app itself: the app was in the foreground and the next launch didn't see it leave
///    (a crash, or iOS closing it for memory, which has no Apple crash report) — with the last steps and memory samples
///    (Perf's log on disk) and the last playback events.
/// On the next launch the owner is asked to send them by e-mail (to the address he enters once) or share them.
final class CrashReporter: NSObject, ObservableObject, MXMetricManagerSubscriber {
    static let shared = CrashReporter()
    @Published private(set) var pending: [URL] = []
    private let stateKey = "crash.lastState", stepKey = "crash.lastStep", stepAtKey = "crash.lastStepAt"
    static let emailKey = "crash.email"
    private let dir: URL = {
        let d = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("crash-reports", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()
    private var started = false

    func launch() {
        guard !started else { return }
        started = true
        let d = UserDefaults.standard
        if d.string(forKey: stateKey) == "active" { writeUncleanExit() }
        d.set("launched", forKey: stateKey)
        let nc = NotificationCenter.default
        nc.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in d.set("active", forKey: self.stateKey) }
        nc.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { _ in d.set("background", forKey: self.stateKey) }
        nc.addObserver(forName: UIApplication.willTerminateNotification, object: nil, queue: .main) { _ in d.set("terminated", forKey: self.stateKey) }
        MXMetricManager.shared.add(self)
        // reports iOS already holds from before (delivered once per launch)
        didReceive(MXMetricManager.shared.pastDiagnosticPayloads)
        refresh()
    }

    /// The step running now, kept on disk so an unclean exit names it.
    func step(_ s: String) {
        let d = UserDefaults.standard
        d.set(s, forKey: stepKey); d.set(Date().timeIntervalSince1970, forKey: stepAtKey)
    }

    private func refresh() {
        let l = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        let r = l.filter { $0.pathExtension == "txt" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        DispatchQueue.main.async { self.pending = r }
    }

    private func header(_ title: String) -> String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "Shasha crash report — \(title)\nالتطبيق \(v) (\(b)) · \(Perf.device) · iOS \(UIDevice.current.systemVersion)\n"
    }

    private func stamp() -> String {
        let f = DateFormatter(); f.dateFormat = "yyyyMMdd-HHmmss"; f.locale = Locale(identifier: "en_US_POSIX"); return f.string(from: Date())
    }

    private func writeUncleanExit() {
        let d = UserDefaults.standard
        var s = header("خروج غير طبيعي (التطبيق كان في الواجهة ولم يُغلق بشكل عادي)")
        if let st = d.string(forKey: stepKey) {
            let at = Date(timeIntervalSince1970: d.double(forKey: stepAtKey))
            s += "آخر خطوة مسجّلة: \(st) — \(at)\n"
        }
        s += "\n[آخر سطور سجل الأداء والذاكرة]\n"
        if let f = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?.appendingPathComponent("perf.log"),
           let t = try? String(contentsOf: f, encoding: .utf8) {
            s += t.split(separator: "\n").suffix(120).joined(separator: "\n") + "\n"
        }
        s += "\nملاحظة: إغلاق iOS للتطبيق بسبب الذاكرة لا يصنع تقرير انهيار من Apple؛ إن وصل تقرير Apple لاحقًا فهو انهيار فعلي.\n"
        try? RedactRule.text(s).write(to: dir.appendingPathComponent("\(stamp())-exit.txt"), atomically: true, encoding: .utf8)
    }

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        for (i, p) in payloads.enumerated() {
            var s = header("تقرير Apple (MetricKit) \(p.timeStampBegin) – \(p.timeStampEnd)")
            for c in p.crashDiagnostics ?? [] {
                s += "\n[انهيار] النوع: \(c.exceptionType?.stringValue ?? "-") · الرمز: \(c.exceptionCode?.stringValue ?? "-") · الإشارة: \(c.signal?.stringValue ?? "-")\n"
                s += "السبب: \(c.terminationReason ?? "-") · \(c.virtualMemoryRegionInfo ?? "")\n"
                s += "إصدار التطبيق: \(c.metaData.applicationBuildVersion)\n"
            }
            for h in p.hangDiagnostics ?? [] { s += "\n[تعليق] المدة: \(h.hangDuration)\n" }
            for c in p.cpuExceptionDiagnostics ?? [] { s += "\n[استهلاك معالج] \(c.totalCPUTime) خلال \(c.totalSampledTime)\n" }
            for w in p.diskWriteExceptionDiagnostics ?? [] { s += "\n[كتابة قرص] \(w.totalWritesCaused)\n" }
            s += "\n[JSON كامل مع مكدّس الاستدعاءات]\n" + (String(data: p.jsonRepresentation(), encoding: .utf8) ?? "")
            try? RedactRule.text(s).write(to: dir.appendingPathComponent("\(stamp())-\(i)-apple.txt"), atomically: true, encoding: .utf8)
        }
        if !payloads.isEmpty { refresh() }
    }

    /// 1.9.8: a report the owner sends himself (the performance report from Settings), in the same mail.
    func attach(_ text: String, name: String) {
        try? RedactRule.text(header(name) + "\n" + text).write(to: dir.appendingPathComponent("\(stamp())-\(name).txt"), atomically: true, encoding: .utf8)
        let l = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        pending = l.filter { $0.pathExtension == "txt" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// A crash or unclean exit among the files (not only a report the owner attached himself).
    var hasCrash: Bool { pending.contains { !$0.lastPathComponent.hasSuffix("-perf.txt") } }

    func joined() -> String { RedactRule.text(pending.compactMap { try? String(contentsOf: $0, encoding: .utf8) }.joined(separator: "\n\n==========\n\n")) }
    func clear() { for u in pending { try? FileManager.default.removeItem(at: u) }; refresh() }
}

/// The mail sheet (Apple Mail with an account), else the share sheet (Gmail app, Files…).
struct CrashSendView: UIViewControllerRepresentable {
    let to: String
    let onDone: (Bool) -> Void
    func makeCoordinator() -> Coord { Coord(onDone) }
    final class Coord: NSObject, MFMailComposeViewControllerDelegate {
        let onDone: (Bool) -> Void
        init(_ f: @escaping (Bool) -> Void) { onDone = f }
        func mailComposeController(_ c: MFMailComposeViewController, didFinishWith r: MFMailComposeResult, error: Error?) {
            c.dismiss(animated: true); onDone(r == .sent)
        }
    }
    func makeUIViewController(context: Context) -> UIViewController {
        let r = CrashReporter.shared
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let subject = "Shasha report \(v)"
        if MFMailComposeViewController.canSendMail() {
            let m = MFMailComposeViewController()
            m.mailComposeDelegate = context.coordinator
            if !to.isEmpty { m.setToRecipients([to]) }
            m.setSubject(subject)
            m.setMessageBody("تقرير انهيار شاشة (\(r.pending.count) ملف) مرفق.", isHTML: false)
            for u in r.pending { if let x = try? String(contentsOf: u, encoding: .utf8) { m.addAttachmentData(Data(RedactRule.text(x).utf8), mimeType: "text/plain", fileName: u.lastPathComponent) } }
            return m
        }
        let a = UIActivityViewController(activityItems: [r.joined()], applicationActivities: nil)   // 1.10.3: redacted text, not the raw files
        a.setValue(subject, forKey: "subject")
        a.completionWithItemsHandler = { _, ok, _, _ in onDone(ok) }
        return a
    }
    func updateUIViewController(_ c: UIViewController, context: Context) {}
}
