import Foundation

/// 파일 하나의 읽기 위치. 이미 읽은 바이트는 다시 읽지 않는다.
public struct FileCursor: Codable, Sendable, Equatable {
    public var size: Int64
    public var modified: Double
    /// 완결된 줄까지만 소비한 오프셋. 잘린 마지막 줄은 다음 스캔에서 다시 읽는다.
    public var offset: Int64

    public init(size: Int64, modified: Double, offset: Int64) {
        self.size = size
        self.modified = modified
        self.offset = offset
    }
}

/// NDJSON(줄 단위 JSON) 파일을 증분으로 읽는다.
///
/// 전체 489MB를 매번 파싱하면 느리지만, append된 부분만 읽으면 갱신 비용이 사실상 0이다.
public final class NDJSONScanner {
    private var cursors: [String: FileCursor]
    /// 커서가 바뀔 때마다 증가한다. 변경이 없으면 캐시를 다시 쓰지 않기 위한 값이다.
    public private(set) var revision = 0

    public init(cursors: [String: FileCursor] = [:]) {
        self.cursors = cursors
    }

    public var snapshotOfCursors: [String: FileCursor] { cursors }

    /// 더 이상 존재하지 않는 파일의 커서를 정리한다.
    public func pruneCursors(keeping paths: Set<String>) {
        let before = cursors.count
        cursors = cursors.filter { paths.contains($0.key) }
        if cursors.count != before { revision += 1 }
    }

    public func resetCursors() {
        cursors.removeAll()
        revision += 1
    }

    /// 마지막 스캔 이후 추가된 완결된 줄들을 돌려준다.
    ///
    /// 파일이 잘리거나 교체됐으면(크기가 오프셋보다 작아지면) 처음부터 다시 읽는다.
    public func newLines(at url: URL) throws -> [Data] {
        let path = url.path
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0

        var cursor = cursors[path] ?? FileCursor(size: 0, modified: 0, offset: 0)

        // 크기와 수정 시각이 모두 그대로면 읽을 것이 없다.
        if cursor.size == size, cursor.modified == modified, cursor.offset > 0 {
            return []
        }
        // 파일이 줄어들었으면 로테이션된 것으로 보고 처음부터 다시 읽는다.
        if size < cursor.offset {
            cursor.offset = 0
        }
        guard size > cursor.offset else {
            cursor.size = size
            cursor.modified = modified
            cursors[path] = cursor
            revision += 1
            return []
        }

        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(cursor.offset))
        guard let chunk = try handle.readToEnd(), !chunk.isEmpty else {
            cursor.size = size
            cursor.modified = modified
            cursors[path] = cursor
            revision += 1
            return []
        }

        let (lines, consumed) = Self.splitCompleteLines(chunk)
        cursor.offset += Int64(consumed)
        cursor.size = size
        cursor.modified = modified
        cursors[path] = cursor
        revision += 1
        return lines
    }

    /// 개행으로 끝나는 완결된 줄만 잘라낸다. 잘린 꼬리는 소비하지 않는다.
    static func splitCompleteLines(_ data: Data) -> (lines: [Data], consumed: Int) {
        var lines = [Data]()
        var lineStart = data.startIndex
        var consumed = 0

        for index in data.indices where data[index] == 0x0A {
            let line = data[lineStart..<index]
            if !line.isEmpty {
                lines.append(Data(line))
            }
            lineStart = data.index(after: index)
            consumed = lineStart - data.startIndex
        }
        return (lines, consumed)
    }
}

/// 로그 디렉토리에서 파일을 찾는다.
public enum LogFileFinder {
    /// `root` 아래에서 확장자가 맞고 `modifiedAfter` 이후에 수정된 파일 경로를 모은다.
    ///
    /// mtime 필터가 성능의 핵심이다. 3,175개 파일 중 최근 것만 열면 갱신이 즉시 끝난다.
    public static func files(
        under root: URL,
        pathExtension: String = "jsonl",
        modifiedAfter: Date? = nil
    ) -> [URL] {
        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return []
        }

        var result = [URL]()
        for case let url as URL in enumerator {
            guard url.pathExtension == pathExtension else { continue }
            guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey]),
                  values.isRegularFile == true
            else { continue }
            if let cutoff = modifiedAfter, let modified = values.contentModificationDate, modified < cutoff {
                continue
            }
            result.append(url)
        }
        return result
    }

    public static func modificationDate(of url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }
}
