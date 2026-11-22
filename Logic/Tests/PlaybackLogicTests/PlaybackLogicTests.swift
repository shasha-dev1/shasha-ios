import XCTest
import CryptoKit
@testable import PlaybackLogic

final class StallDetectorTests: XCTestCase {
    func feed(_ d: inout StallDetector, _ samples: [(Int32, EngineState)], paused: Bool = false) -> [Bool] {
        samples.map { d.sample(timeMs: $0.0, state: $0.1, viewerPaused: paused) }
    }

    func testOpeningShowsSpinner() {
        var d = StallDetector()
        XCTAssertTrue(d.sample(timeMs: 0, state: .opening, viewerPaused: false))
    }

    func testPlayingWithMovingClockNeverSpins() {
        var d = StallDetector()
        // VLC says "buffering" while the clock moves: no spinner.
        let r = feed(&d, [(500, .buffering), (1000, .buffering), (1500, .playing), (2000, .buffering), (2500, .buffering)])
        XCTAssertEqual(r, [false, false, false, false, false])
    }

    func testFrozenClockSpinsAfterThreeTicks() {
        var d = StallDetector()
        let r = feed(&d, [(1000, .playing), (1000, .buffering), (1000, .buffering), (1000, .buffering), (1500, .playing)])
        XCTAssertEqual(r, [false, false, false, true, false])
    }

    func testViewerPauseNeverSpins() {
        var d = StallDetector()
        let r = feed(&d, [(1000, .playing), (1000, .playing), (1000, .playing), (1000, .playing), (1000, .paused)], paused: true)
        XCTAssertEqual(r, [false, false, false, false, false])
    }

    func testEnginePausedEndedErrorNeverSpin() {
        var d = StallDetector()
        for s: EngineState in [.paused, .ended, .error, .stopped] {
            XCTAssertFalse(d.sample(timeMs: 1000, state: s, viewerPaused: false))
            XCTAssertFalse(d.sample(timeMs: 1000, state: s, viewerPaused: false))
            XCTAssertFalse(d.sample(timeMs: 1000, state: s, viewerPaused: false))
            XCTAssertFalse(d.sample(timeMs: 1000, state: s, viewerPaused: false))
        }
    }

    func testSeekResetThenRebufferSpins() {
        var d = StallDetector()
        _ = feed(&d, [(10_000, .playing), (10_500, .playing)])
        d.reset()                                   // viewer seeked to 600 s
        let r = feed(&d, [(600_000, .buffering), (600_000, .buffering), (600_000, .buffering), (600_000, .buffering), (600_400, .playing)])
        XCTAssertEqual(r, [false, false, false, true, false])
    }

    func testLiveClockMovingNoSpinner() {
        var d = StallDetector()
        let r = feed(&d, (1...10).map { (Int32($0 * 500), EngineState.buffering) })
        XCTAssertFalse(r.contains(true))
    }
}

final class EndRuleTests: XCTestCase {
    let len: Int32 = 2_700_000   // 45 min

    func testEndAtRealEndIsFinished() {
        XCTAssertEqual(EndRule.onEnded(lastTimeMs: len - 2_000, lengthMs: len), .finished)
    }

    func testEndInLastMinuteIsFinished() {
        XCTAssertEqual(EndRule.onEnded(lastTimeMs: len - 59_000, lengthMs: len), .finished)
    }

    func testEndAt95PercentIsFinished() {
        XCTAssertEqual(EndRule.onEnded(lastTimeMs: Int32(Double(len) * 0.95), lengthMs: len), .finished)
    }

    func testEarlyEndIsNotFinished() {
        XCTAssertEqual(EndRule.onEnded(lastTimeMs: 600_000, lengthMs: len), .stoppedEarly)
        XCTAssertEqual(EndRule.onEnded(lastTimeMs: len - 5 * 60_000, lengthMs: len), .stoppedEarly)
    }

    func testUnknownLengthOrZeroClockIsNotFinished() {
        XCTAssertEqual(EndRule.onEnded(lastTimeMs: 600_000, lengthMs: 0), .stoppedEarly)
        XCTAssertEqual(EndRule.onEnded(lastTimeMs: 0, lengthMs: len), .stoppedEarly)
    }
}

final class EngineStoppedTests: XCTestCase {
    let len: Int32 = 2_700_000

    func testStoppedOrEndedAlwaysNeedsDecision() {
        XCTAssertTrue(EndRule.engineStopped(state: .stopped, viewerPaused: false, frozenMs: 0, timeMs: len - 1_000, lengthMs: len))
        XCTAssertTrue(EndRule.engineStopped(state: .ended, viewerPaused: false, frozenMs: 0, timeMs: 0, lengthMs: len))
        // …and an early stop is then judged "stopped early", not finished.
        XCTAssertEqual(EndRule.onEnded(lastTimeMs: 600_000, lengthMs: len), .stoppedEarly)
    }

    func testFrozenAtTheEndCountsAfterFourSeconds() {
        // Owner's case: clock stuck at 00:01 left, black picture, engine still "playing".
        XCTAssertFalse(EndRule.engineStopped(state: .playing, viewerPaused: false, frozenMs: 3_500, timeMs: len - 1_000, lengthMs: len))
        XCTAssertTrue(EndRule.engineStopped(state: .buffering, viewerPaused: false, frozenMs: 4_000, timeMs: len - 1_000, lengthMs: len))
        XCTAssertEqual(EndRule.onEnded(lastTimeMs: len - 1_000, lengthMs: len), .finished)
    }

    func testFreezeBeforeTheEndIsOnlyAStall() {
        XCTAssertFalse(EndRule.engineStopped(state: .buffering, viewerPaused: false, frozenMs: 60_000, timeMs: len - 5 * 60_000, lengthMs: len))
        XCTAssertFalse(EndRule.engineStopped(state: .buffering, viewerPaused: false, frozenMs: 60_000, timeMs: 30_000, lengthMs: 0))
    }

    func testViewerPauseOrEnginePauseNeverEnds() {
        XCTAssertFalse(EndRule.engineStopped(state: .playing, viewerPaused: true, frozenMs: 60_000, timeMs: len - 1_000, lengthMs: len))
        XCTAssertFalse(EndRule.engineStopped(state: .paused, viewerPaused: false, frozenMs: 60_000, timeMs: len - 1_000, lengthMs: len))
    }

