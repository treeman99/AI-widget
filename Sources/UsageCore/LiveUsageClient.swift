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
        try send(request(url, method: "GET", headers: headers, body: nil, timeout: timeout), timeout: timeout)
    }

    /// JSON 본문을 싣는 동기 POST. 응답 처리는 GET과 같다.
    static func postJSON(
        _ url: URL,
        body: [String: Any],
        headers: [String: String],
        timeout: TimeInterval = 10
    ) throws -> [String: Any] {
        try send(jsonPostRequest(url, body: body, headers: headers, timeout: timeout), timeout: timeout)
    }

    static func jsonPostRequest(
        _ url: URL,
        body: [String: Any],
        headers: [String: String],
        timeout: TimeInterval = 10
    ) throws -> URLRequest {
        guard let data = try? JSONSerialization.data(withJSONObject: body) else {
            throw LiveUsageError.decode("요청 본문을 JSON으로 만들지 못함")
        }
        var headers = headers
        if headers["Content-Type"] == nil {
            headers["Content-Type"] = "application/json"
        }
        return request(url, method: "POST", headers: headers, body: data, timeout: timeout)
    }

    /// 요청을 조립한다. User-Agent는 호출자가 넘길 때만 바꾸고, 아니면 URLSession 기본값이다.
    /// 다른 클라이언트로 위장하지 않는다. 네트워크 없이 검증할 수 있게 전송과 분리했다.
    static func request(
        _ url: URL,
        method: String,
        headers: [String: String],
        body: Data?,
        timeout: TimeInterval
    ) -> URLRequest {
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = method
        request.httpBody = body
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        return request
    }

    private static func send(_ request: URLRequest, timeout: TimeInterval) throws -> [String: Any] {
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

// MARK: - Gemini (Antigravity CLI)

/// Antigravity CLI(`agy`)의 구독 한도를 Google Cloud Code 내부 엔드포인트에서 읽는다.
///
/// `agy -p /usage`가 쓰는 것과 같은 경로다. 문서화된 공개 API가 아니라 언제든 바뀔 수 있다.
/// 로컬 기록으로 추정할 길이 없어서(대화 기록이 SQLite 안의 protobuf다) 실패하면 마지막
/// 관측값으로만 물러난다.
public struct GeminiLiveClient: LiveUsageFetching {
    public static let quotaEndpoint = URL(
        string: "https://daily-cloudcode-pa.googleapis.com/v1internal:retrieveUserQuotaSummary"
    )!
    public static let loadCodeAssistEndpoint = URL(
        string: "https://daily-cloudcode-pa.googleapis.com/v1internal:loadCodeAssist"
    )!

    public init() {}

    public func fetch(now: Date = Date()) throws -> LiveUsageResult {
        let credentials = try Credentials.gemini(now: now)
        // 토큰은 1시간이면 죽고 agy를 실행해야만 살아난다. 죽은 토큰으로 서버를 두드려 봐야
        // 401만 돌아오므로 네트워크를 타지 않는다.
        if credentials.isExpired(at: now) {
            throw LiveUsageError.tokenExpired
        }
        let headers = Self.headers(accessToken: credentials.accessToken)

        let summary: [String: Any]
        do {
            summary = try HTTP.postJSON(Self.quotaEndpoint, body: [:], headers: headers)
        } catch LiveUsageError.httpStatus(let code) where code == 401 || code == 403 {
            // 들고 있던 토큰이 죽었다. 캐시를 비워 다음 조회가 키체인을 다시 읽게 한다.
            Credentials.invalidateGeminiCache()
            throw LiveUsageError.httpStatus(code)
        }

        // 창부터 확인한다. 응답이 비었으면 플랜 이름을 물으러 한 번 더 나갈 이유가 없다.
        let windows = try Self.nonEmptyWindows(fromSummary: summary)
        return LiveUsageResult(
            windows: windows,
            planLabel: Self.planLabel(headers: headers, now: now),
            fetchedAt: now
        )
    }

    /// 서버가 요구하는 제품 식별을 담은 User-Agent.
    ///
    /// 이 엔드포인트는 토큰만으로 통과시키지 않는다. User-Agent에 `antigravity`가 들어 있지
    /// 않으면 유효한 토큰에도 403("You do not have a valid license of this product")을 준다
    /// (2026-10 실측: URLSession 기본값·`AIUsageBar/1` → 403, `antigravity`가 어디든 들어 있으면 200).
    /// agy인 척하지 않고 앱 이름을 앞에 밝힌 채 어느 제품의 한도를 읽는지만 덧붙인다.
    static let userAgent = "AIUsageBar (antigravity)"

    static func headers(accessToken: String) -> [String: String] {
        ["Authorization": "Bearer \(accessToken)", "User-Agent": userAgent]
    }

    // MARK: 한도 요약

    /// `windows(fromSummary:)`와 같되, 창이 하나도 없으면 해석 실패로 본다.
    static func nonEmptyWindows(fromSummary summary: [String: Any]) throws -> [LiveLimitWindow] {
        let windows = windows(fromSummary: summary)
        guard !windows.isEmpty else {
            throw LiveUsageError.decode("한도 정보가 비어 있음")
        }
        return windows
    }

    /// 요약 응답을 게이지 창으로 바꾼다.
    ///
    /// 그룹은 응답 순서를 따르고, 그룹 안에서는 5시간 → 일간 → 주간 → 기타 순으로 놓는다.
    /// 첫 창이 메뉴바 대표값이 되므로 "5시간 (Gemini)"이 맨 앞에 와야 한다 — 응답은 주간을
    /// 먼저 준다. Antigravity는 Claude·GPT 모델에 별도 풀을 주므로 0%여도 두 그룹을 모두
    /// 보여준다. 일부러 그 풀을 골라 쓰는 사용자에게는 그쪽 숫자가 본론이다.
    static func windows(fromSummary summary: [String: Any]) -> [LiveLimitWindow] {
        guard let groups = summary["groups"] as? [[String: Any]] else { return [] }
        var result = [LiveLimitWindow]()
        for group in groups {
            guard let buckets = group["buckets"] as? [[String: Any]] else { continue }
            let groupName = groupLabel(group["displayName"] as? String)
            let ranked = buckets.enumerated().compactMap { index, bucket -> (rank: Int, index: Int, window: LiveLimitWindow)? in
                guard let parsed = window(fromBucket: bucket, group: groupName) else { return nil }
                return (parsed.rank, index, parsed.window)
            }
            result += ranked.sorted { ($0.rank, $0.index) < ($1.rank, $1.index) }.map(\.window)
        }
        return result
    }

    /// 버킷 하나를 창으로 바꾼다. `rank`는 그룹 안 정렬 순서다.
    static func window(fromBucket bucket: [String: Any], group: String?) -> (rank: Int, window: LiveLimitWindow)? {
        let window = (bucket["window"] as? String)?.lowercased()
        // 버킷인지는 식별 필드로 판단한다. remainingFraction 유무로 거르면 아래의
        // "다 쓴 버킷"을 놓친다.
        guard window != nil || bucket["bucketId"] is String else { return nil }

        // Google API는 proto3 JSON이라 값이 0인 필드를 아예 생략한다. 한도를 다 쓴 버킷은
        // remainingFraction 키 자체가 없을 수 있다 — 없다는 건 "남은 0", 곧 100% 사용이다.
        // 모르는 값으로 보고 건너뛰면 정작 한도에 걸린 순간 게이지가 사라진다.
        let remaining = min(1, max(0, HTTP.double(bucket["remainingFraction"]) ?? 0))

        let rank: Int
        let name: String
        switch window {
        case "5h": (rank, name) = (0, "5시간")
        case "daily": (rank, name) = (1, "일간")
        case "weekly": (rank, name) = (2, "주간")
        default:
            rank = 3
            name = bucket["displayName"] as? String ?? bucket["bucketId"] as? String ?? window ?? "한도"
        }

        // 안 쓴 버킷(남은 비율 1)의 resetTime은 조회할 때마다 now + 창 길이로 미끄러진다.
        // 예약된 리셋이 아니라 "지금 쓰기 시작하면 그때부터"라는 뜻이라 보여주면 오해만 산다.
        var resetsAt: Date?
        if remaining < 1, let text = bucket["resetTime"] as? String {
            resetsAt = ISO8601.parse(text)
        }

        let label = group.map { "\(name) (\($0))" } ?? name
        return (rank, LiveLimitWindow(label: label, percent: (1 - remaining) * 100, resetsAt: resetsAt))
    }

    /// "Gemini Models" → "Gemini", "Claude and GPT models" → "Claude·GPT".
    /// 모르는 그룹은 끝의 " models"만 떼고 그대로 쓴다.
    static func groupLabel(_ displayName: String?) -> String? {
        guard let name = displayName?.trimmingCharacters(in: .whitespaces), !name.isEmpty else {
            return nil
        }
        if name.range(of: "Gemini", options: .caseInsensitive) != nil {
            return "Gemini"
        }
        if name.caseInsensitiveCompare("Claude and GPT models") == .orderedSame {
            return "Claude·GPT"
        }
        for suffix in [" models", " Models"] where name.hasSuffix(suffix) {
            return String(name.dropLast(suffix.count))
        }
        return name
    }

    // MARK: 플랜 이름

    #if arch(arm64)
    private static let platform = "DARWIN_ARM64"
    #else
    private static let platform = "DARWIN_AMD64"
    #endif

    /// agy가 플랜을 물을 때 보내는 것과 같은 본문.
    static var loadCodeAssistBody: [String: Any] {
        ["metadata": ["ideType": "ANTIGRAVITY", "platform": platform, "pluginType": "GEMINI"]]
    }

    private static let planLock = NSLock()
    private static var planAttemptedAt: Date?
    private static var cachedPlanLabel: String?

    /// 플랜 이름을 받지 못했을 때 다시 묻기까지 기다리는 시간.
    static let planRetryInterval: TimeInterval = 3600

    /// 플랜 이름은 **한 번 받으면 다시 묻지 않는다.**
    ///
    /// 한도와 무관한 계정 정보라 수명 동안 바뀌지 않는다고 보고, 응답에 사용자 이메일까지
    /// 실려 오므로 필요 이상으로 받지 않는다. 받지 못했으면 한 시간 뒤에 다시 묻는다 — 매
    /// 조회마다 묻기엔 요청이 아깝고, 아예 안 물으면 네트워크가 한 번 끊긴 것만으로 메뉴바 앱이
    /// 떠 있는 며칠 내내 배지가 빠진다. 실패는 조회 전체를 실패시키지 않는다.
    static func planLabel(headers: [String: String], now: Date = Date()) -> String? {
        planLock.lock()
        if let cachedPlanLabel {
            planLock.unlock()
            return cachedPlanLabel
        }
        if let planAttemptedAt, now.timeIntervalSince(planAttemptedAt) < planRetryInterval {
            planLock.unlock()
            return nil
        }
        planAttemptedAt = now
        planLock.unlock()

        // 네트워크를 기다리는 동안 락을 쥐지 않는다. 그 사이 다른 호출은 nil을 받는다.
        let label = (try? HTTP.postJSON(Self.loadCodeAssistEndpoint, body: loadCodeAssistBody, headers: headers))
            .flatMap { planLabel(fromLoadCodeAssist: $0) }

        planLock.lock()
        defer { planLock.unlock() }
        if let label {
            cachedPlanLabel = label
        }
        return label
    }

    /// 유료 등급(`paidTier`) 이름을, 없으면 현재 등급(`currentTier`) 이름을 쓴다.
    /// 응답에 실린 이메일 등 나머지는 꺼내지도 남기지도 않는다.
    static func planLabel(fromLoadCodeAssist object: [String: Any]) -> String? {
        for key in ["paidTier", "currentTier"] {
            if let name = (object[key] as? [String: Any])?["name"] as? String, !name.isEmpty {
                return name
            }
        }
        return nil
    }
}
