import Foundation

/// Claude Code / Codex / Antigravity CLI가 로그인할 때 저장해 둔 OAuth 자격증명을 **읽기만** 한다.
///
/// 토큰을 갱신하지는 않는다. 갱신은 refresh token을 회전시키기 때문에, 우리가 끼어들면
/// 각 CLI 자신의 세션을 깨뜨릴 수 있다. 만료되면 실시간 조회를 포기하고
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

    public struct Gemini: Sendable, Equatable {
        public let accessToken: String
        /// access token 수명은 1시간이고, agy가 실행될 때만 갱신된다.
        public let expiresAt: Date?

        public var isExpired: Bool { isExpired(at: Date()) }

        public func isExpired(at now: Date) -> Bool {
            guard let expiresAt else { return false }
            return expiresAt <= now
        }
    }

    // MARK: - Claude Code (키체인)

    /// 키체인 항목 이름. Claude Code가 로그인 시 여기에 저장한다.
    public static let claudeKeychainService = "Claude Code-credentials"

    /// 조회가 막힌 뒤 키체인을 다시 두드리기까지 기다리는 시간.
    ///
    /// 막혔다는 건 대개 로그인 키체인이 잠겨 있어 `security`가 잠금 해제 창을 띄웠다는
    /// 뜻이다. 다음 주기에 또 물어보면 같은 창이 5분마다 되돌아오므로 한동안 물러난다.
    /// 백오프는 항목이 아니라 키체인 단위다 (`readKeychainValue` 참고).
    public static let deniedBackoff: TimeInterval = 30 * 60

    /// `expiresAt`이 없는 항목을 만났을 때 캐시를 믿어 주는 시간.
    private static let blindCacheTTL: TimeInterval = 30 * 60

    /// 만료 직전이면 캐시를 버리고 다시 읽는다. Claude Code가 그 사이 갱신해 뒀을 값을 받는다.
    private static let expiryMargin: TimeInterval = 60

    private static let lock = NSLock()
    private static var cachedClaude: Claude?
    private static var cachedClaudeAt: Date?
    private static var cachedGemini: Gemini?
    private static var cachedGeminiAt: Date?
    /// 로그인 키체인 전체에 거는 백오프. Claude와 Gemini가 함께 쓴다.
    private static var keychainBackoffUntil: Date?

    /// 키체인에서 Claude Code 자격증명을 읽는다.
    ///
    /// `SecItem*`을 직접 부르지 않고 `/usr/bin/security`를 자식 프로세스로 띄운다.
    /// 우리가 직접 부르면 macOS가 접근 허용 창을 띄우는데, 그 창을 "항상 허용"으로 잠재울
    /// 방법이 없기 때문이다. 접근 판정은 항목 ACL만 보는 게 아니라 그와 별개인 partition
    /// list도 보는데, Claude Code가 토큰을 갱신할 때마다 `security`로 항목을 덮어써서
    /// partition list가 쓰는 도구의 파티션인 `apple-tool:` 하나로 리셋된다. 빌드할 때
    /// 등록해 둔 앱 cdhash는 그때 함께 지워지고, 자체 서명 인증서에는 팀 ID가 없어
    /// 재빌드에도 안 변하는 `teamid:`로 고정할 수도 없다.
    ///
    /// 거꾸로 `/usr/bin/security`는 그 리셋의 수혜자다. Claude Code 자신의 쓰기가 항목
    /// ACL에 `/usr/bin/security (OK)`를, partition list에 `apple-tool:`을 매번 다시
    /// 심어 준다. 우리가 관리할 빌드 시점 상태가 아예 없다 — 앱의 서명 신원은 이제 키체인
    /// 판정에 참여하지 않는다.
    ///
    /// 창이 사라졌어도 캐시와 백오프는 그대로 둔다. 로그인 키체인이 잠겨 있으면 이번엔
    /// `security` 쪽이 잠금 해제 창을 띄우고 무한정 기다리는데, 5분마다 그 창을 다시 띄우면
    /// 없애려던 문제가 형태만 바꿔 되돌아온다. 백오프의 트리거가 "사용자가 거부함"에서
    /// "조회가 멈춤"으로 옮겨갔을 뿐 역할은 같다.
    public static func claude(account: String = NSUserName(), now: Date = Date()) throws -> Claude {
        if let usable = usableCachedClaude(now: now) {
            return usable
        }

        let read = try readKeychainValue(
            service: claudeKeychainService,
            account: account,
            missingMessage: "Claude Code 로그인 정보를 찾지 못했습니다",
            now: now
        )
        guard let credentials = parseClaude(read.value) else {
            throw LiveUsageError.credentialsUnavailable("키체인 항목에서 accessToken을 찾지 못했습니다")
        }
        storeClaude(credentials, at: read.respondedAt)
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
    /// 30분을 기다리지 않는다. 백오프가 키체인 단위라 Claude와 Gemini가 함께 풀린다.
    public static func resetKeychainBackoff() {
        lock.lock()
        defer { lock.unlock() }
        keychainBackoffUntil = nil
    }

    /// 아직 쓸 수 있는 캐시. 만료됐거나 만료가 코앞이면 nil.
    private static func usableCachedClaude(now: Date) -> Claude? {
        lock.lock()
        defer { lock.unlock() }
        guard let cachedClaude, let cachedClaudeAt,
              isUsable(expiresAt: cachedClaude.expiresAt, cachedAt: cachedClaudeAt, now: now)
        else { return nil }
        return cachedClaude
    }

    private static func storeClaude(_ credentials: Claude, at date: Date) {
        lock.lock()
        defer { lock.unlock() }
        cachedClaude = credentials
        cachedClaudeAt = date
        // 읽기에 성공했다는 건 접근이 허용됐다는 뜻이다.
        keychainBackoffUntil = nil
    }

    /// 만료가 코앞이면 버리고 다시 읽는다. CLI가 그 사이 갱신해 뒀을 값을 받는다.
    private static func isUsable(expiresAt: Date?, cachedAt: Date, now: Date) -> Bool {
        if let expiresAt {
            return expiresAt.timeIntervalSince(now) > expiryMargin
        }
        // 만료 시각을 모르면 오래 믿지 않는다.
        return now.timeIntervalSince(cachedAt) < blindCacheTTL
    }

    // MARK: - Gemini / Antigravity CLI (키체인)

    /// Antigravity CLI(`agy`)가 로그인할 때 저장하는 항목. agy가 쓰는 zalando/go-keyring이
    /// `security add-generic-password -U -s gemini -a antigravity`로 쓴다.
    public static let geminiKeychainService = "gemini"
    public static let geminiKeychainAccount = "antigravity"

    /// 키체인에서 Antigravity CLI 자격증명을 읽는다.
    ///
    /// Claude와 같은 길(`/usr/bin/security`)을 탄다. go-keyring도 저장할 때 `security`를
    /// 띄우므로 agy가 쓸 때마다 항목 ACL에 `/usr/bin/security (OK)`가, partition list에
    /// `apple-tool:`이 다시 심긴다 — 창 없이 읽히는 이유가 Claude와 똑같다.
    ///
    /// access token은 1시간이면 죽고 agy가 실행될 때만 갱신된다. 그래도 직접 갱신하지 않는다
    /// (파일 상단 원칙). 만료된 토큰도 그대로 돌려주고, 네트워크를 탈지는 호출자가 정한다.
    /// 만료가 코앞인 값은 캐시에서 내주지 않으므로, 만료된 동안에는 주기마다 키체인을 다시
    /// 읽어 agy가 그 사이 갱신해 둔 토큰을 바로 집어 온다.
    public static func gemini(now: Date = Date()) throws -> Gemini {
        if let usable = usableCachedGemini(now: now) {
            return usable
        }

        let read = try readKeychainValue(
            service: geminiKeychainService,
            account: geminiKeychainAccount,
            missingMessage: "Antigravity CLI 로그인 정보를 찾지 못했습니다 (agy로 로그인하세요)",
            now: now
        )
        guard let credentials = parseGemini(read.value) else {
            throw LiveUsageError.credentialsUnavailable("키체인 항목에서 access_token을 찾지 못했습니다")
        }
        storeGemini(credentials, at: read.respondedAt)
        return credentials
    }

    /// 서버가 토큰을 거부했다. 들고 있던 값은 죽었으므로 버린다.
    public static func invalidateGeminiCache() {
        lock.lock()
        defer { lock.unlock() }
        cachedGemini = nil
        cachedGeminiAt = nil
    }

    private static func usableCachedGemini(now: Date) -> Gemini? {
        lock.lock()
        defer { lock.unlock() }
        guard let cachedGemini, let cachedGeminiAt,
              isUsable(expiresAt: cachedGemini.expiresAt, cachedAt: cachedGeminiAt, now: now)
        else { return nil }
        return cachedGemini
    }

    private static func storeGemini(_ credentials: Gemini, at date: Date) {
        lock.lock()
        defer { lock.unlock() }
        cachedGemini = credentials
        cachedGeminiAt = date
        keychainBackoffUntil = nil
    }

    // MARK: - 키체인 공통

    /// `security find-generic-password`로 항목 값 하나를 읽는다.
    ///
    /// 백오프는 항목이 아니라 **키체인 단위**로 공유한다. 잠긴 로그인 키체인은 어느 항목을
    /// 읽든 같은 잠금 해제 창을 띄운다. 항목마다 따로 물러나면 Claude 조회가 막혀 물러난
    /// 직후 Gemini 조회가 같은 창을 다시 띄운다 — 없애려던 창이 두 배로 돌아온다.
    private static func readKeychainValue(
        service: String,
        account: String,
        missingMessage: String,
        now: Date
    ) throws -> (value: Data, respondedAt: Date) {
        if let until = backoffDeadline(), until > now {
            let minutes = max(1, Int((until.timeIntervalSince(now) / 60).rounded(.up)))
            throw LiveUsageError.credentialsUnavailable(
                "키체인 조회가 막혀 있습니다 — \(minutes)분 후 다시 시도합니다"
            )
        }

        // 빈 문자열은 필터 해제로 해석된다. 그대로 넘기면 `security`가 아무 항목이나 잡고
        // 그 항목의 승인 창에 걸려 멈춘다. 자식을 띄우기 전에 끊는다.
        guard !account.isEmpty else {
            throw LiveUsageError.credentialsUnavailable("사용자 계정 이름을 확인하지 못했습니다")
        }

        let run: SecurityRun
        do {
            run = try runSecurity([
                "find-generic-password",
                "-s", service,  // 정확 일치다. Claude Code가 만드는 접미사 붙은 항목 수백 개는 안 걸린다.
                "-a", account,
                "-w",           // 값은 stdout으로만 온다. `-g`는 stderr로 흘리므로 쓰지 않는다.
            ])
        } catch SecurityFailure.stalled {
            beginBackoff(from: Date())
            throw LiveUsageError.credentialsUnavailable(
                "키체인이 응답하지 않아 조회를 중단했습니다 (키체인이 잠겨 있을 수 있습니다)"
            )
        } catch SecurityFailure.launch(let detail) {
            // 다시 시도해도 같겠지만 백오프는 걸지 않는다. 계속 보이는 편이 낫다.
            throw LiveUsageError.credentialsUnavailable("security를 실행하지 못했습니다: \(detail)")
        }

        // 잠금 해제 창이 떠 있었다면 위 호출이 그만큼 오래 걸렸다. `now`는 낡았으므로 캐시
        // 시각은 여기서 다시 읽는다. 그러지 않으면 캐시가 세워지자마자 만료될 수 있다.
        let respondedAt = Date()

        guard run.status == 0 else {
            switch run.status {
            case SecurityExit.itemNotFound:
                // 항목 없음, 키체인 파일 없음, HOME이 어긋남이 모두 이 코드로 온다. 사용자가
                // 취할 행동이 같으므로 구분하지 않는다. 백오프도 걸지 않는다 — 창을 띄우지
                // 않고 즉시 끝나므로, 다시 로그인하면 다음 주기에 저절로 복구된다.
                throw LiveUsageError.credentialsUnavailable(missingMessage)
            case SecurityExit.userCanceled, SecurityExit.authFailed, SecurityExit.interactionNotAllowed:
                beginBackoff(from: respondedAt)
                throw LiveUsageError.credentialsUnavailable("키체인 접근이 거부됐습니다")
            default:
                // stderr는 "security: <함수>: <메시지>" 꼴이고, `-w`를 쓰는 한 비밀이 실리지 않는다.
                let detail = String(data: run.errors, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                throw LiveUsageError.credentialsUnavailable(
                    "키체인 오류: " + (detail.isEmpty ? "security 종료 코드 \(run.status)" : detail)
                )
            }
        }

        return (run.output, respondedAt)
    }

    private static func beginBackoff(from now: Date) {
        lock.lock()
        defer { lock.unlock() }
        keychainBackoffUntil = now.addingTimeInterval(deniedBackoff)
    }

    private static func backoffDeadline() -> Date? {
        lock.lock()
        defer { lock.unlock() }
        return keychainBackoffUntil
    }

    // MARK: - security(1) 호출

    /// `/usr/bin/security` 절대 경로. PATH도 셸도 거치지 않는다.
    ///
    /// 셸을 안 거치니 서비스 이름에 공백이 있어도 인용이 필요 없고, PATH에 심어진 가짜
    /// `security`가 위조한 토큰을 돌려주는 경로도 원천 차단된다.
    private static let securityTool = URL(fileURLWithPath: "/usr/bin/security")

    /// 자식이 응답하지 않을 때 포기하기까지의 시간.
    ///
    /// 정상 조회는 수십 ms에 끝난다. 이걸 넘겼다는 건 `security`가 잠금 해제 창을 띄우고
    /// 사용자를 기다리고 있다는 뜻이다. `LiveUsageCache`에는 조회 타임아웃이 없고
    /// `isFetching`이 재진입을 막으므로, 여기서 끊지 않으면 실시간 조회가 영영 멈춘다
    /// (`usagectl`은 동기로 기다리므로 CLI 자체가 멈춘다).
    private static let securityTimeout: TimeInterval = 10

    /// 자식의 stdout을 무한정 믿지 않는다. 정상 페이로드는 8KB 남짓이다.
    private static let maxOutputBytes = 1 << 20

    /// `security`는 실패한 `OSStatus`의 **하위 1바이트**를 종료 코드로 쓴다.
    ///
    /// 실측: `errSecItemNotFound`(-25300 = 0xFFFF9D2C) → 0x2C = 44.
    /// 같은 방식으로 `errSecInteractionNotAllowed`(-25308) → 36,
    /// `errSecAuthFailed`(-25293) → 51, `errSecUserCanceled`(-128) → 128.
    ///
    /// 256마다 충돌하므로 종료 코드에서 원래 상태를 역산할 수는 없다. 아는 값만 분류하고
    /// 나머지는 stderr를 그대로 싣는다. 128이 셸의 "시그널로 죽음" 관례와 겹쳐 보이지만,
    /// 시그널 종료는 `terminationReason` 검사에서 먼저 걸러진다.
    private enum SecurityExit {
        static let interactionNotAllowed: Int32 = 36
        static let itemNotFound: Int32 = 44
        static let authFailed: Int32 = 51
        static let userCanceled: Int32 = 128
    }

    private struct SecurityRun {
        let output: Data
        let errors: Data
        let status: Int32
    }

    private enum SecurityFailure: Error {
        case launch(String)
        /// 시간 안에 끝나지 않았거나 시그널로 죽었다. 어느 쪽이든 "멈췄다"로 취급한다.
        case stalled
    }

    /// 두 파이프를 동시에 비우는 동안 쓰기 대상이 되는 버퍼.
    private final class OutputBuffer: @unchecked Sendable {
        private let lock = NSLock()
        private var storage = Data()

        func append(_ chunk: Data) {
            lock.lock()
            defer { lock.unlock() }
            // 상한을 넘으면 더 담지 않는다. 그래도 읽기는 계속해야 자식이 파이프에 막히지 않는다.
            if storage.count < Credentials.maxOutputBytes {
                storage.append(chunk)
            }
        }

        var data: Data {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }
    }

    private static func runSecurity(_ arguments: [String]) throws -> SecurityRun {
        let process = Process()
        process.executableURL = securityTool
        process.arguments = arguments
        // `usagectl`을 터미널에서 돌릴 때 자식이 사용자의 stdin을 삼키지 못하게 한다.
        process.standardInput = FileHandle.nullDevice

        // HOME은 물려받지 않고 passwd에서 직접 뽑는다. HOME이 아예 없으면 `security`가
        // 세션에서 키체인을 찾아내 정상 동작하지만, **엉뚱한 곳을 가리키면** 로그인 키체인을
        // 못 찾아 exit 44로 조용히 실패한다 — 진짜 로그아웃과 구분이 안 되는 코드다.
        // PATH는 절대 경로로 실행하니 쓰이지 않지만 위생상 고정한다.
        process.environment = ["HOME": loginHomeDirectory(), "PATH": "/usr/bin:/bin"]

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        // `waitUntilExit()`은 이미 끝난 프로세스에도 런루프를 돌려 80ms 넘게 잡아먹는다
        // (실측 중앙값 106ms 대 21ms). 종료 통지로 거두면 그만큼 빠르다. 이 방식을 쓸 때는
        // `waitUntilExit()`을 함께 부르지 않는다.
        let reaped = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in reaped.signal() }

        do {
            try process.run()
        } catch {
            throw SecurityFailure.launch(error.localizedDescription)
        }

        // stdout과 stderr를 **동시에** 비운다. 한쪽만 읽으면 다른 쪽 파이프 버퍼(64KiB)가
        // 차는 순간 서로를 기다리며 교착한다.
        //
        // 타임아웃도 읽기 뒤가 아니라 이 배수 자체에 건다. 멈춤이란 자식이 아무것도 쓰지 않고
        // 파이프도 닫지 않는 상태라, 읽기 뒤에 두면 그 코드에 도달조차 못 한다.
        let output = OutputBuffer()
        let errors = OutputBuffer()
        let drained = DispatchGroup()
        let queue = DispatchQueue(label: "AIUsageBar.security.drain", attributes: .concurrent)
        queue.async(group: drained) { drain(outPipe.fileHandleForReading, into: output) }
        queue.async(group: drained) { drain(errPipe.fileHandleForReading, into: errors) }

        var stalled = false
        if drained.wait(timeout: .now() + securityTimeout) == .timedOut {
            stalled = true
            // SIGTERM이면 떠 있던 창도 함께 닫히고 파이프가 EOF로 풀린다. 손자 프로세스가
            // 파이프를 물고 있는 경우까지 대비해 그래도 안 풀리면 SIGKILL로 간다.
            process.terminate()
            if drained.wait(timeout: .now() + 2) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                drained.wait()
            }
        }
        reaped.wait()

        // Foundation은 Pipe의 읽기 끝을 닫아 주지 않는다. 명시적으로 닫지 않으면 호출당 fd가
        // 2개씩 새어 200회에 4→404까지 늘어난다(실측). GUI 앱이 launchd에서 물려받는 soft
        // limit이 256이라, 5분 주기면 반나절 만에 앱의 모든 fd 요구가 실패한다. 테스트도
        // 데모도 통과하고 나서 반나절 뒤에 죽는 종류의 버그다.
        try? outPipe.fileHandleForReading.close()
        try? errPipe.fileHandleForReading.close()

        // 시그널로 죽었으면 `terminationStatus`는 시그널 번호다. OSStatus에서 온 코드와
        // 섞이지 않게 여기서 먼저 걸러낸다.
        guard !stalled, process.terminationReason == .exit else {
            throw SecurityFailure.stalled
        }
        return SecurityRun(output: output.data, errors: errors.data, status: process.terminationStatus)
    }

    private static func drain(_ handle: FileHandle, into buffer: OutputBuffer) {
        while let chunk = try? handle.read(upToCount: 64 * 1024), !chunk.isEmpty {
            buffer.append(chunk)
        }
    }

    /// 환경변수가 아니라 passwd에서 홈 경로를 얻는다.
    private static func loginHomeDirectory() -> String {
        if let entry = getpwuid(getuid()), let directory = entry.pointee.pw_dir {
            return String(cString: directory)
        }
        return NSHomeDirectory()
    }

    /// `security … -w`가 낸 바이트에서 자격증명을 뽑는다.
    ///
    /// 값에 인쇄 가능 ASCII(0x20~0x7E) 밖의 바이트가 **하나라도** 있으면 `security`는 값
    /// 전체를 소문자 hex 한 줄로 바꿔 낸다. 어느 쪽이든 끝에 개행 하나를 붙인다.
    ///
    /// ```
    /// $ security add-generic-password -s Korean -a me -w '{"a":"한글"}' …
    /// $ security find-generic-password -s Korean -a me -w …
    /// 7b2261223a22ed959ceab880227d
    /// ```
    ///
    /// 지금 Claude Code가 쓰는 JSON은 전부 인쇄 가능 ASCII라 원문이 나오지만, 그 안에는
    /// 사용자가 붙인 MCP 서버 이름이 들어간다 — 한글 이름 하나면 형식이 통째로 바뀐다.
    /// 그때 실패하면 배지가 조용히 '추정'으로 내려갈 뿐이라 사용자가 원인을 알 길이 없다.
    ///
    /// JSON으로 먼저 읽어 보고 실패했을 때만 hex를 푼다. 순서가 이래야 `deadbeef`처럼
    /// hex로도 읽히는 평문을 잘못 해독하지 않는다.
    ///
    /// 키체인 없이 테스트할 수 있도록 순수 함수로 떼어 놨다.
    static func parseClaude(_ raw: Data) -> Claude? {
        var bytes = raw
        while let last = bytes.last, last == 0x0a || last == 0x0d { bytes.removeLast() }
        guard !bytes.isEmpty else { return nil }  // 항목은 있는데 값이 비었다

        guard let oauth = claudeOAuth(in: bytes) ?? hexDecoded(bytes).flatMap({ claudeOAuth(in: $0) }),
              let token = oauth["accessToken"] as? String, !token.isEmpty
        else { return nil }

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

    private static func claudeOAuth(in data: Data) -> [String: Any]? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return root["claudeAiOauth"] as? [String: Any]
    }

    /// `security`는 소문자 hex만 낸다.
    private static func hexDecoded(_ ascii: Data) -> Data? {
        guard ascii.count >= 2, ascii.count % 2 == 0 else { return nil }
        var decoded = Data(capacity: ascii.count / 2)
        var high: UInt8?
        for byte in ascii {
            let nibble: UInt8
            switch byte {
            case 0x30...0x39: nibble = byte - 0x30       // 0-9
            case 0x61...0x66: nibble = byte - 0x61 + 10  // a-f
            default: return nil                          // hex가 아니다 → 원문이었다
            }
            if let pending = high {
                decoded.append(pending << 4 | nibble)
                high = nil
            } else {
                high = nibble
            }
        }
        return high == nil ? decoded : nil
    }

    /// go-keyring이 값을 감쌀 때 붙이는 접두사. 현행판은 base64, 구버전은 hex다.
    private static let goKeyringBase64Prefix = Data("go-keyring-base64:".utf8)
    private static let goKeyringHexPrefix = Data("go-keyring-encoded:".utf8)

    /// `security … -w`가 낸 바이트에서 Antigravity CLI 자격증명을 뽑는다.
    ///
    /// agy가 쓰는 go-keyring은 값을 `go-keyring-base64:` + base64(JSON)로 감싸 저장한다.
    /// 구버전은 `go-keyring-encoded:` + hex(JSON)였고, 접두사가 없으면 원문 JSON이다.
    /// go-keyring이 굳이 감싸는 이유가 `security`의 hex 변환(`parseClaude` 참고)을 피하려는
    /// 것이라 현행판 값은 늘 원문으로 나온다. 그래도 접두사 없는 원문에 비인쇄 바이트가 섞이면
    /// 같은 변환을 타므로 `parseClaude`와 같은 순서로 방어한다 — 그대로 읽어 보고, 실패했을
    /// 때만 hex를 푼 뒤 다시 읽는다.
    ///
    /// JSON에는 refresh_token도 들어 있지만 꺼내지 않는다. 갱신하지 않을 값을 메모리에
    /// 들고 있을 이유가 없다.
    ///
    /// 키체인 없이 테스트할 수 있도록 순수 함수로 떼어 놨다.
    static func parseGemini(_ raw: Data) -> Gemini? {
        // go-keyring의 Get도 앞뒤 공백을 걷어낸 뒤 접두사를 본다.
        let bytes = trimmingASCIIWhitespace(raw)
        guard !bytes.isEmpty else { return nil }  // 항목은 있는데 값이 비었다

        guard let token = geminiToken(in: bytes) ?? hexDecoded(bytes).flatMap({ geminiToken(in: $0) }),
              let accessToken = token["access_token"] as? String, !accessToken.isEmpty
        else { return nil }

        // Go의 time.Time 직렬화라 "2026-10-09T18:40:00.185665+09:00"처럼 소수 6자리와 지역
        // 오프셋이 붙는다. 0001-01-01은 Go의 zero time으로, oauth2에서 "만료 없음"이란
        // 뜻이지 "이미 만료"가 아니다 — 모르는 것으로 둔다.
        var expiresAt: Date?
        if let text = token["expiry"] as? String,
           let date = ISO8601.parse(text),
           date > Date(timeIntervalSince1970: 0) {
            expiresAt = date
        }

        return Gemini(accessToken: accessToken, expiresAt: expiresAt)
    }

    /// go-keyring 포장을 벗기고 `token` 객체를 꺼낸다.
    private static func geminiToken(in data: Data) -> [String: Any]? {
        let json: Data
        if data.starts(with: goKeyringBase64Prefix) {
            guard let decoded = Data(base64Encoded: Data(data.dropFirst(goKeyringBase64Prefix.count))) else {
                return nil
            }
            json = decoded
        } else if data.starts(with: goKeyringHexPrefix) {
            // Go의 hex.EncodeToString은 소문자만 낸다.
            guard let decoded = hexDecoded(Data(data.dropFirst(goKeyringHexPrefix.count))) else {
                return nil
            }
            json = decoded
        } else {
            json = data
        }
        guard let root = try? JSONSerialization.jsonObject(with: json) as? [String: Any] else {
            return nil
        }
        return root["token"] as? [String: Any]
    }

    private static func trimmingASCIIWhitespace(_ data: Data) -> Data {
        func isSpace(_ byte: UInt8) -> Bool {
            byte == 0x20 || byte == 0x09 || byte == 0x0a || byte == 0x0d
        }
        guard let first = data.firstIndex(where: { !isSpace($0) }),
              let last = data.lastIndex(where: { !isSpace($0) })
        else { return Data() }
        return Data(data[first...last])
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
