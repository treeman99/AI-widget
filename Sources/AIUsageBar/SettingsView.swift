import SwiftUI
import UsageCore

/// 숫자 하나를 고치는 줄. 직접 입력과 화살표 조작을 모두 지원한다.
private struct NumberSetting: View {
    let title: String
    let unit: String
    let range: ClosedRange<Double>
    let step: Double
    @Binding var value: Double
    var help: String?

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 6) {
                TextField("", value: $value, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 64)
                    .multilineTextAlignment(.trailing)
                    // 범위를 벗어난 값이 들어오면 조용히 되돌린다.
                    .onSubmit { clamp() }
                    .onChange(of: value) { _, _ in clamp() }
                Text(unit)
                    .foregroundStyle(.secondary)
                Stepper("", value: $value, in: range, step: step)
                    .labelsHidden()
            }
        }
        .help(help ?? "\(Int(range.lowerBound))~\(Int(range.upperBound))\(unit)")
    }

    private func clamp() {
        let clamped = min(max(value, range.lowerBound), range.upperBound)
        if clamped != value { value = clamped }
    }
}

/// 표시와 갱신 동작을 조정한다.
///
/// 기준선 같은 내부 값은 노출하지 않는다. 실시간 조회가 붙은 뒤로는 조회가 실패했을 때만
/// 쓰이는 폴백이고, 자동 캘리브레이션이 알아서 맞춘다. 필요하면 `usagectl calibrate`로 다룬다.
struct SettingsView: View {
    @ObservedObject var store: UsageStore

    @State private var draft: AppConfig

    init(store: UsageStore) {
        self.store = store
        _draft = State(initialValue: store.config)
    }

    private var isDirty: Bool { draft != store.config }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("실시간 조회") {
                    Toggle("공식 API에서 실제 사용률 조회", isOn: $draft.useLiveAPI)

                    NumberSetting(
                        title: "조회 간격",
                        unit: "분",
                        range: 1...60,
                        step: 1,
                        value: liveMinutes,
                        help: "1~60분. 자주 조회한다고 더 정확해지지는 않는다."
                    )
                    .disabled(!draft.useLiveAPI)

                    Text("Claude Code와 Codex가 로그인할 때 저장한 토큰으로 각 서비스의 사용량을 조회합니다. 성공하면 실제 한도 사용률을, 실패하면 마지막 실측값 → 로컬 추정 순으로 표시합니다.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Section("갱신") {
                    NumberSetting(
                        title: "로컬 갱신 주기",
                        unit: "초",
                        range: 10...600,
                        step: 10,
                        value: $draft.refreshInterval,
                        help: "토큰 집계를 다시 계산하는 주기. 로그 변경은 즉시 감지되므로 보조 수단이다."
                    )
                    NumberSetting(
                        title: "오래된 값 기준",
                        unit: "시간",
                        range: 1...168,
                        step: 1,
                        value: staleHours,
                        help: "이 시간이 지난 실측값은 '마지막 관측'으로 표시하고 메뉴바에 ˟를 붙인다."
                    )
                }

                Section("표시") {
                    NumberSetting(title: "주의 (주황)", unit: "%", range: 0...100, step: 5, value: $draft.thresholds.caution)
                    NumberSetting(title: "경고 (빨강)", unit: "%", range: 0...100, step: 5, value: $draft.thresholds.warning)
                    NumberSetting(title: "위험 (굵은 빨강)", unit: "%", range: 0...100, step: 5, value: $draft.thresholds.critical)
                    NumberSetting(
                        title: "일별 차트",
                        unit: "일",
                        range: 7...30,
                        step: 1,
                        value: historyDays,
                        help: "드롭다운 막대 차트에 보여줄 날짜 수."
                    )
                }

                Section("서비스") {
                    ForEach(ServiceID.allCases, id: \.self) { service in
                        Toggle(service.displayName, isOn: binding(for: service))
                    }
                }
            }
            .formStyle(.grouped)

            Divider()

            HStack {
                Button("전체 다시 스캔") {
                    store.fullRescan()
                }
                .help("캐시를 비우고 로그를 처음부터 다시 읽는다.")

                Spacer()

                Button("되돌리기") { draft = store.config }
                    .disabled(!isDirty)
                Button("저장") { store.applyConfig(draft) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!isDirty)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .frame(width: 440, height: 560)
        .onReceive(store.$config) { updated in
            // 편집 중이 아닐 때만 외부 변경(자동 캘리브레이션 등)을 반영한다.
            if !isDirty { draft = updated }
        }
    }

    // MARK: - 단위 변환 바인딩

    private var liveMinutes: Binding<Double> {
        Binding(
            get: { (draft.liveRefreshInterval / 60).rounded() },
            set: { draft.liveRefreshInterval = $0 * 60 }
        )
    }

    private var staleHours: Binding<Double> {
        Binding(
            get: { (draft.staleThreshold / 3600).rounded() },
            set: { draft.staleThreshold = $0 * 3600 }
        )
    }

    private var historyDays: Binding<Double> {
        Binding(
            get: { Double(draft.historyDays) },
            set: { draft.historyDays = Int($0) }
        )
    }

    private func binding(for service: ServiceID) -> Binding<Bool> {
        Binding(
            get: { draft.enabledServices.contains(service) },
            set: { isOn in
                if isOn {
                    if !draft.enabledServices.contains(service) {
                        // 목록 순서를 고정해 메뉴바 표시 순서가 흔들리지 않게 한다.
                        draft.enabledServices = ServiceID.allCases.filter {
                            $0 == service || draft.enabledServices.contains($0)
                        }
                    }
                } else {
                    draft.enabledServices.removeAll { $0 == service }
                }
            }
        )
    }
}