    func testFrozenMsFromDetector() {
        var d = StallDetector()
        for _ in 0..<9 { _ = d.sample(timeMs: 1000, state: .playing, viewerPaused: false) }
        XCTAssertEqual(d.frozenMs, 4_000)
    }
}

final class NextCardRuleTests: XCTestCase {
    let len: Int32 = 2_700_000

    func testShowsOnlyNearTheEnd() {
        XCTAssertFalse(NextCardRule.visible(current: false, hasNext: true, dismissed: false, timeMs: len - 60_000, lengthMs: len, scrubbing: false))
        XCTAssertTrue(NextCardRule.visible(current: false, hasNext: true, dismissed: false, timeMs: len - 39_000, lengthMs: len, scrubbing: false))
    }

    func testStaysVisibleWithoutCountingDownAndHidesWhenSeekingBack() {
        XCTAssertTrue(NextCardRule.visible(current: true, hasNext: true, dismissed: false, timeMs: len - 1_000, lengthMs: len, scrubbing: false))
        XCTAssertTrue(NextCardRule.visible(current: true, hasNext: true, dismissed: false, timeMs: len - 42_000, lengthMs: len, scrubbing: false))
        XCTAssertFalse(NextCardRule.visible(current: true, hasNext: true, dismissed: false, timeMs: len - 50_000, lengthMs: len, scrubbing: false))
    }

    func testNoCardWithoutNextDismissedOrShortItem() {
        XCTAssertFalse(NextCardRule.visible(current: false, hasNext: false, dismissed: false, timeMs: len - 1_000, lengthMs: len, scrubbing: false))
        XCTAssertFalse(NextCardRule.visible(current: false, hasNext: true, dismissed: true, timeMs: len - 1_000, lengthMs: len, scrubbing: false))
        XCTAssertFalse(NextCardRule.visible(current: false, hasNext: true, dismissed: false, timeMs: 90_000, lengthMs: 100_000, scrubbing: false))
    }
}

final class ResumeRuleTests: XCTestCase {
    func testSavesUnderTheSessionOnScreen() {
        let s = PlaybackSession(id: 3, key: "ep3")
        XCTAssertEqual(ResumeRule.save(screen: s, engineSessionId: 3, timeMs: 61_000, lengthMs: 2_700_000),
                       ResumeSave(key: "ep3", positionS: 61, durationS: 2700))
    }

    func testNeverSavesPreviousEpisodeNumbersUnderTheNextKey() {
        // Screen already shows episode 4 (session 4) but the engine numbers still belong to episode 3.
        let next = PlaybackSession(id: 4, key: "ep4")
        XCTAssertNil(ResumeRule.save(screen: next, engineSessionId: 3, timeMs: 2_650_000, lengthMs: 2_700_000))
    }

    func testFreshItemReadingZeroDoesNotWipeResume() {
        let s = PlaybackSession(id: 5, key: "film")
        XCTAssertNil(ResumeRule.save(screen: s, engineSessionId: 5, timeMs: 0, lengthMs: 5_400_000))
        XCTAssertNil(ResumeRule.save(screen: s, engineSessionId: 5, timeMs: 30_000, lengthMs: 0))
        XCTAssertNil(ResumeRule.save(screen: nil, engineSessionId: 5, timeMs: 30_000, lengthMs: 5_400_000))
    }

    func testPeriodicDue() {
        XCTAssertFalse(ResumeRule.periodicDue(lastSavedAtMs: nil, timeMs: 5_000))
        XCTAssertTrue(ResumeRule.periodicDue(lastSavedAtMs: nil, timeMs: 10_000))
        XCTAssertFalse(ResumeRule.periodicDue(lastSavedAtMs: 20_000, timeMs: 25_000))
        XCTAssertTrue(ResumeRule.periodicDue(lastSavedAtMs: 20_000, timeMs: 30_500))
        XCTAssertTrue(ResumeRule.periodicDue(lastSavedAtMs: 600_000, timeMs: 30_000))   // seeked back
    }

    func testStartPosition() {
        XCTAssertNil(ResumeRule.startPosition(stored: nil))
        XCTAssertNil(ResumeRule.startPosition(stored: 10))
        XCTAssertEqual(ResumeRule.startPosition(stored: 125), 125)
    }
}

final class PauseRuleTests: XCTestCase {
    func testCommandsShareOneState() {
        XCTAssertTrue(PauseRule.apply(.pause, viewerPaused: false))
        XCTAssertFalse(PauseRule.apply(.play, viewerPaused: true))
        XCTAssertTrue(PauseRule.apply(.toggle, viewerPaused: false))
        XCTAssertFalse(PauseRule.apply(.toggle, viewerPaused: true))
        XCTAssertTrue(PauseRule.apply(.pause, viewerPaused: true))      // repeated pause stays paused
    }
}

/// Mutable flag shared with async closures (a captured `var` cannot be mutated from a Task).
final class Flag { var on = false }

final class SessionAndDelayedTests: XCTestCase {
    func testNewSessionInvalidatesOld() {
        let g = SessionGate()
        let a = g.begin(key: "ep3")
        XCTAssertTrue(g.isCurrent(a.id))
        let b = g.begin(key: "ep4")
        XCTAssertFalse(g.isCurrent(a.id))
        XCTAssertTrue(g.isCurrent(b.id))
        g.end()
        XCTAssertFalse(g.isCurrent(b.id))
        XCTAssertFalse(g.isCurrent(nil))
    }

    func testDelayedRunsForCurrentSession() async {
        let g = SessionGate()
        let s = g.begin(key: "x")
        let ran = Flag()
        let r = await Delayed.run(after: 10_000_000, stillValid: { g.isCurrent(s.id) }) { ran.on = true }
        XCTAssertTrue(r); XCTAssertTrue(ran.on)
    }

    func testDelayedSkipsStaleSession() async {
        let g = SessionGate()
        let s = g.begin(key: "ep3")
        let ran = Flag()
        let t = Task { await Delayed.run(after: 50_000_000, stillValid: { g.isCurrent(s.id) }) { ran.on = true } }
        _ = g.begin(key: "ep4")          // next episode opened while the old task sleeps
        let r = await t.value
        XCTAssertFalse(r); XCTAssertFalse(ran.on)
    }

