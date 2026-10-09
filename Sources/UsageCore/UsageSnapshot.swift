import Foundation

/// 위젯이 추적하는 서비스.
public enum ServiceID: String, Codable, Sendable, CaseIterable {
    case claudeCode = "claude-code"
    case codex
    case gemini

    public var displayName: String {
        switch self {
        case .claudeCode: return "Claude Code"
        case .codex: return "Codex"
        case .gemini: return "Gemini (Antigravity)"
        }
    }

    /// 메뉴바에 표시할 이름.
    ///
    /// 약어(CC/CX)는 한 글자만 달라 흘긋 볼 때 구분이 안 된다. 폭을 조금 더 쓰더라도
    /// 서로 완전히 다른 단어를 쓴다.
    public var menuBarLabel: String {
        switch self {
        case .claudeCode: return "Claude"
        case .codex: return "Codex"
        case .gemini: return "Gemini"
        }
    }
}

/// 토큰 종류별 합계. 가중치를 적용하지 않은 원본 수치다.
public struct TokenTotals: Codable, Sendable, Equatable {
    public var input: Int
    public var output: Int
    public var cacheRead: Int
    public var cacheWrite: Int

    public init(input: Int = 0, output: Int = 0, cacheRead: Int = 0, cacheWrite: Int = 0) {
        self.input = input
        self.output = output
        self.cacheRead = cacheRead
        self.cacheWrite = cacheWrite
    }

    public var total: Int { input + output + cacheRead + cacheWrite }

    public static func + (lhs: TokenTotals, rhs: TokenTotals) -> TokenTotals {
        TokenTotals(
            input: lhs.input + rhs.input,
            output: lhs.output + rhs.output,
            cacheRead: lhs.cacheRead + rhs.cacheRead,
            cacheWrite: lhs.cacheWrite + rhs.cacheWrite
        )
    }

    public static func += (lhs: inout TokenTotals, rhs: TokenTotals) {
        lhs = lhs + rhs
    }
}

/// 게이지 값이 어디서 왔는지. 숫자의 신뢰도가 출처마다 다르므로 항상 함께 표시한다.
public enum GaugeSource: Sendable, Equatable {
    /// 공식 엔드포인트에서 방금 받은 실제 한도 사용률.
    case live(fetchedAt: Date)
    /// 마지막으로 성공한 실시간 값, 또는 로그에 기록된 관측값. 시간이 지나면 낡는다.
    case snapshot(observedAt: Date)
    /// 로컬 로그를 기준선으로 환산한 추정치. 공식 한도가 아니다.
    case estimate

    public var isEstimate: Bool {
        if case .estimate = self { return true }
        return false
    }

    /// 값이 관측된 시각. 실시간이면 조회 시각이다.
    public var timestamp: Date? {
        switch self {
        case .live(let fetchedAt): return fetchedAt
        case .snapshot(let observedAt): return observedAt
        case .estimate: return nil
        }
    }

    /// 배지에 쓸 짧은 라벨. 실시간은 굳이 표시하지 않는다.
    public var badge: String? {
        switch self {
        case .live: return nil
        case .snapshot: return "마지막 관측"
        case .estimate: return "추정"
        }
    }
}

/// 한도 사용률 게이지 하나.
public struct UsageGauge: Sendable, Equatable {
    /// 0 이상. 100을 넘을 수 있다(기준선 초과).
    public let percent: Double
    public let source: GaugeSource
    /// "5시간" / "주간" 등.
    public let windowLabel: String
    public let resetsAt: Date?

    public init(percent: Double, source: GaugeSource, windowLabel: String, resetsAt: Date?) {
        self.percent = percent
        self.source = source
        self.windowLabel = windowLabel
        self.resetsAt = resetsAt
    }

    public var isEstimate: Bool { source.isEstimate }
}

/// 하루치 사용량. 드롭다운의 일별 차트에 쓴다.
public struct DailyUsage: Codable, Sendable, Equatable {
    /// 로컬 시간 기준 그날 0시.
    public let day: Date
    public let totals: TokenTotals
    public let weighted: Double

    public init(day: Date, totals: TokenTotals, weighted: Double) {
        self.day = day
        self.totals = totals
        self.weighted = weighted
    }
}

