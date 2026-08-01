import Foundation
import Security

/// Claude Code / Codex가 로그인할 때 저장해 둔 OAuth 자격증명을 **읽기만** 한다.
///
/// 토큰을 갱신하지는 않는다. 갱신은 refresh token을 회전시키기 때문에, 우리가 끼어들면
/// Claude Code나 Codex 자신의 세션을 깨뜨릴 수 있다. 만료되면 실시간 조회를 포기하고
/// 마지막 값이나 로컬 추정으로 물러난다.
public enum Credentials {

    public struct Claude: Sendable, Equatable {
        public let accessToken: String
        public let expiresAt: Date?
        /// "max", "pro" 등.
        public let subscriptionType: String?
        /// "default_claude_max_5x" 등.
        public let rateLimitTier: String?

        public var isExpired: Bool {
            guard let expiresAt else { return false }
            return expiresAt <= Date()
        }

        /// "Max 5x" 처럼 사람이 읽는 플랜 이름.
        public var planLabel: String? {
            if let tier = rateLimitTier {
                // default_claude_max_5x → Max 5x
                let cleaned = tier
                    .replacingOccurrences(of: "default_claude_", with: "")
                    .replacingOccurrences(of: "default_", with: "")
                if cleaned.hasPrefix("max_") {
                    return "Max " + cleaned.dropFirst(4).replacingOccurrences(of: "_", with: " ")
                }
                if !cleaned.isEmpty, cleaned != "default" {
                    return cleaned.replacingOccurrences(of: "_", with: " ").capitalized
                }
            }
            return subscriptionType?.capitalized
        }
    }

    public struct Codex: Sendable, Equatable {
        public let accessToken: String
        public let accountId: String?
    }

    // MARK: - Claude Code (키체인)

    /// 키체인 항목 이름. Claude Code가 로그인 시 여기에 저장한다.
    public static let claudeKeychainService = "Claude Code-credentials"

    /// 접근이 거부된 뒤 키체인을 다시 두드리기까지 기다리는 시간.
    ///
    /// 거부 직후 다음 주기에 또 물어보면 같은 창이 5분마다 되돌아온다. 창을 닫았다는 건
    /// 지금은 됐다는 뜻이므로 한동안 물러난다.
    public static let deniedBackoff: TimeInterval = 30 * 60

    /// `expiresAt`이 없는 항목을 만났을 때 캐시를 믿어 주는 시간.
    private static let blindCacheTTL: TimeInterval = 30 * 60

    /// 만료 직전이면 캐시를 버리고 다시 읽는다. Claude Code가 그 사이 갱신해 뒀을 값을 받는다.
    private static let expiryMargin: TimeInterval = 60

    private static let lock = NSLock()
    private static var cachedClaude: Claude?
    private static var cachedClaudeAt: Date?
    private static var claudeBackoffUntil: Date?

    /// 키체인에서 Claude Code 자격증명을 읽는다.
    ///
    /// 다른 앱이 만든 항목이라 macOS가 접근 허용 창을 띄운다. 창이 반복해서 뜨는 것을 막기 위해
    /// 두 가지를 한다 — 받은 토큰을 만료 시각까지 메모리에 들고 있어 갱신 주기마다만 읽고,
    /// 사용자가 창을 닫으면 `deniedBackoff` 동안 다시 묻지 않는다.
    ///
    /// 창이 아예 안 뜨게 하려면 앱이 안정된 서명을 가져야 한다. ad-hoc 서명은 designated
    /// requirement가 바이너리 해시라서 재빌드마다 "항상 허용" 기록이 무효가 된다.
    /// `scripts/create-signing-cert.sh` 참고.
    public static func claude(account: String = NSUserName(), now: Date = Date()) throws -> Claude {
        if let usable = usableCachedClaude(now: now) {
            return usable
        }

        if let until = backoffDeadline(), until > now {
            let minutes = max(1, Int((until.timeIntervalSince(now) / 60).rounded(.up)))
            throw LiveUsageError.credentialsUnavailable(
                "키체인 접근이 거부됐습니다 — \(minutes)분 후 다시 시도합니다"
            )
        }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: claudeKeychainService,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)

        // 접근 허용 창이 떠 있는 동안 위 호출은 무한정 블록된다(이 창에는 타임아웃이 없다).
        // `now`는 창이 뜨기 전 시각이라 그만큼 낡았으므로, 백오프와 캐시 시각은 여기서
        // 다시 읽는다. 그러지 않으면 창을 오래 놔뒀을 때 백오프가 세워지자마자 만료된다.
        let respondedAt = Date()

