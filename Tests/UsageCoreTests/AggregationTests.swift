import XCTest
@testable import UsageCore

final class AggregationTests: XCTestCase {

    private func record(
        _ offsetSeconds: TimeInterval,
        key: String,
        model: String = "claude-opus-5",
        input: Int = 100,
        output: Int = 100,
        cacheRead: Int = 0,
        cacheWrite5m: Int = 0,
        cacheWrite1h: Int = 0,
        base: Date = Date(timeIntervalSince1970: 1_800_000_000)
    ) -> UsageRecord {
        UsageRecord(
            timestamp: base.addingTimeInterval(offsetSeconds),
            model: model,
            input: input,
            output: output,
            cacheRead: cacheRead,
            cacheWrite5m: cacheWrite5m,
            cacheWrite1h: cacheWrite1h,
            dedupKey: key
        )
    }

    // MARK: - 중복 제거

    func testDeduplicationKeepsFirstOccurrenceOnly() {
        // 세션 재개 시 같은 응답이 여러 파일에 그대로 복제되는 상황.
        let records = [
            record(0, key: "req_a|msg_a"),
            record(0, key: "req_a|msg_a"),
            record(0, key: "req_a|msg_a"),
            record(10, key: "req_b|msg_b"),
            record(20, key: "req_c|msg_c"),
            record(10, key: "req_b|msg_b"),
        ]
        let unique = records.deduplicatedByKey()
        XCTAssertEqual(records.count, 6)
        XCTAssertEqual(unique.count, 3)
        XCTAssertEqual(unique.map(\.dedupKey), ["req_a|msg_a", "req_b|msg_b", "req_c|msg_c"])
    }

    func testDeduplicationInflationRatioMatchesObservedShape() {
        // 실측(최근 24시간): 3,737개 레코드 → 고유 2,003개, 약 1.87배.
        // 같은 비율의 합성 데이터로 집계가 부풀려지지 않는지 확인한다.
        var records = [UsageRecord]()
        for index in 0..<2003 {
            records.append(record(Double(index), key: "req_\(index)|msg_\(index)"))
        }
        for index in 0..<1734 {
            records.append(record(Double(index), key: "req_\(index)|msg_\(index)"))
        }
        XCTAssertEqual(records.count, 3737)

        let unique = records.deduplicatedByKey()
        XCTAssertEqual(unique.count, 2003)

        let inflated = TokenWeight.weightedSum(records)
        let correct = TokenWeight.weightedSum(unique)
        XCTAssertEqual(inflated / correct, 3737.0 / 2003.0, accuracy: 0.001)
    }

    // MARK: - 5시간 블록

    func testBuildsSingleBlockForCloselySpacedRecords() {
        let records = [record(0, key: "a"), record(600, key: "b"), record(3600, key: "c")]
        let blocks = SessionBlocks.build(from: records)
        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(blocks[0].records.count, 3)
        XCTAssertEqual(blocks[0].end.timeIntervalSince(blocks[0].start), 5 * 3600)
    }

    func testStartsNewBlockAfterWindowElapses() {
        // 5시간 창을 넘어서면 새 블록이 열린다.
        let records = [record(0, key: "a"), record(5 * 3600 + 60, key: "b")]
        let blocks = SessionBlocks.build(from: records)
        XCTAssertEqual(blocks.count, 2)
    }

    func testStartsNewBlockAfterLongIdleGap() {
        // 창 안이라도 5시간 이상 공백이면 새 블록으로 본다.
        let records = [record(0, key: "a"), record(6 * 3600, key: "b"), record(6 * 3600 + 60, key: "c")]
        let blocks = SessionBlocks.build(from: records)
        XCTAssertEqual(blocks.count, 2)
        XCTAssertEqual(blocks[1].records.count, 2)
    }

    func testBlockStartIsFlooredToHour() {
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        let blocks = SessionBlocks.build(from: [record(0, key: "a", base: base)])
        let start = blocks[0].start.timeIntervalSince1970
        XCTAssertEqual(start.truncatingRemainder(dividingBy: 3600), 0)
        XCTAssertLessThanOrEqual(blocks[0].start, base)
    }

