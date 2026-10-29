import Foundation

/// Timers on `RunLoop.main` in `.common` mode keep firing while a menu bar menu is open (run loop in `.eventTracking`).
enum CommonModeTimer {
    @MainActor
    static func make(
        _ interval: TimeInterval, repeats: Bool, _ fire: @escaping @MainActor () -> Void
    ) -> Timer {
        let timer = Timer(timeInterval: interval, repeats: repeats) { _ in
            MainActor.assumeIsolated { fire() }
        }
        RunLoop.main.add(timer, forMode: .common)
        return timer
    }
}