    func testDelayedSkipsWhenCancelled() async {
        let ran = Flag()
        let t = Task { await Delayed.run(after: 200_000_000, stillValid: { true }) { ran.on = true } }
        t.cancel()                        // player closed
        let r = await t.value
        XCTAssertFalse(r); XCTAssertFalse(ran.on)
    }
}

final class GroupOrderRuleTests: XCTestCase {
    func testSavedOrderThenNewGroups() {
        XCTAssertEqual(GroupOrderRule.arrange(provider: ["a", "b", "c", "d"], saved: ["c", "a"]), ["c", "a", "b", "d"])
    }
    func testRemovedAndDuplicateIdsIgnored() {
        XCTAssertEqual(GroupOrderRule.arrange(provider: ["a", "b"], saved: ["x", "b", "b", "a"]), ["b", "a"])
    }
    func testNoSavedOrderKeepsProvider() {
        XCTAssertEqual(GroupOrderRule.arrange(provider: ["a", "b"], saved: []), ["a", "b"])
    }
}

final class DiagRuleTests: XCTestCase {
    func testRedactsLinksAndSecrets() {
        let s = DiagRule.redact("open http://srv.example:8080/series/ali/pa55/123.mkv failed for ali / pa55", secrets: ["ali", "pa55"])
        XCTAssertFalse(s.contains("http")); XCTAssertFalse(s.contains("pa55")); XCTAssertFalse(s.contains("ali"))
        XCTAssertTrue(s.contains("[رابط مخفي]"))
    }
    func testShortSecretsIgnored() {
        XCTAssertEqual(DiagRule.redact("a b", secrets: ["a"]), "a b")
    }
    func testFourcc() {
        XCTAssertEqual(DiagRule.fourcc(0x63766568), "hevc")     // 'h','e','v','c' little-endian
        XCTAssertEqual(DiagRule.fourcc(0), "غير متاح")
    }
    func testProbeLinesOnlyWhatIsThere() {
        let v: [String: Any] = ["codec_name": "hevc", "profile": "Main 10", "color_transfer": "smpte2084",
                                "side_data_list": [["side_data_type": "DOVI configuration record", "dv_profile": 5, "dv_bl_signal_compatibility_id": 0]]]
        let lines = DiagRule.probeLines(video: v, audio: nil)
        XCTAssertTrue(lines.contains("فيديو ترميز: hevc"))
        XCTAssertTrue(lines.contains("فيديو color_transfer: smpte2084"))
        XCTAssertTrue(lines.contains { $0.contains("DOVI") && $0.contains("dv_profile=5") })
        XCTAssertFalse(lines.contains { $0.contains("color_primaries") })
        XCTAssertTrue(DiagRule.probeLines(video: nil, audio: nil).isEmpty)
    }
}

final class CopyRuleTests: XCTestCase {
    func testSameWorkAcrossTags() {
        let a = CopyRule.key("4K-AMZ - The Lord of the Rings: The Rings of Power (2022) (US)")
        XCTAssertEqual(a, "the lord of the rings the rings of power")
        XCTAssertEqual(CopyRule.key("AR - The Lord of the Rings The Rings of Power"), a)
        XCTAssertEqual(CopyRule.key("The Lord of the Rings: The Rings of Power [4K]"), a)
        XCTAssertEqual(CopyRule.key("4K-NF - The Diplomat (2023) (US)"), "the diplomat")
    }
    func testDifferentWorksStayDifferent() {
        XCTAssertNotEqual(CopyRule.key("The Diplomat"), CopyRule.key("The Diplomat's Wife"))
    }
    func testDolbyVision5() {
        XCTAssertTrue(CopyRule.isDolbyVision5(["فيديو side data: DOVI configuration record (dv_profile=5, dv_bl_signal_compatibility_id=0)"]))
        XCTAssertFalse(CopyRule.isDolbyVision5(["فيديو side data: DOVI configuration record (dv_profile=8, dv_bl_signal_compatibility_id=1)"]))
        XCTAssertFalse(CopyRule.isDolbyVision5(["فيديو color_transfer: bt709"]))
    }
}

final class SearchRuleTests: XCTestCase {
    func testArabicVariantsMatch() {
        XCTAssertTrue(SearchRule.matches(SearchRule.fold("مسلسل الأميرة"), SearchRule.fold("الاميره")))
        XCTAssertTrue(SearchRule.matches(SearchRule.fold("مُسَلْسَل"), SearchRule.fold("مسلسل")))
        XCTAssertTrue(SearchRule.matches(SearchRule.fold("على مسؤولية"), SearchRule.fold("علي مسوولية")))
    }
    func testLatinCaseAndAccents() {
        XCTAssertTrue(SearchRule.matches(SearchRule.fold("The Rings of Power"), SearchRule.fold("rings OF")))
        XCTAssertTrue(SearchRule.matches(SearchRule.fold("Amélie"), SearchRule.fold("amelie")))
        XCTAssertFalse(SearchRule.matches(SearchRule.fold("Dune"), SearchRule.fold("dun2")))
    }
    func testEmptyQueryMatchesAll() {
        XCTAssertTrue(SearchRule.matches(SearchRule.fold("anything"), ""))
    }
}

final class TmdbRuleTests: XCTestCase {
    func testSplitTag() {
        XCTAssertEqual(TmdbRule.split("AR-TR-S - Yeraltı (2026)").tag, "AR-TR-S")
        XCTAssertEqual(TmdbRule.split("AR-TR-S - Yeraltı (2026)").title, "Yeraltı (2026)")
        XCTAssertNil(TmdbRule.split("The Diplomat").tag)
    }
    func testYearAndTerms() {
        XCTAssertEqual(TmdbRule.year("Yeraltı (2026) تحت الارض"), 2026)
        XCTAssertEqual(TmdbRule.searchTerms("Yeraltı (2026) تحت الارض"), ["Yeraltı تحت الارض", "Yeraltı", "تحت الارض"])
    }
    func testChooseOnlyUnambiguous() {
        let a = TmdbRule.Candidate(id: 1, name: "Dune", originalName: "Dune", year: 2021)
        let b = TmdbRule.Candidate(id: 2, name: "Dune", originalName: "Dune", year: 1984)
        XCTAssertEqual(TmdbRule.choose([a, b], term: "Dune", year: 2021), 1)
        XCTAssertNil(TmdbRule.choose([a, b], term: "Dune", year: nil))
        XCTAssertNil(TmdbRule.choose([a], term: "Dune Part Two", year: 2021))
    }
    func testLibraryKey() {
        XCTAssertEqual(TmdbRule.libraryKey("EN| The Batman (2022) [4K]"), TmdbRule.key("The Batman"))
    }
}

