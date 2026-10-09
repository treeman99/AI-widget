import Foundation

/// Antigravity CLI(`agy`)로 쓰는 Gemini 구독 한도를 보여준다.
///
/// 로컬 로그 스캔이 없다. agy의 대화 기록은 SQLite 안의 protobuf라 토큰을 셀 수 없고,
/// 셀 수 있더라도 한도 대비 비율은 서버만 안다. 그래서 실시간 조회 결과만 쓴다.
///
/// Claude·Codex와 다른 점은 토큰이 1시간마다 죽는다는 것이다. agy가 실행될 때만 갱신되므로
/// 하루의 대부분은 조회가 안 되고, 화면은 마지막 관측값으로 버틴다. 아래의 짧은 신선도 창과
/// 상태 파일이 모두 이 사정에서 나왔다.
public final class GeminiProvider: UsageProvider {
    public let id = ServiceID.gemini

    /// 실시간으로 인정하는 창의 하한. 조회 간격을 아주 짧게 잡아도 이보다 빨리 낡았다고 하지 않는다.
    public static let minimumFreshness: TimeInterval = 600

    private struct PersistedState: Codable {
        var version: Int
        var lastResult: LiveUsageResult
    }

    /// 마지막 관측 저장 위치. 테스트가 실제 상태 파일을 건드리지 않도록 주입 가능하게 둔다.
    private let stateURL: URL?
    private var config: AppConfig
    private let live: LiveUsageCache
    /// 디스크에 있는 결과의 조회 시각. 같은 결과를 주기마다 다시 쓰지 않는다.
    private var persistedFetchedAt: Date?

    /// `liveFetcher`를 넘기지 않으면 실제 조회기와 공유 상태 파일을 쓴다.
    /// 조회기를 주입하면(테스트) `stateURL`을 명시하지 않는 한 저장하지 않는다.
    public init(
        config: AppConfig = AppConfig.load(),
        stateURL: URL? = nil,
        liveFetcher: LiveUsageFetching? = nil
    ) {
        self.config = config
        self.live = LiveUsageCache(
            fetcher: liveFetcher ?? GeminiLiveClient(),
            interval: config.liveRefreshInterval,
            label: "gemini"
        )
        if let stateURL {
            self.stateURL = stateURL
        } else {
            self.stateURL = (liveFetcher == nil) ? Paths.stateFile(for: .gemini) : nil
        }
        loadState()
    }

    public func updateConfig(_ config: AppConfig) {
        self.config = config
        live.interval = config.liveRefreshInterval
    }

    /// 마지막 실시간 조회에서 난 오류. 없으면 nil.
    public var liveError: LiveUsageError? { live.lastError }

    /// 마지막으로 성공한 조회 시각. 지난 실행에서 불러온 값일 수도 있다.
    public var lastObservedAt: Date? { live.result?.fetchedAt }

    /// 실시간 결과가 도착했을 때 불린다. 임의의 큐에서 불린다.
    public var onLiveUpdate: (@Sendable () -> Void)? {
        get { live.onUpdate }
        set { live.onUpdate = newValue }
    }

    /// 조회가 끝날 때까지 기다린다. 한 번 실행하고 끝나는 CLI에서 쓴다.
    public func primeLiveUsage(now: Date = Date()) {
        guard config.useLiveAPI else { return }
        live.refreshBlocking(now: now, force: true)
        persistIfChanged()
    }

    /// 조회 간격을 무시하고 즉시 다시 시도한다. 사용자가 '갱신'을 눌렀을 때 쓴다.
    public func forceLiveRefresh(now: Date = Date()) {
        guard config.useLiveAPI else { return }
        live.refreshIfNeeded(now: now, force: true)
    }

    /// 이 시간 안에 받은 값만 실시간으로 표시한다.
    ///
    /// Claude·Codex처럼 `staleThreshold`(기본 24시간)를 쓰면 안 된다. 여기서는 토큰이 죽어
    /// 조회가 실패하는 게 평상시라, 24시간 창이면 몇 시간 전 값이 '실시간' 배지를 달고 나온다.
    /// 조회 주기를 두 번 넘긴 값은 낡은 것으로 본다. 다만 한 번의 일시 실패로 배지가 깜박이지
    /// 않게 `minimumFreshness`보다 짧게 잡지는 않는다.
    public static func freshWindow(for config: AppConfig) -> TimeInterval {
        max(2 * config.liveRefreshInterval, minimumFreshness)
    }

