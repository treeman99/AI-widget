import Foundation

/// 로그의 ISO8601 타임스탬프 파싱.
///
/// 형식이 `2026-07-29T12:54:55.903Z`로 고정이라 직접 파싱한다. 수만 건을 처리하므로
/// `ISO8601DateFormatter`보다 훨씬 빠르고, 형식이 어긋나면 포매터로 넘겨 재시도한다.
public enum ISO8601 {
    private static let fallbackFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let plainFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    public static func parse(_ string: String) -> Date? {
        if let date = fastParse(string) { return date }
        if let date = fallbackFormatter.date(from: string) { return date }
        return plainFormatter.date(from: string)
    }

    /// `YYYY-MM-DDTHH:MM:SS[.fff]Z` 전용 경로.
    private static func fastParse(_ string: String) -> Date? {
        let utf8 = Array(string.utf8)
        guard utf8.count >= 20 else { return nil }
        guard utf8[4] == 0x2D, utf8[7] == 0x2D, utf8[10] == 0x54,
              utf8[13] == 0x3A, utf8[16] == 0x3A, utf8.last == 0x5A
        else { return nil }

        func number(_ range: Range<Int>) -> Int? {
            var value = 0
            for index in range {
                let byte = utf8[index]
                guard byte >= 0x30, byte <= 0x39 else { return nil }
                value = value * 10 + Int(byte - 0x30)
            }
            return value
        }

        guard let year = number(0..<4), let month = number(5..<7), let day = number(8..<10),
              let hour = number(11..<13), let minute = number(14..<16), let second = number(17..<19)
        else { return nil }

        var fraction = 0.0
        if utf8.count > 20, utf8[19] == 0x2E {
            var index = 20
            var scale = 0.1
            while index < utf8.count, utf8[index] >= 0x30, utf8[index] <= 0x39 {
                fraction += Double(utf8[index] - 0x30) * scale
                scale /= 10
                index += 1
            }
        }

        // 1970-01-01부터의 일수를 직접 계산한다(그레고리력, UTC 고정).
        let days = daysFromCivil(year: year, month: month, day: day)
        let seconds = Double(days) * 86400 + Double(hour) * 3600 + Double(minute) * 60 + Double(second)
        return Date(timeIntervalSince1970: seconds + fraction)
    }

    /// Howard Hinnant의 days_from_civil 알고리즘.
    private static func daysFromCivil(year: Int, month: Int, day: Int) -> Int {
        let y = year - (month <= 2 ? 1 : 0)
        let era = (y >= 0 ? y : y - 399) / 400
        let yearOfEra = y - era * 400
        let dayOfYear = (153 * (month + (month > 2 ? -3 : 9)) + 2) / 5 + day - 1
        let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
        return era * 146_097 + dayOfEra - 719_468
    }
}
