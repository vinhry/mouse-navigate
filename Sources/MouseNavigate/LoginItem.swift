import ServiceManagement

/// Launch at Login, which macOS keeps for the app itself.
@MainActor
enum LoginItem {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// Registered, but macOS is holding it until the user allows it in System Settings.
    static var needsApproval: Bool {
        SMAppService.mainApp.status == .requiresApproval
    }

    /// Switches it on or off. One that is waiting for approval sends the user to approve it,
    /// since registering again would change nothing. Says why when macOS refuses.
    static func toggle() {
        set(!isEnabled)
    }

    static func set(_ enabled: Bool) {
        let service = SMAppService.mainApp
        do {
            if enabled {
                if service.status == .requiresApproval {
                    SMAppService.openSystemSettingsLoginItems()
                } else if service.status != .enabled {
                    try service.register()
                }
            } else if service.status == .enabled || service.status == .requiresApproval {
                try service.unregister()
            }
        } catch {
            // Typically an unsigned or unbundled build, which macOS will not start at login.
            Log.launch.error("Launch at Login could not be changed: \(error.localizedDescription, privacy: .public)")
            AlertPresenter.modal(
                "Launch at Login couldn't be changed",
                error.localizedDescription
                    + "\n\nmacOS starts only a signed copy that runs from an app bundle at login, "
                    + "so a build run from source or from the Terminal cannot be registered.",
                style: .warning
            )
        }
    }
}