    // MARK: - 마지막 관측 저장

    /// 지난 실행이 남긴 마지막 관측을 불러온다. 토큰이 죽은 채 앱이 다시 떠도 빈 칸 대신
    /// 그 값을 '마지막 관측'으로 보여주기 위해서다. 몇 백 바이트라 생성 시점에 바로 읽는다.
    private func loadState() {
        guard let stateURL,
              let state = JSONStore.load(PersistedState.self, from: stateURL),
              state.version == 1
        else { return }
        live.seed(state.lastResult)
        persistedFetchedAt = state.lastResult.fetchedAt
    }

    /// 새 결과가 들어왔을 때만 쓴다.
    private func persistIfChanged() {
        guard let stateURL,
              let result = live.result,
              result.fetchedAt != persistedFetchedAt
        else { return }
        // 실패해도 화면에는 영향이 없다. 다음 결과가 들어오면 다시 쓴다.
        try? JSONStore.save(PersistedState(version: 1, lastResult: result), to: stateURL)
        persistedFetchedAt = result.fetchedAt
    }

    /// 메모리와 디스크의 마지막 관측을 모두 버린다 (`usagectl reset`).
    ///
    /// Claude·Codex의 캐시와 달리 이 값은 다시 만들 수 없다. 재스캔할 로그가 없으므로,
    /// 토큰이 죽어 있으면 agy를 다음에 실행할 때까지 빈 칸이 된다. 그래도 reset에서는
    /// 지운다. reset은 사용자가 쌓인 상태를 의심하고 명시적으로 처음부터 시작하겠다는
    /// 동사이고, 로그아웃했거나 계정을 바꾼 뒤 남은 옛 계정의 숫자를 걷어낼 방법이 이것뿐이다.
    /// 반대로 앱의 '전체 다시 스캔'은 로그 캐시 재구축이 목적이라 이 함수를 부르지 않는다.
    public func resetCache() {
        live.reset()
        persistedFetchedAt = nil
        if let stateURL {
            try? FileManager.default.removeItem(at: stateURL)
        }
    }

    // MARK: - 스냅샷

    public func snapshot(now: Date = Date()) throws -> ServiceSnapshot {
        // 다른 서비스는 실시간을 끄면 로컬 추정으로 물러나지만 여기는 물러날 곳이 없다.
        guard config.useLiveAPI else {
            return ServiceSnapshot(
                id: id,
                status: .noData("실시간 조회가 꺼져 있습니다 (Gemini는 로컬 추정이 없습니다)")
            )
        }

        live.refreshIfNeeded(now: now)
        persistIfChanged()

        let error = live.lastError
        guard let gauges = live.gauges(now: now, freshWithin: Self.freshWindow(for: config)) else {
            return ServiceSnapshot(id: id, status: .noData(Self.noDataMessage(for: error)))
        }

        var details = live.result?.details ?? []
        if let error {
            // 숫자는 지난 관측으로 그리되, 왜 갱신이 안 되는지는 한 줄로 알린다.
            details.append(UsageDetail(label: "실시간 조회", value: Self.liveErrorSummary(error)))
        }

        return ServiceSnapshot(
            id: id,
            planLabel: live.result?.planLabel,
            gauges: gauges,
            // 낡은 값일 때만 기준 시각을 노출한다. UI가 이걸로 'HH:mm 기준' 줄을 그린다.
            observedAt: gauges.first.flatMap { gauge in
                if case .snapshot(let observedAt) = gauge.source { return observedAt }
                return nil
            },
            details: details,
            status: .ok
        )
    }

    /// details 한 줄에 들어갈 짧은 설명. 토큰 만료는 고장이 아니라 평상시라, 오류문 대신
    /// 언제 풀리는지를 알려 준다.
    static func liveErrorSummary(_ error: LiveUsageError) -> String {
        if case .tokenExpired = error {
            return "토큰 만료 · agy 실행 시 재개"
        }
        return error.description
    }

    /// 보여줄 관측값이 하나도 없을 때의 안내. 토큰 만료는 여기서도 고장이 아니라 할 일로 말한다.
    static func noDataMessage(for error: LiveUsageError?) -> String {
        switch error {
        case .none:
            return "실시간 조회 대기 중"
        case .tokenExpired?:
            return "Antigravity 토큰이 만료됐습니다 — agy를 한 번 실행하면 다시 붙습니다"
        case let error?:
            return "실시간 조회 실패 · \(error.description)"
        }
    }
}
