import XCTest
@testable import UsageCore

final class ScannerTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AIUsageBarTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func write(_ text: String, to name: String) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func append(_ text: String, to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
    }

    // MARK: - 줄 분리

    func testSplitKeepsPartialTrailingLineUnconsumed() {
        let data = Data("{\"a\":1}\n{\"b\":2}\n{\"c\":3".utf8)
        let (lines, consumed) = NDJSONScanner.splitCompleteLines(data)
        XCTAssertEqual(lines.count, 2)
        // 마지막 미완결 줄은 소비하지 않아 다음 스캔에서 완성된 뒤 읽힌다.
        XCTAssertEqual(consumed, 16)
        XCTAssertEqual(String(data: lines[0], encoding: .utf8), "{\"a\":1}")
    }

    func testSplitSkipsBlankLines() {
        let data = Data("a\n\n\nb\n".utf8)
        let (lines, _) = NDJSONScanner.splitCompleteLines(data)
        XCTAssertEqual(lines.count, 2)
    }

    // MARK: - 증분 읽기

    func testIncrementalScanReadsOnlyNewLines() throws {
        let url = try write("line1\nline2\n", to: "a.jsonl")
        let scanner = NDJSONScanner()

        let first = try scanner.newLines(at: url)
        XCTAssertEqual(first.count, 2)

        // 변경이 없으면 다시 읽지 않는다.
        let second = try scanner.newLines(at: url)
        XCTAssertEqual(second.count, 0)

        try append("line3\n", to: url)
        let third = try scanner.newLines(at: url)
        XCTAssertEqual(third.count, 1)
        XCTAssertEqual(String(data: third[0], encoding: .utf8), "line3")
    }

    func testPartialLineIsCompletedOnNextScan() throws {
        let url = try write("full\npar", to: "b.jsonl")
        let scanner = NDJSONScanner()

        let first = try scanner.newLines(at: url)
        XCTAssertEqual(first.map { String(data: $0, encoding: .utf8) }, ["full"])

        try append("tial\n", to: url)
        let second = try scanner.newLines(at: url)
        XCTAssertEqual(second.map { String(data: $0, encoding: .utf8) }, ["partial"])
    }

    func testTruncatedFileIsRereadFromStart() throws {
        let url = try write("a\nb\nc\n", to: "c.jsonl")
        let scanner = NDJSONScanner()
        XCTAssertEqual(try scanner.newLines(at: url).count, 3)

        // 파일이 교체되어 더 짧아지면 처음부터 다시 읽어야 한다.
        try "x\n".write(to: url, atomically: true, encoding: .utf8)
        XCTAssertEqual(try scanner.newLines(at: url).count, 1)
    }

    func testMissingFileThrows() {
        let scanner = NDJSONScanner()
        let missing = directory.appendingPathComponent("nope.jsonl")
        XCTAssertThrowsError(try scanner.newLines(at: missing))
    }

    func testPruneCursorsDropsUnknownPaths() throws {
        let url = try write("a\n", to: "d.jsonl")
        let scanner = NDJSONScanner()
        _ = try scanner.newLines(at: url)
        XCTAssertEqual(scanner.snapshotOfCursors.count, 1)

        scanner.pruneCursors(keeping: [])
        XCTAssertTrue(scanner.snapshotOfCursors.isEmpty)
    }

    // MARK: - 파일 탐색

    func testFinderFiltersByExtensionAndMtime() throws {
        let nested = directory.appendingPathComponent("sub", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        _ = try write("x\n", to: "keep.jsonl")
        try "y\n".write(to: nested.appendingPathComponent("nested.jsonl"), atomically: true, encoding: .utf8)
        try "z\n".write(to: directory.appendingPathComponent("ignore.txt"), atomically: true, encoding: .utf8)

        let all = LogFileFinder.files(under: directory)
        XCTAssertEqual(Set(all.map(\.lastPathComponent)), ["keep.jsonl", "nested.jsonl"])

        let future = LogFileFinder.files(under: directory, modifiedAfter: Date().addingTimeInterval(3600))
        XCTAssertTrue(future.isEmpty)
    }

    // MARK: - 프로바이더 통합

    func testClaudeProviderDeduplicatesAcrossFiles() throws {
        let timestamp = "2026-07-29T12:00:00.000Z"
        func line(_ requestId: String, _ messageId: String) -> String {
            let object: [String: Any] = [
                "requestId": requestId,
                "timestamp": timestamp,
                "message": [
                    "id": messageId,
                    "model": "claude-opus-5",
                    "usage": ["input_tokens": 10, "output_tokens": 10],
                ],
            ]
            let data = try! JSONSerialization.data(withJSONObject: object)
            return String(data: data, encoding: .utf8)!
        }

        // 같은 응답이 두 파일에 중복 기록된 상황을 재현한다.
        _ = try write(line("req_1", "msg_1") + "\n" + line("req_2", "msg_2") + "\n", to: "session-a.jsonl")
        _ = try write(line("req_1", "msg_1") + "\n" + line("req_3", "msg_3") + "\n", to: "session-b.jsonl")

        let provider = ClaudeCodeProvider(root: directory, config: AppConfig(useLiveAPI: false))
        provider.resetCache()
        let now = ISO8601.parse(timestamp)!.addingTimeInterval(60)
        let stats = try provider.refresh(now: now)

        XCTAssertEqual(stats.recordsParsed, 4)
        XCTAssertEqual(provider.allRecords.count, 3)
        XCTAssertEqual(stats.duplicatesDropped, 1)
    }

    func testClaudeProviderReportsMissingDirectory() {
        let provider = ClaudeCodeProvider(
            root: directory.appendingPathComponent("does-not-exist"),
            config: AppConfig(useLiveAPI: false)
        )
        provider.resetCache()
        XCTAssertThrowsError(try provider.refresh()) { error in
            guard case UsageError.logDirectoryMissing = error else {
                return XCTFail("예상과 다른 오류: \(error)")
            }
        }
    }

    func testClaudeProviderSurvivesCorruptedLines() throws {
        let object: [String: Any] = [
            "requestId": "req_1",
            "timestamp": "2026-07-29T12:00:00.000Z",
            "message": ["id": "msg_1", "model": "claude-opus-5", "usage": ["input_tokens": 1, "output_tokens": 1]],
        ]
        let good = String(data: try JSONSerialization.data(withJSONObject: object), encoding: .utf8)!
        _ = try write("{ broken\n" + good + "\nnot json at all\n", to: "mixed.jsonl")

        let provider = ClaudeCodeProvider(root: directory, config: AppConfig(useLiveAPI: false))
        provider.resetCache()
        let stats = try provider.refresh(now: ISO8601.parse("2026-07-29T12:01:00.000Z")!)
        XCTAssertEqual(stats.linesRead, 3)
        XCTAssertEqual(provider.allRecords.count, 1)
    }

    func testCodexProviderZeroesExpiredWindow() throws {
        let observed = "2026-07-26T09:16:57.598Z"
        let resetsAt = ISO8601.parse(observed)!.addingTimeInterval(3600).timeIntervalSince1970
        let object: [String: Any] = [
            "timestamp": observed,
            "type": "event_msg",
            "payload": [
                "type": "token_count",
                "rate_limits": [
                    "primary": ["used_percent": 42.0, "window_minutes": 10080, "resets_at": resetsAt],
                    "plan_type": "plus",
                ],
            ],
        ]
        let json = String(data: try JSONSerialization.data(withJSONObject: object), encoding: .utf8)!
        _ = try write(json + "\n", to: "rollout-test.jsonl")

        let provider = CodexProvider(root: directory, config: AppConfig(useLiveAPI: false))
        provider.resetCache()

        // 리셋 전에는 관측값을 그대로 보여준다.
        let before = try provider.snapshot(now: Date(timeIntervalSince1970: resetsAt - 60))
        XCTAssertEqual(before.primaryGauge?.percent, 42.0)
        XCTAssertNotNil(before.primaryGauge?.resetsAt)

        // 리셋 시각이 지나면 낡은 퍼센트를 그대로 두지 않는다.
        provider.resetCache()
        let after = try provider.snapshot(now: Date(timeIntervalSince1970: resetsAt + 60))
        XCTAssertEqual(after.primaryGauge?.percent, 0)
        XCTAssertNil(after.primaryGauge?.resetsAt)
        XCTAssertEqual(after.planLabel, "Plus")
    }
}
