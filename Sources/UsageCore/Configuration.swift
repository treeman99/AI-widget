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

    // 이후에 필드가 추가돼도 기존 설정 파일을 계속 읽을 수 있게 모든 키를 옵셔널로 디코딩한다.
    private enum CodingKeys: String, CodingKey {
        case baselines, thresholds, refreshInterval, enabledServices, claudePlanLabel, staleThreshold
        case useLiveAPI, liveRefreshInterval, historyDays
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        baselines = try container.decodeIfPresent(Baselines.self, forKey: .baselines) ?? .fallback
        thresholds = try container.decodeIfPresent(ColorThresholds.self, forKey: .thresholds) ?? ColorThresholds()
        refreshInterval = try container.decodeIfPresent(TimeInterval.self, forKey: .refreshInterval) ?? 60
        enabledServices = try container.decodeIfPresent([ServiceID].self, forKey: .enabledServices) ?? ServiceID.allCases
        claudePlanLabel = try container.decodeIfPresent(String.self, forKey: .claudePlanLabel) ?? "Max 5x"
        staleThreshold = try container.decodeIfPresent(TimeInterval.self, forKey: .staleThreshold) ?? 24 * 3600
        useLiveAPI = try container.decodeIfPresent(Bool.self, forKey: .useLiveAPI) ?? true
        liveRefreshInterval = try container.decodeIfPresent(TimeInterval.self, forKey: .liveRefreshInterval) ?? 300
        historyDays = try container.decodeIfPresent(Int.self, forKey: .historyDays) ?? 14
    }
}
