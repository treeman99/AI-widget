import XCTest
@testable import UsageCore

/// 정해 둔 순서대로 결과를 내는 스텁. 마지막 항목은 계속 반복한다. 네트워크·키체인을 타지 않는다.
private final class ScriptedFetcher: LiveUsageFetching, @unchecked Sendable {
    private let lock = NSLock()
    private var script: [Result<LiveUsageResult, LiveUsageError>]
    private var calls = 0

    init(_ script: [Result<LiveUsageResult, LiveUsageError>]) {
        precondition(!script.isEmpty)
        self.script = script
    }

    var callCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return calls
    }

    func fetch(now: Date) throws -> LiveUsageResult {
        lock.lock()
        defer { lock.unlock() }
        calls += 1
        let next = script.count > 1 ? script.removeFirst() : script[0]
        switch next {
        case .success(let result):
            // 호출 시각을 반영해 신선도 판단을 검증할 수 있게 한다.
            return LiveUsageResult(
                windows: result.windows,
                planLabel: result.planLabel,
                details: result.details,
                fetchedAt: now
            )
        case .failure(let error):
            throw error
        }
    }
}

final class GeminiTests: XCTestCase {

    /// 초 단위까지만 있는 UTC 시각. 검증 대상인 `ISO8601.parse`에 기대지 않으려고 포매터를 쓴다.
    private static func utc(_ text: String) -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)!
    }

    /// fixture를 받은 시각 무렵. 모든 리셋 시각보다 앞이다.
    private let base = GeminiTests.utc("2026-10-09T08:52:00Z")

    // MARK: - 자격증명 파싱

    /// agy가 저장하는 JSON과 같은 모양. refresh_token과 id_token도 함께 들어 있다.
    private static let tokenJSON = """
    {"token":{"access_token":"ya29.test-access","token_type":"Bearer","refresh_token":"1//test-refresh",\
    "expiry":"2026-10-09T18:40:00.185665+09:00"},"auth_method":"consumer","id_token":"eyJ.test"}
    """

    private static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    /// 2026-10-09T09:40:00.185665Z
    private static let expectedExpiry = utc("2026-10-09T09:40:00Z").addingTimeInterval(0.185665)

    private func assertParsed(_ credentials: Credentials.Gemini?, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(credentials?.accessToken, "ya29.test-access", file: file, line: line)
        guard let expiresAt = credentials?.expiresAt else {
            return XCTFail("만료 시각을 읽지 못했다", file: file, line: line)
        }
        XCTAssertEqual(
            expiresAt.timeIntervalSince1970,
            Self.expectedExpiry.timeIntervalSince1970,
            accuracy: 0.000_001,
            file: file,
            line: line
        )
    }

    /// 현행 go-keyring의 저장 형태. `security … -w`는 끝에 개행 하나를 붙인다.
    func testParseGeminiReadsBase64Payload() {
        let value = "go-keyring-base64:" + Data(Self.tokenJSON.utf8).base64EncodedString() + "\n"
        assertParsed(Credentials.parseGemini(Data(value.utf8)))
    }

    /// 구버전 go-keyring은 hex로 감쌌다.
    func testParseGeminiReadsLegacyHexPayload() {
        let value = "go-keyring-encoded:" + Self.hex(Data(Self.tokenJSON.utf8)) + "\n"
        assertParsed(Credentials.parseGemini(Data(value.utf8)))
    }

    func testParseGeminiReadsUnprefixedJSON() {
        assertParsed(Credentials.parseGemini(Data((Self.tokenJSON + "\n").utf8)))
    }

    /// 값에 비인쇄 바이트가 섞이면 `security`가 값 전체를 소문자 hex로 낸다.
    /// 접두사 없는 원문(한글 포함)과 감싼 값 양쪽에서 같은 결과가 나와야 한다.
    func testParseGeminiDecodesSecurityHexOutput() {
        let korean = Self.tokenJSON.replacingOccurrences(of: "\"consumer\"", with: "\"개인\"")
        let plainHex = Self.hex(Data(korean.utf8)) + "\n"
        assertParsed(Credentials.parseGemini(Data(plainHex.utf8)))

        let wrapped = "go-keyring-base64:" + Data(Self.tokenJSON.utf8).base64EncodedString()
        let wrappedHex = Self.hex(Data(wrapped.utf8)) + "\n"
        assertParsed(Credentials.parseGemini(Data(wrappedHex.utf8)))
    }

    /// go-keyring의 Get처럼 앞뒤 공백을 걷어낸다.
    func testParseGeminiTrimsSurroundingWhitespace() {
        let value = "  go-keyring-base64:" + Data(Self.tokenJSON.utf8).base64EncodedString() + "\r\n\n"
        assertParsed(Credentials.parseGemini(Data(value.utf8)))
    }

    /// 항목은 있는데 값이 비었거나 모양이 다르면 exit 0이라 성공처럼 보인다. 여기서 걸러야 한다.
    func testParseGeminiRejectsEmptyGarbageAndMissingToken() {
        let rejected = [
            "",
            "\n",
            "garbage",
            "deadbeef\n",                       // hex로도 읽히는 평문
            "go-keyring-base64:@@not-base64@@",
            "go-keyring-encoded:zz",
            "{}",
            #"{"access_token":"top-level-is-not-the-shape"}"#,
            #"{"token":{}}"#,
            #"{"token":{"access_token":""}}"#,
            #"{"token":{"refresh_token":"1//only-refresh"}}"#,
        ]
        for text in rejected {
            XCTAssertNil(Credentials.parseGemini(Data(text.utf8)), text)
        }
    }

    /// Go의 zero time은 oauth2에서 "만료 없음"이다. 이미 만료된 것으로 읽으면 안 된다.
    func testParseGeminiTreatsGoZeroTimeAsUnknownExpiry() throws {
        let json = #"{"token":{"access_token":"t","expiry":"0001-01-01T00:00:00Z"}}"#
        let credentials = try XCTUnwrap(Credentials.parseGemini(Data(json.utf8)))
        XCTAssertNil(credentials.expiresAt)
        XCTAssertFalse(credentials.isExpired(at: base))
    }

    func testGeminiExpiryCheck() {
        let credentials = Credentials.Gemini(accessToken: "t", expiresAt: base)
        XCTAssertFalse(credentials.isExpired(at: base.addingTimeInterval(-1)))
        XCTAssertTrue(credentials.isExpired(at: base))
        XCTAssertTrue(credentials.isExpired(at: base.addingTimeInterval(3600)))
    }

    // MARK: - 타임스탬프 (오프셋)

    func testISO8601ParsesOffsetWithMicroseconds() throws {
        let parsed = try XCTUnwrap(ISO8601.parse("2026-10-09T18:40:00.185665+09:00"))
        XCTAssertEqual(parsed.timeIntervalSince1970, Self.expectedExpiry.timeIntervalSince1970, accuracy: 0.000_001)
    }

    func testISO8601ParsesNegativeAndZeroOffsets() throws {
        let expected = Self.utc("2026-10-09T09:40:00Z")
        XCTAssertEqual(ISO8601.parse("2026-10-09T04:10:00-05:30"), expected)
        XCTAssertEqual(ISO8601.parse("2026-10-09T09:40:00+00:00"), expected)
        let claude = try XCTUnwrap(ISO8601.parse("2026-07-31T08:20:00.549133+00:00"))
        XCTAssertEqual(
            claude.timeIntervalSince1970,
            Self.utc("2026-07-31T08:20:00Z").timeIntervalSince1970 + 0.549133,
            accuracy: 0.000_001
        )
    }

    // MARK: - 한도 요약 응답

    /// `retrieveUserQuotaSummary` 실제 응답 사본.
    private static let fixture = """
    {
      "groups": [
        {
          "buckets": [
            {"bucketId": "gemini-weekly", "displayName": "Weekly Limit Remaining", "window": "weekly",
             "resetTime": "2026-10-16T08:41:03Z",
             "description": "You have used some of your weekly limit, it will fully refresh in 6 days, 23 hours.",
             "remainingFraction": 0.991495},
            {"bucketId": "gemini-5h", "displayName": "Five Hour Limit Remaining", "window": "5h",
             "resetTime": "2026-10-09T13:41:03Z",
             "description": "You have used some of your 5-hour limit, it will fully refresh in 4 hours, 49 minutes.",
             "remainingFraction": 0.9899}
          ],
          "displayName": "Gemini Models",
          "description": "Models within this group: Gemini Flash, Gemini Pro"
        },
        {
          "buckets": [
            {"bucketId": "3p-weekly", "displayName": "Weekly Limit Remaining", "window": "weekly",
             "resetTime": "2026-10-16T08:51:10Z", "remainingFraction": 1},
            {"bucketId": "3p-5h", "displayName": "Five Hour Limit Remaining", "window": "5h",
             "resetTime": "2026-10-09T13:51:10Z", "remainingFraction": 1}
          ],
          "displayName": "Claude and GPT models",
          "description": "Models within this group: Claude Opus, Claude Sonnet, GPT-OSS"
        }
      ],
      "description": "Within each group, models share a weekly limit and a 5-hour limit. Quota is consumed proportionally to the cost of the tokens."
    }
    """

    private static func object(_ json: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
    }

    private static func summary(buckets: [[String: Any]], group: String = "Gemini Models") -> [String: Any] {
        let entry: [String: Any] = ["displayName": group, "buckets": buckets]
        return ["groups": [entry]]
    }

    func testWindowsFromFixture() throws {
        let windows = GeminiLiveClient.windows(fromSummary: try Self.object(Self.fixture))

        // 첫 창이 메뉴바 대표값이다. 응답은 주간을 먼저 주지만 Gemini 5시간이 맨 앞이어야 한다.
        XCTAssertEqual(windows.map(\.label), ["5시간 (Gemini)", "주간 (Gemini)", "5시간 (Claude·GPT)", "주간 (Claude·GPT)"])
        XCTAssertEqual(windows[0].percent, 1.01, accuracy: 0.000_001)
        XCTAssertEqual(windows[1].percent, 0.8505, accuracy: 0.000_001)
        XCTAssertEqual(windows[2].percent, 0)
        XCTAssertEqual(windows[3].percent, 0)

        XCTAssertEqual(windows[0].resetsAt, Self.utc("2026-10-09T13:41:03Z"))
        XCTAssertEqual(windows[1].resetsAt, Self.utc("2026-10-16T08:41:03Z"))
        // 안 쓴 버킷의 resetTime은 조회할 때마다 미끄러지는 값이라 버린다.
        XCTAssertNil(windows[2].resetsAt)
        XCTAssertNil(windows[3].resetsAt)
    }

    /// proto3 JSON은 0인 필드를 생략한다. 한도를 다 쓴 버킷에는 remainingFraction이 없다.
    func testMissingRemainingFractionMeansFullyUsed() throws {
        let summary = Self.summary(buckets: [
            ["bucketId": "gemini-5h", "window": "5h", "resetTime": "2026-10-09T13:41:03Z"],
        ])
        let window = try XCTUnwrap(GeminiLiveClient.windows(fromSummary: summary).first)
        XCTAssertEqual(window.percent, 100)
        XCTAssertEqual(window.resetsAt, Self.utc("2026-10-09T13:41:03Z"), "다 쓴 버킷의 리셋 시각은 진짜다")
    }

    func testRemainingFractionIsClamped() throws {
        let summary = Self.summary(buckets: [
            ["bucketId": "a", "window": "5h", "resetTime": "2026-10-09T13:41:03Z", "remainingFraction": -0.1],
            ["bucketId": "b", "window": "weekly", "resetTime": "2026-10-16T08:41:03Z", "remainingFraction": 1.2],
        ])
        let windows = GeminiLiveClient.windows(fromSummary: summary)
        XCTAssertEqual(windows.map(\.percent), [100, 0])
        XCTAssertNotNil(windows[0].resetsAt)
        XCTAssertNil(windows[1].resetsAt, "1을 넘는 값은 1로 잘리고, 안 쓴 버킷으로 취급한다")
    }

    func testEmptySummaryIsDecodeError() {
        let summaries: [[String: Any]] = [[:], ["groups": [Any]()], Self.summary(buckets: [])]
        for summary in summaries {
            XCTAssertThrowsError(try GeminiLiveClient.nonEmptyWindows(fromSummary: summary)) { error in
                guard case LiveUsageError.decode = error else {
                    return XCTFail("해석 실패여야 한다: \(error)")
                }
            }
        }
    }

    func testWindowOrderAndLabelsWithinGroup() {
        let summary = Self.summary(
            buckets: [
                ["bucketId": "w", "window": "weekly", "remainingFraction": 0.5],
                ["bucketId": "m", "displayName": "Monthly Limit", "window": "monthly", "remainingFraction": 0.5],
                ["bucketId": "d", "window": "daily", "remainingFraction": 0.5],
                ["bucketId": "h", "window": "5h", "remainingFraction": 0.5],
            ],
            group: "Open Models"
        )
        let labels = GeminiLiveClient.windows(fromSummary: summary).map(\.label)
        XCTAssertEqual(labels, ["5시간 (Open)", "일간 (Open)", "주간 (Open)", "Monthly Limit (Open)"])
    }

    /// 식별 필드가 없는 항목은 버킷이 아니다. remainingFraction 누락 규칙이 여기까지 번지면 안 된다.
    func testEntriesWithoutBucketIdentityAreSkipped() {
        let summary = Self.summary(buckets: [["remainingFraction": 0.5], ["description": "x"]])
        XCTAssertTrue(GeminiLiveClient.windows(fromSummary: summary).isEmpty)
    }

    func testGroupLabels() {
        XCTAssertEqual(GeminiLiveClient.groupLabel("Gemini Models"), "Gemini")
        XCTAssertEqual(GeminiLiveClient.groupLabel("Claude and GPT models"), "Claude·GPT")
        XCTAssertEqual(GeminiLiveClient.groupLabel("Open models"), "Open")
        XCTAssertEqual(GeminiLiveClient.groupLabel("Experimental"), "Experimental")
        XCTAssertNil(GeminiLiveClient.groupLabel(nil))
        XCTAssertNil(GeminiLiveClient.groupLabel(" "))
    }

    func testPlanLabelFromLoadCodeAssist() {
        XCTAssertEqual(
            GeminiLiveClient.planLabel(fromLoadCodeAssist: [
                "currentTier": ["id": "standard-tier", "name": "Gemini Code Assist"],
                "paidTier": ["id": "g1-pro-tier", "name": "Google AI Pro"],
            ]),
            "Google AI Pro"
        )
        XCTAssertEqual(
            GeminiLiveClient.planLabel(fromLoadCodeAssist: ["currentTier": ["name": "Free"]]),
            "Free"
        )
        XCTAssertNil(GeminiLiveClient.planLabel(fromLoadCodeAssist: ["paidTier": ["name": ""]]))
        XCTAssertNil(GeminiLiveClient.planLabel(fromLoadCodeAssist: [:]))
    }

    /// 한도 조회는 빈 JSON 객체를 POST한다. User-Agent는 건드리지 않는다.
    func testPostRequestShape() throws {
        let request = try HTTP.jsonPostRequest(
            GeminiLiveClient.quotaEndpoint,
            body: [:],
            headers: ["Authorization": "Bearer x"]
        )
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.httpBody, Data("{}".utf8))
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer x")
        XCTAssertNil(request.value(forHTTPHeaderField: "User-Agent"))
    }

    /// 서버는 User-Agent에 `antigravity`가 없으면 유효한 토큰에도 403을 준다.
    /// 그 조건을 맞추되 앱 이름은 그대로 밝힌다.
    func testGeminiHeadersIdentifyAppAndProduct() {
        let headers = GeminiLiveClient.headers(accessToken: "x")
        XCTAssertEqual(headers["Authorization"], "Bearer x")
        let userAgent = headers["User-Agent"]
        XCTAssertTrue(userAgent?.hasPrefix("AIUsageBar") == true)
        XCTAssertNotNil(userAgent?.range(of: "antigravity", options: .caseInsensitive))
    }

    // MARK: - 설정 마이그레이션

    private static func decodeConfig(_ json: String) throws -> AppConfig {
        try JSONDecoder().decode(AppConfig.self, from: Data(json.utf8))
    }

    /// Gemini가 생기기 전의 설정 파일. 그대로 읽으면 Gemini가 영영 꺼진 채다.
    func testLegacyConfigTurnsGeminiOn() throws {
        let config = try Self.decodeConfig(#"{"enabledServices":["claude-code","codex"],"claudePlanLabel":"Max 20x"}"#)
        XCTAssertEqual(config.enabledServices, [.claudeCode, .codex, .gemini])
        XCTAssertEqual(config.knownServices, ServiceID.allCases)
        XCTAssertEqual(config.claudePlanLabel, "Max 20x")
    }

    func testLegacyConfigKeepsDisabledServiceOff() throws {
        let config = try Self.decodeConfig(#"{"enabledServices":["claude-code"]}"#)
        XCTAssertEqual(config.enabledServices, [.claudeCode, .gemini], "사용자가 끈 Codex는 그대로 꺼져 있어야 한다")
    }

    func testGeminiStaysOffOnceUserDisabledIt() throws {
        let config = try Self.decodeConfig(
            #"{"enabledServices":["claude-code","codex"],"knownServices":["claude-code","codex","gemini"]}"#
        )
        XCTAssertEqual(config.enabledServices, [.claudeCode, .codex])
    }

    func testKnownServicesSurviveRoundTrip() throws {
        var config = AppConfig()
        XCTAssertEqual(config.knownServices, ServiceID.allCases)
        config.enabledServices = [.claudeCode, .codex]

        let decoded = try JSONDecoder().decode(AppConfig.self, from: JSONEncoder().encode(config))
        XCTAssertEqual(decoded.enabledServices, [.claudeCode, .codex])
        XCTAssertEqual(decoded, config)
    }

    /// 모르는 서비스 이름 하나 때문에 설정 전체(기준선 포함)를 잃으면 안 된다.
    func testUnknownServiceNamesAreIgnored() throws {
        let config = try Self.decodeConfig("""
        {"enabledServices":["claude-code","future-service"],
         "knownServices":["claude-code","codex","gemini","future-service"],
         "baselines":{"fiveHour":123,"weekly":456,"autoCalibrate":false}}
        """)
        XCTAssertEqual(config.enabledServices, [.claudeCode])
        XCTAssertEqual(config.baselines, Baselines(fiveHour: 123, weekly: 456, autoCalibrate: false))
    }

    // MARK: - 캐시 시드

    func testSeedFillsOnlyEmptyCacheAndDoesNotDelayFirstFetch() throws {
        let fresh = LiveUsageResult(
            windows: [LiveLimitWindow(label: "5시간 (Gemini)", percent: 30, resetsAt: nil)],
            planLabel: nil,
            fetchedAt: base
        )
        let fetcher = ScriptedFetcher([.success(fresh)])
        let cache = LiveUsageCache(fetcher: fetcher, interval: 300)

        let old = LiveUsageResult(
            windows: [LiveLimitWindow(label: "5시간 (Gemini)", percent: 10, resetsAt: nil)],
            planLabel: nil,
            fetchedAt: base.addingTimeInterval(-7200)
        )
        cache.seed(old)
        XCTAssertEqual(cache.result, old)

        // 시드는 시도로 치지 않는다. 간격을 기다리지 않고 첫 조회가 돈다.
        cache.refreshBlocking(now: base)
        XCTAssertEqual(fetcher.callCount, 1)
        XCTAssertEqual(cache.result?.windows.first?.percent, 30)

        // 이미 결과가 있으면 시드는 덮어쓰지 않는다.
        cache.seed(old)
        XCTAssertEqual(cache.result?.fetchedAt, base)
    }

    // MARK: - 제공자

    private func fixtureResult() throws -> LiveUsageResult {
        LiveUsageResult(
            windows: GeminiLiveClient.windows(fromSummary: try Self.object(Self.fixture)),
            planLabel: "Google AI Pro",
            fetchedAt: base
        )
    }

    private func temporaryStateURL() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("GeminiState-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory.appendingPathComponent("state-gemini.json")
    }

    func testFreshWindowIsTwiceIntervalWithFloor() {
        XCTAssertEqual(GeminiProvider.freshWindow(for: AppConfig(liveRefreshInterval: 60)), 600)
        XCTAssertEqual(GeminiProvider.freshWindow(for: AppConfig(liveRefreshInterval: 300)), 600)
        XCTAssertEqual(GeminiProvider.freshWindow(for: AppConfig(liveRefreshInterval: 900)), 1800)
    }

    func testProviderShowsFreshResultAsLive() throws {
        let provider = GeminiProvider(config: AppConfig(), liveFetcher: ScriptedFetcher([.success(try fixtureResult())]))
        provider.primeLiveUsage(now: base)
        let snapshot = try provider.snapshot(now: base.addingTimeInterval(60))

        XCTAssertEqual(snapshot.id, .gemini)
        XCTAssertEqual(snapshot.status, .ok)
        XCTAssertEqual(snapshot.planLabel, "Google AI Pro")
        XCTAssertEqual(snapshot.gauges.count, 4)
        XCTAssertEqual(snapshot.primaryGauge?.windowLabel, "5시간 (Gemini)")
        XCTAssertEqual(snapshot.primaryGauge?.source, .live(fetchedAt: base))
        XCTAssertNil(snapshot.observedAt)
        XCTAssertTrue(snapshot.details.isEmpty)
        XCTAssertNil(snapshot.tokensToday, "로컬 집계가 없으므로 토큰 수를 지어내지 않는다")
    }

    /// 토큰이 죽어 조회가 실패하면, 신선도 창이 지난 값은 '마지막 관측'으로 내려가고 이유가 한 줄 붙는다.
    func testProviderDegradesToSnapshotAfterFreshWindow() throws {
        let fetcher = ScriptedFetcher([.success(try fixtureResult()), .failure(.tokenExpired)])
        let provider = GeminiProvider(config: AppConfig(liveRefreshInterval: 300), liveFetcher: fetcher)
        provider.primeLiveUsage(now: base)

        let later = base.addingTimeInterval(601)
        provider.primeLiveUsage(now: later)
        let snapshot = try provider.snapshot(now: later)

        XCTAssertEqual(fetcher.callCount, 2)
        XCTAssertEqual(snapshot.status, .ok)
        XCTAssertEqual(snapshot.primaryGauge?.source, .snapshot(observedAt: base))
        XCTAssertEqual(snapshot.primaryGauge?.source.badge, "마지막 관측")
        XCTAssertEqual(snapshot.observedAt, base)
        XCTAssertEqual(snapshot.details, [UsageDetail(label: "실시간 조회", value: "토큰 만료 · agy 실행 시 재개")])
    }

    func testProviderShowsOtherErrorsVerbatim() throws {
        let fetcher = ScriptedFetcher([.success(try fixtureResult()), .failure(.httpStatus(500))])
        let provider = GeminiProvider(config: AppConfig(), liveFetcher: fetcher)
        provider.primeLiveUsage(now: base)
        provider.primeLiveUsage(now: base.addingTimeInterval(30))
        let snapshot = try provider.snapshot(now: base.addingTimeInterval(30))

        // 아직 신선도 창 안이라 실시간으로 그리지만, 방금 실패했다는 사실은 숨기지 않는다.
        XCTAssertEqual(snapshot.primaryGauge?.source, .live(fetchedAt: base))
        XCTAssertEqual(snapshot.details, [UsageDetail(label: "실시간 조회", value: "서버 응답 500")])
    }

    func testProviderPersistsAndRestoresLastObservation() throws {
        let stateURL = try temporaryStateURL()

        let first = GeminiProvider(
            config: AppConfig(),
            stateURL: stateURL,
            liveFetcher: ScriptedFetcher([.success(try fixtureResult())])
        )
        first.primeLiveUsage(now: base)
        XCTAssertTrue(FileManager.default.fileExists(atPath: stateURL.path))

        // 토큰이 죽은 채 앱이 다시 떴다.
        let later = base.addingTimeInterval(3600)
        let fetcher = ScriptedFetcher([.failure(.tokenExpired)])
        let restarted = GeminiProvider(config: AppConfig(), stateURL: stateURL, liveFetcher: fetcher)
        XCTAssertEqual(restarted.lastObservedAt, base)

        restarted.primeLiveUsage(now: later)
        let snapshot = try restarted.snapshot(now: later)

        XCTAssertEqual(fetcher.callCount, 1)
        XCTAssertEqual(snapshot.status, .ok)
        XCTAssertEqual(snapshot.planLabel, "Google AI Pro")
        XCTAssertEqual(snapshot.gauges.map(\.windowLabel), ["5시간 (Gemini)", "주간 (Gemini)", "5시간 (Claude·GPT)", "주간 (Claude·GPT)"])
        XCTAssertEqual(snapshot.gauges[0].percent, 1.01, accuracy: 0.000_001)
        XCTAssertEqual(snapshot.gauges[0].resetsAt, Self.utc("2026-10-09T13:41:03Z"))
        XCTAssertEqual(snapshot.primaryGauge?.source, .snapshot(observedAt: base))
        XCTAssertEqual(snapshot.observedAt, base)
        XCTAssertEqual(snapshot.details, [UsageDetail(label: "실시간 조회", value: "토큰 만료 · agy 실행 시 재개")])

        // 같은 결과는 다시 쓰지 않는다. 지워 둔 파일이 되살아나지 않아야 한다.
        try FileManager.default.removeItem(at: stateURL)
        _ = try restarted.snapshot(now: later.addingTimeInterval(10))
        XCTAssertFalse(FileManager.default.fileExists(atPath: stateURL.path))
    }

    func testResetCacheForgetsLastObservation() throws {
        let stateURL = try temporaryStateURL()
        let fetcher = ScriptedFetcher([.success(try fixtureResult()), .failure(.tokenExpired)])
        let provider = GeminiProvider(config: AppConfig(), stateURL: stateURL, liveFetcher: fetcher)
        provider.primeLiveUsage(now: base)
        XCTAssertTrue(FileManager.default.fileExists(atPath: stateURL.path))

        provider.resetCache()
        XCTAssertFalse(FileManager.default.fileExists(atPath: stateURL.path))
        XCTAssertNil(provider.lastObservedAt)

        provider.primeLiveUsage(now: base.addingTimeInterval(10))
        let snapshot = try provider.snapshot(now: base.addingTimeInterval(10))
        XCTAssertEqual(snapshot.status, .noData("Antigravity 토큰이 만료됐습니다 — agy를 한 번 실행하면 다시 붙습니다"))
    }

    func testProviderWithoutAnyResultReportsFailure() throws {
        let provider = GeminiProvider(config: AppConfig(), liveFetcher: ScriptedFetcher([.failure(.tokenExpired)]))
        provider.primeLiveUsage(now: base)
        let snapshot = try provider.snapshot(now: base)

        XCTAssertEqual(snapshot.status, .noData("Antigravity 토큰이 만료됐습니다 — agy를 한 번 실행하면 다시 붙습니다"))
        XCTAssertTrue(snapshot.gauges.isEmpty)
        XCTAssertEqual(provider.liveError, .tokenExpired)
    }

    func testNoDataMessages() {
        XCTAssertEqual(GeminiProvider.noDataMessage(for: nil), "실시간 조회 대기 중")
        XCTAssertEqual(GeminiProvider.noDataMessage(for: .httpStatus(500)), "실시간 조회 실패 · 서버 응답 500")
    }

    func testProviderSkipsLiveWhenDisabled() throws {
        let fetcher = ScriptedFetcher([.success(try fixtureResult())])
        let provider = GeminiProvider(config: AppConfig(useLiveAPI: false), liveFetcher: fetcher)
        provider.primeLiveUsage(now: base)
        let snapshot = try provider.snapshot(now: base)

        XCTAssertEqual(fetcher.callCount, 0, "설정에서 껐으면 키체인도 네트워크도 타면 안 된다")
        XCTAssertEqual(snapshot.status, .noData("실시간 조회가 꺼져 있습니다 (Gemini는 로컬 추정이 없습니다)"))
    }
}
