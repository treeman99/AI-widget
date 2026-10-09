import Foundation
import UsageCore

// 숫자를 눈으로 검증하기 위한 CLI. 메뉴바 UI를 붙이기 전에 UsageCore가 맞는 값을
// 내놓는지 여기서 확인한다.

let arguments = Array(CommandLine.arguments.dropFirst())
let command = arguments.first ?? "status"

func printUsage() {
    print("""
    usagectl — AI 사용량 확인

    사용법:
      usagectl status              현재 사용량 요약
      usagectl calibrate [--days N]  과거 로그로 기준선 산출 (기본 30일)
      usagectl debug [--dedup]     스캔 통계와 중복 제거 검증
      usagectl config              현재 설정 출력
      usagectl reset               캐시 삭제 후 전체 재스캔
    """)
}

func hasFlag(_ name: String) -> Bool { arguments.contains(name) }

func intOption(_ name: String) -> Int? {
    guard let index = arguments.firstIndex(of: name), arguments.indices.contains(index + 1) else { return nil }
    return Int(arguments[index + 1])
}

let now = Date()

switch command {

case "status":
    let monitor = UsageMonitor()
    // 한 번 실행하고 끝나는 프로세스라 조회가 끝날 때까지 기다린다.
    monitor.primeLiveUsage(now: now)
    let snapshot = monitor.refresh(now: now)

    for service in snapshot.services {
        let plan = service.planLabel.map { " · \($0)" } ?? ""
        print("\n\(service.id.displayName)\(plan)")

        switch service.status {
        case .failed(let message):
            print("  ⚠️  \(message)")
            continue
        case .noData(let message):
            print("  — \(message)")
        case .ok:
            break
        }

        for gauge in service.gauges {
            let badge = gauge.source.badge.map { " (\($0))" } ?? ""
            var line = "  \(Format.bar(gauge.percent))  \(Format.percent(gauge.percent))  \(gauge.windowLabel)\(badge)"
            if let resetsAt = gauge.resetsAt {
                line += " · \(Format.remaining(until: resetsAt, from: now)) 후 리셋"
            }
            print(line)
        }
        if case .live(let fetchedAt) = service.primaryGauge?.source {
            print("  ● 실시간 · \(Format.elapsed(since: fetchedAt, to: now)) 조회")
        }
        for detail in service.details {
            print("  \(detail.label): \(detail.value)")
        }

        if let today = service.tokensToday {
            print("  오늘   \(Format.tokens(today.total)) tok  (in \(Format.tokens(today.input)) / out \(Format.tokens(today.output)) / cache r \(Format.tokens(today.cacheRead)) w \(Format.tokens(today.cacheWrite)))")
        }
        if let week = service.tokensLast7Days {
            print("  7일    \(Format.tokens(week.total)) tok")
        }
        if service.daily.contains(where: { $0.weighted > 0 }) {
            let peak = service.daily.map(\.weighted).max() ?? 0
            let blocks = ["▁", "▂", "▃", "▄", "▅", "▆", "▇", "█"]
            let spark = service.daily.map { day -> String in
                guard peak > 0, day.weighted > 0 else { return "·" }
                let index = min(blocks.count - 1, Int((day.weighted / peak * Double(blocks.count - 1)).rounded()))
                return blocks[index]
            }.joined()
            let first = service.daily.first.map { Format.day($0.day) } ?? ""
            print("  \(service.daily.count)일   \(spark)  (\(first) → 오늘)")
        }
        if !service.modelShares.isEmpty {
            let breakdown = service.modelShares
                .map { "\($0.model) \(Int(($0.share * 100).rounded()))%" }
                .joined(separator: " · ")
            print("  모델   \(breakdown)")
        }
        if let observedAt = service.observedAt {
            let stale = service.isStale(now: now, threshold: monitor.config.staleThreshold)
            let marker = stale ? "  ⚠️ 오래된 스냅샷" : ""
            print("  한도 기준시각 \(Format.clock(observedAt)) (\(Format.elapsed(since: observedAt, to: now)))\(marker)")
        }
        if let lastActivityAt = service.lastActivityAt {
            print("  마지막 활동   \(Format.clock(lastActivityAt)) (\(Format.elapsed(since: lastActivityAt, to: now)))")
        }
        let liveError: LiveUsageError?
        switch service.id {
        case .claudeCode: liveError = monitor.claudeProvider.liveError
        case .codex: liveError = monitor.codexProvider.liveError
        case .gemini: liveError = monitor.geminiProvider.liveError
        }
        if let liveError {
            print("  ⚠️ 실시간 조회 실패: \(liveError.description)")
        }
    }

    print(String(format: "\n갱신 %.0fms", snapshot.elapsed * 1000))

case "calibrate":
    let days = intOption("--days") ?? 30
    let monitor = UsageMonitor()
    print("최근 \(days)일 로그를 전체 재스캔합니다...")
    do {
        let result = try monitor.calibrate(now: now, lookback: TimeInterval(days) * 24 * 3600)
        print("""

        기준선 산출 결과
          레코드 (중복 제거 후) : \(result.recordCount)
          5시간 블록 수         : \(result.blockCount)
          활동일                : \(result.activeDays)일
          5시간 블록 피크       : \(Format.tokens(Int(result.fiveHourPeak))) 가중토큰\(result.fiveHourPeakAt.map { " (\(Format.clock($0)))" } ?? "")
          7일 롤링 피크         : \(Format.tokens(Int(result.weeklyPeak))) 가중토큰
        """)
        if let start = result.periodStart, let end = result.periodEnd {
            print("  기간                  : \(Format.clock(start)) ~ \(Format.clock(end))")
        }
        print("\n설정에 저장했습니다: \(Paths.configFile.path)")
    } catch {
        print("실패: \(error)")
        exit(1)
    }

case "debug":
    let monitor = UsageMonitor()
    let claude = monitor.claudeProvider
    let codex = monitor.codexProvider

    if hasFlag("--dedup") {
        // 중복 제거 검증: 원본 레코드 수와 고유 레코드 수를 직접 비교한다.
        claude.resetCache()
        do {
            try claude.refresh(now: now)
        } catch {
            print("스캔 실패: \(error)")
            exit(1)
        }
        let unique = claude.allRecords
        let hours = intOption("--hours") ?? 24
        let windowStart = now.addingTimeInterval(-TimeInterval(hours) * 3600)

        // refresh()가 이미 중복을 제거했으므로 원본 수는 스캔 통계에서 가져온다.
        let stats = claude.lastScan
        let rawInWindow = stats.recordsParsed
        let uniqueInWindow = unique.inRange(windowStart, now.addingTimeInterval(1)).count

        print("""
        중복 제거 검증
          스캔한 파일        : \(stats.filesScanned)
          읽은 줄            : \(stats.linesRead)
          usage 레코드(원본) : \(rawInWindow)
          중복으로 버린 수    : \(stats.duplicatesDropped)
          고유 레코드(전체)   : \(unique.count)
          고유 레코드(\(hours)h) : \(uniqueInWindow)
          비율               : \(rawInWindow > 0 ? String(format: "%.2f배", Double(rawInWindow) / Double(max(1, unique.count))) : "-")
        """)
    } else {
        do {
            let claudeStats = try claude.refresh(now: now)
            print("""
            Claude Code 스캔
              파일 \(claudeStats.filesScanned) · 새 줄 \(claudeStats.linesRead) · 신규 레코드 \(claudeStats.recordsParsed)
              중복 제거 \(claudeStats.duplicatesDropped) · 보관 중 \(claude.allRecords.count)
              소요 \(String(format: "%.0fms", claudeStats.elapsed * 1000))
            """)
        } catch {
            print("Claude Code 스캔 실패: \(error)")
        }

        do {
            let codexStats = try codex.refresh(now: now)
            print("""

            Codex 스캔
              파일 \(codexStats.filesScanned) · 새 줄 \(codexStats.linesRead)
              token_count 이벤트 \(codexStats.tokenEvents) · rate_limits \(codexStats.rateLimitEvents)
              소요 \(String(format: "%.0fms", codexStats.elapsed * 1000))
            """)
            if let limits = codex.currentRateLimits {
                print("  최신 한도 관측: \(Format.clock(limits.observedAt)) · plan=\(limits.planType ?? "-")")
                if let primary = limits.primary {
                    let reset = primary.resetsAt.map { Format.clock($0) } ?? "-"
                    print("    primary   \(primary.usedPercent)% · \(primary.windowLabel)(\(primary.windowMinutes)분) · 리셋 \(reset)")
                }
                if let secondary = limits.secondary {
                    let reset = secondary.resetsAt.map { Format.clock($0) } ?? "-"
                    print("    secondary \(secondary.usedPercent)% · \(secondary.windowLabel)(\(secondary.windowMinutes)분) · 리셋 \(reset)")
                }
            }
        } catch {
            print("Codex 스캔 실패: \(error)")
        }

        // Gemini는 스캔할 로그가 없다. 실시간 조회가 언제까지 가능한지와 마지막 관측만 보인다.
        // 토큰 값은 어떤 형태로도 찍지 않는다 — 터미널 스크롤백과 붙여넣은 이슈에 남는다.
        print("\nGemini (Antigravity)")
        do {
            let credentials = try Credentials.gemini(now: now)
            if let expiresAt = credentials.expiresAt {
                let state = credentials.isExpired(at: now)
                    ? "만료됨 (\(Format.elapsed(since: expiresAt, to: now))) · agy를 실행하면 갱신된다"
                    : "\(Format.remaining(until: expiresAt, from: now)) 남음"
                print("  토큰 만료    \(Format.clock(expiresAt)) · \(state)")
            } else {
                print("  토큰 만료    알 수 없음")
            }
        } catch let error as LiveUsageError {
            print("  자격증명     \(error.description)")
        } catch {
            print("  자격증명     \(error)")
        }
        if let observedAt = monitor.geminiProvider.lastObservedAt {
            print("  마지막 관측  \(Format.clock(observedAt)) (\(Format.elapsed(since: observedAt, to: now)))")
        } else {
            print("  마지막 관측  없음")
        }
    }

case "config":
    let config = AppConfig.load()
    print("""
    설정 파일: \(Paths.configFile.path)

      플랜               : \(config.claudePlanLabel)
      기준선 5시간        : \(Format.tokens(Int(config.baselines.fiveHour))) 가중토큰
      기준선 7일          : \(Format.tokens(Int(config.baselines.weekly))) 가중토큰
      자동 캘리브레이션    : \(config.baselines.autoCalibrate ? "켜짐" : "꺼짐")
      임계치              : \(Int(config.thresholds.caution))% / \(Int(config.thresholds.warning))% / \(Int(config.thresholds.critical))%
      갱신 주기           : \(Int(config.refreshInterval))초
      stale 기준          : \(Int(config.staleThreshold / 3600))시간
      활성 서비스         : \(config.enabledServices.map(\.displayName).joined(separator: ", "))
    """)

case "reset":
    let monitor = UsageMonitor()
    monitor.claudeProvider.resetCache()
    monitor.codexProvider.resetCache()
    // Gemini의 상태 파일은 스캔 캐시가 아니라 마지막 관측 그 자체라 재스캔으로 돌아오지 않는다.
    // 토큰이 죽어 있으면 agy를 다음에 실행할 때까지 빈 칸이 된다. 그래도 지운다 — reset은
    // 쌓인 상태를 버리고 처음부터 보겠다는 명시적 요청이고, 로그아웃·계정 변경 뒤 남은 옛 숫자를
    // 걷어낼 방법이 이것뿐이다. 실행 중인 앱은 메모리에 제 사본을 들고 있다가 다음 성공한
    // 조회 때 다시 쓰므로, 실제로 비는 건 토큰이 죽은 채 앱을 다시 띄웠을 때뿐이다.
    monitor.geminiProvider.resetCache()
    print("캐시를 비웠습니다. 다시 스캔합니다...")
    let snapshot = monitor.refresh(now: now)
    print(String(format: "완료 (%.0fms)", snapshot.elapsed * 1000))

case "-h", "--help", "help":
    printUsage()

default:
    print("알 수 없는 명령: \(command)\n")
    printUsage()
    exit(1)
}
