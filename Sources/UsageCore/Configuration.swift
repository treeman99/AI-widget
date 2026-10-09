import Foundation

/// Claude Code의 한도 기준선. 로컬 로그에는 "한도 대비 %"가 없어서 직접 정한다.
public struct Baselines: Codable, Sendable, Equatable {
    /// 5시간 블록 기준선 (가중 토큰).
    public var fiveHour: Double
    /// 7일 기준선 (가중 토큰).
    public var weekly: Double
    /// 새 피크가 관측되면 기준선을 자동으로 올린다.
    public var autoCalibrate: Bool

    public init(fiveHour: Double, weekly: Double, autoCalibrate: Bool = true) {
        self.fiveHour = fiveHour
        self.weekly = weekly
        self.autoCalibrate = autoCalibrate
    }

    /// 캘리브레이션 전에 쓰는 초깃값. `usagectl calibrate`가 실측치로 덮어쓴다.
    public static let fallback = Baselines(fiveHour: 40_000_000, weekly: 250_000_000)
}

/// 메뉴바 숫자 색을 바꾸는 임계치(%).
public struct ColorThresholds: Codable, Sendable, Equatable {
    public var caution: Double
    public var warning: Double
    public var critical: Double

    public init(caution: Double = 50, warning: Double = 80, critical: Double = 95) {
        self.caution = caution
        self.warning = warning
        self.critical = critical
    }

    public enum Level: Sendable, Equatable {
        case normal, caution, warning, critical
    }

    public func level(for percent: Double) -> Level {
        if percent >= critical { return .critical }
        if percent >= warning { return .warning }
        if percent >= caution { return .caution }
        return .normal
    }
}

public struct AppConfig: Codable, Sendable, Equatable {
    public var baselines: Baselines
    public var thresholds: ColorThresholds
    /// 주기 갱신 간격(초). 파일 변경 감시가 별도로 즉시 갱신을 트리거한다.
    public var refreshInterval: TimeInterval
    public var enabledServices: [ServiceID]
    /// 이 설정 파일이 이미 "본" 서비스. 새 서비스를 기존 사용자에게 켜 주는 데 쓴다.
    ///
    /// `enabledServices`만으로는 "사용자가 끈 서비스"와 "설정을 저장할 때 아직 없던 서비스"를
    /// 구분할 수 없다. Gemini가 생기기 전의 설정은 `["claude-code","codex"]`라, 그대로 두면
    /// Gemini는 사용자가 고른 적도 없이 영영 꺼진 채다. 디코딩할 때 여기 없는 서비스만 켜고
    /// 목록을 최신으로 맞추므로, 나중에 사용자가 끈 서비스는 계속 꺼져 있다.
    public var knownServices: [ServiceID]
    /// 구독 플랜 표시용 라벨.
    public var claudePlanLabel: String
    /// 이 시간(초)보다 오래된 값은 stale로 표시한다.
    public var staleThreshold: TimeInterval
    /// 공식 엔드포인트에서 실제 한도 사용률을 조회할지. 끄면 로컬 로그 추정만 쓴다.
    public var useLiveAPI: Bool
    /// 실시간 조회 간격(초). 로컬 스캔보다 훨씬 뜸하게 돈다.
    public var liveRefreshInterval: TimeInterval
    /// 드롭다운 일별 차트에 보여줄 날짜 수.
    public var historyDays: Int

    public init(
        baselines: Baselines = .fallback,
        thresholds: ColorThresholds = ColorThresholds(),
        refreshInterval: TimeInterval = 60,
        enabledServices: [ServiceID] = ServiceID.allCases,
        claudePlanLabel: String = "Max 5x",
        staleThreshold: TimeInterval = 24 * 3600,
        useLiveAPI: Bool = true,
        liveRefreshInterval: TimeInterval = 300,
        historyDays: Int = 14
    ) {
        self.baselines = baselines
        self.thresholds = thresholds
        self.refreshInterval = refreshInterval
        self.enabledServices = enabledServices
        self.knownServices = ServiceID.allCases
        self.claudePlanLabel = claudePlanLabel
        self.staleThreshold = staleThreshold
        self.useLiveAPI = useLiveAPI
        self.liveRefreshInterval = liveRefreshInterval
        self.historyDays = historyDays
    }

    public static func load() -> AppConfig {
        JSONStore.load(AppConfig.self, from: Paths.configFile) ?? AppConfig()
    }

    public func save() throws {
        try JSONStore.save(self, to: Paths.configFile)
    }

    /// `knownServices`가 생기기 전의 설정 파일이 알던 서비스.
    static let legacyKnownServices: [ServiceID] = [.claudeCode, .codex]

    // 이후에 필드가 추가돼도 기존 설정 파일을 계속 읽을 수 있게 모든 키를 옵셔널로 디코딩한다.
    private enum CodingKeys: String, CodingKey {
        case baselines, thresholds, refreshInterval, enabledServices, knownServices, claudePlanLabel, staleThreshold
        case useLiveAPI, liveRefreshInterval, historyDays
    }

    /// 서비스 목록을 문자열로 읽고 모르는 값은 버린다.
    ///
    /// `[ServiceID]`로 바로 읽으면 모르는 이름 하나(더 새 버전이 저장한 서비스 등)에 디코딩
    /// 전체가 실패하고, `load()`가 기본값으로 물러나면서 기준선까지 잃는다.
    private static func decodeServices(
        _ container: KeyedDecodingContainer<CodingKeys>,
        forKey key: CodingKeys
    ) throws -> [ServiceID]? {
        try container.decodeIfPresent([String].self, forKey: key)?.compactMap(ServiceID.init(rawValue:))
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        baselines = try container.decodeIfPresent(Baselines.self, forKey: .baselines) ?? .fallback
        thresholds = try container.decodeIfPresent(ColorThresholds.self, forKey: .thresholds) ?? ColorThresholds()
        refreshInterval = try container.decodeIfPresent(TimeInterval.self, forKey: .refreshInterval) ?? 60
        let enabled = try Self.decodeServices(container, forKey: .enabledServices) ?? ServiceID.allCases
        let known = try Self.decodeServices(container, forKey: .knownServices) ?? Self.legacyKnownServices
        // 이 파일이 처음 보는 서비스는 켜서 들인다. 순서는 allCases를 따른다.
        let unseen = ServiceID.allCases.filter { !known.contains($0) }
        enabledServices = unseen.isEmpty
            ? enabled
            : ServiceID.allCases.filter { enabled.contains($0) || unseen.contains($0) }
        knownServices = ServiceID.allCases
        claudePlanLabel = try container.decodeIfPresent(String.self, forKey: .claudePlanLabel) ?? "Max 5x"
        staleThreshold = try container.decodeIfPresent(TimeInterval.self, forKey: .staleThreshold) ?? 24 * 3600
        useLiveAPI = try container.decodeIfPresent(Bool.self, forKey: .useLiveAPI) ?? true
        liveRefreshInterval = try container.decodeIfPresent(TimeInterval.self, forKey: .liveRefreshInterval) ?? 300
        historyDays = try container.decodeIfPresent(Int.self, forKey: .historyDays) ?? 14
    }
}
