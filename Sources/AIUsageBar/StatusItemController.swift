import AppKit
import Combine
import SwiftUI
import UsageCore

/// 메뉴바 항목과 드롭다운 팝오버를 관리한다.
@MainActor
final class StatusItemController: NSObject, NSPopoverDelegate {
    private let statusItem: NSStatusItem
    private let popover = NSPopover()
    private let store: UsageStore
    private var cancellables = Set<AnyCancellable>()
    private var settingsWindow: NSWindow?
    /// 메뉴바 외관은 다크 모드뿐 아니라 **바탕화면 밝기에 따라서도** 바뀐다.
    /// 바뀔 때마다 제목을 다시 그려야 색이 따라간다.
    private var appearanceObservation: NSKeyValueObservation?

    init(store: UsageStore) {
        self.store = store
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        configureButton()
        configurePopover()

        store.$snapshot
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateTitle() }
            .store(in: &cancellables)
        store.$config
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateTitle() }
            .store(in: &cancellables)

        updateTitle()
    }

    private func configureButton() {
        guard let button = statusItem.button else { return }
        button.target = self
        button.action = #selector(togglePopover)
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])

        appearanceObservation = button.observe(\.effectiveAppearance) { [weak self] _, _ in
            Task { @MainActor in self?.updateTitle() }
        }
    }

    private func configurePopover() {
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        let root = DropdownView(
            store: store,
            onOpenSettings: { [weak self] in self?.openSettings() },
            onQuit: { NSApp.terminate(nil) }
        )
        popover.contentViewController = NSHostingController(rootView: root)
    }

    // MARK: - 메뉴바 제목

    private func updateTitle() {
        guard let button = statusItem.button else { return }
        // 다이내믹 색이 **메뉴바의** 밝기(바탕화면에 따라 바뀐다)에 맞춰 풀리도록
        // 버튼의 외관을 현재 그리기 컨텍스트로 세운 뒤 문자열을 만든다.
        button.effectiveAppearance.performAsCurrentDrawingAppearance {
            button.attributedTitle = makeTitle()
        }
    }

    private func makeTitle() -> NSAttributedString {
        let size = NSFont.systemFontSize - 1
        // 이름은 굵게, 숫자는 보통 굵기로 두면 "라벨 + 값" 구조가 눈에 바로 들어온다.
        let labelFont = NSFont.systemFont(ofSize: size, weight: .bold)
        let valueFont = NSFont.monospacedDigitSystemFont(ofSize: size, weight: .regular)
        let result = NSMutableAttributedString()

        func append(_ text: String, font: NSFont, color: NSColor) {
            result.append(NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color]))
        }

        guard let snapshot = store.snapshot, !snapshot.services.isEmpty else {
            append("AI …", font: valueFont, color: .labelColor)
            return result
        }

        var first = true
        for service in snapshot.services {
            // 메뉴바는 반투명이라 옅은 색이 배경에 묻힌다. 구분은 색이 아니라 간격으로 준다.
            if !first { append("   ", font: valueFont, color: .labelColor) }
            first = false
            append("\(service.id.menuBarLabel) ", font: labelFont, color: .labelColor)

            switch service.status {
            case .failed:
                append("!", font: labelFont, color: .systemRed)
            case .noData:
                append("–", font: valueFont, color: .labelColor)
            case .ok:
                guard let gauge = service.primaryGauge else {
                    append("–", font: valueFont, color: .labelColor)
                    continue
                }
                let level = store.config.thresholds.level(for: gauge.percent)
                let font = level == .critical
                    ? NSFont.monospacedDigitSystemFont(ofSize: size, weight: .bold)
                    : valueFont
                append(Format.percent(gauge.percent), font: font, color: Self.color(for: level))
                if service.isStale(now: Date(), threshold: store.config.staleThreshold) {
                    // 실시간 조회가 안 돼 예전 값을 쓰는 중이라는 표시.
                    append("˟", font: valueFont, color: .labelColor)
                }
            }
        }
        return result
    }

    /// 메뉴바는 밝은 배경과 어두운 배경 양쪽에 올라간다. 두 경우 모두 읽히는 색만 쓴다.
    /// (systemYellow는 밝은 메뉴바에서 거의 안 보여 쓰지 않는다.)
    static func color(for level: ColorThresholds.Level) -> NSColor {
        switch level {
        case .normal: return .labelColor
        case .caution: return .systemOrange
        case .warning: return .systemRed
        case .critical: return .systemRed
        }
    }

    // MARK: - 팝오버

    @objc private func togglePopover() {
        if popover.isShown {
            popover.performClose(nil)
        } else {
            guard let button = statusItem.button else { return }
            store.refresh()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    // MARK: - 설정 창

    private func openSettings() {
        popover.performClose(nil)

        if settingsWindow == nil {
            let controller = NSHostingController(rootView: SettingsView(store: store))
            let window = NSWindow(contentViewController: controller)
            window.title = "AI Usage 설정"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            // 메뉴바 전용 앱은 비활성화될 때 창을 숨기기 쉬운데, 설정 창은 계속 떠 있어야 한다.
            window.hidesOnDeactivate = false
            window.center()
            settingsWindow = window
        }

        // LSUIElement 앱은 먼저 앱을 활성화해야 창이 키 윈도우가 되고 텍스트 입력이 들어간다.
        // 팝오버가 닫히는 사이클 안에서 바로 하면 포커스를 뺏길 수 있어 다음 런루프로 미룬다.
        DispatchQueue.main.async { [weak self] in
            NSApp.activate(ignoringOtherApps: true)
            self?.settingsWindow?.makeKeyAndOrderFront(nil)
        }
    }
}
