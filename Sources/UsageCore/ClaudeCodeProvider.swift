import Foundation

/// `~/.claude/projects/**/*.jsonl`을 읽어 Claude Code 사용량을 만든다.
///
/// 중복 제거가 필수다. 세션 재개와 컴팩션 때 이전 메시지가 다시 기록돼서, 최근 24시간
/// 기준 3,737개 레코드 중 고유한 것은 2,003개뿐이다. 그대로 합산하면 1.87배 과대 집계된다.
public final class ClaudeCodeProvider: UsageProvider {
    public let id = ServiceID.claudeCode

    /// 평상시 보관 기간. 런타임 게이지는 5시간 블록과 7일 창만 쓰므로 짧게 유지해
    /// 캐시 파일과 로드 비용을 줄인다.
    public static let defaultRetention: TimeInterval = 8 * 24 * 3600

    /// 보관 기간. 캘리브레이션이 30일 피크를 볼 때만 일시적으로 늘린다.
    public var retention: TimeInterval = ClaudeCodeProvider.defaultRetention

    public struct ScanStats: Sendable, Equatable {
        public var filesScanned = 0
        public var linesRead = 0
        public var recordsParsed = 0
        public var duplicatesDropped = 0
        public var malformedLines = 0
        public var elapsed: TimeInterval = 0
    }

    private struct PersistedState: Codable {
        var version: Int
        var cursors: [String: FileCursor]
        var records: [UsageRecord]
    }

    private let root: URL
    /// 캐시 저장 위치. 테스트가 실제 상태 파일을 건드리지 않도록 주입 가능하게 둔다.
    private let stateURL: URL?
    private var config: AppConfig
    private var scanner: NDJSONScanner
    private var records: [UsageRecord] = []
    private var stateLoaded = false
    private var lastSavedAt: Date?
    /// 캐시 저장 최소 간격. Claude Code가 활발히 돌 때 수 MB 파일을 몇 초마다 다시 쓰지 않게 한다.
    /// 캐시가 조금 뒤처져도 다음 실행에서 앞선 오프셋부터 다시 읽고 중복 제거가 처리하므로 안전하다.
    public var saveThrottle: TimeInterval = 30
    public private(set) var lastScan = ScanStats()
    /// 공식 엔드포인트 조회. 성공하면 기준선 추정 대신 실제 사용률을 쓴다.
    private let live: LiveUsageCache

    /// `stateURL`이 nil이면 캐시를 저장하지 않는다(테스트 기본값).
    /// 기본 로그 경로를 쓸 때만 공유 상태 파일을 자동으로 붙인다.
    public init(
        root: URL = Paths.claudeProjects,
        config: AppConfig = AppConfig.load(),
        stateURL: URL? = nil,
        liveFetcher: LiveUsageFetching = ClaudeLiveClient()
    ) {
        self.root = root
        self.config = config
        self.scanner = NDJSONScanner()
        self.live = LiveUsageCache(fetcher: liveFetcher, interval: config.liveRefreshInterval, label: "claude")
        if let stateURL {
            self.stateURL = stateURL
        } else {
            self.stateURL = (root == Paths.claudeProjects) ? Paths.stateFile(for: .claudeCode) : nil
        }
    }

    public func updateConfig(_ config: AppConfig) {
        self.config = config
        live.interval = config.liveRefreshInterval
    }

    /// 마지막 실시간 조회에서 난 오류. 없으면 nil.
    public var liveError: LiveUsageError? { live.lastError }

    /// 실시간 결과가 도착했을 때 불린다. 임의의 큐에서 불린다.
    public var onLiveUpdate: (@Sendable () -> Void)? {
        get { live.onUpdate }
        set { live.onUpdate = newValue }
    }

    /// 조회가 끝날 때까지 기다린다. 한 번 실행하고 끝나는 CLI에서 쓴다.
    public func primeLiveUsage(now: Date = Date()) {
        guard config.useLiveAPI else { return }
        live.refreshBlocking(now: now, force: true)
    }

    /// 중복 제거된 전체 레코드. 캘리브레이션에서 쓴다.
    public var allRecords: [UsageRecord] { records }

    // MARK: - 스캔

