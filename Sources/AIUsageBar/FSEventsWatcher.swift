import CoreServices
import Foundation

/// 로그 디렉토리를 재귀적으로 감시해 변경 즉시 갱신을 트리거한다.
///
/// 주기 타이머만으로는 최대 갱신 주기만큼 늦게 반영된다. Claude Code나 Codex가 로그를
/// 쓰는 순간 바로 숫자가 오르도록 FSEvents를 함께 쓴다.
final class FSEventsWatcher {
    private let paths: [String]
    private let latency: CFTimeInterval
    private let handler: () -> Void
    private let queue = DispatchQueue(label: "AIUsageBar.fsevents")
    private var stream: FSEventStreamRef?

    init(paths: [String], latency: CFTimeInterval = 2.0, handler: @escaping () -> Void) {
        // 존재하지 않는 경로를 넘기면 스트림 생성이 실패하므로 걸러낸다.
        self.paths = paths.filter { FileManager.default.fileExists(atPath: $0) }
        self.latency = latency
        self.handler = handler
    }

    func start() {
        guard stream == nil, !paths.isEmpty else { return }

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<FSEventsWatcher>.fromOpaque(info).takeUnretainedValue()
            watcher.handler()
        }

        // 파일 단위 이벤트는 세션 파일이 수천 개라 과하다. 디렉토리 단위 신호로 충분하다.
        guard let created = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            paths as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            latency,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagNoDefer)
        ) else { return }

        FSEventStreamSetDispatchQueue(created, queue)
        FSEventStreamStart(created)
        stream = created
    }

    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    deinit { stop() }
}