        // 사용자가 창을 닫았거나 시스템이 대화를 막았다. 잠시 물러난다.
        if status == errSecUserCanceled || status == errSecAuthFailed || status == errSecInteractionNotAllowed {
            beginBackoff(from: respondedAt)
        }

        guard status == errSecSuccess, let data = item as? Data else {
            throw LiveUsageError.credentialsUnavailable(Self.keychainMessage(for: status))
        }

        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = root["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String, !token.isEmpty
        else {
            throw LiveUsageError.credentialsUnavailable("키체인 항목에서 accessToken을 찾지 못했습니다")
        }

        // expiresAt은 밀리초 단위 epoch다.
        var expiresAt: Date?
        if let milliseconds = (oauth["expiresAt"] as? NSNumber)?.doubleValue {
            expiresAt = Date(timeIntervalSince1970: milliseconds / 1000)
        }

        let credentials = Claude(
            accessToken: token,
            expiresAt: expiresAt,
            subscriptionType: oauth["subscriptionType"] as? String,
            rateLimitTier: oauth["rateLimitTier"] as? String
        )
        storeClaude(credentials, at: respondedAt)
        return credentials
    }

    /// 서버가 토큰을 거부했다. 들고 있던 값은 죽었으므로 버린다.
    public static func invalidateClaudeCache() {
        lock.lock()
        defer { lock.unlock() }
        cachedClaude = nil
        cachedClaudeAt = nil
    }

    /// 사용자가 드롭다운의 '갱신'을 눌렀을 때 백오프를 걷어낸다
    /// (`UsageMonitor.forceLiveRefresh`가 부른다). 명시적으로 다시 시도하겠다는 뜻이므로
    /// 30분을 기다리지 않는다.
    public static func resetClaudeBackoff() {
        lock.lock()
        defer { lock.unlock() }
        claudeBackoffUntil = nil
    }

    /// 아직 쓸 수 있는 캐시. 만료됐거나 만료가 코앞이면 nil.
    private static func usableCachedClaude(now: Date) -> Claude? {
        lock.lock()
        defer { lock.unlock() }
        guard let cachedClaude, let cachedClaudeAt else { return nil }
        if let expiresAt = cachedClaude.expiresAt {
            return expiresAt.timeIntervalSince(now) > expiryMargin ? cachedClaude : nil
        }
        // 만료 시각을 모르면 오래 믿지 않는다.
        return now.timeIntervalSince(cachedClaudeAt) < blindCacheTTL ? cachedClaude : nil
    }

    private static func storeClaude(_ credentials: Claude, at date: Date) {
        lock.lock()
        defer { lock.unlock() }
        cachedClaude = credentials
        cachedClaudeAt = date
        // 읽기에 성공했다는 건 접근이 허용됐다는 뜻이다.
        claudeBackoffUntil = nil
    }

    private static func beginBackoff(from now: Date) {
        lock.lock()
        defer { lock.unlock() }
        claudeBackoffUntil = now.addingTimeInterval(deniedBackoff)
    }

    private static func backoffDeadline() -> Date? {
        lock.lock()
        defer { lock.unlock() }
        return claudeBackoffUntil
    }

    private static func keychainMessage(for status: OSStatus) -> String {
        switch status {
        case errSecItemNotFound:
            return "Claude Code 로그인 정보를 찾지 못했습니다"
        case errSecUserCanceled, errSecAuthFailed, errSecInteractionNotAllowed:
            return "키체인 접근이 거부됐습니다"
        default:
            let detail = SecCopyErrorMessageString(status, nil) as String? ?? "코드 \(status)"
            return "키체인 오류: \(detail)"
        }
    }

    // MARK: - Codex (auth.json)

    public static var codexAuthFile: URL {
        Paths.home.appendingPathComponent(".codex/auth.json")
    }

    public static func codex(at url: URL = Credentials.codexAuthFile) throws -> Codex {
        guard let data = try? Data(contentsOf: url) else {
            throw LiveUsageError.credentialsUnavailable("Codex 로그인 정보를 찾지 못했습니다")
        }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tokens = root["tokens"] as? [String: Any],
              let token = tokens["access_token"] as? String, !token.isEmpty
        else {
            throw LiveUsageError.credentialsUnavailable("auth.json에서 access_token을 찾지 못했습니다")
        }
        return Codex(accessToken: token, accountId: tokens["account_id"] as? String)
    }
}
