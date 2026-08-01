import SwiftUI
import UsageCore

/// 메뉴바를 클릭했을 때 뜨는 상세 패널.
///
/// 한 화면에서 "지금 얼마나 남았나 / 언제 리셋되나 / 최근에 얼마나 썼나 / 뭐가 먹고 있나"를
/// 모두 답하는 것이 목표다. 길어져도 스크롤로 감당한다.
struct DropdownView: View {
    @ObservedObject var store: UsageStore
    var onOpenSettings: () -> Void
    var onQuit: () -> Void

    /// 리셋 카운트다운을 실시간으로 줄이기 위한 틱.
    @State private var now = Date()
    private let tick = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()

            ScrollView {
                if let snapshot = store.snapshot, !snapshot.services.isEmpty {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(snapshot.services.enumerated()), id: \.element.id) { index, service in
                            if index > 0 {
                                Divider().padding(.vertical, 14)
                            }
                            ServiceSection(
                                service: service,
                                thresholds: store.config.thresholds,
                                staleThreshold: store.config.staleThreshold,
                                now: now
                            )
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)
                } else {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small).scaleEffect(0.7)
                        Text("사용량을 읽는 중…")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
                }
            }
            .frame(maxHeight: 560)

            Divider()
            footer
        }
        .frame(width: 340)
        .onReceive(tick) { now = $0 }
        .onAppear { now = Date() }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text("AI Usage")
                .font(.system(size: 13, weight: .semibold))
            Spacer()
            if store.isRefreshing {
                ProgressView().controlSize(.small).scaleEffect(0.6)
            }
            Text(refreshLabel)
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 10)
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Button {
                store.refreshNow()
            } label: {
                Label("갱신", systemImage: "arrow.clockwise").font(.system(size: 11))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)

            Spacer()

            Button(action: onOpenSettings) {
                Image(systemName: "gearshape").font(.system(size: 12))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("설정")

            Button(action: onQuit) {
                Image(systemName: "power").font(.system(size: 12))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("종료")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var refreshLabel: String {
        guard let lastRefreshedAt = store.lastRefreshedAt else { return "" }
        return Format.elapsed(since: lastRefreshedAt, to: now) + " 갱신"
    }
}

// MARK: - 서비스 블록

private struct ServiceSection: View {
    let service: ServiceSnapshot
    let thresholds: ColorThresholds
    let staleThreshold: TimeInterval
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            titleRow

            switch service.status {
            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)

            case .noData(let message):
                Text(message)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

            case .ok:
                VStack(alignment: .leading, spacing: 11) {
                    ForEach(Array(service.gauges.enumerated()), id: \.offset) { _, gauge in
                        GaugeRow(gauge: gauge, thresholds: thresholds, now: now)
                    }
                }
            }

            if !service.details.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(Array(service.details.enumerated()), id: \.offset) { _, detail in
                        HStack {
                            Text(detail.label)
                            Spacer()
                            Text(detail.value).foregroundStyle(.primary)
                        }
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                    }
                }
            }

            if service.daily.contains(where: { $0.weighted > 0 }) {
                DailyChart(daily: service.daily, now: now)
            }

            tokenSummary

            if !service.modelShares.isEmpty {
                ModelShareRow(shares: service.modelShares)
            }

            if let observedAt = service.observedAt {
                // 실시간 조회가 실패해 예전 값을 쓰는 중이라는 뜻이다.
                let stale = service.isStale(now: now, threshold: staleThreshold)
                Label(
                    "\(Format.clock(observedAt)) 기준 (\(Format.elapsed(since: observedAt, to: now)))",
                    systemImage: "clock.arrow.circlepath"
                )
                .font(.system(size: 10))
                .foregroundStyle(stale ? .orange : .secondary)
            }
        }
    }

    private var titleRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(service.id.displayName)
                .font(.system(size: 12.5, weight: .semibold))

            if case .live = service.primaryGauge?.source {
                HStack(spacing: 3) {
                    Circle().fill(Color.green).frame(width: 5, height: 5)
                    Text("실시간").font(.system(size: 9.5, weight: .medium))
                }
                .foregroundStyle(.secondary)
            }

            Spacer()

            if let plan = service.planLabel {
                Text(plan)
                    .font(.system(size: 9.5, weight: .semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.primary.opacity(0.07), in: Capsule())
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var tokenSummary: some View {
        if service.tokensToday != nil || service.tokensLast7Days != nil {
            HStack(spacing: 14) {
                if let today = service.tokensToday {
                    metric("오늘", Format.tokens(today.total))
                }
                if let week = service.tokensLast7Days {
                    metric("7일", Format.tokens(week.total))
                }
                if let week = service.tokensLast7Days, week.output > 0 {
                    metric("출력", Format.tokens(week.output))
                }
                Spacer()
            }
        }
    }

    private func metric(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label)
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
            Text(value)
                .font(.system(size: 11.5, weight: .medium).monospacedDigit())
        }
    }
}