    /// 캐시를 무시하고 처음부터 다시 읽는다.
    public func resetCache() {
        scanner.resetCursors()
        records.removeAll()
        stateLoaded = true
    }

    private func loadStateIfNeeded() {
        guard !stateLoaded else { return }
        stateLoaded = true
        guard let stateURL,
              let state = JSONStore.load(PersistedState.self, from: stateURL),
              state.version == 1
        else { return }
        scanner = NDJSONScanner(cursors: state.cursors)
        records = state.records
    }

    private func saveState() {
        guard let stateURL else { return }
        let state = PersistedState(version: 1, cursors: scanner.snapshotOfCursors, records: records)
        try? JSONStore.save(state, to: stateURL)
    }

    /// 변경된 파일만 다시 읽어 레코드를 갱신한다.
    @discardableResult
    public func refresh(now: Date = Date()) throws -> ScanStats {
        loadStateIfNeeded()
        let started = Date()
        var stats = ScanStats()

        guard FileManager.default.fileExists(atPath: root.path) else {
            throw UsageError.logDirectoryMissing(root.path)
        }

        let cutoff = now.addingTimeInterval(-retention)
        let files = LogFileFinder.files(under: root, modifiedAfter: cutoff)
        stats.filesScanned = files.count

        let revisionBefore = scanner.revision
        var fresh = [UsageRecord]()
        for file in files {
            let lines: [Data]
            do {
                lines = try scanner.newLines(at: file)
            } catch {
                // 한 파일이 사라지거나 읽히지 않아도 나머지는 계속 처리한다.
                continue
            }
            stats.linesRead += lines.count
            for line in lines {
                switch Self.parseLine(line) {
                case .some(let record):
                    fresh.append(record)
                case .none:
                    // usage가 없는 줄(사용자 메시지, 요약 등)이 대부분이라 오류로 세지 않는다.
                    break
                }
            }
        }
        scanner.pruneCursors(keeping: Set(files.map(\.path)))

        let before = records.count + fresh.count
        records.append(contentsOf: fresh)
        // 시간순 정렬을 유지한다. 블록 계산과 "마지막 활동" 표시가 순서에 의존한다.
        records = records
            .deduplicatedByKey()
            .filter { $0.timestamp >= cutoff }
            .sorted { $0.timestamp < $1.timestamp }
        stats.recordsParsed = fresh.count
        stats.duplicatesDropped = max(0, before - records.count)

        // 아무것도 바뀌지 않았으면 수 MB짜리 캐시를 다시 쓰지 않는다.
        let changed = scanner.revision != revisionBefore || !fresh.isEmpty
        let throttleElapsed = lastSavedAt.map { Date().timeIntervalSince($0) >= saveThrottle } ?? true
        if changed, throttleElapsed {
            saveState()
            lastSavedAt = Date()
        }

        stats.elapsed = Date().timeIntervalSince(started)
        lastScan = stats
        return stats
    }

    // MARK: - 파싱

    /// 한 줄에서 사용량 레코드를 뽑는다. usage가 없으면 nil.
    static func parseLine(_ data: Data) -> UsageRecord? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let message = object["message"] as? [String: Any],
              let usage = message["usage"] as? [String: Any],
              let timestampString = object["timestamp"] as? String,
              let timestamp = ISO8601.parse(timestampString)
        else { return nil }

        let model = (message["model"] as? String) ?? "unknown"
        guard !TokenWeight.excludedModels.contains(model) else { return nil }

        let input = intValue(usage["input_tokens"])
        let output = intValue(usage["output_tokens"])
        let cacheRead = intValue(usage["cache_read_input_tokens"])
        let cacheWriteTotal = intValue(usage["cache_creation_input_tokens"])

        var write5m = cacheWriteTotal
        var write1h = 0
        if let breakdown = usage["cache_creation"] as? [String: Any] {
            let ephemeral5m = intValue(breakdown["ephemeral_5m_input_tokens"])
            let ephemeral1h = intValue(breakdown["ephemeral_1h_input_tokens"])
            if ephemeral5m + ephemeral1h > 0 {
                write5m = ephemeral5m
                write1h = ephemeral1h
            }
        }

