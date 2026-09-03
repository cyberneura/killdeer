import Foundation
import ServiceManagement

/// Whether Killdeer opens itself at login.
///
/// `SMAppService` is the modern replacement for dropping a plist in
/// `~/Library/LaunchAgents`: macOS owns the registration, and the user can turn
/// it off in System Settings without going through the app. The state is
/// therefore read back from the system rather than stored here, so that the
/// menu cannot claim something the system does not agree with.
@MainActor
final class LoginItemController: ObservableObject {
    @Published private(set) var status: SMAppService.Status = .notRegistered
    @Published private(set) var lastError: String?

    /// `SMAppService.mainApp` registers a bundle. `swift run killdeer-app`
    /// produces a bare executable with no bundle to register, so the toggle is
    /// hidden there rather than shown and always failing.
    let isAvailable: Bool

    private var pollingTask: Task<Void, Never>?

    var isEnabled: Bool { status == .enabled }

    init() {
        isAvailable = Bundle.main.bundleURL.pathExtension == "app"
        guard isAvailable else { return }
        status = SMAppService.mainApp.status
        // System Settings can turn the login item off without telling the app.
        // Without this the checkmark goes on claiming it is registered until
        // the next launch.
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                guard !Task.isCancelled else { break }
                self?.status = SMAppService.mainApp.status
            }
        }
    }

    deinit {
        pollingTask?.cancel()
    }

    func setEnabled(_ enabled: Bool) {
        lastError = nil
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            lastError = error.localizedDescription
        }
        // Re-read rather than assuming it took. Registering an app the user has
        // already denied leaves the service in `.requiresApproval`, not enabled.
        status = SMAppService.mainApp.status
    }

    func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
