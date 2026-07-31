import XCTest
@testable import UsageCore

/// 실시간 조회를 흉내 내는 스텁. 네트워크를 타지 않는다.
private struct StubFetcher: LiveUsageFetching {
    let result: LiveUsageResult?
    let error: LiveUsageError?

    init(result: LiveUsageResult? = nil, error: LiveUsageError? = nil) {
        self.result = result
        self.error = error
    }

    func fetch(now: Date) throws -> LiveUsageResult {
        if let error { throw error }
        guard let result else { throw LiveUsageError.decode("결과 없음") }
        // 호출 시각을 반영해 캐시가 신선도를 판단할 수 있게 한다.
        return LiveUsageResult(windows: result.windows, planLabel: result.planLabel, fetchedAt: now)
    }
}

/// 호출 횟수를 세는 스텁. 조회 간격 제한을 검증한다.
private final class CountingFetcher: LiveUsageFetching, @unchecked Sendable {
    private(set) var callCount = 0

    func fetch(now: Date) throws -> LiveUsageResult {
        callCount += 1
        return LiveUsageResult(
            windows: [LiveLimitWindow(label: "주간", percent: 42, resetsAt: nil)],
            planLabel: "Plus",
            fetchedAt: now
        )
    }
}

final class LiveUsageTests: XCTestCase {

    private let base = Date(timeIntervalSince1970: 1_800_000_000)

    // MARK: - Claude 응답 파싱

    func testParsesClaudeUsageResponse() throws {
        // 실제 엔드포인트 응답 형태 (6자리 소수 + "+00:00" 오프셋).
        let payload: [String: Any] = [
            "five_hour": ["utilization": 11.0, "resets_at": "2026-07-31T08:20:00.549133+00:00"],
            "seven_day": ["utilization": 91.0, "resets_at": "2026-08-01T00:00:00.549156+00:00"],
        ]

        let fiveHour = try XCTUnwrap(ClaudeLiveClient.window(from: payload["five_hour"], label: "5시간"))
        XCTAssertEqual(fiveHour.percent, 11.0)
        XCTAssertEqual(fiveHour.label, "5시간")
        XCTAssertNotNil(fiveHour.resetsAt, "타임존 오프셋이 붙은 타임스탬프를 파싱하지 못했다")

        let sevenDay = try XCTUnwrap(ClaudeLiveClient.window(from: payload["seven_day"], label: "주간"))
        XCTAssertEqual(sevenDay.percent, 91.0)
    }

    func testClaudeWindowIsNilWhenUtilizationMissing() {
        XCTAssertNil(ClaudeLiveClient.window(from: ["resets_at": "2026-07-31T08:20:00Z"], label: "5시간"))
        XCTAssertNil(ClaudeLiveClient.window(from: NSNull(), label: "5시간"))
        XCTAssertNil(ClaudeLiveClient.window(from: nil, label: "5시간"))
    }

    // MARK: - Codex 응답 파싱

    func testParsesCodexUsageResponse() throws {
        let window: [String: Any] = [
            "used_percent": 38,
            "limit_window_seconds": 604_800,
            "reset_after_seconds": 434_228,
            "reset_at": 1_785_906_013,
        ]
        let parsed = try XCTUnwrap(CodexLiveClient.window(from: window))
        XCTAssertEqual(parsed.percent, 38)
        XCTAssertEqual(parsed.label, "주간")
        XCTAssertEqual(parsed.resetsAt, Date(timeIntervalSince1970: 1_785_906_013))
    }

    func testCodexWindowLabels() {
        XCTAssertEqual(CodexLiveClient.label(forWindowSeconds: 604_800), "주간")
        XCTAssertEqual(CodexLiveClient.label(forWindowSeconds: 86_400), "일간")
        XCTAssertEqual(CodexLiveClient.label(forWindowSeconds: 18_000), "5시간")
        XCTAssertEqual(CodexLiveClient.label(forWindowSeconds: 10_800), "3시간")
    }

    func testCodexWindowHandlesNullSecondary() {
        XCTAssertNil(CodexLiveClient.window(from: NSNull()))
        XCTAssertNil(CodexLiveClient.window(from: ["limit_window_seconds": 604_800]))
    }

    // MARK: - 캐시

    func testCacheRespectsInterval() {
        let fetcher = CountingFetcher()
        let cache = LiveUsageCache(fetcher: fetcher, interval: 300)

        cache.refreshBlocking(now: base)
        XCTAssertEqual(fetcher.callCount, 1)

        // 간격 안에서는 다시 호출하지 않는다.
        cache.refreshBlocking(now: base.addingTimeInterval(60))
        cache.refreshBlocking(now: base.addingTimeInterval(299))
        XCTAssertEqual(fetcher.callCount, 1)

        cache.refreshBlocking(now: base.addingTimeInterval(300))
        XCTAssertEqual(fetcher.callCount, 2)

        // force는 간격을 무시한다.
        cache.refreshBlocking(now: base.addingTimeInterval(301), force: true)
        XCTAssertEqual(fetcher.callCount, 3)
    }

