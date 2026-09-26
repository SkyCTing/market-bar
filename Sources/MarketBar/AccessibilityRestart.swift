import AppKit

struct AccessibilityRestartPolicy {
    private var observedDenial = false
    private var attemptedRestart = false

    mutating func shouldRestart(trusted: Bool, canRestart: Bool) -> Bool {
        if !trusted {
            observedDenial = true
            return false
        }
        guard observedDenial, !attemptedRestart, canRestart else { return false }
        attemptedRestart = true
        return true
    }
}

@MainActor
enum AccessibilityRestart {
    static func relaunch(onFailure: @escaping @MainActor @Sendable (String) -> Void) {
        let appURL = Bundle.main.bundleURL
        guard appURL.pathExtension == "app" else {
            onFailure("当前程序不是从应用包启动的")
            return
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        configuration.activates = false
        let currentPID = ProcessInfo.processInfo.processIdentifier
        NSWorkspace.shared.openApplication(at: appURL, configuration: configuration) { app, error in
            let newPID = app?.processIdentifier
            let failure = error?.localizedDescription
            Task { @MainActor in
                if let failure {
                    onFailure(failure)
                } else if let newPID, newPID != currentPID {
                    NSApp.terminate(nil)
                } else {
                    onFailure("系统没有启动新的应用进程")
                }
            }
        }
    }
}
