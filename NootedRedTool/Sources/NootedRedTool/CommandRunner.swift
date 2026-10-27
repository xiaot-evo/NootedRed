import Foundation

struct CommandResult {
    let status: Int32
    let output: String
}

enum CommandRunner {
    static func run(_ executable: String, _ arguments: [String], timeout: TimeInterval = 15) async -> CommandResult {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: executable)
                process.arguments = arguments

                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = pipe

                do {
                    try process.run()
                } catch {
                    continuation.resume(returning: CommandResult(status: -1, output: error.localizedDescription))
                    return
                }

                let deadline = DispatchTime.now() + timeout
                DispatchQueue.global().asyncAfter(deadline: deadline) {
                    if process.isRunning { process.terminate() }
                }

                process.waitUntilExit()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let output = String(data: data, encoding: .utf8) ?? ""
                continuation.resume(returning: CommandResult(status: process.terminationStatus,
                                                           output: output.trimmingCharacters(in: .whitespacesAndNewlines)))
            }
        }
    }

    static func runAsAdmin(_ command: String) async -> CommandResult {
        let escaped = command
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let script = "do shell script \"\(escaped)\" with administrator privileges"
        return await run("/usr/bin/osascript", ["-e", script], timeout: 60)
    }
}