    func testActiveBlockIsNilAfterExpiry() {
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        let blocks = SessionBlocks.build(from: [record(0, key: "a", base: base)])
        XCTAssertNotNil(SessionBlocks.active(in: blocks, now: base.addingTimeInterval(60)))
        XCTAssertNil(SessionBlocks.active(in: blocks, now: base.addingTimeInterval(6 * 3600)))
    }

    func testEmptyRecordsProduceNoBlocks() {
        XCTAssertTrue(SessionBlocks.build(from: []).isEmpty)
        XCTAssertNil(SessionBlocks.active(in: [], now: Date()))
    }

    // MARK: - 범위 필터

    func testInRangeIsHalfOpen() {
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        let records = [record(0, key: "a", base: base), record(100, key: "b", base: base)]
        let filtered = records.inRange(base, base.addingTimeInterval(100))
        XCTAssertEqual(filtered.map(\.dedupKey), ["a"])
    }

    // MARK: - 가중치

    func testModelCoefficients() {
        XCTAssertEqual(TokenWeight.coefficient(for: "claude-fable-5"), 2.0)
        XCTAssertEqual(TokenWeight.coefficient(for: "claude-opus-5"), 1.0)
        XCTAssertEqual(TokenWeight.coefficient(for: "claude-opus-4-8"), 1.0)
        XCTAssertEqual(TokenWeight.coefficient(for: "claude-sonnet-5"), 0.6)
        XCTAssertEqual(TokenWeight.coefficient(for: "claude-haiku-4-5-20251001"), 0.2)
        // 모르는 모델은 과소평가를 피하려고 Opus로 본다.
        XCTAssertEqual(TokenWeight.coefficient(for: "some-future-model"), 1.0)
    }

    func testWeightedTokensFollowPricingStructure() {
        let opus = record(0, key: "a", model: "claude-opus-5", input: 1000, output: 1000, cacheRead: 1000, cacheWrite5m: 1000, cacheWrite1h: 1000)
        // 1000*1 + 1000*5 + 1000*0.1 + 1000*1.25 + 1000*2 = 9350
        XCTAssertEqual(TokenWeight.weighted(opus), 9350, accuracy: 0.001)

        let sonnet = record(0, key: "b", model: "claude-sonnet-5", input: 1000, output: 1000, cacheRead: 1000, cacheWrite5m: 1000, cacheWrite1h: 1000)
        XCTAssertEqual(TokenWeight.weighted(sonnet), 9350 * 0.6, accuracy: 0.001)
    }

    // MARK: - 캘리브레이션

    func testRollingPeakFindsDensestWindow() {
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        var records = [UsageRecord]()
        // 처음 3건은 흩어져 있고, 뒤의 5건은 짧은 구간에 몰려 있다.
        for index in 0..<3 {
            records.append(record(Double(index) * 86400, key: "sparse\(index)", base: base))
        }
        for index in 0..<5 {
            records.append(record(10 * 86400 + Double(index) * 60, key: "dense\(index)", base: base))
        }
        let peak = Calibration.rollingPeak(records.sorted { $0.timestamp < $1.timestamp }, window: 3600)
        let single = TokenWeight.weighted(records[0])
        XCTAssertEqual(peak, single * 5, accuracy: 0.001)
    }

    func testCalibrationUsesSameBlockAlgorithmAsRuntime() {
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        let records = [
            record(0, key: "a", base: base),
            record(60, key: "b", base: base),
            record(10 * 3600, key: "c", base: base),
        ]
        let result = Calibration.compute(records: records, now: base.addingTimeInterval(11 * 3600), lookback: 30 * 86400)
        XCTAssertEqual(result.blockCount, 2)
        XCTAssertEqual(result.recordCount, 3)
        // 피크 블록은 레코드 2건이 들어 있는 첫 블록이다.
        XCTAssertEqual(result.fiveHourPeak, TokenWeight.weighted(records[0]) * 2, accuracy: 0.001)
    }

    func testCalibrationOnEmptyInputKeepsFallback() {
        let result = Calibration.compute(records: [], now: Date())
        XCTAssertEqual(result.recordCount, 0)
        let baselines = Calibration.baselines(from: result, fallback: .fallback)
        XCTAssertEqual(baselines.fiveHour, Baselines.fallback.fiveHour)
        XCTAssertEqual(baselines.weekly, Baselines.fallback.weekly)
    }
}