final class TraktRuleTests: XCTestCase {
    func testPollCodes() {
        XCTAssertEqual(TraktRule.poll(200), .success)
        XCTAssertEqual(TraktRule.poll(400), .pending)
        XCTAssertEqual(TraktRule.poll(418), .denied)
        XCTAssertEqual(TraktRule.poll(429), .slowDown)
        XCTAssertEqual(TraktRule.poll(500), .failed(500))
    }
    func testProgressAndExit() {
        XCTAssertEqual(TraktRule.percent(positionMs: 500, durationMs: 1000), 50)
        XCTAssertNil(TraktRule.percent(positionMs: 5, durationMs: 0))
        XCTAssertEqual(TraktRule.exitAction(94.9), .pause)
        XCTAssertEqual(TraktRule.exitAction(95), .stop)
        XCTAssertFalse(TraktRule.worthSending(0.5))
    }
    func testSearchTitle() {
        let r = TraktRule.searchTitle("Alıkara (2026)\nعلي كارا", fallbackYear: nil)
        XCTAssertEqual(r.title, "Alıkara"); XCTAssertEqual(r.year, 2026)
    }
    func testIdentityEpisode() {
        let i = TraktRule.identity(title: "The Diplomat", year: 2023, tmdb: 194764, season: 2, number: 3)
        XCTAssertNotNil(i["show"]); XCTAssertEqual((i["episode"] as? [String: Int])?["number"], 3)
        let b = TraktRule.body(i, progress: 12.345).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        XCTAssertEqual(b?["progress"] as? Double, 12.35)
    }
}

final class TraktResumeRuleTests: XCTestCase {
    func testChoices() {
        let now = Date()
        XCTAssertEqual(TraktResumeRule.choose(localPos: nil, localAt: nil, traktPct: 40, traktAt: now), .trakt(40))
        XCTAssertEqual(TraktResumeRule.choose(localPos: 300, localAt: nil, traktPct: 40, traktAt: now), .local)
        XCTAssertEqual(TraktResumeRule.choose(localPos: 300, localAt: now.addingTimeInterval(-3600), traktPct: 40, traktAt: now), .trakt(40))
        XCTAssertEqual(TraktResumeRule.choose(localPos: 300, localAt: now, traktPct: 40, traktAt: now.addingTimeInterval(-3600)), .local)
        XCTAssertEqual(TraktResumeRule.choose(localPos: nil, localAt: nil, traktPct: 97, traktAt: now), .none)
    }
}

final class CloudSyncRuleTests: XCTestCase {
    func testAccountIgnoresSchemeCaseAndPath() {
        let a = CloudSyncRule.account(server: "http://Example.com:8080/", user: "u", sha256: { $0 })
        XCTAssertEqual(a, String("example.com:8080|u".prefix(16)))
        XCTAssertEqual(CloudSyncRule.account(server: "http://example.com", user: "u", sha256: { $0 }), String("example.com:80|u".prefix(16)))
        XCTAssertNil(CloudSyncRule.account(server: "nonsense", user: "u", sha256: { $0 }))
    }
    func testKnownHashSameAsTvApp() {
        // sha256("example.com:80|u") — the TV app's CloudSyncCoreTest checks the same value.
        let h = CloudSyncRule.account(server: "http://example.com", user: "u", sha256: { s in
            SHA256.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined() })
        XCTAssertEqual(h, "99a6431f6092f25a")
    }
    func testMergeNewestWins() {
        var a = CloudSyncRule.File(); var b = CloudSyncRule.File()
        a.progress["k"] = .init(pos: 10, dur: 100, w: false, at: 1, show: nil)
        b.progress["k"] = .init(pos: 50, dur: 100, w: false, at: 2, show: nil)
        b.progress["j"] = .init(pos: 5, dur: 100, w: false, at: 1, show: nil)
        let m = CloudSyncRule.merge(a, b)
        XCTAssertEqual(m.progress["k"]?.pos, 50); XCTAssertEqual(m.progress.count, 2)
        XCTAssertEqual(CloudSyncRule.merge(b, a).progress["k"]?.pos, 50)
        XCTAssertEqual(CloudSyncRule.newer(b, than: a).map(\.key), ["j", "k"])
    }
    func testLimitKeepsNewest() {
        var f = CloudSyncRule.File()
        for i in 0..<10 { f.progress["k\(i)"] = .init(pos: 1, dur: 2, w: false, at: Int64(i), show: nil) }
        let m = CloudSyncRule.merge(f, CloudSyncRule.File(), limit: 3)
        XCTAssertEqual(Set(m.progress.keys), ["k7", "k8", "k9"])
    }
}

final class CategoryNameRuleTests: XCTestCase {
    func testDecorationsRemoved() {
        XCTAssertEqual(CategoryNameRule.display("ᴅᴏʟʙʏ ᴀᴜᴅɪᴏ"), "DOLBY AUDIO")
        XCTAssertEqual(CategoryNameRule.display("🇸🇦 | مسلسلات عربية"), "مسلسلات عربية")
        XCTAssertEqual(CategoryNameRule.display("★ AR | Netflix ★"), "AR Netflix")
        XCTAssertEqual(CategoryNameRule.display("𝐓𝐔𝐑𝐊𝐈𝐒𝐇 - "), "TURKISH")
        XCTAssertEqual(CategoryNameRule.display("🔥🔥 4K UHD 🔥"), "4K UHD")
    }
    func testPlainKept() {
        XCTAssertEqual(CategoryNameRule.display("يعرض الآن تركي مترجم"), "يعرض الآن تركي مترجم")
        XCTAssertEqual(CategoryNameRule.display("Action 2024"), "Action 2024")
        XCTAssertEqual(CategoryNameRule.display("🔥"), "🔥")   // nothing left → original
    }
}

