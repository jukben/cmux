// Sources/Island/IslandWindowController.swift

import AppKit
import Combine
import SwiftUI

/// Owns a single `NotchPanel` plus its hosted `IslandRootView`.
///
/// Responsibilities:
///   • position the panel on the notch screen (or main screen on non-notch Macs)
///   • show/hide the panel based on `provider.sessions.isEmpty`
///   • wire the view model to the provider
///   • flip `ignoresMouseEvents` when the view opens or closes so collapsed
///     clicks pass through and expanded clicks are received
///   • detect clicks in the pill rect via global + local `NSEvent` monitors
///     — the panel itself has `ignoresMouseEvents = true` when closed so it
///     cannot receive the click that would otherwise open the island.
///     This mirrors the approach in farouqaldori/claude-island
///     (`NotchWindow` + global monitor), adapted for cmux.
///   • tear down cleanly on `shutdown()`
@MainActor
final class IslandWindowController: NSWindowController {

    private let provider: IslandStateProvider
    private let viewModel: IslandRootViewModel
    private var cancellables: Set<AnyCancellable> = []

    /// Screen the panel is positioned on. Stored so mouse-monitor handlers
    /// can compute the current pill rect in screen coordinates.
    private let targetScreen: NSScreen

    private var globalMouseMonitor: Any?
    private var localMouseMonitor: Any?

