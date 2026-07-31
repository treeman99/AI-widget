import Foundation

/// 앱이 쓰는 경로 모음.
public enum Paths {
    public static var home: URL {
        URL(fileURLWithPath: NSHomeDirectory())
    }

    /// Claude Code 세션 로그 루트.
    public static var claudeProjects: URL {
        home.appendingPathComponent(".claude/projects", isDirectory: true)
    }

    /// Codex CLI 세션 로그 루트.
    public static var codexSessions: URL {
        home.appendingPathComponent(".codex/sessions", isDirectory: true)
    }

    /// 캐시·설정 저장소.
    public static var appSupport: URL {
        home.appendingPathComponent("Library/Application Support/AIUsageBar", isDirectory: true)
    }

    public static var configFile: URL {
        appSupport.appendingPathComponent("config.json")
    }

    public static func stateFile(for service: ServiceID) -> URL {
        appSupport.appendingPathComponent("state-\(service.rawValue).json")
    }

    public static func ensureAppSupportExists() throws {
        try FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)
    }
}

/// Codable 값을 JSON 파일로 읽고 쓴다. 쓰기는 임시 파일 후 교체라 중간에 죽어도 깨지지 않는다.
public enum JSONStore {
    public static func load<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try? decoder.decode(type, from: data)
    }

    public static func save<T: Encodable>(_ value: T, to url: URL) throws {
        try Paths.ensureAppSupportExists()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        let data = try encoder.encode(value)
        let temporary = url.appendingPathExtension("tmp")
        try data.write(to: temporary, options: .atomic)
        _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary)
    }
}