    /// 비동기 경로: 조회를 던져두고 즉시 반환하며, 끝나면 onUpdate로 알린다.
    func testAsyncRefreshNotifiesOnCompletion() {
        let fetcher = CountingFetcher()
        let cache = LiveUsageCache(fetcher: fetcher, interval: 300)
        let updated = expectation(description: "실시간 결과 도착")
        cache.onUpdate = { updated.fulfill() }

        cache.refreshIfNeeded(now: base)
        wait(for: [updated], timeout: 2)
        XCTAssertEqual(fetcher.callCount, 1)
        XCTAssertEqual(cache.result?.windows.first?.percent, 42)
    }

    func testCacheKeepsLastResultAfterFailure() {
        let good = LiveUsageResult(
            windows: [LiveLimitWindow(label: "주간", percent: 38, resetsAt: nil)],
            planLabel: "Plus",
            fetchedAt: base
        )
        let cache = LiveUsageCache(fetcher: StubFetcher(result: good), interval: 60)
        cache.refreshBlocking(now: base)
        XCTAssertEqual(cache.result?.windows.first?.percent, 38)

        // 실패해도 마지막 실측값은 지우지 않는다. 낡은 실측이 추정보다 낫다.
        let failing = LiveUsageCache(fetcher: StubFetcher(error: .tokenExpired), interval: 60)
        failing.refreshBlocking(now: base)
        XCTAssertNil(failing.result)
        XCTAssertEqual(failing.lastError, .tokenExpired)
    }

    func testGaugeSourceDegradesToSnapshotWhenStale() throws {
        let result = LiveUsageResult(
            windows: [LiveLimitWindow(label: "주간", percent: 38, resetsAt: nil)],
            planLabel: "Plus",
            fetchedAt: base
        )
        let cache = LiveUsageCache(fetcher: StubFetcher(result: result), interval: 60)
        cache.refreshBlocking(now: base)

        let fresh = try XCTUnwrap(cache.gauges(now: base.addingTimeInterval(60), freshWithin: 3600))
        guard case .live = fresh[0].source else {
            return XCTFail("신선한 값은 실시간으로 표시해야 한다")
        }

        let stale = try XCTUnwrap(cache.gauges(now: base.addingTimeInterval(7200), freshWithin: 3600))
        guard case .snapshot(let observedAt) = stale[0].source else {
            return XCTFail("오래된 값은 마지막 관측으로 표시해야 한다")
        }
        XCTAssertEqual(observedAt, base)
    }

    func testExpiredWindowIsZeroed() throws {
        let result = LiveUsageResult(
            windows: [LiveLimitWindow(label: "주간", percent: 38, resetsAt: base.addingTimeInterval(60))],
            planLabel: "Plus",
            fetchedAt: base
        )
        let cache = LiveUsageCache(fetcher: StubFetcher(result: result), interval: 60)
        cache.refreshBlocking(now: base)

        let before = try XCTUnwrap(cache.gauges(now: base.addingTimeInterval(30), freshWithin: 3600))
        XCTAssertEqual(before[0].percent, 38)

        // 리셋 시각이 지나면 한도가 초기화된 것으로 본다.
        let after = try XCTUnwrap(cache.gauges(now: base.addingTimeInterval(120), freshWithin: 3600))
        XCTAssertEqual(after[0].percent, 0)
        XCTAssertNil(after[0].resetsAt)
    }

    func testGaugesAreNilWithoutResult() {
        let cache = LiveUsageCache(fetcher: StubFetcher(error: .tokenExpired), interval: 60)
        cache.refreshBlocking(now: base)
        XCTAssertNil(cache.gauges(now: base, freshWithin: 3600))
    }

    // MARK: - 프로바이더 폴백

    func testProviderFallsBackToEstimateWhenLiveFails() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LiveFallback-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let timestamp = "2026-07-29T12:00:00.000Z"
        let object: [String: Any] = [
            "requestId": "req_1",
            "timestamp": timestamp,
            "message": [
                "id": "msg_1",
                "model": "claude-opus-5",
                "usage": ["input_tokens": 1000, "output_tokens": 1000],
            ],
        ]
        let line = String(data: try JSONSerialization.data(withJSONObject: object), encoding: .utf8)!
        try (line + "\n").write(
            to: directory.appendingPathComponent("session.jsonl"),
            atomically: true,
            encoding: .utf8
        )

        let provider = ClaudeCodeProvider(
            root: directory,
            config: AppConfig(),
            liveFetcher: StubFetcher(error: .tokenExpired)
        )
        provider.resetCache()

