import Foundation

/// CLI와 메뉴바가 함께 쓰는 표시 형식.
public enum Format {

    /// 12_400_000 → "12.4M"
    public static func tokens(_ count: Int) -> String {
        let value = Double(count)
        switch abs(value) {
        case 1_000_000_000...:
            return String(format: "%.2fB", value / 1_000_000_000)
        case 1_000_000...:
            return String(format: "%.1fM", value / 1_000_000)
        case 1_000...:
            return String(format: "%.1fK", value / 1_000)
        default:
            return "\(count)"
        }
    }

    /// 남은 시간. "3시간 12분", "5일 4시간", "2분"
    public static func remaining(until date: Date, from now: Date = Date()) -> String {
        let seconds = date.timeIntervalSince(now)
        guard seconds > 0 else { return "지금" }
        let days = Int(seconds) / 86400
        let hours = (Int(seconds) % 86400) / 3600
        let minutes = (Int(seconds) % 3600) / 60
        if days > 0 { return hours > 0 ? "\(days)일 \(hours)시간" : "\(days)일" }
        if hours > 0 { return minutes > 0 ? "\(hours)시간 \(minutes)분" : "\(hours)시간" }
        return "\(max(1, minutes))분"
    }

    /// 경과 시간. "5일 전", "3시간 전", "방금"
    public static func elapsed(since date: Date, to now: Date = Date()) -> String {
        let seconds = now.timeIntervalSince(date)
        guard seconds >= 60 else { return "방금" }
        let days = Int(seconds) / 86400
        let hours = (Int(seconds) % 86400) / 3600
        let minutes = (Int(seconds) % 3600) / 60
        if days > 0 { return "\(days)일 전" }
        if hours > 0 { return "\(hours)시간 전" }
        return "\(minutes)분 전"
    }

    public static func percent(_ value: Double) -> String {
        String(format: "%.0f%%", value.rounded())
    }

    /// 터미널용 막대. "▓▓▓▓▓░░░░░░░░░"
    public static func bar(_ percent: Double, width: Int = 14) -> String {
        let ratio = max(0, min(1, percent / 100))
        let filled = Int((ratio * Double(width)).rounded())
        return String(repeating: "▓", count: filled) + String(repeating: "░", count: width - filled)
    }

    private static let clockFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ko_KR")
        formatter.dateFormat = "M/d HH:mm"
        return formatter
    }()

    public static func clock(_ date: Date) -> String {
        clockFormatter.string(from: date)
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ko_KR")
        formatter.dateFormat = "M/d"
        return formatter
    }()

    public static func day(_ date: Date) -> String {
        dayFormatter.string(from: date)
    }
}
