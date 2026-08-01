import Foundation

/// Codex 세션 로그에 기록된 구독 한도 스냅샷.
public struct RateLimitWindow: Codable, Sendable, Equatable {
    public let usedPercent: Double
    public let windowMinutes: Int
    public let resetsAt: Date?

    public init(usedPercent: Double, windowMinutes: Int, resetsAt: Date?) {
        self.usedPercent = usedPercent
        self.windowMinutes = windowMinutes
        self.resetsAt = resetsAt
    }

    /// 리셋 시각이 지났으면 이 값은 낡은 것이고 한도는 이미 초기화됐다.
    public func hasExpired(now: Date) -> Bool {
        guard let resetsAt else { return false }
        return resetsAt <= now
    }

    public var windowLabel: String {
        switch windowMinutes {
        case 10080: return "주간"
        case 1440: return "일간"
        case 300: return "5시간"
        default:
            if windowMinutes % 60 == 0 { return "\(windowMinutes / 60)시간" }
            return "\(windowMinutes)분"
        }
    }
}

public struct RateLimitSnapshot: Codable, Sendable, Equatable {
    public let observedAt: Date
    public let planType: String?
    public let primary: RateLimitWindow?
    public let secondary: RateLimitWindow?
}

/// `~/.codex/sessions/**/rollout-*.jsonl`을 읽어 Codex(ChatGPT 구독) 사용량을 만든다.
///
/// 이 로그에는 구독 한도 사용률이 실제 수치로 들어 있다. 다만 **마지막으로 Codex를 실행한
/// 시점의 스냅샷**이라 값이 오래됐을 수 있어서, 관측 시각을 함께 표시한다.
public final class CodexProvider: UsageProvider {
    public let id = ServiceID.codex

    public static let defaultRetention: TimeInterval = 32 * 24 * 3600

    /// Codex 로그는 훨씬 작아서 넉넉히 보관해도 부담이 없다.
    public var retention: TimeInterval = CodexProvider.defaultRetention

    public struct ScanStats: Sendable, Equatable {
        public var filesScanned = 0
        public var linesRead = 0
        public var tokenEvents = 0
        public var rateLimitEvents = 0
        public var elapsed: TimeInterval = 0
    }

    struct UsageSample: Codable, Sendable, Equatable {
        let timestamp: Date
        let totals: TokenTotals
    }

    private struct PersistedState: Codable {
        var version: Int
        var cursors: [String: FileCursor]
        var samples: [UsageSample]
        var latestRateLimits: RateLimitSnapshot?
    }

    private let root: URL
    /// 캐시 저장 위치. 테스트가 실제 상태 파일을 건드리지 않도록 주입 가능하게 둔다.
    private let stateURL: URL?
    private var config: AppConfig
    private var scanner: NDJSONScanner
    private var samples: [UsageSample] = []
    private var latestRateLimits: RateLimitSnapshot?
    private var stateLoaded = false
    public private(set) var lastScan = ScanStats()
    /// 공식 엔드포인트 조회. 로그의 rate_limits는 마지막 실행 시점 스냅샷이라 여기가 훨씬 정확하다.
    private let live: LiveUsageCache

    /// `stateURL`이 nil이면 캐시를 저장하지 않는다(테스트 기본값).
    /// 기본 로그 경로를 쓸 때만 공유 상태 파일을 자동으로 붙인다.
    public init(
        root: URL = Paths.codexSessions,
        config: AppConfig = AppConfig.load(),
        stateURL: URL? = nil,
        liveFetcher: LiveUsageFetching = CodexLiveClient()
    ) {
        self.root = root
        self.config = config
        self.scanner = NDJSONScanner()
        self.live = LiveUsageCache(fetcher: liveFetcher, interval: config.liveRefreshInterval, label: "codex")
        if let stateURL {
            self.stateURL = stateURL
        } else {
            self.stateURL = (root == Paths.codexSessions) ? Paths.stateFile(for: .codex) : nil
        }
    }

    public func updateConfig(_ config: AppConfig) {
        self.config = config
        live.interval = config.liveRefreshInterval
    }

    public var currentRateLimits: RateLimitSnapshot? { latestRateLimits }

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

