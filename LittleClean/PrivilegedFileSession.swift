import AppKit
import Foundation
import LocalAuthentication
import Security
import ServiceManagement

/// Performs privileged file operations after the current user authenticates.
///
/// Apple's administrator dialog does not offer Touch ID to third-party apps,
/// so this session prefers Local Authentication (Touch ID, with password
/// fallback) plus a privileged helper. If the helper is unavailable, it falls
/// back to Authorization Services / AppleScript, which can only ask for a password.
nonisolated final class PrivilegedFileSession: @unchecked Sendable {
    private var helperConnection: NSXPCConnection?
    private var authorization: AuthorizationRef?
    private var didCancel = false
    private var didAuthenticateWithLocalAuthentication = false

    deinit {
        invalidate()
    }

    func invalidate() {
        helperConnection?.invalidate()
        helperConnection = nil
        if let authorization {
            AuthorizationFree(authorization, [.destroyRights])
            self.authorization = nil
        }
    }

    func remove(path: String) -> Bool {
        if didCancel { return false }
        if isHelperEnabled {
            guard authenticateWithTouchIDOrPassword() else { return false }
            return helperRemove(path: path)
        }
        return runWithoutHelper(
            tool: "/bin/rm",
            arguments: ["-rf", path],
            appleScript: { self.removeWithAppleScript(path: path) }
        )
    }

    func moveToTrash(path: String) -> Bool {
        if didCancel { return false }
        let destination = uniqueTrashDestination(for: path)
        if isHelperEnabled {
            guard authenticateWithTouchIDOrPassword() else { return false }
            return helperMove(path: path, to: destination)
        }
        return runWithoutHelper(
            tool: "/bin/mv",
            arguments: ["-f", path, destination],
            appleScript: { self.trashWithAppleScript(path: path, destination: destination) }
        )
    }

    private func runWithoutHelper(
        tool: String,
        arguments: [String],
        appleScript: () -> Bool
    ) -> Bool {
        if executeAuthorized(tool: tool, arguments: arguments) {
            return true
        }
        // User dismissed the first password dialog; do not pop a second one.
        if didCancel { return false }
        return appleScript()
    }

    private func uniqueTrashDestination(for path: String) -> String {
        let trashDir = ("~/.Trash" as NSString).expandingTildeInPath
        let baseName = URL(fileURLWithPath: path).lastPathComponent
        var destination = (trashDir as NSString).appendingPathComponent(baseName)
        if FileManager.default.fileExists(atPath: destination) {
            destination = (trashDir as NSString).appendingPathComponent(
                "\(Int(Date().timeIntervalSince1970))-\(baseName)"
            )
        }
        return destination
    }

    // MARK: - Local Authentication (Touch ID + password)

    private func authenticateWithTouchIDOrPassword() -> Bool {
        if didAuthenticateWithLocalAuthentication { return true }
        if didCancel { return false }

        let context = LAContext()
        context.localizedFallbackTitle = String(localized: "Use Password")
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: nil) else {
            return false
        }

        let reason = String(localized: "Authenticate to modify protected files.")
        let semaphore = DispatchSemaphore(value: 0)
        var success = false
        context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { ok, _ in
            success = ok
            semaphore.signal()
        }
        semaphore.wait()

        if success {
            didAuthenticateWithLocalAuthentication = true
            return true
        }
        didCancel = true
        return false
    }

    // MARK: - Privileged helper

    private var isHelperEnabled: Bool {
        SMAppService.daemon(plistName: LittleCleanHelperConst.launchdPlistName).status == .enabled
    }

    private func helperProxy(onError: @escaping () -> Void) -> LittleCleanHelperProtocol? {
        if helperConnection == nil {
            let connection = NSXPCConnection(
                machServiceName: LittleCleanHelperConst.machServiceName,
                options: .privileged
            )
            connection.remoteObjectInterface = NSXPCInterface(with: LittleCleanHelperProtocol.self)
            connection.invalidationHandler = { [weak self] in
                self?.helperConnection = nil
            }
            connection.interruptionHandler = { [weak self] in
                self?.helperConnection = nil
            }
            connection.resume()
            helperConnection = connection
        }
        return helperConnection?.remoteObjectProxyWithErrorHandler { _ in
            onError()
        } as? LittleCleanHelperProtocol
    }

    private func helperRemove(path: String) -> Bool {
        helperCall { finish in
            guard let proxy = self.helperProxy(onError: { finish(false) }) else {
                finish(false)
                return
            }
            proxy.removePath(path) { ok, _ in
                finish(ok)
            }
        }
    }

    private func helperMove(path: String, to destination: String) -> Bool {
        helperCall { finish in
            guard let proxy = self.helperProxy(onError: { finish(false) }) else {
                finish(false)
                return
            }
            proxy.movePath(path, to: destination) { ok, _ in
                finish(ok)
            }
        }
    }

    private func helperCall(_ body: (@escaping (Bool) -> Void) -> Void) -> Bool {
        let lock = NSLock()
        var finished = false
        let semaphore = DispatchSemaphore(value: 0)
        var success = false
        let finish: (Bool) -> Void = { ok in
            lock.lock()
            defer { lock.unlock() }
            guard !finished else { return }
            finished = true
            success = ok
            semaphore.signal()
        }
        body(finish)
        _ = semaphore.wait(timeout: .now() + 180)
        return success
    }

    // MARK: - Authorization Services fallback (password only)

    private func executeAuthorized(tool: String, arguments: [String]) -> Bool {
        guard let authorization = obtainAuthorization() else { return false }
        return tool.withCString { toolPointer in
            let cStrings = arguments.map { strdup($0) }
            defer {
                for pointer in cStrings {
                    free(pointer)
                }
            }
            var argv = cStrings + [nil]
            var communicationsPipe: UnsafeMutablePointer<FILE>?
            let status = argv.withUnsafeMutableBufferPointer { buffer in
                AuthorizationExecuteWithPrivileges(
                    authorization,
                    toolPointer,
                    [],
                    buffer.baseAddress,
                    &communicationsPipe
                )
            }
            if let communicationsPipe {
                drain(communicationsPipe)
            }
            return status == errAuthorizationSuccess
        }
    }

    private func obtainAuthorization() -> AuthorizationRef? {
        if let authorization { return authorization }
        if didCancel { return nil }

        var authRef: AuthorizationRef?
        var status = AuthorizationCreate(nil, nil, [], &authRef)
        guard status == errAuthorizationSuccess, let authRef else { return nil }

        let prompt = String(localized: "LittleClean needs administrator access to modify protected files.")
        let rightName = "system.privilege.admin"
        let promptKey = "prompt"
        status = prompt.withCString { promptPointer in
            rightName.withCString { rightPointer in
                promptKey.withCString { promptKeyPointer in
                    var right = AuthorizationItem(
                        name: rightPointer,
                        valueLength: 0,
                        value: nil,
                        flags: 0
                    )
                    var environmentItem = AuthorizationItem(
                        name: promptKeyPointer,
                        valueLength: prompt.utf8.count,
                        value: UnsafeMutableRawPointer(mutating: promptPointer),
                        flags: 0
                    )
                    return withUnsafeMutablePointer(to: &right) { rightItem in
                        withUnsafeMutablePointer(to: &environmentItem) { environmentItemPointer in
                            var rights = AuthorizationRights(count: 1, items: rightItem)
                            var environment = AuthorizationEnvironment(count: 1, items: environmentItemPointer)
                            return AuthorizationCopyRights(
                                authRef,
                                &rights,
                                &environment,
                                [.interactionAllowed, .extendRights, .preAuthorize],
                                nil
                            )
                        }
                    }
                }
            }
        }

        if status == errAuthorizationCanceled {
            didCancel = true
            AuthorizationFree(authRef, [.destroyRights])
            return nil
        }
        guard status == errAuthorizationSuccess else {
            AuthorizationFree(authRef, [.destroyRights])
            return nil
        }
        authorization = authRef
        return authRef
    }

    private func drain(_ pipe: UnsafeMutablePointer<FILE>) {
        let fd = fileno(pipe)
        var buffer = [UInt8](repeating: 0, count: 256)
        while Darwin.read(fd, &buffer, buffer.count) > 0 {}
        fclose(pipe)
    }

    // MARK: - AppleScript fallback

    private func removeWithAppleScript(path: String) -> Bool {
        let script = "do shell script \"rm -rf \" & quoted form of \"\(path)\" with administrator privileges"
        return runAppleScript(script)
    }

    private func trashWithAppleScript(path: String, destination: String) -> Bool {
        let script = """
        do shell script "mv -f " & quoted form of "\(path)" & " " & quoted form of "\(destination)" with administrator privileges
        """
        return runAppleScript(script)
    }

    private func runAppleScript(_ source: String) -> Bool {
        var errorDict: NSDictionary?
        guard let appleScript = NSAppleScript(source: source) else { return false }
        appleScript.executeAndReturnError(&errorDict)
        if errorDict == nil { return true }
        let code = errorDict?[NSAppleScript.errorNumber] as? Int
        if code == -128 || code == Int(errAuthorizationCanceled) {
            didCancel = true
        }
        return false
    }
}

@_silgen_name("AuthorizationExecuteWithPrivileges")
private nonisolated func AuthorizationExecuteWithPrivileges(
    _ authorization: AuthorizationRef,
    _ pathToTool: UnsafePointer<CChar>,
    _ options: AuthorizationFlags,
    _ arguments: UnsafePointer<UnsafeMutablePointer<CChar>?>?,
    _ communicationsPipe: UnsafeMutablePointer<UnsafeMutablePointer<FILE>?>?
) -> OSStatus
