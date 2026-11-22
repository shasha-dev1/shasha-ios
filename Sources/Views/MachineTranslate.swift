import SwiftUI
import NaturalLanguage
#if canImport(Translation)
import Translation
#endif

/// 1.4.1: on-device machine translation of descriptions into Arabic (Apple's Translation framework, iOS 18+).
/// Used only when a description has no Arabic text (TMDB has no Arabic overview, or the provider's plot is in
/// another language). The text is translated on the phone; the app sends it nowhere. Always labelled
/// «ترجمة آلية», and the original stays one tap away. Same idea as the TV app (ML Kit there).
enum MachineTranslate {
    static let key = "mt.enabled"
    /// On by default, like the TV app. Settings → Playback has the switch.
    static var enabled: Bool { UserDefaults.standard.object(forKey: key) as? Bool ?? true }

    static func hasArabic(_ s: String) -> Bool {
        s.unicodeScalars.contains { (0x0600...0x06FF).contains($0.value) || (0x0750...0x077F).contains($0.value) }
    }

    /// Source language guessed on the device (no network). Nil when unsure: then nothing is translated, so the
    /// system never has to ask the viewer which language the text is in.
    static func sourceLanguage(_ s: String) -> Locale.Language? {
        let r = NLLanguageRecognizer()
        r.processString(s)
        guard let (lang, p) = r.languageHypotheses(withMaximum: 1).first, p >= 0.6, lang != .arabic, lang != .undetermined else { return nil }
        return Locale.Language(identifier: lang.rawValue)
    }

    static func wanted(_ s: String) -> Bool {
        enabled && s.count >= 20 && !hasArabic(s) && sourceLanguage(s) != nil
    }

    // Results kept in memory for this run (translation on the device is quick; nothing is written to disk).
    @MainActor private static var done: [String: String] = [:]
    /// Set when the viewer dismissed the language download or the system refused: no more automatic prompts
    /// until the app restarts; the «ترجم» button still works.
    @MainActor static var autoStopped = false

    @MainActor static func cached(_ s: String) -> String? { done[s] }
    @MainActor static func store(_ s: String, _ t: String) {
        if done.count > 500 { done.removeAll() }
        done[s] = t
    }
}

/// Description text with "more / less", plus the Arabic machine translation when it applies.
struct ExpandableText: View {
    let text: String
    var lines = 4
    @State private var open = false
    @State private var translated: String?
    @State private var showOriginal = false
    @State private var request = 0          // bumps to ask for a translation (automatic once, then by button)
    @State private var failed = false

    private var shown: String { (!showOriginal ? translated : nil) ?? text }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(shown).font(.subheadline).lineLimit(open ? nil : lines).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 14) {
                Button(open ? "أقل" : "المزيد") { withAnimation(.easeInOut(duration: 0.2)) { open.toggle() } }
                if translated != nil {
                    Button(showOriginal ? "عرض الترجمة" : "النص الأصلي") { showOriginal.toggle() }
                } else if failed {
                    Button("ترجم") { failed = false; request += 1 }
                }
            }
            .font(.footnote.weight(.semibold)).foregroundStyle(Theme.accent)
            if translated != nil && !showOriginal {
                Text("ترجمة آلية على الجهاز").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .modifier(TranslateIfNeeded(text: text, request: $request, result: $translated, failed: $failed))
        .onChange(of: text) { _ in translated = nil; showOriginal = false; failed = false }
    }
}

private struct TranslateIfNeeded: ViewModifier {
    let text: String
    @Binding var request: Int
    @Binding var result: String?
    @Binding var failed: Bool

    func body(content: Content) -> some View {
        #if canImport(Translation)
        if #available(iOS 18.0, *), MachineTranslate.wanted(text) {
            content.modifier(Translate18(text: text, request: $request, result: $result, failed: $failed))
        } else {
            content
        }
        #else
        content
        #endif
    }
}

#if canImport(Translation)
@available(iOS 18.0, *)
private struct Translate18: ViewModifier {
    let text: String
    @Binding var request: Int
    @Binding var result: String?
    @Binding var failed: Bool
    @State private var config: TranslationSession.Configuration?
    @State private var manual = false

