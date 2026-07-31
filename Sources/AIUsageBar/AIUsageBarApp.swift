import AppKit

/// Dock 아이콘 없이 메뉴바에만 상주한다.
///
/// Info.plist의 `LSUIElement`와 함께 동작하며, `.app` 번들 없이 바이너리를 직접 실행할 때도
/// 같은 동작을 보장하려고 코드에서도 activation policy를 지정한다.
@main
@MainActor
struct AIUsageBarApp {
    static func main() {
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        application.setActivationPolicy(.accessory)
        application.run()
    }
}
