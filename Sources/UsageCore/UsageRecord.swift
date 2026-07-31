import Foundation

/// 로그에서 뽑아낸 사용량 레코드 하나.
///
/// `dedupKey`가 핵심이다. Claude Code는 세션 재개·컴팩션 때 이전 메시지를 다시 기록하기
/// 때문에 같은 API 응답이 여러 파일에 최대 7번까지 중복 등장한다. 이 키로 걸러내지 않으면
/// 사용량이 2배 가까이 부풀려진다.
public struct UsageRecord: Codable, Sendable, Equatable {
    public let timestamp: Date
    public let model: String
    public let input: Int
    public let output: Int
    public let cacheRead: Int
    public let cacheWrite5m: Int
    public let cacheWrite1h: Int
    /// `(requestId, message.id)` 조합. 둘 다 없으면 폴백 키를 쓴다.
    public let dedupKey: String

    public init(
        timestamp: Date,
        model: String,
        input: Int,
        output: Int,
        cacheRead: Int,
        cacheWrite5m: Int,
        cacheWrite1h: Int,
        dedupKey: String
    ) {
        self.timestamp = timestamp
        self.model = model
        self.input = input
        self.output = output
        self.cacheRead = cacheRead
        self.cacheWrite1h = cacheWrite1h
        self.cacheWrite5m = cacheWrite5m
        self.dedupKey = dedupKey
    }

    public var cacheWrite: Int { cacheWrite5m + cacheWrite1h }

    public var totals: TokenTotals {
        TokenTotals(input: input, output: output, cacheRead: cacheRead, cacheWrite: cacheWrite)
    }
}

extension Array where Element == UsageRecord {
    /// 시간순 정렬 + 중복 제거. 같은 키가 여러 번 나오면 첫 번째만 남긴다.
    public func deduplicatedByKey() -> [UsageRecord] {
        var seen = Set<String>()
        seen.reserveCapacity(count)
        var result = [UsageRecord]()
        result.reserveCapacity(count)
        for record in self {
            if seen.insert(record.dedupKey).inserted {
                result.append(record)
            }
        }
        return result
    }

    /// 주어진 구간 [start, end)에 속하는 레코드.
    public func inRange(_ start: Date, _ end: Date) -> [UsageRecord] {
        filter { $0.timestamp >= start && $0.timestamp < end }
    }

    public var tokenTotals: TokenTotals {
        reduce(into: TokenTotals()) { $0 += $1.totals }
    }
}
