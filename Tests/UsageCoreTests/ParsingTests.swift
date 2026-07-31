import XCTest
@testable import UsageCore

final class ParsingTests: XCTestCase {

    // MARK: - 타임스탬프

    func testFastISO8601MatchesFormatter() throws {
        let samples = [
            "2026-07-29T12:54:55.903Z",
            "2026-01-01T00:00:00.000Z",
            "2026-12-31T23:59:59.999Z",
            "2024-02-29T06:30:15.500Z",
        ]
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        for sample in samples {
            let expected = try XCTUnwrap(formatter.date(from: sample))
            let actual = try XCTUnwrap(ISO8601.parse(sample))
            XCTAssertEqual(actual.timeIntervalSince1970, expected.timeIntervalSince1970, accuracy: 0.001, sample)
        }
    }

    func testISO8601HandlesMissingFractionalSeconds() {
        let date = ISO8601.parse("2026-07-29T12:54:55Z")
        XCTAssertNotNil(date)
    }

    func testISO8601RejectsGarbage() {
        XCTAssertNil(ISO8601.parse(""))
        XCTAssertNil(ISO8601.parse("not-a-date"))
        XCTAssertNil(ISO8601.parse("2026-07-29"))
    }

    // MARK: - Claude Code 라인 파싱

    private func claudeLine(
        requestId: String? = "req_1",
        messageId: String? = "msg_1",
        model: String = "claude-opus-5",
        timestamp: String = "2026-07-29T12:54:55.903Z"
    ) -> Data {
        var message: [String: Any] = [
            "model": model,
            "usage": [
                "input_tokens": 10,
                "output_tokens": 20,
                "cache_read_input_tokens": 1000,
                "cache_creation_input_tokens": 300,
                "cache_creation": [
                    "ephemeral_5m_input_tokens": 200,
                    "ephemeral_1h_input_tokens": 100,
                ],
            ],
        ]
        if let messageId { message["id"] = messageId }
        var object: [String: Any] = ["type": "assistant", "message": message, "timestamp": timestamp]
        if let requestId { object["requestId"] = requestId }
        return try! JSONSerialization.data(withJSONObject: object)
    }

    func testParsesClaudeUsageLine() throws {
        let record = try XCTUnwrap(ClaudeCodeProvider.parseLine(claudeLine()))
        XCTAssertEqual(record.model, "claude-opus-5")
        XCTAssertEqual(record.input, 10)
        XCTAssertEqual(record.output, 20)
        XCTAssertEqual(record.cacheRead, 1000)
        XCTAssertEqual(record.cacheWrite5m, 200)
        XCTAssertEqual(record.cacheWrite1h, 100)
        XCTAssertEqual(record.dedupKey, "req_1|msg_1")
    }

    func testFallsBackToTotalWhenCacheBreakdownMissing() throws {
        let object: [String: Any] = [
            "message": [
                "id": "msg_1",
                "model": "claude-sonnet-5",
                "usage": ["input_tokens": 5, "output_tokens": 5, "cache_creation_input_tokens": 900],
            ],
            "timestamp": "2026-07-29T12:00:00.000Z",
        ]
        let data = try JSONSerialization.data(withJSONObject: object)
        let record = try XCTUnwrap(ClaudeCodeProvider.parseLine(data))
        // 세부 내역이 없으면 전체를 5분 TTL 쓰기로 간주한다.
        XCTAssertEqual(record.cacheWrite5m, 900)
        XCTAssertEqual(record.cacheWrite1h, 0)
    }

    func testSkipsSyntheticModel() {
        XCTAssertNil(ClaudeCodeProvider.parseLine(claudeLine(model: "<synthetic>")))
    }

    func testSkipsLinesWithoutUsage() throws {
        let object: [String: Any] = ["type": "user", "timestamp": "2026-07-29T12:00:00.000Z"]
        let data = try JSONSerialization.data(withJSONObject: object)
        XCTAssertNil(ClaudeCodeProvider.parseLine(data))
    }

    func testToleratesMalformedJSON() {
        // 손상된 줄이 있어도 크래시하지 않고 nil을 준다.
        XCTAssertNil(ClaudeCodeProvider.parseLine(Data("{ not json".utf8)))
        XCTAssertNil(ClaudeCodeProvider.parseLine(Data()))
        XCTAssertNil(ClaudeCodeProvider.parseLine(Data("[]".utf8)))
    }

