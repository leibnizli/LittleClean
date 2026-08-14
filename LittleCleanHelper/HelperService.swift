import Foundation
import Security

final class HelperXPCDelegate: NSObject, NSXPCListenerDelegate {
    func listener(
        _ listener: NSXPCListener,
        shouldAcceptNewConnection newConnection: NSXPCConnection
    ) -> Bool {
        guard HelperConnectionAuthorizer.isLittleClean(newConnection) else {
            newConnection.invalidate()
            return false
        }

        newConnection.exportedInterface = NSXPCInterface(with: LittleCleanHelperProtocol.self)
        newConnection.exportedObject = HelperService()
        newConnection.resume()
        return true
    }
}

final class HelperService: NSObject, LittleCleanHelperProtocol {
    func removePath(_ path: String, withReply reply: @escaping (Bool, String?) -> Void) {
        let standardized = standardizedPath(path)
        guard HelperPathPolicy.allowsRemoval(of: standardized) else {
            reply(false, "Path is not allowed.")
            return
        }
        do {
            try FileManager.default.removeItem(atPath: standardized)
            reply(true, nil)
        } catch {
            reply(false, error.localizedDescription)
        }
    }

    func movePath(
        _ path: String,
        to destination: String,
        withReply reply: @escaping (Bool, String?) -> Void
    ) {
        let source = standardizedPath(path)
        let dest = standardizedPath(destination)
        guard HelperPathPolicy.allowsRemoval(of: source),
              HelperPathPolicy.allowsTrashDestination(dest) else {
            reply(false, "Path is not allowed.")
            return
        }
        do {
            try FileManager.default.moveItem(atPath: source, toPath: dest)
            reply(true, nil)
        } catch {
            reply(false, error.localizedDescription)
        }
    }

    private func standardizedPath(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
    }
}

enum HelperPathPolicy {
    private static let forbiddenPrefixes = [
        "/System",
        "/bin",
        "/sbin",
        "/private/etc",
        "/private/var/db",
        "/Library/Apple",
        "/Library/OSAnalytics"
    ]

    private static let forbiddenExact = [
        "/",
        "/Applications",
        "/Library",
        "/Users",
        "/private",
        "/opt",
        "/usr",
        "/usr/local",
        "/opt/homebrew"
    ]

    static func allowsRemoval(of path: String) -> Bool {
        guard !path.isEmpty, path.hasPrefix("/"), !path.contains("\0") else { return false }
        if forbiddenExact.contains(path) { return false }
        if path == "/usr" || (path.hasPrefix("/usr/") && !path.hasPrefix("/usr/local/")) {
            return false
        }
        if forbiddenPrefixes.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) {
            return false
        }
        if let appBundlePath = containingAppBundlePath(),
           path == appBundlePath || path.hasPrefix(appBundlePath + "/") {
            return false
        }
        return true
    }

    static func allowsTrashDestination(_ path: String) -> Bool {
        guard allowsRemoval(of: path) else { return false }
        return path.contains("/.Trash/")
    }

    private static func containingAppBundlePath() -> String? {
        var url = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        for _ in 0..<8 {
            if url.pathExtension == "app" {
                return url.standardizedFileURL.path
            }
            let parent = url.deletingLastPathComponent()
            if parent.path == url.path { break }
            url = parent
        }
        return nil
    }
}

enum HelperConnectionAuthorizer {
    static func isLittleClean(_ connection: NSXPCConnection) -> Bool {
        guard let client = guestCode(forPID: connection.processIdentifier),
              let requirement = appRequirement() else {
            return false
        }
        return SecCodeCheckValidity(client, SecCSFlags(rawValue: 0), requirement) == errSecSuccess
    }

    private static func guestCode(forPID pid: pid_t) -> SecCode? {
        var code: SecCode?
        let status = SecCodeCopyGuestWithAttributes(
            nil,
            [kSecGuestAttributePid: pid] as CFDictionary,
            SecCSFlags(rawValue: 0),
            &code
        )
        return status == errSecSuccess ? code : nil
    }

    private static func appRequirement() -> SecRequirement? {
        let statement = """
        identifier "\(LittleCleanHelperConst.appBundleIdentifier)" \
        and certificate leaf[subject.OU] = "\(LittleCleanHelperConst.teamIdentifier)"
        """
        var requirement: SecRequirement?
        let status = SecRequirementCreateWithString(
            statement as CFString,
            SecCSFlags(rawValue: 0),
            &requirement
        )
        return status == errSecSuccess ? requirement : nil
    }
}
