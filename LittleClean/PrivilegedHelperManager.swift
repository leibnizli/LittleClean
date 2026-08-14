import Combine
import Foundation
import ServiceManagement

@MainActor
final class PrivilegedHelperManager: ObservableObject {
    static let shared = PrivilegedHelperManager()
    static let preferenceKey = "enableTouchIDHelper"
    static let didEnableKey = "touchIDHelperDidBecomeEnabled"

    @Published var isOn = false
    @Published var requiresApproval = false
    @Published var isBusy = false
    @Published var errorMessage: String?

    /// Latest value the user asked for. Rapid toggles overwrite this so only
    /// the final on/off state is applied to SMAppService.
    private var desiredOn: Bool?
    private var isApplying = false

    private var service: SMAppService {
        SMAppService.daemon(plistName: LittleCleanHelperConst.launchdPlistName)
    }

    var statusMessage: String {
        if requiresApproval {
            return String(
                localized: "Allow LittleClean in System Settings → General → Login Items & Extensions."
            )
        }
        if isOn {
            return String(localized: "Touch ID is available for protected files.")
        }
        return String(localized: "Protected files will ask for an administrator password.")
    }

    func refresh() {
        applyStatusToPublishedState()
    }

    func setOn(_ on: Bool) async {
        desiredOn = on
        isOn = on
        requiresApproval = on && service.status != .enabled
        errorMessage = nil
        UserDefaults.standard.set(on, forKey: Self.preferenceKey)
        if !on {
            UserDefaults.standard.set(false, forKey: Self.didEnableKey)
        }
        guard !isApplying else { return }
        await applyDesiredState()
    }

    func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    private func applyDesiredState() async {
        isApplying = true
        isBusy = true
        defer {
            isApplying = false
            isBusy = false
        }

        while let target = desiredOn {
            desiredOn = nil
            await apply(target)
        }
        applyStatusToPublishedState()
    }

    private func apply(_ on: Bool) async {
        let status = service.status
        do {
            if on {
                guard status != .enabled else {
                    errorMessage = nil
                    return
                }
                try service.register()
                errorMessage = nil
                if service.status == .requiresApproval, desiredOn != false {
                    SMAppService.openSystemSettingsLoginItems()
                }
            } else {
                guard status == .enabled || status == .requiresApproval else {
                    errorMessage = nil
                    return
                }
                try await service.unregister()
                errorMessage = nil
            }
        } catch {
            errorMessage = error.localizedDescription
            if on, service.status == .requiresApproval, desiredOn != false {
                errorMessage = nil
                SMAppService.openSystemSettingsLoginItems()
            }
        }
    }

    private func applyStatusToPublishedState() {
        let status = service.status
        let defaults = UserDefaults.standard
        let didBecomeEnabled = defaults.bool(forKey: Self.didEnableKey)

        if status == .enabled {
            defaults.set(true, forKey: Self.preferenceKey)
            defaults.set(true, forKey: Self.didEnableKey)
            requiresApproval = false
            isOn = true
            return
        }

        // System Settings turned off a helper that was previously running.
        // Match the app toggle to that, instead of leaving it looking enabled.
        if didBecomeEnabled, desiredOn == nil, !isApplying {
            defaults.set(false, forKey: Self.preferenceKey)
            defaults.set(false, forKey: Self.didEnableKey)
            requiresApproval = false
            isOn = false
            errorMessage = nil
            if status == .requiresApproval {
                Task { try? await service.unregister() }
            }
            return
        }

        let prefersHelper = defaults.bool(forKey: Self.preferenceKey)
        if prefersHelper {
            isOn = true
            requiresApproval = true
            return
        }

        isOn = false
        requiresApproval = false
    }
}
