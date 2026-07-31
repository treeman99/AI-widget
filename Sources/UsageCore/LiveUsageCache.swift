import Foundation

/// 실시간 조회 결과를 보관하고 호출 빈도를 제한한다.
///
/// 로컬 로그 스캔은 몇십 ms지만 네트워크 조회는 초 단위다(키체인 접근만으로도 프로세스당
/// 첫 회 몇 초가 걸린다). 그래서 조회는 **비동기로 던져두고 즉시 반환**하고, 화면에는
/// 직전 결과를 쓴다. 결과가 도착하면 `onUpdate`로 알린다.
public final class LiveUsageCache: @unchecked Sendable {
    private let fetcher: LiveUsageFetching
    private let queue: DispatchQueue
    private let lock = NSLock()

    private var storedResult: LiveUsageResult?
    private var storedError: LiveUsageError?
    private var lastAttemptAt: Date?
    private var isFetching = false

    /// 새 결과가 도착했을 때 호출된다. 임의의 큐에서 불린다.
    public var onUpdate: (@Sendable () -> Void)?

    private var storedInterval: TimeInterval

    public init(fetcher: LiveUsageFetching, interval: TimeInterval = 300, label: String = "live") {
        self.fetcher = fetcher
        self.storedInterval = interval
        self.queue = DispatchQueue(label: "AIUsageBar.live.\(label)", qos: .utility)
    }

    public var interval: TimeInterval {
        get { lock.withLock { storedInterval } }
        set { lock.withLock { storedInterval = newValue } }
    }

    /// 마지막으로 성공한 조회 결과. 실패해도 지우지 않는다 — 낡은 실측값이 추정치보다 낫다.
    public var result: LiveUsageResult? { lock.withLock { storedResult } }
    /// 마지막 시도에서 난 오류. 성공하면 nil로 되돌린다.
    public var lastError: LiveUsageError? { lock.withLock { storedError } }

    /// 간격이 지났으면 백그라운드에서 조회를 시작하고 **즉시 반환**한다.
    public func refreshIfNeeded(now: Date, force: Bool = false) {
        guard claimAttempt(now: now, force: force) else { return }
        queue.async { [weak self] in
            self?.performFetch(now: Date())
        }
    }

    /// 조회가 끝날 때까지 기다린다. 한 번 실행하고 끝나는 CLI에서 쓴다.
    public func refreshBlocking(now: Date, force: Bool = false) {
        guard claimAttempt(now: now, force: force) else { return }
        performFetch(now: now)
    }

    /// 지금 조회해야 하는지 판단하고, 해야 한다면 진행 중 표시를 세운다.
    private func claimAttempt(now: Date, force: Bool) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if isFetching { return false }
        if !force, let lastAttemptAt, now.timeIntervalSince(lastAttemptAt) < storedInterval {
            return false
        }
        lastAttemptAt = now
        isFetching = true
        return true
    }

    private func performFetch(now: Date) {
        var succeeded = false
        do {
            let fetched = try fetcher.fetch(now: now)
            lock.withLock {
                storedResult = fetched
                storedError = nil
                isFetching = false
            }
            succeeded = true
        } catch let error as LiveUsageError {
            lock.withLock {
                storedError = error
                isFetching = false
            }
        } catch {
            lock.withLock {
                storedError = .network(error.localizedDescription)
                isFetching = false
            }
        }
        if succeeded { onUpdate?() }
    }

    public func reset() {
        lock.withLock {
            storedResult = nil
            storedError = nil
            lastAttemptAt = nil
        }
    }

    /// 조회 결과를 게이지로 바꾼다.
    ///
    /// 방금 받은 값이면 `.live`, 조회에 실패해 예전 값을 재사용하는 중이면 `.snapshot`으로
    /// 표시해 사용자가 숫자의 나이를 알 수 있게 한다.
    public func gauges(now: Date, freshWithin: TimeInterval) -> [UsageGauge]? {
        guard let result = self.result else { return nil }
        let isFresh = now.timeIntervalSince(result.fetchedAt) <= freshWithin
        let source: GaugeSource = isFresh
            ? .live(fetchedAt: result.fetchedAt)
            : .snapshot(observedAt: result.fetchedAt)

        return result.windows.map { window in
            // 리셋 시각이 지났으면 한도는 이미 초기화됐다. 낡은 퍼센트를 그대로 두지 않는다.
            let expired = window.resetsAt.map { $0 <= now } ?? false
            return UsageGauge(
                percent: expired ? 0 : window.percent,
                source: source,
                windowLabel: window.label,
                resetsAt: expired ? nil : window.resetsAt
            )
        }
    }
}

extension NSLock {
    fileprivate func withLock<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}
