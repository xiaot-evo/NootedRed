import Foundation

struct CommandResult {
    let status: Int32
    let output: String

    var succeeded: Bool { status == 0 }
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

    /// 通过 `osascript` 的 `with administrator privileges` 以 root 身份执行 shell 命令。
    /// 用户取消授权时返回非零状态，可用 `isUserCancellation` 识别。
    static func runAsAdmin(_ command: String, timeout: TimeInterval = 60) async -> CommandResult {
        let escaped = command
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let script = "do shell script \"\(escaped)\" with administrator privileges"
        return await run("/usr/bin/osascript", ["-e", script], timeout: timeout)
    }

    /// 把任意字符串安全地包进 shell 单引号（内部单引号转为 `'\''`）。
    static func shellSingleQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// 用户在弹出的管理员授权窗口中点了“取消”。
    static func isUserCancellation(_ result: CommandResult) -> Bool {
        let text = result.output
        return text.contains("User canceled")
            || text.contains("User cancelled")
            || text.contains("(-128)")
            || text.contains("取消")
    }
}
