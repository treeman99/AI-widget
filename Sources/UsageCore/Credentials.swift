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

    /// 키체인에서 Claude Code 자격증명을 읽는다.
    ///
    /// 다른 앱의 키체인 항목이라 macOS가 **최초 1회 접근 허용 창**을 띄운다.
    /// "항상 허용"을 누르면 이후에는 묻지 않는다(앱을 다시 빌드해 서명이 바뀌면 다시 묻는다).
    public static func claude(account: String = NSUserName()) throws -> Claude {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: claudeKeychainService,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
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

        return Claude(
            accessToken: token,
            expiresAt: expiresAt,
            subscriptionType: oauth["subscriptionType"] as? String,
            rateLimitTier: oauth["rateLimitTier"] as? String
        )
    }

    private static func keychainMessage(for status: OSStatus) -> String {
        switch status {
        case errSecItemNotFound:
            return "Claude Code 로그인 정보를 찾지 못했습니다"
        case errSecUserCanceled, errSecAuthFailed:
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
