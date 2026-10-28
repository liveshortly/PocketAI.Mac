import AppKit
import Observation
import SwiftUI

/// Tracks whether the person is actively scrolling.
///
/// A transcript that follows the stream is right only while they are reading
/// the tail. The moment they touch the wheel or trackpad it must stop moving
/// under them — being at the bottom is not the same as wanting to be dragged
/// there mid-gesture. Auto-follow resumes once they have been still for a beat.
@MainActor
@Observable
final class ScrollActivity {
    /// True from the first scroll event until `idleDelay` after the last one.
    private(set) var isScrolling = false

    private var monitor: Any?
    private var settleTask: Task<Void, Never>?
    /// How long "not doing anything" means. Long enough to cover the pause
    /// between two flicks, short enough that following feels automatic.
    private let idleDelay: Duration = .milliseconds(900)

    nonisolated init() {}

    func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            Task { @MainActor in self?.noteScroll() }
            return event
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        settleTask?.cancel()
        settleTask = nil
        isScrolling = false
    }

    private func noteScroll() {
        isScrolling = true
        settleTask?.cancel()
        settleTask = Task { [weak self, idleDelay] in
            try? await Task.sleep(for: idleDelay)
            guard !Task.isCancelled else { return }
            self?.isScrolling = false
        }
    }
}
