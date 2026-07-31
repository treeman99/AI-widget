import Combine
import Foundation
import UsageCore

/// UI가 관찰하는 상태. 스캔은 백그라운드 큐에서만 하고 결과만 메인으로 넘긴다.
@MainActor
final class UsageStore: ObservableObject {
    @Published private(set) var snapshot: UsageSnapshot?
    @Published private(set) var lastRefreshedAt: Date?
    @Published private(set) var isRefreshing = false
    @Published var config: AppConfig

    /// `monitor`는 이 큐에서만 만진다.
    private let workQueue = DispatchQueue(label: "AIUsageBar.usage", qos: .utility)
    private let monitor: UsageMonitor
    private var timer: Timer?
    private var watcher: FSEventsWatcher?
    /// 파일 변경이 몰릴 때 갱신이 겹치지 않게 한다.
    private var refreshPending = false
    /// 파일 변경으로 트리거된 갱신의 최소 간격. 활발히 작업 중일 때 초당 여러 번 도는 것을 막는다.
    private let watcherDebounce: TimeInterval = 3
    private var lastWatcherRefreshAt: Date?

    init() {
        let loaded = AppConfig.load()
        config = loaded
        monitor = UsageMonitor(config: loaded)
    }

    func start() {
        // 실시간 조회는 백그라운드에서 돌고, 결과가 도착하면 화면을 다시 그린다.
        monitor.onLiveUpdate = { [weak self] in
            Task { @MainActor in self?.refresh() }
        }
        scheduleTimer()
        startWatching()
        refresh()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        watcher?.stop()
        watcher = nil
    }

    // MARK: - 갱신

    func refresh() {
        guard !isRefreshing else {
            refreshPending = true
            return
        }
        isRefreshing = true
        let now = Date()
        workQueue.async { [monitor] in
            let result = monitor.refresh(now: now)
            let updatedConfig = monitor.config
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.snapshot = result
                self.lastRefreshedAt = result.generatedAt
                // 자동 캘리브레이션이 기준선을 올렸을 수 있어 설정을 다시 읽어온다.
                if updatedConfig != self.config {
                    self.config = updatedConfig
                }
                self.isRefreshing = false
                if self.refreshPending {
                    self.refreshPending = false
                    self.refresh()
                }
            }
        }
    }

    /// 캐시를 버리고 전체를 다시 읽는다.
    func fullRescan() {
        workQueue.async { [monitor] in
            monitor.claudeProvider.resetCache()
            monitor.codexProvider.resetCache()
        }
        refresh()
    }

    // MARK: - 설정

    func applyConfig(_ newConfig: AppConfig) {
        config = newConfig
        try? newConfig.save()
        workQueue.async { [monitor] in
            monitor.updateConfig(newConfig)
        }
        scheduleTimer()
        refresh()
    }

    // MARK: - 스케줄링

    private func scheduleTimer() {
        timer?.invalidate()
        let interval = max(10, config.refreshInterval)
        let created = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        // 팝오버가 열려 있을 때도 타이머가 계속 돌도록 common 모드에 등록한다.
        RunLoop.main.add(created, forMode: .common)
        timer = created
    }

    private func startWatching() {
        watcher?.stop()
        let created = FSEventsWatcher(
            paths: [Paths.claudeProjects.path, Paths.codexSessions.path]
        ) { [weak self] in
            Task { @MainActor in self?.refreshFromWatcher() }
        }
        created.start()
        watcher = created
    }

    /// 파일 변경 신호로 들어온 갱신. 연속 변경을 흘려보낸다.
    private func refreshFromWatcher() {
        let now = Date()
        if let last = lastWatcherRefreshAt, now.timeIntervalSince(last) < watcherDebounce {
            return
        }
        lastWatcherRefreshAt = now
        refresh()
    }
}
