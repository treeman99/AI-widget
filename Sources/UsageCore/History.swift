import Foundation

/// 레코드를 드롭다운이 그릴 수 있는 형태로 요약한다.
public enum History {

    /// 최근 `days`일의 일별 사용량. 기록이 없는 날도 0으로 채워 차트 간격이 일정하게 한다.
    public static func daily(
        from records: [UsageRecord],
        days: Int,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> [DailyUsage] {
        guard days > 0 else { return [] }
        let today = calendar.startOfDay(for: now)

        var buckets = [Date: (totals: TokenTotals, weighted: Double)]()
        for record in records {
            let day = calendar.startOfDay(for: record.timestamp)
            guard let distance = calendar.dateComponents([.day], from: day, to: today).day,
                  distance >= 0, distance < days
            else { continue }
            var bucket = buckets[day] ?? (TokenTotals(), 0)
            bucket.totals += record.totals
            bucket.weighted += TokenWeight.weighted(record)
            buckets[day] = bucket
        }

        return (0..<days).reversed().compactMap { offset in
            guard let day = calendar.date(byAdding: .day, value: -offset, to: today) else { return nil }
            let bucket = buckets[day] ?? (TokenTotals(), 0)
            return DailyUsage(day: day, totals: bucket.totals, weighted: bucket.weighted)
        }
    }

    /// 모델별 비중. 가중 토큰 기준이라 "한도를 무엇이 먹고 있나"를 보여준다.
    public static func modelShares(from records: [UsageRecord], limit: Int = 4) -> [ModelShare] {
        guard !records.isEmpty else { return [] }

        var weightedByFamily = [String: Double]()
        for record in records {
            weightedByFamily[family(of: record.model), default: 0] += TokenWeight.weighted(record)
        }
        let total = weightedByFamily.values.reduce(0, +)
        guard total > 0 else { return [] }

        return weightedByFamily
            .map { ModelShare(model: $0.key, weighted: $0.value, share: $0.value / total) }
            .sorted { $0.weighted > $1.weighted }
            .prefix(limit)
            .map { $0 }
    }

    /// `claude-opus-4-5-20251101` → `Opus`
    static func family(of model: String) -> String {
        let name = model.lowercased()
        for candidate in ["fable", "mythos", "opus", "sonnet", "haiku"] where name.contains(candidate) {
            return candidate.capitalized
        }
        return "기타"
    }
}