    func body(content: Content) -> some View {
        content
            .task(id: text) { await prepare(manual: false) }
            .onChange(of: request) { _ in Task { await prepare(manual: true) } }
            .translationTask(config) { session in
                let t0 = Date()
                do {
                    let r = try await session.translate(text)
                    let out = r.targetText.trimmingCharacters(in: .whitespacesAndNewlines)
                    await MainActor.run {
                        if out.isEmpty { failed = true; return }
                        MachineTranslate.store(text, out)
                        result = out
                        Perf.shared.add("ترجمة آلية", ms: Date().timeIntervalSince(t0) * 1000, "\(text.count) حرف", span: true)
                    }
                } catch {
                    await MainActor.run {
                        failed = true
                        MachineTranslate.autoStopped = true
                        Perf.shared.add("ترجمة آلية فشلت", ms: 0, error.localizedDescription)
                    }
                }
            }
    }

    @MainActor private func prepare(manual: Bool) async {
        if let c = MachineTranslate.cached(text) { result = c; return }
        if !manual && MachineTranslate.autoStopped { failed = true; return }
        guard let src = MachineTranslate.sourceLanguage(text) else { return }
        let target = Locale.Language(identifier: "ar")
        let status = await LanguageAvailability().status(from: src, to: target)
        guard status != .unsupported else { return }     // e.g. a language pair Apple does not offer
        if config == nil || config?.source != src {
            config = TranslationSession.Configuration(source: src, target: target)
        } else if manual {
            config?.invalidate()                          // run the task again (button press)
        }
    }
}
#endif

// MARK: Many short texts at once (episode overviews of one season) — 1.4.2

/// Translates every text in `texts` that needs it, in one batch, and fills `result` (original → Arabic).
/// Same rules as the single description: on the device, automatic once, quiet when unsure or unsupported.
struct TranslateBatch: ViewModifier {
    let texts: [String]
    @Binding var result: [String: String]

    func body(content: Content) -> some View {
        #if canImport(Translation)
        if #available(iOS 18.0, *), MachineTranslate.enabled {
            content.modifier(TranslateBatch18(texts: texts, result: $result))
        } else {
            content
        }
        #else
        content
        #endif
    }
}

#if canImport(Translation)
@available(iOS 18.0, *)
private struct TranslateBatch18: ViewModifier {
    let texts: [String]
    @Binding var result: [String: String]
    @State private var config: TranslationSession.Configuration?
    @State private var pending: [String] = []

    func body(content: Content) -> some View {
        content
            .task(id: texts) { await prepare() }
            .translationTask(config) { session in
                let todo = await MainActor.run { pending }
                guard !todo.isEmpty else { return }
                let t0 = Date()
                let reqs = todo.enumerated().map { TranslationSession.Request(sourceText: $0.element, clientIdentifier: String($0.offset)) }
                do {
                    let rs = try await session.translations(from: reqs)
                    await MainActor.run {
                        var out = result
                        for r in rs {
                            guard let i = r.clientIdentifier.flatMap(Int.init), i < todo.count else { continue }
                            let t = r.targetText.trimmingCharacters(in: .whitespacesAndNewlines)
                            if !t.isEmpty { out[todo[i]] = t; MachineTranslate.store(todo[i], t) }
                        }
                        result = out
                        Perf.shared.add("ترجمة آلية (حلقات)", ms: Date().timeIntervalSince(t0) * 1000, "\(todo.count) نص", span: true)
                    }
                } catch {
                    await MainActor.run {
                        MachineTranslate.autoStopped = true
                        Perf.shared.add("ترجمة آلية فشلت (حلقات)", ms: 0, error.localizedDescription)
                    }
                }
            }
    }

    @MainActor private func prepare() async {
        var out = result
        var need: [String] = []
        for t in Set(texts) where MachineTranslate.wanted(t) {
            if let c = MachineTranslate.cached(t) { out[t] = c } else { need.append(t) }
        }
        if out != result { result = out }
        guard !need.isEmpty, !MachineTranslate.autoStopped,
              let src = MachineTranslate.sourceLanguage(need.joined(separator: "\n")) else { return }
        let target = Locale.Language(identifier: "ar")
        guard await LanguageAvailability().status(from: src, to: target) != .unsupported else { return }
        pending = need.filter { MachineTranslate.sourceLanguage($0) == src }
        guard !pending.isEmpty else { return }
        if config == nil || config?.source != src {
            config = TranslationSession.Configuration(source: src, target: target)
        } else {
            config?.invalidate()
        }
    }
}
#endif
