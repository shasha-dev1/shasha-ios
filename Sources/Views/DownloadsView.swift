import SwiftUI

/// 1.8.0: films and episodes kept on the phone. Everything here is read from the phone: the list, the files, the
/// resume points and the kept subtitles — nothing waits for the provider or Google.
struct DownloadsView: View {
    @ObservedObject private var dl = Downloads.shared
    @EnvironmentObject var library: Library
    @Binding var play: PlayItem?
    @State private var deleting: DownloadItem?

    var body: some View {
        List {
            if dl.items.isEmpty {
                Text("ما فيه تنزيلات. افتح فيلمًا أو حلقة واضغط «تنزيل».").foregroundStyle(.secondary)
            }
            ForEach(dl.items) { it in
                row(it)
                    .swipeActions { Button("حذف", role: .destructive) { deleting = it } }
            }
            Section {
                Text("""
                • تنزيل واحد في كل مرة، ويتوقف تلقائيًا وأنت تشاهد من المزوّد، ويكمل بعدها.
                • على Wi‑Fi فقط، إلا إذا سمحت ببيانات الجوال لتنزيل معيّن.
                • والتطبيق مفتوح: كل ما يصل يُحفظ أولًا بأول — الإيقاف أو انقطاع الشبكة أو المشاهدة لا تضيّع شيئًا.
                • في الخلفية أو الشاشة مقفلة: يكمل بتنزيل iOS (iOS يقرر السرعة) ويُضاف لما يخلص. إذا أوقفته قبل ما يخلص، قد يُعاد ما نزل في الخلفية فقط.
                • إذا سحبت التطبيق من مبدّل التطبيقات يوقف iOS التنزيل؛ المحفوظ يبقى ويكمل لما تفتح التطبيق.
                • الملف ما يُعتبر جاهزًا إلا إذا اكتمل حجمه كما أعلنه المزوّد.
                """).font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("التنزيلات")
        .confirmationDialog("حذف «\(deleting?.title ?? "")» من الجهاز؟", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            titleVisibility: .visible) {
            Button("حذف", role: .destructive) { if let d = deleting { dl.delete(d.id) }; deleting = nil }
        } message: { Text("نقطة التوقف والترجمة تبقى.") }
    }

    private func mb(_ n: Int64) -> String { Downloads.size(n) }

    @ViewBuilder private func row(_ it: DownloadItem) -> some View {
        let have = dl.liveHave[it.id] ?? it.have
        VStack(alignment: .leading, spacing: 6) {
            Text(it.title).font(.subheadline.weight(.semibold)).lineLimit(2)
            if let t = it.total, t > 0, it.state != .done {
                ProgressView(value: Double(min(have, t)), total: Double(t))
                Text("\(mb(have)) من \(mb(t))").font(.caption).foregroundStyle(.secondary)
            } else if it.state == .done, let t = it.total {
                Text(mb(t)).font(.caption).foregroundStyle(.secondary)
            }
            Text(stateText(it)).font(.caption).foregroundStyle(it.state == .failed || it.state == .noSpace ? .orange : .secondary)
            if let n = it.note { Text(n).font(.caption2).foregroundStyle(.secondary) }
            HStack(spacing: 10) {
                switch it.state {
                case .done:
                    Button { playItem(it) } label: { Label("تشغيل", systemImage: "play.fill") }.buttonStyle(.borderedProminent)
                case .downloading, .queued, .waitingPlayback:
                    Button { dl.pause(it.id) } label: { Label("إيقاف مؤقت", systemImage: "pause.fill") }.buttonStyle(.bordered)
                case .waitingWifi:
                    Button { dl.allowCellular(it.id) } label: { Label("السماح ببيانات الجوال", systemImage: "antenna.radiowaves.left.and.right") }
                        .buttonStyle(.bordered)
                case .paused, .failed, .noSpace:
                    Button { dl.resume(it.id) } label: { Label("استكمال", systemImage: "arrow.down.circle") }.buttonStyle(.bordered)
                }
                if it.cellular && it.state != .done { Text("مسموح بالبيانات").font(.caption2).foregroundStyle(.secondary) }
            }
            .font(.caption)
        }
        .padding(.vertical, 4)
    }

    private func stateText(_ it: DownloadItem) -> String {
        switch it.state {
        case .queued: return "في الانتظار"
        case .downloading: return "يتنزّل"
        case .paused: return "موقوف"
        case .waitingPlayback: return "موقوف أثناء المشاهدة — يكمل بعد ما تقفل المشغّل"
        case .waitingWifi: return "ينتظر Wi‑Fi"
        case .noSpace: return "المساحة لا تكفي"
        case .failed: return "توقف"
        case .done: return "جاهز للمشاهدة بدون إنترنت"
        }
    }

    /// Plays from the saved details only (no provider, no series page). The player picks the local file by key.
    private func playItem(_ it: DownloadItem) {
        guard let file = dl.localFile(source: UUID(uuidString: it.sourceId), key: it.key) else { return }
        play = .vod(list: [VodPlay(title: it.title, url: file.absoluteString, key: it.key,
                                   query: SubQuery(name: it.queryName, season: it.season, episode: it.number),
                                   season: it.season, number: it.number, container: it.ext, traktName: it.traktName)], index: 0)
    }
}

/// «تنزيل» on a film page / episode row: shows the state of this item's download.
struct DownloadButton: View {
    @ObservedObject private var dl = Downloads.shared
    @EnvironmentObject var library: Library
    let key: String
    let kind: String
    let streamId: String
    let ext: String
    let title: String
    let queryName: String
    var season: Int? = nil
    var number: Int? = nil
    var traktName: String? = nil
    var compact = false

    var body: some View {
        let it = dl.item(source: library.active?.id, key: key)
        Button {
            guard let s = library.active, s.kind == .xtream else { return }
            if let it {
                if it.state == .paused || it.state == .failed || it.state == .noSpace { dl.resume(it.id) }
            } else {
                dl.add(source: s, key: key, kind: kind, streamId: streamId, ext: ext, title: title, queryName: queryName,
                       season: season, number: number, traktName: traktName)
            }
        } label: {
            if compact {
                Image(systemName: icon(it)).font(.title3)
            } else {
                Label(text(it), systemImage: icon(it)).frame(maxWidth: .infinity).padding(.vertical, 4)
            }
        }
        .disabled(library.active?.kind != .xtream)
        .accessibilityLabel(text(it))
    }

    private func icon(_ it: DownloadItem?) -> String {
        switch it?.state {
        case nil: return "arrow.down.circle"
        case .done: return "checkmark.circle.fill"
        case .failed, .noSpace: return "exclamationmark.circle"
        case .paused: return "pause.circle"
        default: return "arrow.down.circle.dotted"
        }
    }

    private func text(_ it: DownloadItem?) -> String {
        guard let it else { return "تنزيل للمشاهدة بدون إنترنت" }
        switch it.state {
        case .done: return "محفوظ على الجهاز"
        case .failed, .noSpace: return "التنزيل توقف — اضغط للاستكمال"
        case .paused: return "التنزيل موقوف — اضغط للاستكمال"
        default:
            if let t = it.total, t > 0 { return "يتنزّل \(Int(Double(dl.liveHave[it.id] ?? it.have) / Double(t) * 100))٪" }
            return "في قائمة التنزيل"
        }
    }
}

/// The OK to use mobile data for a download, while the app is open (in the background it is a notification).
struct CellularAsk: ViewModifier {
    @ObservedObject private var dl = Downloads.shared
    func body(content: Content) -> some View {
        content.alert("ما فيه Wi‑Fi", isPresented: Binding(get: { dl.cellularAsk != nil }, set: { if !$0 { dl.cellularAsk = nil } })) {
            Button("موافق — كمّل ببيانات الجوال") { if let id = dl.cellularAsk { dl.allowCellular(id) } }
            Button("انتظر Wi‑Fi", role: .cancel) { dl.cellularAsk = nil }
        } message: {
            Text("«\(dl.items.first { $0.id == dl.cellularAsk }?.title ?? "")» ينتظر Wi‑Fi. تكمل ببيانات الجوال؟ قد يستهلك عدة GB.")
        }
    }
}