// MARK: - 게이지

private struct GaugeRow: View {
    let gauge: UsageGauge
    let thresholds: ColorThresholds
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
                Text(gauge.windowLabel)
                    .font(.system(size: 11))
                if let badge = gauge.source.badge {
                    Text(badge)
                        .font(.system(size: 9))
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Color.primary.opacity(0.08), in: Capsule())
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(Format.percent(gauge.percent))
                    .font(.system(size: 12, weight: .semibold).monospacedDigit())
                    .foregroundStyle(color)
            }

            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.09))
                    Capsule()
                        .fill(color)
                        .frame(width: max(2, geometry.size.width * fillRatio))
                }
            }
            .frame(height: 6)

            if let resetsAt = gauge.resetsAt {
                Text("\(Format.remaining(until: resetsAt, from: now)) 후 리셋 · \(Format.clock(resetsAt))")
                    .font(.system(size: 9.5))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var fillRatio: Double { max(0, min(1, gauge.percent / 100)) }

    private var color: Color {
        switch thresholds.level(for: gauge.percent) {
        case .normal: return .accentColor
        case .caution: return .yellow
        case .warning: return .orange
        case .critical: return .red
        }
    }
}

// MARK: - 일별 차트

private struct DailyChart: View {
    let daily: [DailyUsage]
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text("최근 \(daily.count)일")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                Spacer()
                if let peak = daily.map(\.totals.total).max(), peak > 0 {
                    Text("최대 \(Format.tokens(peak))")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                }
            }

            HStack(alignment: .bottom, spacing: 2) {
                ForEach(Array(daily.enumerated()), id: \.offset) { _, day in
                    // 가중 토큰 기준이라 "한도를 얼마나 먹었나"에 비례한다.
                    let ratio = peak > 0 ? day.weighted / peak : 0
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(isToday(day.day) ? Color.accentColor : Color.accentColor.opacity(0.45))
                        .frame(height: max(2, 34 * ratio))
                        .help("\(Format.day(day.day)) · \(Format.tokens(day.totals.total)) tok")
                }
            }
            .frame(height: 34, alignment: .bottom)

            HStack {
                Text(daily.first.map { Format.day($0.day) } ?? "")
                Spacer()
                Text("오늘")
            }
            .font(.system(size: 8.5))
            .foregroundStyle(.tertiary)
        }
    }

    private var peak: Double { daily.map(\.weighted).max() ?? 0 }

    private func isToday(_ date: Date) -> Bool {
        Calendar.current.isDate(date, inSameDayAs: now)
    }
}

// MARK: - 모델 비중

private struct ModelShareRow: View {
    let shares: [ModelShare]

    /// 모델마다 고정 색을 주어 눈이 익숙해지게 한다.
    private func color(for model: String) -> Color {
        switch model {
        case "Opus": return .accentColor
        case "Fable", "Mythos": return .purple
        case "Sonnet": return .teal
        case "Haiku": return .green
        default: return .gray
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("모델 비중 (7일)")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)

            GeometryReader { geometry in
                HStack(spacing: 1.5) {
                    ForEach(Array(shares.enumerated()), id: \.offset) { _, share in
                        Capsule()
                            .fill(color(for: share.model))
                            .frame(width: max(2, geometry.size.width * share.share))
                    }
                }
            }
            .frame(height: 5)

            HStack(spacing: 10) {
                ForEach(Array(shares.enumerated()), id: \.offset) { _, share in
                    HStack(spacing: 3) {
                        Circle().fill(color(for: share.model)).frame(width: 5, height: 5)
                        Text("\(share.model) \(Int((share.share * 100).rounded()))%")
                    }
                }
                Spacer()
            }
            .font(.system(size: 9.5))
            .foregroundStyle(.secondary)
        }
    }
}