/// 모델별 사용 비중.
public struct ModelShare: Sendable, Equatable {
    /// "Opus", "Sonnet" 처럼 짧게 정리한 이름.
    public let model: String
    public let weighted: Double
    /// 0~1.
    public let share: Double

    public init(model: String, weighted: Double, share: Double) {
        self.model = model
        self.weighted = weighted
        self.share = share
    }
}

/// 게이지로 표현하기 애매한 부가 정보 한 줄. (크레딧 잔액 등)
public struct UsageDetail: Codable, Sendable, Equatable {
    public let label: String
    public let value: String

    public init(label: String, value: String) {
        self.label = label
        self.value = value
    }
}

public enum SnapshotStatus: Sendable, Equatable {
    case ok
    /// 로그는 읽었지만 표시할 데이터가 없다.
    case noData(String)
    /// 파싱이나 접근에 실패했다. 조용히 0을 표시하지 않고 오류를 드러낸다.
    case failed(String)
}

/// 서비스 하나의 현재 상태.
public struct ServiceSnapshot: Sendable {
    public let id: ServiceID
    public let planLabel: String?
    /// 첫 번째가 메뉴바에 표시되는 대표 게이지다.
    public let gauges: [UsageGauge]
    public let tokensToday: TokenTotals?
    public let tokensLast7Days: TokenTotals?
    /// 게이지 값이 관측된 시각. **스냅샷형 데이터에만 설정한다.**
    ///
    /// Codex의 한도 퍼센트는 마지막으로 Codex를 실행했을 때 기록된 값이라 시간이 지나면
    /// 낡는다. 반면 Claude Code는 로컬 로그를 매번 다시 집계하므로 항상 현재값이고,
    /// 여기에 값을 넣지 않는다. 이 필드가 stale 경고를 만든다.
    public let observedAt: Date?
    /// 마지막으로 사용 기록이 남은 시각. 정보 표시용이며 stale 판정과 무관하다.
    public let lastActivityAt: Date?
    /// 최근 며칠간의 일별 사용량. 오래된 날이 앞이다.
    public let daily: [DailyUsage]
    /// 모델별 비중. 큰 순서다.
    public let modelShares: [ModelShare]
    /// 크레딧 잔액처럼 게이지가 아닌 부가 정보.
    public let details: [UsageDetail]
    public let status: SnapshotStatus

    public init(
        id: ServiceID,
        planLabel: String? = nil,
        gauges: [UsageGauge] = [],
        tokensToday: TokenTotals? = nil,
        tokensLast7Days: TokenTotals? = nil,
        observedAt: Date? = nil,
        lastActivityAt: Date? = nil,
        daily: [DailyUsage] = [],
        modelShares: [ModelShare] = [],
        details: [UsageDetail] = [],
        status: SnapshotStatus = .ok
    ) {
        self.id = id
        self.planLabel = planLabel
        self.gauges = gauges
        self.tokensToday = tokensToday
        self.tokensLast7Days = tokensLast7Days
        self.observedAt = observedAt
        self.lastActivityAt = lastActivityAt
        self.daily = daily
        self.modelShares = modelShares
        self.details = details
        self.status = status
    }

    public var primaryGauge: UsageGauge? { gauges.first }

    /// 관측 시각이 threshold보다 오래됐으면 stale.
    public func isStale(now: Date = Date(), threshold: TimeInterval = 24 * 3600) -> Bool {
        guard let observedAt else { return false }
        return now.timeIntervalSince(observedAt) > threshold
    }
}

/// 모든 서비스를 합친 한 번의 갱신 결과.
public struct UsageSnapshot: Sendable {
    public let services: [ServiceSnapshot]
    public let generatedAt: Date
    /// 갱신에 걸린 시간(초).
    public let elapsed: TimeInterval

    public init(services: [ServiceSnapshot], generatedAt: Date = Date(), elapsed: TimeInterval = 0) {
        self.services = services
        self.generatedAt = generatedAt
        self.elapsed = elapsed
    }

    public func service(_ id: ServiceID) -> ServiceSnapshot? {
        services.first { $0.id == id }
    }
}

/// 서비스별 사용량 제공자.
public protocol UsageProvider: AnyObject {
    var id: ServiceID { get }
    /// 증분 스캔 후 현재 스냅샷을 만든다.
    func snapshot(now: Date) throws -> ServiceSnapshot
}