final class WorkRuleTests: XCTestCase {
    func testProviderCopiesOfOneWorkShareAKey() {
        let a = WorkRule.key("4K-AMZ - The Lord of the Rings: The Rings of Power (2022) (US)", kind: "show")
        let b = WorkRule.key("The Lord of the Rings: The Rings of Power (2022)", kind: "show")
        XCTAssertFalse(a.isEmpty)
        XCTAssertEqual(a, b)
    }
    func testDifferentYearsAreDifferentWorks() {
        XCTAssertNotEqual(WorkRule.key("Dune (1984)", kind: "movie"), WorkRule.key("Dune (2021)", kind: "movie"))
    }
    func testYearAndNoYearStaySeparate() {
        XCTAssertNotEqual(WorkRule.key("Dune (2021)", kind: "movie"), WorkRule.key("Dune", kind: "movie"))
    }
    func testFilmAndSeriesNeverMatch() {
        XCTAssertNotEqual(WorkRule.key("Fargo (1996)", kind: "movie"), WorkRule.key("Fargo (1996)", kind: "show"))
    }
    func testBareAndBracketedYearMatch() {
        XCTAssertEqual(WorkRule.key("Lanterns (2026) (US)", kind: "show"), WorkRule.key("Lanterns 2026", kind: "show"))
    }
    func testYearParsing() {
        XCTAssertEqual(WorkRule.year("Lanterns (2026) (US)"), 2026)
        XCTAssertNil(WorkRule.year("رجال تحت الطربوش"))
        XCTAssertEqual(WorkRule.key("2012", kind: "movie"), "")
    }
}

