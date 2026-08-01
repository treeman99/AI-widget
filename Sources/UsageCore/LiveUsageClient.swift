import Foundation

/// 실시간 조회에서 돌아온 한도 창 하나.
public struct LiveLimitWindow: Codable, Sendable, Equatable {
    public let label: String
    public let percent: Double
    public let resetsAt: Date?

    public init(label: String, percent: Double, resetsAt: Date?) {
        self.label = label
        self.percent = percent
        self.resetsAt = resetsAt
    }
}

public struct LiveUsageResult: Codable, Sendable, Equatable {
    public let windows: [LiveLimitWindow]
    public let planLabel: String?
    /// 크레딧 잔액처럼 게이지가 아닌 부가 정보.
    public let details: [UsageDetail]
    public let fetchedAt: Date

    public init(
        windows: [LiveLimitWindow],
        planLabel: String?,
        details: [UsageDetail] = [],
        fetchedAt: Date
    ) {
        self.windows = windows
        self.planLabel = planLabel
        self.details = details
        self.fetchedAt = fetchedAt
    }
}

public enum LiveUsageError: Error, CustomStringConvertible, Equatable {
    case credentialsUnavailable(String)
    case tokenExpired
    case httpStatus(Int)
    case network(String)
    case decode(String)

    public var description: String {
        switch self {
        case .credentialsUnavailable(let detail): return detail
        case .tokenExpired: return "로그인 토큰이 만료됐습니다"
        case .httpStatus(401), .httpStatus(403): return "인증이 거부됐습니다 (토큰 만료 가능성)"
        case .httpStatus(let code): return "서버 응답 \(code)"
        case .network(let detail): return "네트워크 오류: \(detail)"
        case .decode(let detail): return "응답 해석 실패: \(detail)"
        }
    }
}

/// 서비스별 실시간 사용량 조회기.
public protocol LiveUsageFetching: Sendable {
    func fetch(now: Date) throws -> LiveUsageResult
}

// MARK: - 공통 HTTP

enum HTTP {
    /// 백그라운드 큐에서 호출하는 동기 GET. 타임아웃 안에 못 받으면 실패로 본다.
    static func getJSON(
        _ url: URL,
        headers: [String: String],
        timeout: TimeInterval = 10
    ) throws -> [String: Any] {
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "GET"
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }

        var payload: Data?
        var response: URLResponse?
        var failure: Error?
        let semaphore = DispatchSemaphore(value: 0)

        let task = URLSession.shared.dataTask(with: request) { data, urlResponse, error in
            payload = data
            response = urlResponse
            failure = error
            semaphore.signal()
        }
        task.resume()

        if semaphore.wait(timeout: .now() + timeout + 2) == .timedOut {
            task.cancel()
            throw LiveUsageError.network("응답 시간 초과")
        }
        if let failure {
            throw LiveUsageError.network(failure.localizedDescription)
        }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw LiveUsageError.httpStatus(http.statusCode)
        }
        guard let payload,
              let object = try? JSONSerialization.jsonObject(with: payload) as? [String: Any]
        else {
            throw LiveUsageError.decode("JSON 객체가 아님")
        }
        return object
    }

    static func double(_ any: Any?) -> Double? {
        (any as? NSNumber)?.doubleValue
    }
}

// MARK: - Claude

/// Claude 구독 사용량을 공식 엔드포인트에서 읽는다.
///
/// Claude Code의 `/usage`가 쓰는 것과 같은 경로다. 문서화된 공개 API는 아니므로
/// 언제든 바뀔 수 있고, 실패하면 로컬 로그 기반 추정으로 물러난다.
public struct ClaudeLiveClient: LiveUsageFetching {
    public static let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!

    public init() {}