    /// 조회 간격을 무시하고 즉시 다시 시도한다. 사용자가 '갱신'을 눌렀을 때 쓴다.
    public func forceLiveRefresh(now: Date = Date()) {
        guard config.useLiveAPI else { return }
        live.refreshIfNeeded(now: now, force: true)
    }

    // MARK: - 스캔

    public func resetCache() {
        scanner.resetCursors()
        samples.removeAll()
        latestRateLimits = nil
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
        samples = state.samples
        latestRateLimits = state.latestRateLimits
    }

    private func saveState() {
        guard let stateURL else { return }
        let state = PersistedState(
            version: 1,
            cursors: scanner.snapshotOfCursors,
            samples: samples,
            latestRateLimits: latestRateLimits
        )
        try? JSONStore.save(state, to: stateURL)
    }

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
        for file in files {
            let lines: [Data]
            do {
                lines = try scanner.newLines(at: file)
            } catch {
                continue
            }
            stats.linesRead += lines.count
            for line in lines {
                guard let event = Self.parseLine(line) else { continue }
                if let totals = event.totals {
                    samples.append(UsageSample(timestamp: event.timestamp, totals: totals))
                    stats.tokenEvents += 1
                }
                if let limits = event.rateLimits {
                    stats.rateLimitEvents += 1
                    // 항상 가장 최근에 관측된 값을 유지한다.
                    if latestRateLimits == nil || event.timestamp > latestRateLimits!.observedAt {
                        latestRateLimits = RateLimitSnapshot(
                            observedAt: event.timestamp,
                            planType: limits.planType,
                            primary: limits.primary,
                            secondary: limits.secondary
                        )
                    }
                }
            }
        }
        scanner.pruneCursors(keeping: Set(files.map(\.path)))

        samples = samples.filter { $0.timestamp >= cutoff }.sorted { $0.timestamp < $1.timestamp }

        if scanner.revision != revisionBefore {
            saveState()
        }