        let requestId = object["requestId"] as? String
        let messageId = message["id"] as? String
        let key: String
        if requestId != nil || messageId != nil {
            key = "\(requestId ?? "-")|\(messageId ?? "-")"
        } else {
            // 두 ID가 모두 없는 레코드(전체의 0.5% 미만)는 내용으로 식별한다.
            key = "ts:\(timestamp.timeIntervalSince1970)|\(model)|\(input)|\(output)|\(cacheRead)|\(cacheWriteTotal)"
        }

        return UsageRecord(
            timestamp: timestamp,
            model: model,
            input: input,
            output: output,
            cacheRead: cacheRead,
            cacheWrite5m: write5m,
            cacheWrite1h: write1h,
            dedupKey: key
        )
    }

    private static func intValue(_ any: Any?) -> Int {
        if let number = any as? NSNumber { return number.intValue }
        if let int = any as? Int { return int }
        return 0
    }

    // MARK: - 스냅샷

    public func snapshot(now: Date = Date()) throws -> ServiceSnapshot {
        do {
            try refresh(now: now)
        } catch let error as UsageError {
            return ServiceSnapshot(id: id, status: .failed(error.description))
        }

        // 실시간 조회가 되면 그 값을 쓰고, 안 되면 로컬 기준선 추정으로 물러난다.
        if config.useLiveAPI {
            live.refreshIfNeeded(now: now)
        }
        let liveGauges = config.useLiveAPI ? live.gauges(now: now, freshWithin: config.staleThreshold) : nil

        guard !records.isEmpty || liveGauges != nil else {
            return ServiceSnapshot(id: id, planLabel: config.claudePlanLabel, status: .noData("세션 기록 없음"))
        }

        let weekStart = now.addingTimeInterval(-7 * 24 * 3600)
        let weekRecords = records.inRange(weekStart, now.addingTimeInterval(1))
        let dayStart = Calendar.current.startOfDay(for: now)
        let todayRecords = records.inRange(dayStart, now.addingTimeInterval(1))

        let gauges = liveGauges ?? estimateGauges(now: now, weekRecords: weekRecords)
        let planLabel = live.result?.planLabel ?? config.claudePlanLabel

        return ServiceSnapshot(
            id: id,
            planLabel: planLabel,
            gauges: gauges,
            tokensToday: todayRecords.tokenTotals,
            tokensLast7Days: weekRecords.tokenTotals,
            // 실시간 값이 낡았을 때만 기준 시각을 노출한다. 추정치는 항상 현재값이라 대상이 아니다.
            observedAt: gauges.first.flatMap { gauge in
                if case .snapshot(let observedAt) = gauge.source { return observedAt }
                return nil
            },
            lastActivityAt: records.last?.timestamp,
            daily: History.daily(from: records, days: config.historyDays, now: now),
            modelShares: History.modelShares(from: weekRecords),
            details: live.result?.details ?? [],
            status: .ok
        )
    }

    /// 실시간 조회가 불가능할 때 쓰는 기준선 환산 게이지.
    private func estimateGauges(now: Date, weekRecords: [UsageRecord]) -> [UsageGauge] {
        let blocks = SessionBlocks.build(from: records)
        let activeBlock = SessionBlocks.active(in: blocks, now: now)
        return [
            UsageGauge(
                percent: percent(activeBlock?.weighted ?? 0, of: config.baselines.fiveHour),
                source: .estimate,
                windowLabel: "5시간",
                resetsAt: activeBlock?.end
            ),
            UsageGauge(
                percent: percent(TokenWeight.weightedSum(weekRecords), of: config.baselines.weekly),
                source: .estimate,
                windowLabel: "최근 7일",
                resetsAt: nil
            ),
        ]
    }

    private func percent(_ value: Double, of baseline: Double) -> Double {
        guard baseline > 0 else { return 0 }
        return value / baseline * 100
    }
}

public enum UsageError: Error, CustomStringConvertible {
    case logDirectoryMissing(String)
    case parseFailure(String)

    public var description: String {
        switch self {
        case .logDirectoryMissing(let path): return "로그 디렉토리 없음: \(path)"
        case .parseFailure(let detail): return "파싱 실패: \(detail)"
        }
    }
}
