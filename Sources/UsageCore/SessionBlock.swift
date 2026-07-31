import Foundation

/// Claude 구독의 5시간 사용 블록.
///
/// 한도는 롤링 5시간이 아니라 "첫 메시지에서 시작해 5시간 뒤 리셋되는 블록"으로 동작한다.
/// 블록은 시작 시각을 정시로 내림하고, 5시간이 지나거나 5시간 이상 공백이 생기면 새로 연다.
public struct SessionBlock: Sendable, Equatable {
    public let start: Date
    public let end: Date
    public let lastActivity: Date
    public let records: [UsageRecord]

    public init(start: Date, end: Date, lastActivity: Date, records: [UsageRecord]) {
        self.start = start
        self.end = end
        self.lastActivity = lastActivity
        self.records = records
    }

    public var weighted: Double { TokenWeight.weightedSum(records) }
    public var totals: TokenTotals { records.tokenTotals }

    public func isActive(now: Date) -> Bool { now < end }
}

public enum SessionBlocks {
    public static let defaultDuration: TimeInterval = 5 * 3600

    /// 시간순 정렬된 레코드를 블록으로 나눈다.
    public static func build(
        from records: [UsageRecord],
        duration: TimeInterval = defaultDuration
    ) -> [SessionBlock] {
        guard !records.isEmpty else { return [] }
        let sorted = records.sorted { $0.timestamp < $1.timestamp }

        var blocks = [SessionBlock]()
        var currentStart = floorToHour(sorted[0].timestamp)
        var currentRecords = [UsageRecord]()
        var lastActivity = sorted[0].timestamp

        for record in sorted {
            let exceededWindow = record.timestamp >= currentStart.addingTimeInterval(duration)
            let idleGap = record.timestamp.timeIntervalSince(lastActivity) >= duration

            if !currentRecords.isEmpty, exceededWindow || idleGap {
                blocks.append(
                    SessionBlock(
                        start: currentStart,
                        end: currentStart.addingTimeInterval(duration),
                        lastActivity: lastActivity,
                        records: currentRecords
                    )
                )
                currentStart = floorToHour(record.timestamp)
                currentRecords = []
            }
            currentRecords.append(record)
            lastActivity = record.timestamp
        }

        if !currentRecords.isEmpty {
            blocks.append(
                SessionBlock(
                    start: currentStart,
                    end: currentStart.addingTimeInterval(duration),
                    lastActivity: lastActivity,
                    records: currentRecords
                )
            )
        }
        return blocks
    }

    /// 지금 열려 있는 블록. 마지막 블록의 만료 시각이 지났으면 nil이다.
    public static func active(in blocks: [SessionBlock], now: Date) -> SessionBlock? {
        guard let last = blocks.last, last.isActive(now: now) else { return nil }
        return last
    }

    /// 정시로 내림. 블록 경계를 사람이 읽기 좋게 만든다.
    static func floorToHour(_ date: Date) -> Date {
        let seconds = date.timeIntervalSince1970
        return Date(timeIntervalSince1970: (seconds / 3600).rounded(.down) * 3600)
    }
}