    func testFallbackDedupKeyWhenBothIdsMissing() throws {
        let record = try XCTUnwrap(ClaudeCodeProvider.parseLine(claudeLine(requestId: nil, messageId: nil)))
        XCTAssertTrue(record.dedupKey.hasPrefix("ts:"), record.dedupKey)
    }

    func testNullRequestIdStillUsesMessageId() throws {
        let record = try XCTUnwrap(ClaudeCodeProvider.parseLine(claudeLine(requestId: nil)))
        XCTAssertEqual(record.dedupKey, "-|msg_1")
    }

    // MARK: - Codex 라인 파싱

    func testParsesCodexRateLimits() throws {
        let object: [String: Any] = [
            "timestamp": "2026-07-26T09:16:57.598Z",
            "type": "event_msg",
            "payload": [
                "type": "token_count",
                "info": [
                    "last_token_usage": [
                        "input_tokens": 22051,
                        "cached_input_tokens": 1000,
                        "cache_write_input_tokens": 51,
                        "output_tokens": 294,
                        "total_tokens": 22345,
                    ],
                ],
                "rate_limits": [
                    "primary": ["used_percent": 9.0, "window_minutes": 10080, "resets_at": 1_785_658_627],
                    "secondary": NSNull(),
                    "plan_type": "plus",
                ],
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: object)
        let event = try XCTUnwrap(CodexProvider.parseLine(data))

        let limits = try XCTUnwrap(event.rateLimits)
        XCTAssertEqual(limits.planType, "plus")
        let primary = try XCTUnwrap(limits.primary)
        XCTAssertEqual(primary.usedPercent, 9.0)
        XCTAssertEqual(primary.windowMinutes, 10080)
        XCTAssertEqual(primary.windowLabel, "주간")
        XCTAssertEqual(primary.resetsAt, Date(timeIntervalSince1970: 1_785_658_627))
        XCTAssertNil(limits.secondary)

        let totals = try XCTUnwrap(event.totals)
        // cached / cache_write는 input_tokens에 포함돼 있으므로 빼서 중복 계산을 막는다.
        XCTAssertEqual(totals.input, 22051 - 1000 - 51)
        XCTAssertEqual(totals.cacheRead, 1000)
        XCTAssertEqual(totals.cacheWrite, 51)
        XCTAssertEqual(totals.output, 294)
    }

    func testIgnoresNonTokenCountCodexLines() throws {
        let object: [String: Any] = [
            "timestamp": "2026-07-26T09:16:57.598Z",
            "type": "event_msg",
            "payload": ["type": "agent_message", "message": "hello"],
        ]
        let data = try JSONSerialization.data(withJSONObject: object)
        XCTAssertNil(CodexProvider.parseLine(data))
    }

    func testRateLimitExpiry() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let expired = RateLimitWindow(usedPercent: 42, windowMinutes: 10080, resetsAt: now.addingTimeInterval(-60))
        let live = RateLimitWindow(usedPercent: 42, windowMinutes: 10080, resetsAt: now.addingTimeInterval(60))
        let unknown = RateLimitWindow(usedPercent: 42, windowMinutes: 10080, resetsAt: nil)

        XCTAssertTrue(expired.hasExpired(now: now))
        XCTAssertFalse(live.hasExpired(now: now))
        XCTAssertFalse(unknown.hasExpired(now: now))
    }

    func testWindowLabels() {
        XCTAssertEqual(RateLimitWindow(usedPercent: 0, windowMinutes: 10080, resetsAt: nil).windowLabel, "주간")
        XCTAssertEqual(RateLimitWindow(usedPercent: 0, windowMinutes: 1440, resetsAt: nil).windowLabel, "일간")
        XCTAssertEqual(RateLimitWindow(usedPercent: 0, windowMinutes: 300, resetsAt: nil).windowLabel, "5시간")
        XCTAssertEqual(RateLimitWindow(usedPercent: 0, windowMinutes: 180, resetsAt: nil).windowLabel, "3시간")
        XCTAssertEqual(RateLimitWindow(usedPercent: 0, windowMinutes: 45, resetsAt: nil).windowLabel, "45분")
    }
}
