import Foundation

struct BootArgumentState {
    var raw: String = ""
    var knownFlags: Set<String> = []
    var otherArguments: [String] = []

    var allArguments: [String] {
        var result = otherArguments
        for feature in BootFeature.catalog where knownFlags.contains(feature.flag) {
            result.append(feature.flag)
        }
        return result
    }

    var serialized: String {
        allArguments.joined(separator: " ")
    }

    static func parse(_ raw: String) -> BootArgumentState {
        let tokens = raw.split(separator: " ").map(String.init)
        let flags = Set(tokens.filter { $0.hasPrefix("-") })
        let known = Set(BootFeature.catalog.map(\.flag))
        return BootArgumentState(raw: raw, knownFlags: flags.intersection(known),
                                 otherArguments: tokens.filter { !known.contains($0) })
    }
}

enum BootArgumentManager {
    static func load() async -> BootArgumentState {
        let result = await CommandRunner.run("/usr/sbin/nvram", ["-p"])
        let raw = SystemProbe.parseBootArgs(result.output)
        return BootArgumentState.parse(raw)
    }

    static func save(_ state: BootArgumentState) async -> CommandResult {
        let value = state.serialized
        if value.isEmpty {
            return await CommandRunner.runAsAdmin("/usr/sbin/nvram -d boot-args")
        }
        let escaped = value.replacingOccurrences(of: "'", with: "'\\''")
        return await CommandRunner.runAsAdmin("/usr/sbin/nvram boot-args='\(escaped)'")
    }
}