    public func fetch(now: Date = Date()) throws -> LiveUsageResult {
        let credentials = try Credentials.claude()
        if credentials.isExpired {
            throw LiveUsageError.tokenExpired
        }

        let object: [String: Any]
        do {
            object = try HTTP.getJSON(
                Self.endpoint,
                headers: [
                    "Authorization": "Bearer \(credentials.accessToken)",
                    "anthropic-beta": "oauth-2025-04-20",
                    "Content-Type": "application/json",
                ]
            )
        } catch LiveUsageError.httpStatus(let code) where code == 401 || code == 403 {
            // 들고 있던 토큰이 죽었다. 캐시를 비워 다음 조회가 키체인을 다시 읽게 한다.
            Credentials.invalidateClaudeCache()
            throw LiveUsageError.httpStatus(code)
        }

        // `limits` 배열이 가장 자세하다(세션 / 전체 주간 / 모델별 주간). 없으면 요약 필드로 물러난다.
        var windows = Self.windows(fromLimits: object["limits"])
        if windows.isEmpty {
            if let window = Self.window(from: object["five_hour"], label: "현재 세션 (5시간)") {
                windows.append(window)
            }
            if let window = Self.window(from: object["seven_day"], label: "이번 주 (전체 모델)") {
                windows.append(window)
            }
        }
        guard !windows.isEmpty else {
            throw LiveUsageError.decode("한도 정보가 비어 있음")
        }

        return LiveUsageResult(
            windows: windows,
            planLabel: credentials.planLabel,
            details: Self.details(from: object),
            fetchedAt: now
        )
    }

    /// `limits` 배열을 게이지 창으로 바꾼다.
    ///
    /// 모델별 주간 한도는 실제로 쓰고 있을 때만 보여준다. 0%짜리 항목이 줄줄이 늘어서면
    /// 정작 봐야 할 숫자가 묻힌다.
    static func windows(fromLimits any: Any?) -> [LiveLimitWindow] {
        guard let limits = any as? [[String: Any]] else { return [] }
        var result = [LiveLimitWindow]()

        for limit in limits {
            guard let percent = HTTP.double(limit["percent"]) else { continue }
            let kind = limit["kind"] as? String ?? ""
            let isActive = (limit["is_active"] as? NSNumber)?.boolValue ?? false

            let label: String
            switch kind {
            case "session":
                label = "현재 세션 (5시간)"
            case "weekly_all":
                label = "이번 주 (전체 모델)"
            case "weekly_scoped":
                guard percent > 0 || isActive else { continue }
                let scope = limit["scope"] as? [String: Any]
                let model = (scope?["model"] as? [String: Any])?["display_name"] as? String
                label = model.map { "이번 주 (\($0))" } ?? "이번 주 (일부 모델)"
            default:
                guard percent > 0 || isActive else { continue }
                label = kind.replacingOccurrences(of: "_", with: " ").capitalized
            }

            var resetsAt: Date?
            if let text = limit["resets_at"] as? String {
                resetsAt = ISO8601.parse(text)
            }
            result.append(LiveLimitWindow(label: label, percent: percent, resetsAt: resetsAt))
        }
        return result
    }

    static func details(from object: [String: Any]) -> [UsageDetail] {
        var details = [UsageDetail]()

        if let extra = object["extra_usage"] as? [String: Any],
           (extra["is_enabled"] as? NSNumber)?.boolValue == true {
            if let utilization = HTTP.double(extra["utilization"]) {
                details.append(UsageDetail(label: "추가 사용량", value: Format.percent(utilization)))
            } else {
                details.append(UsageDetail(label: "추가 사용량", value: "사용 중"))
            }
        }

        if let spend = object["spend"] as? [String: Any],
           (spend["enabled"] as? NSNumber)?.boolValue == true,
           let used = spend["used"] as? [String: Any],
           let minor = HTTP.double(used["amount_minor"]) {
            let exponent = HTTP.double(used["exponent"]) ?? 2
            let amount = minor / pow(10, exponent)
            let currency = used["currency"] as? String ?? "USD"
            details.append(UsageDetail(label: "크레딧 사용", value: String(format: "%.2f %@", amount, currency)))
        }

        return details
    }

