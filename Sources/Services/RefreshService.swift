import Foundation
import Combine

@MainActor
final class RefreshService {
    static let shared = RefreshService()

    private var timer: Timer?
    private(set) var scheduledInterval: Int?
    private var isMenuOpen = false
    private var cancellables = Set<AnyCancellable>()
    private let defaults: UserDefaults
    private let refreshAction: @MainActor () -> Void

    private var refreshInterval: Int {
        if isMenuOpen { return 1 }
        let value = defaults.object(forKey: "refreshInterval") as? Int ?? 30
        return value.clamped(to: 10...300)
    }

    init(defaults: UserDefaults = .standard, refresh: @escaping @MainActor () -> Void = { AppState.shared.poll() }) {
        self.defaults = defaults
        self.refreshAction = refresh
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .debounce(for: .milliseconds(500), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                self?.restartIfNeeded()
            }
            .store(in: &cancellables)
    }

    func start() {
        scheduleTimer()
        refreshAction()
    }

    func setMenuOpen(_ isOpen: Bool) {
        guard isMenuOpen != isOpen else { return }
        isMenuOpen = isOpen
        guard timer != nil else { return }

        scheduleTimer()
        if isOpen { refreshAction() }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        scheduledInterval = nil
    }

    private func scheduleTimer() {
        timer?.invalidate()
        let interval = refreshInterval
        scheduledInterval = interval
        let timer = Timer(timeInterval: TimeInterval(interval), repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refreshAction()
            }
        }
        self.timer = timer
        // Menus run in event-tracking mode, where default-mode timers pause.
        RunLoop.main.add(timer, forMode: .common)
    }

    private func restartIfNeeded() {
        guard timer != nil, scheduledInterval != refreshInterval else { return }
        start()
    }
}

private extension Int {
    func clamped(to range: ClosedRange<Int>) -> Int {
        return Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}