        let now = ISO8601.parse(timestamp)!.addingTimeInterval(60)
        provider.primeLiveUsage(now: now)
        let snapshot = try provider.snapshot(now: now)

        XCTAssertEqual(snapshot.status, .ok)
        XCTAssertTrue(snapshot.gauges.allSatisfy(\.isEstimate), "실시간 실패 시 추정치로 물러나야 한다")
        XCTAssertEqual(provider.liveError, .tokenExpired)
    }

    func testProviderPrefersLiveOverEstimate() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LivePreferred-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let timestamp = "2026-07-29T12:00:00.000Z"
        let object: [String: Any] = [
            "requestId": "req_1",
            "timestamp": timestamp,
            "message": [
                "id": "msg_1",
                "model": "claude-opus-5",
                "usage": ["input_tokens": 1000, "output_tokens": 1000],
            ],
        ]
        let line = String(data: try JSONSerialization.data(withJSONObject: object), encoding: .utf8)!
        try (line + "\n").write(
            to: directory.appendingPathComponent("session.jsonl"),
            atomically: true,
            encoding: .utf8
        )

        let live = LiveUsageResult(
            windows: [
                LiveLimitWindow(label: "5시간", percent: 11, resetsAt: nil),
                LiveLimitWindow(label: "주간", percent: 91, resetsAt: nil),
            ],
            planLabel: "Max 5x",
            fetchedAt: base
        )
        let provider = ClaudeCodeProvider(
            root: directory,
            config: AppConfig(),
            liveFetcher: StubFetcher(result: live)
        )
        provider.resetCache()

        let now = ISO8601.parse(timestamp)!.addingTimeInterval(60)
        provider.primeLiveUsage(now: now)
        let snapshot = try provider.snapshot(now: now)

        XCTAssertEqual(snapshot.gauges.count, 2)
        XCTAssertEqual(snapshot.gauges[0].percent, 11)
        XCTAssertEqual(snapshot.gauges[1].percent, 91)
        XCTAssertFalse(snapshot.gauges[0].isEstimate)
        XCTAssertEqual(snapshot.planLabel, "Max 5x")
        // 실시간이어도 토큰 집계는 로컬 로그에서 계속 나온다.
        XCTAssertEqual(snapshot.tokensToday?.total, 2000)
    }

    func testProviderSkipsLiveWhenDisabled() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LiveDisabled-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let timestamp = "2026-07-29T12:00:00.000Z"
        let object: [String: Any] = [
            "requestId": "req_1",
            "timestamp": timestamp,
            "message": [
                "id": "msg_1",
                "model": "claude-opus-5",
                "usage": ["input_tokens": 1000, "output_tokens": 1000],
            ],
        ]
        let line = String(data: try JSONSerialization.data(withJSONObject: object), encoding: .utf8)!
        try (line + "\n").write(
            to: directory.appendingPathComponent("session.jsonl"),
            atomically: true,
            encoding: .utf8
        )

        let fetcher = CountingFetcher()
        let provider = ClaudeCodeProvider(
            root: directory,
            config: AppConfig(useLiveAPI: false),
            liveFetcher: fetcher
        )
        provider.resetCache()
        _ = try provider.snapshot(now: ISO8601.parse(timestamp)!.addingTimeInterval(60))

        XCTAssertEqual(fetcher.callCount, 0, "설정에서 껐으면 네트워크를 타면 안 된다")
    }

    // MARK: - 자격증명 파싱

    func testClaudePlanLabelFromRateLimitTier() {
        let credentials = Credentials.Claude(
            accessToken: "x",
            expiresAt: nil,
            subscriptionType: "max",
            rateLimitTier: "default_claude_max_5x"
        )
        XCTAssertEqual(credentials.planLabel, "Max 5x")
    }

    func testClaudePlanLabelFallsBackToSubscriptionType() {
        let credentials = Credentials.Claude(
            accessToken: "x",
            expiresAt: nil,
            subscriptionType: "pro",
            rateLimitTier: nil
        )
        XCTAssertEqual(credentials.planLabel, "Pro")
    }

    func testExpiryCheck() {
        let expired = Credentials.Claude(
            accessToken: "x",
            expiresAt: Date().addingTimeInterval(-60),
            subscriptionType: nil,
            rateLimitTier: nil
        )
        let valid = Credentials.Claude(
            accessToken: "x",
            expiresAt: Date().addingTimeInterval(3600),
            subscriptionType: nil,
            rateLimitTier: nil
        )
        XCTAssertTrue(expired.isExpired)
        XCTAssertFalse(valid.isExpired)
    }

    func testCodexCredentialsMissingFileThrows() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("no-such-auth-\(UUID().uuidString).json")
        XCTAssertThrowsError(try Credentials.codex(at: missing))
    }
}
