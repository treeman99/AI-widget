import Foundation

/// 토큰을 "Opus 입력 토큰 상당"으로 환산한다.
///
/// 실제 구독 한도 알고리즘은 비공개이므로, 요금 구조에 비례하는 가중치를 쓴다.
/// 단가 출처: Anthropic 공개 요금표 (per MTok, 2026-07 기준)
///   Fable 5   $10 / $50
///   Opus 5    $5  / $25   ← 기준(계수 1.0)
///   Sonnet 5  $3  / $15
///   Haiku 4.5 $1  / $5
/// 모든 모델에서 출력/입력 비율이 5배로 동일하다.
///
/// 캐시 배수는 프롬프트 캐싱 요금 구조를 따른다.
///   5분 TTL 쓰기 1.25x · 1시간 TTL 쓰기 2.0x · 읽기 0.1x
public enum TokenWeight {

    // MARK: 컴포넌트 배수 (입력 토큰 = 1.0 기준)

    public static let inputMultiplier = 1.0
    public static let outputMultiplier = 5.0
    public static let cacheWrite5mMultiplier = 1.25
    public static let cacheWrite1hMultiplier = 2.0
    public static let cacheReadMultiplier = 0.1

    // MARK: 모델 계수 (Opus 입력 단가 = 1.0 기준)

    public static let fableCoefficient = 2.0
    public static let opusCoefficient = 1.0
    public static let sonnetCoefficient = 0.6
    public static let haikuCoefficient = 0.2

    /// 집계에서 제외할 모델 이름. Claude Code가 내부적으로 만드는 가짜 레코드다.
    public static let excludedModels: Set<String> = ["<synthetic>"]

    /// 모델 이름에서 계수를 얻는다. 이름은 `claude-opus-5`, `claude-haiku-4-5-20251001` 같은 형태다.
    public static func coefficient(for model: String) -> Double {
        let name = model.lowercased()
        if name.contains("fable") || name.contains("mythos") { return fableCoefficient }
        if name.contains("opus") { return opusCoefficient }
        if name.contains("sonnet") { return sonnetCoefficient }
        if name.contains("haiku") { return haikuCoefficient }
        // 모르는 모델은 Opus로 간주한다. 과소평가보다 과대평가가 안전하다.
        return opusCoefficient
    }

    /// 레코드 하나의 가중 토큰.
    public static func weighted(_ record: UsageRecord) -> Double {
        let raw =
            Double(record.input) * inputMultiplier
            + Double(record.output) * outputMultiplier
            + Double(record.cacheWrite5m) * cacheWrite5mMultiplier
            + Double(record.cacheWrite1h) * cacheWrite1hMultiplier
            + Double(record.cacheRead) * cacheReadMultiplier
        return raw * coefficient(for: record.model)
    }

    /// 레코드 여러 개의 가중 토큰 합.
    public static func weightedSum<S: Sequence>(_ records: S) -> Double where S.Element == UsageRecord {
        records.reduce(0) { $0 + weighted($1) }
    }
}