        stats.elapsed = Date().timeIntervalSince(started)
        lastScan = stats
        return stats
    }

    // MARK: - 파싱

    struct ParsedEvent {
        let timestamp: Date
        let totals: TokenTotals?
        let rateLimits: (planType: String?, primary: RateLimitWindow?, secondary: RateLimitWindow?)?
    }

    /// `type: "event_msg"` + `payload.type: "token_count"` 인 줄만 의미가 있다.
    static func parseLine(_ data: Data) -> ParsedEvent? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let payload = object["payload"] as? [String: Any],
              (payload["type"] as? String) == "token_count",
              let timestampString = object["timestamp"] as? String,
              let timestamp = ISO8601.parse(timestampString)
        else { return nil }

        var totals: TokenTotals?
        if let info = payload["info"] as? [String: Any],
           let last = info["last_token_usage"] as? [String: Any] {
            let inputTotal = intValue(last["input_tokens"])
            let cachedInput = intValue(last["cached_input_tokens"])
            let cacheWrite = intValue(last["cache_write_input_tokens"])
            let output = intValue(last["output_tokens"])
            // cached / cache_write는 input_tokens에 포함돼 있어 중복 계산을 피한다.
            let uncachedInput = max(0, inputTotal - cachedInput - cacheWrite)
            totals = TokenTotals(
                input: uncachedInput,
                output: output,
                cacheRead: cachedInput,
                cacheWrite: cacheWrite
            )
        }

        var limits: (planType: String?, primary: RateLimitWindow?, secondary: RateLimitWindow?)?
        if let rateLimits = payload["rate_limits"] as? [String: Any] {
            limits = (
                planType: rateLimits["plan_type"] as? String,
                primary: parseWindow(rateLimits["primary"]),
                secondary: parseWindow(rateLimits["secondary"])
            )
        }

        guard totals != nil || limits != nil else { return nil }
        return ParsedEvent(timestamp: timestamp, totals: totals, rateLimits: limits)
    }

    private static func parseWindow(_ any: Any?) -> RateLimitWindow? {
        guard let dictionary = any as? [String: Any] else { return nil }
        guard let used = (dictionary["used_percent"] as? NSNumber)?.doubleValue else { return nil }
        let minutes = intValue(dictionary["window_minutes"])
        var resetsAt: Date?
        if let epoch = (dictionary["resets_at"] as? NSNumber)?.doubleValue {
            resetsAt = Date(timeIntervalSince1970: epoch)
        }
        return RateLimitWindow(usedPercent: used, windowMinutes: minutes, resetsAt: resetsAt)
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

        if config.useLiveAPI {
            live.refreshIfNeeded(now: now)
        }
        let liveGauges = config.useLiveAPI ? live.gauges(now: now, freshWithin: config.staleThreshold) : nil

        let weekStart = now.addingTimeInterval(-7 * 24 * 3600)
        let dayStart = Calendar.current.startOfDay(for: now)
        let weekTotals = samples.filter { $0.timestamp >= weekStart }
            .reduce(into: TokenTotals()) { $0 += $1.totals }
        let todayTotals = samples.filter { $0.timestamp >= dayStart }
            .reduce(into: TokenTotals()) { $0 += $1.totals }

        // 실시간 조회가 되면 그 값을 쓴다. 로그의 rate_limits는 마지막 실행 시점 값이라
        // Codex를 며칠 안 쓰면 크게 어긋난다.
        if let liveGauges {
            return ServiceSnapshot(
                id: id,
                planLabel: live.result?.planLabel,
                gauges: liveGauges,
                tokensToday: todayTotals,
                tokensLast7Days: weekTotals,
                observedAt: liveGauges.first.flatMap { gauge in
                    if case .snapshot(let observedAt) = gauge.source { return observedAt }
                    return nil
                },
                lastActivityAt: samples.last?.timestamp,
                daily: dailyHistory(now: now),
                details: live.result?.details ?? [],
                status: .ok
            )
        }

        guard let limits = latestRateLimits else {
            let detail = live.lastError.map { "실시간 조회 실패 · \($0.description)" }
                ?? (samples.isEmpty ? "Codex 세션 기록 없음" : "한도 정보 없음")
            return ServiceSnapshot(
                id: id,
                gauges: [],
                tokensToday: samples.isEmpty ? nil : todayTotals,
                tokensLast7Days: samples.isEmpty ? nil : weekTotals,
                observedAt: nil,
                lastActivityAt: samples.last?.timestamp,
                status: .noData(detail)
            )
        }

        var gauges = [UsageGauge]()
        for window in [limits.primary, limits.secondary].compactMap({ $0 }) {
            // 리셋 시각이 지났으면 한도는 이미 초기화됐다. 낡은 퍼센트를 그대로 보여주지 않는다.
            let expired = window.hasExpired(now: now)
            gauges.append(
                UsageGauge(
                    percent: expired ? 0 : window.usedPercent,
                    source: .snapshot(observedAt: limits.observedAt),
                    windowLabel: window.windowLabel,
                    resetsAt: expired ? nil : window.resetsAt
                )
            )
        }

        return ServiceSnapshot(
            id: id,
            planLabel: limits.planType.map { $0.capitalized },
            gauges: gauges,
            tokensToday: todayTotals,
            tokensLast7Days: weekTotals,
            // 이 퍼센트는 마지막 Codex 실행 시점의 스냅샷이다. 오래되면 경고를 띄운다.
            observedAt: limits.observedAt,
            lastActivityAt: samples.last?.timestamp,
            daily: dailyHistory(now: now),
            status: .ok
        )
    }

    /// Codex 로그에는 모델 정보가 없어 토큰 합계만 일별로 모은다.
    private func dailyHistory(now: Date, calendar: Calendar = .current) -> [DailyUsage] {
        let days = config.historyDays
        guard days > 0 else { return [] }
        let today = calendar.startOfDay(for: now)

        var buckets = [Date: TokenTotals]()
        for sample in samples {
            let day = calendar.startOfDay(for: sample.timestamp)
            guard let distance = calendar.dateComponents([.day], from: day, to: today).day,
                  distance >= 0, distance < days
            else { continue }
            buckets[day, default: TokenTotals()] += sample.totals
        }

        return (0..<days).reversed().compactMap { offset in
            guard let day = calendar.date(byAdding: .day, value: -offset, to: today) else { return nil }
            let totals = buckets[day] ?? TokenTotals()
            return DailyUsage(day: day, totals: totals, weighted: Double(totals.total))
        }
    }
}