    static func window(from any: Any?, label: String) -> LiveLimitWindow? {
        guard let dictionary = any as? [String: Any],
              let utilization = HTTP.double(dictionary["utilization"])
        else { return nil }
        var resetsAt: Date?
        if let text = dictionary["resets_at"] as? String {
            resetsAt = ISO8601.parse(text)
        }
        return LiveLimitWindow(label: label, percent: utilization, resetsAt: resetsAt)
    }
}

// MARK: - Codex

/// Codex(ChatGPT 구독) 사용량을 공식 엔드포인트에서 읽는다.
///
/// 로그에 남는 `rate_limits`는 마지막 실행 시점 스냅샷이지만, 이 경로는 현재값을 준다.
public struct CodexLiveClient: LiveUsageFetching {
    public static let endpoint = URL(string: "https://chatgpt.com/backend-api/wham/usage")!

    public init() {}

    public func fetch(now: Date = Date()) throws -> LiveUsageResult {
        let credentials = try Credentials.codex()

        var headers = [
            "Authorization": "Bearer \(credentials.accessToken)",
            "Content-Type": "application/json",
        ]
        if let accountId = credentials.accountId {
            headers["chatgpt-account-id"] = accountId
        }

        let object = try HTTP.getJSON(Self.endpoint, headers: headers)

        guard let rateLimit = object["rate_limit"] as? [String: Any] else {
            throw LiveUsageError.decode("rate_limit 없음")
        }

        var windows = [LiveLimitWindow]()
        if let window = Self.window(from: rateLimit["primary_window"]) {
            windows.append(window)
        }
        if let window = Self.window(from: rateLimit["secondary_window"]) {
            windows.append(window)
        }
        guard !windows.isEmpty else {
            throw LiveUsageError.decode("한도 정보가 비어 있음")
        }

        return LiveUsageResult(
            windows: windows,
            planLabel: (object["plan_type"] as? String)?.capitalized,
            details: Self.details(from: object),
            fetchedAt: now
        )
    }

    static func details(from object: [String: Any]) -> [UsageDetail] {
        var details = [UsageDetail]()

        if let credits = object["credits"] as? [String: Any] {
            if (credits["unlimited"] as? NSNumber)?.boolValue == true {
                details.append(UsageDetail(label: "크레딧", value: "무제한"))
            } else if (credits["has_credits"] as? NSNumber)?.boolValue == true,
                      let balance = credits["balance"] as? String {
                details.append(UsageDetail(label: "크레딧", value: balance))
            }
        }

        if let resetCredits = object["rate_limit_reset_credits"] as? [String: Any],
           let available = HTTP.double(resetCredits["available_count"]), available > 0 {
            details.append(UsageDetail(label: "한도 리셋 크레딧", value: "\(Int(available))개"))
        }

        return details
    }

    static func window(from any: Any?) -> LiveLimitWindow? {
        guard let dictionary = any as? [String: Any],
              let percent = HTTP.double(dictionary["used_percent"])
        else { return nil }

        var resetsAt: Date?
        if let epoch = HTTP.double(dictionary["reset_at"]) {
            resetsAt = Date(timeIntervalSince1970: epoch)
        } else if let seconds = HTTP.double(dictionary["reset_after_seconds"]) {
            resetsAt = Date().addingTimeInterval(seconds)
        }

        let seconds = HTTP.double(dictionary["limit_window_seconds"]) ?? 0
        return LiveLimitWindow(label: Self.label(forWindowSeconds: seconds), percent: percent, resetsAt: resetsAt)
    }

    static func label(forWindowSeconds seconds: Double) -> String {
        switch Int(seconds) {
        case 604_800: return "주간"
        case 86_400: return "일간"
        case 18_000: return "5시간"
        case 0: return "한도"
        default:
            let hours = Int(seconds) / 3600
            return hours > 0 ? "\(hours)시간" : "\(Int(seconds) / 60)분"
        }
    }
}
