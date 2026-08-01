import Foundation

/// 서비스별 제공자를 묶어 한 번에 갱신한다. CLI와 메뉴바 앱이 공유하는 진입점.
///
/// 내부에 동기화가 없다. 생성 이후에는 **하나의 큐에서만** 호출해야 한다
/// (메뉴바 앱은 `UsageStore`의 전용 직렬 큐에 가둔다).
public final class UsageMonitor: @unchecked Sendable {
    public private(set) var config: AppConfig
    private let claude: ClaudeCodeProvider
    private let codex: CodexProvider

    public init(config: AppConfig = AppConfig.load()) {
        self.config = config
        self.claude = ClaudeCodeProvider(config: config)
        self.codex = CodexProvider(config: config)
    }

    public var claudeProvider: ClaudeCodeProvider { claude }
    public var codexProvider: CodexProvider { codex }

    public func updateConfig(_ config: AppConfig) {
        self.config = config
        claude.updateConfig(config)
        codex.updateConfig(config)
    }

    /// 실시간 결과가 도착했을 때 불린다. 두 서비스 모두에 같은 핸들러가 걸린다.
    public var onLiveUpdate: (@Sendable () -> Void)? {
        didSet {
            claude.onLiveUpdate = onLiveUpdate
            codex.onLiveUpdate = onLiveUpdate
        }
    }

    /// 실시간 조회가 끝날 때까지 기다린다. 한 번 실행하고 끝나는 CLI에서 쓴다.
    ///
    /// 메뉴바 앱은 이걸 부르지 않는다 — 조회는 백그라운드로 던져두고 화면은 즉시 그린다.
    public func primeLiveUsage(now: Date = Date()) {
        for id in ServiceID.allCases where config.enabledServices.contains(id) {
            if id == .claudeCode {
                claude.primeLiveUsage(now: now)
            } else {
                codex.primeLiveUsage(now: now)
            }
        }
    }

    /// 사용자가 '갱신'을 눌렀다. 조회 간격과 키체인 백오프를 걷어내고 즉시 다시 시도한다.
    ///
    /// 평소 갱신(`refresh`)은 5분 간격 스로틀을 지키고, 키체인 접근이 거부된 뒤에는 30분간
    /// 물러난다. 사용자가 버튼을 누른 건 "지금 다시"라는 뜻이므로 두 제약을 모두 푼다.
    public func forceLiveRefresh(now: Date = Date()) {
        Credentials.resetClaudeBackoff()
        for id in ServiceID.allCases where config.enabledServices.contains(id) {
            if id == .claudeCode {
                claude.forceLiveRefresh(now: now)
            } else {
                codex.forceLiveRefresh(now: now)
            }
        }
    }

    /// 활성화된 서비스를 모두 갱신한다.
    public func refresh(now: Date = Date()) -> UsageSnapshot {
        let started = Date()
        var services = [ServiceSnapshot]()

        for id in ServiceID.allCases where config.enabledServices.contains(id) {
            let provider: UsageProvider = (id == .claudeCode) ? claude : codex
            do {
                var snapshot = try provider.snapshot(now: now)
                if id == .claudeCode {
                    snapshot = applyAutoCalibration(to: snapshot)
                }
                services.append(snapshot)
            } catch {
                services.append(ServiceSnapshot(id: id, status: .failed("\(error)")))
            }
        }

        return UsageSnapshot(
            services: services,
            generatedAt: now,
            elapsed: Date().timeIntervalSince(started)
        )
    }

    /// 새 피크를 만나면 기준선을 올린다. 기준선을 넘긴 상태는 100%로 표시한다.
    ///
    /// 추정 게이지에만 적용한다. 실시간 값은 실제 한도라 기준선과 무관하다.
    private func applyAutoCalibration(to snapshot: ServiceSnapshot) -> ServiceSnapshot {
        guard config.baselines.autoCalibrate, !snapshot.gauges.isEmpty else { return snapshot }

        var baselines = config.baselines
        var changed = false
        var gauges = snapshot.gauges

        if gauges.indices.contains(0), gauges[0].isEstimate, gauges[0].percent > 100 {
            baselines.fiveHour *= gauges[0].percent / 100
            gauges[0] = UsageGauge(
                percent: 100,
                source: gauges[0].source,
                windowLabel: gauges[0].windowLabel,
                resetsAt: gauges[0].resetsAt
            )
            changed = true
        }
        if gauges.indices.contains(1), gauges[1].isEstimate, gauges[1].percent > 100 {
            baselines.weekly *= gauges[1].percent / 100
            gauges[1] = UsageGauge(
                percent: 100,
                source: gauges[1].source,
                windowLabel: gauges[1].windowLabel,
                resetsAt: gauges[1].resetsAt
            )
            changed = true
        }

        guard changed else { return snapshot }
        config.baselines = baselines
        claude.updateConfig(config)
        try? config.save()

        return ServiceSnapshot(
            id: snapshot.id,
            planLabel: snapshot.planLabel,
            gauges: gauges,
            tokensToday: snapshot.tokensToday,
            tokensLast7Days: snapshot.tokensLast7Days,
            observedAt: snapshot.observedAt,
            lastActivityAt: snapshot.lastActivityAt,
            status: snapshot.status
        )
    }

    /// 전체 로그를 다시 읽어 기준선을 산출하고 설정에 저장한다.
    @discardableResult
    public func calibrate(now: Date = Date(), lookback: TimeInterval = Calibration.defaultLookback) throws -> Calibration.Result {
        // 평상시에는 8일치만 들고 있으므로, 캘리브레이션 동안만 보관 기간을 늘린다.
        let previousRetention = claude.retention
        claude.retention = lookback + 2 * 24 * 3600
        defer { claude.retention = previousRetention }

        claude.resetCache()
        try claude.refresh(now: now)
        let result = Calibration.compute(records: claude.allRecords, now: now, lookback: lookback)
        config.baselines = Calibration.baselines(
            from: result,
            autoCalibrate: config.baselines.autoCalibrate,
            fallback: config.baselines
        )
        claude.updateConfig(config)
        try config.save()
        return result
    }
}