final class CloudSyncSafetyTests: XCTestCase {
    func testUnreadableFileIsRefusedNotEmpty() {
        XCTAssertThrowsError(try CloudSyncRule.decode(Data("not json".utf8))) { XCTAssertEqual($0 as? CloudSyncRule.FileError, .unreadable) }
    }
    func testNewerFormatIsRefused() {
        XCTAssertThrowsError(try CloudSyncRule.decode(Data(#"{"v":2,"progress":{}}"#.utf8))) {
            XCTAssertEqual($0 as? CloudSyncRule.FileError, .newerFormat(2))
        }
    }
    func testTooBigIsRefused() {
        XCTAssertThrowsError(try CloudSyncRule.decode(Data(repeating: 32, count: 11), maxBytes: 10))
    }
    func testTvFileWithoutNewFieldsDecodes() throws {
        // Exactly what the TV app 0.9.10 writes (CloudSyncCore.encode).
        let tv = #"{"v":1,"progress":{"99a6431f6092f25a|ep|77":{"pos":120.5,"dur":2700,"w":false,"at":1732280000000,"show":"9"}}}"#
        let f = try CloudSyncRule.decode(Data(tv.utf8))
        XCTAssertEqual(f.progress["99a6431f6092f25a|ep|77"]?.show, "9")
        XCTAssertNil(f.progress["99a6431f6092f25a|ep|77"]?.x)
    }
    func testRemovalFlagRoundTripsAndIsOmittedWhenNil() throws {
        var f = CloudSyncRule.File()
        f.progress["a"] = .init(pos: 1, dur: 2, w: false, at: 5, show: nil, x: true)
        f.progress["b"] = .init(pos: 1, dur: 2, w: false, at: 5, show: nil)
        let data = try JSONEncoder().encode(f)
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertEqual(text.components(separatedBy: "\"x\"").count - 1, 1)
        XCTAssertEqual(try CloudSyncRule.decode(data), f)
    }
    func testFutureClockEntryNeverWins() {
        let now: Int64 = 1_800_000_000_000
        var local = CloudSyncRule.File(); var remote = CloudSyncRule.File()
        local.progress["k"] = .init(pos: 30, dur: 100, w: false, at: now - 1000, show: nil)
        remote.progress["k"] = .init(pos: 90, dur: 100, w: false, at: now + 3 * 24 * 3600 * 1000, show: nil)
        XCTAssertTrue(CloudSyncRule.newer(remote, than: local, nowMs: now).isEmpty)
        XCTAssertEqual(CloudSyncRule.merge(local, remote, nowMs: now).progress["k"]?.pos, 30)
    }
    func testRewatchAfterOldCompletionWins() {
        let now: Int64 = 1_800_000_000_000
        var tv = CloudSyncRule.File(); var phone = CloudSyncRule.File()
        tv.progress["k"] = .init(pos: 0, dur: 100, w: true, at: now - 10_000, show: nil)
        phone.progress["k"] = .init(pos: 20, dur: 100, w: false, at: now - 1_000, show: nil)
        let m = CloudSyncRule.merge(tv, phone, nowMs: now)
        XCTAssertEqual(m.progress["k"]?.w, false); XCTAssertEqual(m.progress["k"]?.pos, 20)
    }
    func testOlderCopyDoesNotUndoRemoval() {
        let now: Int64 = 1_800_000_000_000
        var cloud = CloudSyncRule.File(); var phone = CloudSyncRule.File()
        cloud.progress["k"] = .init(pos: 40, dur: 100, w: false, at: now - 50_000, show: nil)
        phone.progress["k"] = .init(pos: 40, dur: 100, w: false, at: now - 1_000, show: nil, x: true)
        XCTAssertEqual(CloudSyncRule.merge(phone, cloud, nowMs: now).progress["k"]?.x, true)
        XCTAssertTrue(CloudSyncRule.newer(cloud, than: phone, nowMs: now).isEmpty)
    }
}

final class CloudSyncConcurrencyTests: XCTestCase {
    let now: Int64 = 1_800_000_000_000
    func e(_ pos: Double, _ at: Int64, x: Bool? = nil) -> CloudSyncRule.Entry { .init(pos: pos, dur: 100, w: false, at: at, show: nil, x: x) }

    func testOverwrittenUploadIsDetectedAndRepaired() {
        var start = CloudSyncRule.File(); start.progress["s"] = e(1, now - 9000)
        var phone = CloudSyncRule.File(); phone.progress["p"] = e(30, now - 2000)
        var tv = CloudSyncRule.File(); tv.progress["t"] = e(60, now - 1000)
        // Both read `start`; the phone uploads, then the TV uploads its own merge over it.
        let onDrive = CloudSyncRule.merge(start, tv, nowMs: now)
        XCTAssertFalse(CloudSyncRule.covers(onDrive, phone, nowMs: now))     // the phone's re-read notices
        let repaired = CloudSyncRule.merge(onDrive, phone, nowMs: now)
        XCTAssertTrue(CloudSyncRule.covers(repaired, phone, nowMs: now))
        XCTAssertTrue(CloudSyncRule.covers(repaired, tv, nowMs: now))
        XCTAssertEqual(Set(repaired.progress.keys), ["s", "p", "t"])
    }
    func testRemovalSurvivesRepeatedMergesWithTheTvsRow() {
        var drive = CloudSyncRule.File(); drive.progress["k"] = e(40, now - 1000, x: true)
        var tvRow = CloudSyncRule.File(); tvRow.progress["k"] = e(40, now - 1000)
        for _ in 0..<5 { drive = CloudSyncRule.merge(drive, tvRow, nowMs: now) }
        XCTAssertEqual(drive.progress["k"]?.x, true)
        var replay = CloudSyncRule.File(); replay.progress["k"] = e(55, now)
        XCTAssertNil(CloudSyncRule.merge(drive, replay, nowMs: now).progress["k"]?.x)   // played again later: back
    }
    func testFutureEntriesCountedKeptAndLimitInclusive() {
        var f = CloudSyncRule.File()
        f.progress["f"] = e(10, now + 2 * 24 * 3600 * 1000)
        f.progress["edge"] = e(10, now + CloudSyncRule.futureSlackMs)
        XCTAssertEqual(CloudSyncRule.futureCount(f, nowMs: now), 1)
        XCTAssertEqual(CloudSyncRule.newer(f, than: CloudSyncRule.File(), nowMs: now).map(\.key), ["edge"])
        var local = CloudSyncRule.File(); local.progress["ok"] = e(5, now)
        XCTAssertNotNil(CloudSyncRule.merge(f, local, nowMs: now).progress["f"])          // stays in the file
    }
}

final class WorkRuleEdgeTests: XCTestCase {
    func testDubbedAndQualityCopiesAreOneWork() {
        let a = WorkRule.key("AR-DUB - Frozen (2013) (مدبلج)", kind: "movie")
        let b = WorkRule.key("4K | Frozen (2013)", kind: "movie")
        XCTAssertFalse(a.isEmpty); XCTAssertEqual(a, b)
    }
    func testSimilarTitlesStayApart() {
        XCTAssertNotEqual(WorkRule.key("Spider-Man (2002)", kind: "movie"), WorkRule.key("Spider-Man: No Way Home (2021)", kind: "movie"))
        XCTAssertNotEqual(WorkRule.key("The Office (2005)", kind: "show"), WorkRule.key("The Office (2001)", kind: "show"))
        XCTAssertNotEqual(WorkRule.key("Dune Part Two (2024)", kind: "movie"), WorkRule.key("Dune (2024)", kind: "movie"))
    }
    func testMissingYearOnBothMerges() {
        XCTAssertEqual(WorkRule.key("رجال تحت الطربوش", kind: "show"), WorkRule.key("FHD - رجال تحت الطربوش", kind: "show"))
    }
}

/// 1.7.1: the race and clock cases the owner asked for, with the same model as the TV app's tests.
final class CloudSyncRaceAndClockTests: XCTestCase {
    let now: Int64 = 1_800_000_000_000
    func e(_ pos: Double, _ at: Int64) -> CloudSyncRule.Entry { .init(pos: pos, dur: 100, w: false, at: at, show: nil) }
    func file(_ d: [String: CloudSyncRule.Entry]) -> CloudSyncRule.File { CloudSyncRule.File(v: 1, progress: d) }

    struct Drive { var file: CloudSyncRule.File; var version = 1 }
    /// Upload as the apps do: merge own data into what was read; with `checkVersion`, merge into the current file if it
    /// changed since the read. Returns the read-back check.
    func upload(_ d: inout Drive, read: CloudSyncRule.File, readVersion: Int, mine: CloudSyncRule.File, checkVersion: Bool) -> Bool {
        let base = (checkVersion && d.version != readVersion) ? d.file : read
        d.file = CloudSyncRule.merge(base, mine, nowMs: now); d.version += 1
        return CloudSyncRule.covers(d.file, mine, nowMs: now)
    }

    func testStaleUploadAfterTheOtherFinishedIsAKnownLimitWithoutVersionCheck() {
        var d = Drive(file: file(["s": e(1, now - 9000)]))
        let readByB = d.file, vB = d.version
        let a = file(["a": e(30, now - 2000)]), b = file(["b": e(60, now - 1000)])
        XCTAssertTrue(upload(&d, read: d.file, readVersion: d.version, mine: a, checkVersion: true))   // A done
        XCTAssertTrue(upload(&d, read: readByB, readVersion: vB, mine: b, checkVersion: false))         // B "verifies" too
        // Both checks passed, yet A's entry is gone from the cloud; A still has it locally and restores it on its next
        // sync only. This is why the docs don't call it "no data loss".
        XCTAssertNil(d.file.progress["a"])
        XCTAssertFalse(CloudSyncRule.covers(d.file, a, nowMs: now))
        _ = upload(&d, read: d.file, readVersion: d.version, mine: a, checkVersion: true)
        XCTAssertEqual(Set(d.file.progress.keys), ["s", "a", "b"])
    }
    func testStaleUploadIsCaughtByTheVersionCheck() {
        var d = Drive(file: file(["s": e(1, now - 9000)]))
        let readByB = d.file, vB = d.version
        _ = upload(&d, read: d.file, readVersion: d.version, mine: file(["a": e(30, now - 2000)]), checkVersion: true)
        _ = upload(&d, read: readByB, readVersion: vB, mine: file(["b": e(60, now - 1000)]), checkVersion: true)
        XCTAssertEqual(Set(d.file.progress.keys), ["s", "a", "b"])
    }
    func testClockAheadIsSentInGoogleTime() {
        let skew: Int64 = 2 * 24 * 3600 * 1000
        let sent = CloudSyncRule.stamp(now - 60_000 + skew, skewMs: skew, nowLocalMs: now + skew)
        XCTAssertEqual(sent, now - 60_000)
        XCTAssertEqual(CloudSyncRule.newer(file(["k": e(9, sent)]), than: file([:]), nowMs: now).count, 1)
    }
    func testClockBehindStillWinsWithItsNewerAction() {
        let skew: Int64 = -2 * 24 * 3600 * 1000
        let cloud = file(["k": e(10, now - 3_600_000)])
        let mine = file(["k": e(70, CloudSyncRule.stamp(now + skew - 1000, skewMs: skew, nowLocalMs: now + skew))])
        XCTAssertEqual(CloudSyncRule.merge(cloud, mine, nowMs: now).progress["k"]?.pos, 70)
        let raw = file(["k": e(70, now + skew - 1000)])
        XCTAssertEqual(CloudSyncRule.merge(cloud, raw, nowMs: now).progress["k"]?.pos, 10)   // why the correction matters
    }
    func testFixingTheClockSendsAnOrphanEntryAtNow() {
        let future = now + 3 * 24 * 3600 * 1000
        var cloud = file(["k": e(40, future)])
        XCTAssertTrue(CloudSyncRule.newer(cloud, than: file([:]), nowMs: now).isEmpty)          // stuck while wrong
        let p = CloudSyncRule.prepareOwn(file(["k": e(40, CloudSyncRule.stamp(future, skewMs: nil))]), file: cloud, nowMs: now)
        XCTAssertEqual(p.restamped, ["k"])
        cloud = CloudSyncRule.merge(cloud, p.send, nowMs: now)
        XCTAssertEqual(cloud.progress["k"]?.at, now)
        XCTAssertEqual(CloudSyncRule.newer(cloud, than: file([:]), nowMs: now).count, 1)
    }
    func testOldEventFromAWrongClockNeverBeatsANewerCorrectWatch() {
        // A (2 days ahead, skew unknown) paused at 40 an hour ago; B (right clock) watched to 75 ten minutes ago;
        // A's clock is corrected (skew ≈ 0) and A syncs.
        let aWrong = now - 3_600_000 + 2 * 24 * 3600 * 1000
        var cloud = file(["k": e(75, now - 600_000)])
        let aLocal = file(["k": e(40, CloudSyncRule.stamp(aWrong, skewMs: 0))])
        let p = CloudSyncRule.prepareOwn(aLocal, file: cloud, nowMs: now)
        XCTAssertEqual(p.withheld, ["k"]); XCTAssertNil(p.send.progress["k"])
        cloud = CloudSyncRule.merge(cloud, p.send, nowMs: now)
        XCTAssertEqual(cloud.progress["k"]?.pos, 75)
        XCTAssertEqual(CloudSyncRule.newer(cloud, than: p.send, nowMs: now).map(\.key), ["k"])   // A takes B's
        for _ in 0..<3 { cloud = CloudSyncRule.merge(cloud, CloudSyncRule.prepareOwn(aLocal, file: cloud, nowMs: now).send, nowMs: now) }
        XCTAssertEqual(cloud.progress["k"]?.pos, 75)
    }
    func testOwnEntryWithinJitterIsSentAsIs() {
        let p = CloudSyncRule.prepareOwn(file(["k": e(1, now + 60_000)]), file: file([:]), nowMs: now)
        XCTAssertEqual(p.send.progress["k"]?.at, now + 60_000)
        XCTAssertTrue(p.withheld.isEmpty && p.restamped.isEmpty)
    }
    func testRoundTripThroughLocalClockIsStable() {
        let skew: Int64 = 7 * 60_000
        let fileAt = now - 5000
        let storedLocally = CloudSyncRule.toLocal(fileAt, skewMs: skew)
        XCTAssertEqual(CloudSyncRule.stamp(storedLocally, skewMs: skew, nowLocalMs: now + skew), fileAt)
    }

    // 1.7.3: device report — every sync "applied 46" with nothing new. Each measurement of the skew differs by up
    // to about a second; entries must still come back to exactly the file's time.
    func testSkewJitterDoesNotReapplyOrReuploadTheSameEntries() {
        var cloud = file([:])
        for i in 0..<46 { cloud.progress["acct|movie|\(i)"] = e(Double(i), now - Int64(i) * 61_234 - 123) }
        var skew: Int64? = nil
        var local = file([:])          // what the phone keeps, re-stamped with the current skew on each sync
        var stored: [String: Double] = [:]   // phone's stored times, seconds (as Date keeps them)
        for measured: Int64 in [3_412, 4_080, 2_950, 3_999, 2_431, 3_700] {
            skew = CloudSyncRule.steadySkew(old: skew, measured: measured)
            local = file([:])
            for (k, t) in stored { local.progress[k] = e(cloud.progress[k]!.pos, CloudSyncRule.stamp(CloudSyncRule.ms(t), skewMs: skew)) }
            let toApply = CloudSyncRule.newer(cloud, than: local, nowMs: now)
            if !stored.isEmpty {
                XCTAssertTrue(toApply.isEmpty, "re-applied with measured skew \(measured)")
                XCTAssertEqual(CloudSyncRule.merge(cloud, local, nowMs: now), cloud, "re-upload with measured skew \(measured)")
            }
            for (k, x) in toApply { stored[k] = Double(CloudSyncRule.toLocal(x.at, skewMs: skew)) / 1000 }
        }
        XCTAssertEqual(skew, 3_412)
    }
    func testARealClockChangeIsStillPickedUp() {
        XCTAssertEqual(CloudSyncRule.steadySkew(old: 3_000, measured: 4_900), 3_000)
        XCTAssertEqual(CloudSyncRule.steadySkew(old: 3_000, measured: 5_001), 5_001)
        XCTAssertEqual(CloudSyncRule.steadySkew(old: 3_000, measured: -7 * 60_000), -7 * 60_000)
        XCTAssertEqual(CloudSyncRule.steadySkew(old: nil, measured: 1_234), 1_234)
    }
    func testMillisecondsAreRoundedNotTruncated() {
        for at: Int64 in [1_732_300_000_123, 1_763_830_000_001, 1_763_830_000_999, 1_763_830_000_577] {
            XCTAssertEqual(CloudSyncRule.ms(Date(timeIntervalSince1970: Double(at) / 1000).timeIntervalSince1970), at)
        }
    }
}

/// 1.7.5: subtitle sharing through Drive. The names must be the same on both apps (same vectors in the TV tests).
final class SubSyncRuleTests: XCTestCase {
    let sha: (String) -> String = { SHA256.hash(data: Data($0.utf8)).map { String(format: "%02x", $0) }.joined() }
    let day: Int64 = 24 * 3600 * 1000
    let now: Int64 = 1_800_000_000_000

    func testFileNamesMatchTheTvApp() {
        XCTAssertEqual(SubSyncRule.fileName(key: "0123456789abcdef|movie|12345", sha256: sha), "shasha-sub-v1-200a02eb8884dc7d433f9fe5.srt")
        XCTAssertEqual(SubSyncRule.fileName(key: "0123456789abcdef|ep|987654", sha256: sha), "shasha-sub-v1-b89e90fd6ac239417f88da25.srt")
    }
    func testOldFilesGo() {
        let files = [SubSyncRule.Stored(id: "new", modifiedMs: now - day),
                     SubSyncRule.Stored(id: "edge", modifiedMs: now - 30 * day),
                     SubSyncRule.Stored(id: "old", modifiedMs: now - 31 * day),
                     SubSyncRule.Stored(id: "unknown", modifiedMs: 0)]
        XCTAssertEqual(Set(SubSyncRule.prune(files, nowMs: now)), ["old", "unknown"])
    }
    func testAtMost150AreKeptNewestFirst() {
        let files = (0..<160).map { SubSyncRule.Stored(id: "f\($0)", modifiedMs: now - Int64($0) * 60_000) }
        let gone = SubSyncRule.prune(files, nowMs: now)
        XCTAssertEqual(gone.count, 10)
        XCTAssertEqual(Set(gone), Set((150..<160).map { "f\($0)" }))
    }
    // 1.7.7: a subtitle uploaded long ago but used yesterday on the other device must not be deleted.
    func testRecentUseOnTheOtherDeviceKeepsTheFile() {
        let st = SubSyncRule.stamp(modifiedMs: now - 40 * day, usedMs: now - day)
        XCTAssertEqual(SubSyncRule.prune([SubSyncRule.Stored(id: "a", modifiedMs: st)], nowMs: now), [])
        XCTAssertEqual(SubSyncRule.stamp(modifiedMs: now - 40 * day, usedMs: nil), now - 40 * day)
        XCTAssertFalse(SubSyncRule.needsTouch(usedMs: now - 3_600_000, modifiedMs: now - 40 * day, nowMs: now))
        XCTAssertTrue(SubSyncRule.needsTouch(usedMs: now - 2 * day, modifiedMs: now - 40 * day, nowMs: now))
        XCTAssertFalse(SubSyncRule.needsTouch(usedMs: nil, modifiedMs: now - 3_600_000, nowMs: now))
    }
    func testClipKeepsWholeCharacters() {
        let s = String(repeating: "ترجمة ", count: 30)
        let c = SubSyncRule.clip(s)
        XCTAssertLessThanOrEqual(c.utf8.count, 90)
        XCTAssertTrue(s.hasPrefix(c))
    }
}

/// 1.7.6: imported / downloaded subtitle files are checked by content before use.
final class SubFileCheckTests: XCTestCase {
    let srt = "1\n00:00:01,000 --> 00:00:02,500\nمرحبا بك\n\n2\n00:00:03,000 --> 00:00:04,000\nكيف حالك\n"
    let ass = "[Script Info]\nTitle: t\n\n[V4+ Styles]\nStyle: Default,Arial,20\n\n[Events]\nFormat: Layer, Start, End, Style, Text\nDialogue: 0,0:00:01.00,0:00:02.00,Default,{\\b1}Hello{\\b0}\n"

    func testSrtUtf8() {
        guard case .success(let c) = SubFileCheck.check(Data(srt.utf8)) else { return XCTFail() }
        XCTAssertEqual(c.format, .srt); XCTAssertEqual(c.lang, "ar"); XCTAssertEqual(c.text, srt)
    }
    func testSrtWithBomAndCrLf() {
        let d = Data([0xEF, 0xBB, 0xBF]) + Data(srt.replacingOccurrences(of: "\n", with: "\r\n").utf8)
        guard case .success(let c) = SubFileCheck.check(d) else { return XCTFail() }
        XCTAssertEqual(c.format, .srt); XCTAssertFalse(c.text.hasPrefix("\u{FEFF}"))
    }
    func testOldArabicEncodingIsDecoded() {
        let enc = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.windowsArabic.rawValue)))
        guard let d = srt.data(using: enc) else { return XCTFail("no cp1256") }
        XCTAssertNil(String(data: d, encoding: .utf8))
        guard case .success(let c) = SubFileCheck.check(d) else { return XCTFail() }
        XCTAssertTrue(c.text.contains("مرحبا بك")); XCTAssertEqual(c.lang, "ar")
    }
    func testAssKeepsStylesAndTags() {
        guard case .success(let c) = SubFileCheck.check(Data(ass.utf8)) else { return XCTFail() }
        XCTAssertEqual(c.format, .ass); XCTAssertEqual(c.text, ass); XCTAssertTrue(c.text.contains("{\\b1}"))
    }
    func testRefusals() {
        XCTAssertEqual(SubFileCheck.check(Data()), .failure(.empty))
        XCTAssertEqual(SubFileCheck.check(Data("just some notes".utf8)), .failure(.notSubtitle))
        XCTAssertEqual(SubFileCheck.check(Data([0x50, 0x4B, 0x03, 0x04, 0, 0, 0x14, 0])), .failure(.binary))
        XCTAssertEqual(SubFileCheck.check(Data(("WEBVTT\n\n00:00:01.000 --> 00:00:02.000\nhi\n").utf8)), .failure(.unsupported("WebVTT")))
        let big = Data(repeating: 0x41, count: SubFileCheck.maxSRTBytes + 10) + Data("\n00:00:01,000 --> 00:00:02,000\nx\n".utf8)
        XCTAssertEqual(SubFileCheck.check(big), .failure(.tooBig(bytes: big.count, limit: SubFileCheck.maxSRTBytes)))
    }
}

