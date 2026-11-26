import Foundation

/// Installs (or updates) the root helper through the standard macOS administrator prompt.
/// To remove it by hand: `sudo sh Helper/uninstall-helper.sh` from the source tree.
enum HelperInstaller {
    static let socketPath = "/var/run/fancurve.sock"

    private static func resource(_ name: String) -> String? {
        Bundle.main.path(forResource: name, ofType: nil)
    }

    static func install() async -> HelperError? {
        guard let script = resource("install-helper.sh"), let helper = resource("fancurved") else {
            return HelperError(L("error.missingFiles"))
        }
        return await runAsAdmin("/bin/sh \(shellQuote(script)) \(shellQuote(helper)) \(getuid())",
                                prompt: L("installer.prompt"))
    }

    static func shellQuote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    private static func appleScriptString(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    private static func runAsAdmin(_ command: String, prompt: String) async -> HelperError? {
        let source = "do shell script \(appleScriptString(command)) with prompt \(appleScriptString(prompt)) with administrator privileges"
        return await withCheckedContinuation { cont in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            p.arguments = ["-e", source]
            let err = Pipe()
            p.standardError = err
            p.standardOutput = Pipe()
            p.terminationHandler = { proc in
                if proc.terminationStatus == 0 { cont.resume(returning: nil); return }
                let msg = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                // -128 = the user pressed Cancel in the password prompt: not an error worth showing.
                cont.resume(returning: msg.contains("-128") ? nil : HelperError(msg.trimmingCharacters(in: .whitespacesAndNewlines)))
            }
            do { try p.run() } catch { cont.resume(returning: HelperError(error.localizedDescription)) }
        }
    }
}