    init(provider: IslandStateProvider, router: IslandJumpRouter) {
        self.provider = provider

        let screen = IslandWindowController.resolveScreen()
        let notchSize = IslandWindowController.resolveNotchSize(on: screen)
        self.targetScreen = screen

        self.viewModel = IslandRootViewModel(
            notchWidth: notchSize.width,
            notchHeight: notchSize.height,
            router: router
        )

        let windowHeight: CGFloat = 750
        let frame = NSRect(
            x: screen.frame.origin.x,
            y: screen.frame.maxY - windowHeight,
            width: screen.frame.width,
            height: windowHeight
        )

        let panel = NotchPanel(contentRect: frame)
        panel.contentView = NSHostingView(rootView: IslandRootView(viewModel: viewModel))
        panel.setFrame(frame, display: true)
        panel.ignoresMouseEvents = true

        super.init(window: panel)

        viewModel.bind(to: provider)

        // Visibility: panel only orderFronts when the sessions list is non-empty.
        provider.sessionsPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] sessions in
                self?.reconcile(sessions: sessions)
            }
            .store(in: &cancellables)

        // Mouse event pass-through: when the view closes, clicks outside
        // the (now-invisible) pill pass through to whatever is underneath.
        // When the view opens, we accept events so row buttons work.
        viewModel.$isOpen
            .receive(on: DispatchQueue.main)
            .sink { [weak panel] isOpen in
                panel?.ignoresMouseEvents = !isOpen
            }
            .store(in: &cancellables)

        installMouseMonitors()
        reconcile(sessions: provider.currentSessions)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Convenience used by the router's collapse callback and the
    /// AppDelegate shutdown path. Overrides `NSWindowController.close()`
    /// so external callers use the same entry point; we only collapse the
    /// SwiftUI pill state here and leave window tear-down to `shutdown()`.
    override func close() {
        viewModel.close()
    }

    /// Called by `AppDelegate` when the island.enabled setting flips off.
    /// Removes the panel, cancels subscriptions, breaks the router's
    /// retain on self.
    func shutdown() {
        cancellables.removeAll()
        removeMouseMonitors()
        window?.orderOut(nil)
        window?.contentView = nil
        self.window = nil
    }

    // MARK: - Private

    private func reconcile(sessions: [IslandSession]) {
        if sessions.isEmpty {
            window?.orderOut(nil)
        } else if window?.isVisible != true {
            window?.orderFront(nil)
        }
    }

    // MARK: - Mouse monitors

    private func installMouseMonitors() {
        // Global monitor: fires for clicks in OTHER apps (when cmux is not
        // the active app). Used to catch the "click the pill from another
        // app to open the island" case. Global monitors MUST NOT consume
        // events — they only observe.
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown]
        ) { [weak self] _ in
            let location = NSEvent.mouseLocation
            DispatchQueue.main.async {
                self?.handleClick(at: location)
            }
        }

        // Local monitor: fires for clicks INSIDE cmux. Needed when the user
        // is currently focused on cmux and clicks on the pill from within
        // their own app. Must return the event so the normal delivery path
        // continues (SwiftUI buttons in the expanded row still need it).
        localMouseMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown]
        ) { [weak self] event in
            let location = NSEvent.mouseLocation
            self?.handleClick(at: location)
            return event
        }
    }

    private func removeMouseMonitors() {
        if let monitor = globalMouseMonitor {
            NSEvent.removeMonitor(monitor)
            globalMouseMonitor = nil
        }
        if let monitor = localMouseMonitor {
            NSEvent.removeMonitor(monitor)
            localMouseMonitor = nil
        }
    }

    /// Decide whether a mouse-down at the given screen location should
    /// open or close the island. Called for every left-click globally + locally.
    private func handleClick(at screenLocation: NSPoint) {
        // Ignore clicks when there's nothing to show.
        guard !viewModel.sessions.isEmpty else { return }

        let pillRect = currentShapeRectInScreenCoordinates()
        let hitsPill = pillRect.contains(screenLocation)

        if viewModel.isOpen {
            // Expanded: any click outside the expanded shape collapses
            // the island. Clicks inside the shape either land on a row
            // (handled by SwiftUI's Button) or on empty shape space
            // (ignored — doesn't close).
            if !hitsPill {
                viewModel.close()
            }
        } else {
            // Collapsed: only clicks inside the closed pill rect open it.
            if hitsPill {
                viewModel.open()
            }
        }
    }

    /// Current shape rect in *screen coordinates* (origin bottom-left,
    /// Y increases upward — same coordinate system as `NSEvent.mouseLocation`).
    ///
    /// The SwiftUI `NotchShape` is rendered centered at the top of the
    /// panel, which is positioned against the top of `targetScreen`. The
    /// shape's size comes from the view model and changes when the island
    /// opens or closes.
    private func currentShapeRectInScreenCoordinates() -> NSRect {
        let shapeSize = viewModel.shapeSize
        let screenFrame = targetScreen.frame
        let centerX = screenFrame.origin.x + screenFrame.width / 2
        let top = screenFrame.maxY
        return NSRect(
            x: centerX - shapeSize.width / 2,
            y: top - shapeSize.height,
            width: shapeSize.width,
            height: shapeSize.height
        )
    }

    // MARK: - Screen resolution

    private static func resolveScreen() -> NSScreen {
        if let notched = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) {
            return notched
        }
        return NSScreen.main ?? NSScreen.screens.first ?? NSScreen()
    }

    /// Returns the physical notch rect size, or a synthetic `(200, 32)`
    /// on non-notch Macs so the geometry stays consistent.
    private static func resolveNotchSize(on screen: NSScreen) -> CGSize {
        let insetTop = screen.safeAreaInsets.top
        if insetTop > 0 {
            // auxiliaryTopLeftArea / auxiliaryTopRightArea expose the menu-
            // bar regions on either side of the physical notch on macOS
            // Sequoia+. If they aren't available, fall back to a fraction of
            // the screen width. The exact notch width is not critical for
            // correctness — only for visual centering.
            let leftWidth = screen.auxiliaryTopLeftArea?.width ?? 0
            let rightWidth = screen.auxiliaryTopRightArea?.width ?? 0
            let notchWidth = max(120, screen.frame.width - leftWidth - rightWidth)
            return CGSize(width: notchWidth, height: insetTop)
        }
        return CGSize(width: 200, height: 32)
    }
}
