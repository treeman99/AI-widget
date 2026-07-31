import Foundation

/// 실사용 기록에서 Claude Code 기준선을 산출한다.
///
/// 공식 한도가 공개돼 있지 않으므로, 과거에 실제로 도달했던 최대치를 기준선으로 쓴다.
/// 한도에 부딪힌 적이 있다면 그 피크가 곧 실질 한도이고, 없다면 최소한 "평소 대비 지금
/// 얼마나 쓰고 있나"는 정확하게 보여준다.
public enum Calibration {
    public struct Result: Sendable, Equatable {
        public let fiveHourPeak: Double
        public let fiveHourPeakAt: Date?
        public let weeklyPeak: Double
        public let recordCount: Int
        public let blockCount: Int
        public let activeDays: Int
        public let periodStart: Date?
        public let periodEnd: Date?
    }

    public static let defaultLookback: TimeInterval = 30 * 24 * 3600

    /// 5시간 블록 피크와 7일 롤링 피크를 계산한다.
    ///
    /// 5시간 값은 런타임 게이지와 **같은 블록 알고리즘**으로 뽑는다. 측정 방식이 다르면
    /// 기준선과 현재값의 단위가 어긋난다.
    public static func compute(
        records: [UsageRecord],
        now: Date = Date(),
        lookback: TimeInterval = defaultLookback
    ) -> Result {
        let cutoff = now.addingTimeInterval(-lookback)
        let scoped = records.filter { $0.timestamp >= cutoff }.sorted { $0.timestamp < $1.timestamp }

        guard !scoped.isEmpty else {
            return Result(
                fiveHourPeak: 0, fiveHourPeakAt: nil, weeklyPeak: 0,
                recordCount: 0, blockCount: 0, activeDays: 0,
                periodStart: nil, periodEnd: nil
            )
        }

        let blocks = SessionBlocks.build(from: scoped)
        var peak = 0.0
        var peakAt: Date?
        for block in blocks {
            let weighted = block.weighted
            if weighted > peak {
                peak = weighted
                peakAt = block.start
            }
        }

        let weeklyPeak = rollingPeak(scoped, window: 7 * 24 * 3600)

        var days = Set<DateComponents>()
        let calendar = Calendar.current
        for record in scoped {
            days.insert(calendar.dateComponents([.year, .month, .day], from: record.timestamp))
        }

        return Result(
            fiveHourPeak: peak,
            fiveHourPeakAt: peakAt,
            weeklyPeak: weeklyPeak,
            recordCount: scoped.count,
            blockCount: blocks.count,
            activeDays: days.count,
            periodStart: scoped.first?.timestamp,
            periodEnd: scoped.last?.timestamp
        )
    }

    /// 정렬된 레코드에 대한 롤링 윈도우 최대 가중 토큰. 투 포인터로 O(n).
    static func rollingPeak(_ sorted: [UsageRecord], window: TimeInterval) -> Double {
        var peak = 0.0
        var runningSum = 0.0
        var lowerIndex = 0
        for upperIndex in sorted.indices {
            runningSum += TokenWeight.weighted(sorted[upperIndex])
            let lowerBound = sorted[upperIndex].timestamp.addingTimeInterval(-window)
            while lowerIndex < upperIndex, sorted[lowerIndex].timestamp < lowerBound {
                runningSum -= TokenWeight.weighted(sorted[lowerIndex])
                lowerIndex += 1
            }
            peak = max(peak, runningSum)
        }
        return peak
    }

    /// 계산 결과를 기준선으로 바꾼다. 데이터가 없으면 폴백 값을 유지한다.
    public static func baselines(
        from result: Result,
        autoCalibrate: Bool = true,
        fallback: Baselines = .fallback
    ) -> Baselines {
        Baselines(
            fiveHour: result.fiveHourPeak > 0 ? result.fiveHourPeak : fallback.fiveHour,
            weekly: result.weeklyPeak > 0 ? result.weeklyPeak : fallback.weekly,
            autoCalibrate: autoCalibrate
        )
    }
}
