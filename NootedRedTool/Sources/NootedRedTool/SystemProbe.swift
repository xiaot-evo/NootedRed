import Foundation

enum SystemProbe {
    static func snapshot() async -> MachineInfo {
        var info = MachineInfo()

        async let version = CommandRunner.run("/usr/bin/sw_vers", ["-productVersion"])
        async let build = CommandRunner.run("/usr/bin/sw_vers", ["-buildVersion"])
        async let kernel = CommandRunner.run("/usr/sbin/sysctl", ["-n", "kern.osversion"])
        async let arch = CommandRunner.run("/usr/bin/uname", ["-m"])
        async let host = CommandRunner.run("/bin/hostname", [])
        async let model = CommandRunner.run("/usr/sbin/sysctl", ["-n", "hw.model"])
        async let cpu = CommandRunner.run("/usr/sbin/sysctl", ["-n", "machdep.cpu.brand_string"])
        async let mem = CommandRunner.run("/usr/sbin/sysctl", ["-n", "hw.memsize"])
        async let gpu = CommandRunner.run("/usr/sbin/system_profiler", ["SPDisplaysDataType"])
        async let nvram = CommandRunner.run("/usr/sbin/nvram", ["-p"])
        async let sip = CommandRunner.run("/usr/bin/csrutil", ["status"])
        async let loaded = CommandRunner.run("/usr/bin/kmutil", ["showloaded", "--list-only"])
        async let userPatch = CommandRunner.run("/usr/sbin/ioreg", ["-p", "IOService", "-n", "NootedRedUserPatch", "-r", "-l"])

        let versionText = await version.output
        let buildText = await build.output
        let kernelText = await kernel.output
        info.osVersion = versionText.isEmpty ? "—" : versionText
        info.build = buildText.isEmpty ? "—" : buildText
        info.kernel = kernelText.isEmpty ? "—" : kernelText
        let archText = await arch.output
        info.architecture = archText.isEmpty ? "—" : archText
        let hostText = await host.output
        info.hostname = hostText.isEmpty ? "—" : hostText
        let modelText = await model.output
        info.model = modelText.isEmpty ? "—" : modelText
        let cpuText = await cpu.output
        info.cpu = cpuText.isEmpty ? "—" : cpuText

        if let memory = UInt64(await mem.output) {
            info.memory = String(format: "%.0f GB", Double(memory) / 1_073_741_824.0)
        }

        let gpuText = await gpu.output
        info.gpu = parseGPU(gpuText)

        let nvramText = await nvram.output
        info.bootArgs = parseBootArgs(nvramText)

        let sipText = await sip.output
        info.sip = sipText.isEmpty ? "—" : sipText

        let loadedText = await loaded.output
        if let version = parseKextVersion(loadedText, identifier: "org.ChefKiss.NootedRed") {
            info.kextVersion = version
        }
        if let version = parseKextVersion(loadedText, identifier: "org.ChefKiss.NootedRedUserPatch") {
            info.userPatchVersion = version
        }

        let userPatchText = await userPatch.output
        info.appliedPages = parseIoregValue(userPatchText, key: "NRedUserPatchAppliedPages") ?? "—"
        info.appliedSites = parseIoregValue(userPatchText, key: "NRedUserPatchSites") ?? "—"

        let efiConfig = FileManager.default.fileExists(atPath: "/Volumes/NO NAME/EFI/OC/config.plist")
        info.efiState = efiConfig ? "已挂载" : "未挂载"
        info.efiConfig = efiConfig ? "/Volumes/NO NAME/EFI/OC/config.plist" : "—"

        info.gpuHang = await lastGPUHang()

        return info
    }

    static func currentKexts() async -> [KextFileInfo] {
        let base = URL(fileURLWithPath: "/Volumes/NO NAME/EFI/OC/Kexts")
        guard FileManager.default.fileExists(atPath: base.path) else {
            return [
                KextFileInfo(name: "NootedRed.kext", version: "—", path: "EFI 未挂载", enabled: false, symbol: "shippingbox"),
                KextFileInfo(name: "NootedRedUserPatch.kext", version: "—", path: "EFI 未挂载", enabled: false, symbol: "shippingbox")
            ]
        }

        var result: [KextFileInfo] = []
        let config = NSDictionary(contentsOfFile: "/Volumes/NO NAME/EFI/OC/config.plist")
        let kernel = config?["Kernel"] as? [String: Any]
        let addEntries = kernel?["Add"] as? [[String: Any]] ?? []
        for name in ["NootedRed.kext", "NootedRedUserPatch.kext"] {
            let path = base.appendingPathComponent(name)
            let info = path.appendingPathComponent("Contents/Info.plist")
            let version = (NSDictionary(contentsOf: info)?["CFBundleVersion"] as? String) ?? "—"
            let entry = addEntries.first { ($0["BundlePath"] as? String) == name }
            let enabled = (entry?["Enabled"] as? Bool) ?? false
            result.append(KextFileInfo(name: name, version: version, path: path.path, enabled: enabled,
                                       symbol: name.contains("UserPatch") ? "square.stack.3d.up" : "cpu"))
        }
        return result
    }

    static func parseGPU(_ text: String) -> String {
        let lines = text.components(separatedBy: .newlines)
        for line in lines {
            if line.contains("Chipset Model:"), let value = line.split(separator: ":", maxSplits: 1).last {
                return value.trimmingCharacters(in: .whitespaces)
            }
        }
        return "—"
    }

    static func parseBootArgs(_ text: String) -> String {
        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("boot-args") {
                let parts = trimmed.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: true)
                if parts.count > 1 { return parts[1].trimmingCharacters(in: .whitespaces) }
                let parts2 = trimmed.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
                if parts2.count > 1 { return String(parts2[1]).trimmingCharacters(in: .whitespaces) }
            }
        }
        return ""
    }

    static func parseKextVersion(_ text: String, identifier: String) -> String? {
        for line in text.components(separatedBy: .newlines) where line.contains(identifier) {
            let pieces = line.split(separator: " ")
            if let index = pieces.firstIndex(where: { $0.hasPrefix("(") && $0.hasSuffix(")") }) {
                return String(pieces[index]).trimmingCharacters(in: CharacterSet(charactersIn: "()"))
            }
        }
        return nil
    }

    static func parseIoregValue(_ text: String, key: String) -> String? {
        for line in text.components(separatedBy: .newlines) where line.contains("\"\(key)\"") {
            let pieces = line.split(separator: "=", maxSplits: 1)
            if pieces.count == 2 {
                return pieces[1].trimmingCharacters(in: CharacterSet(charactersIn: " \t\""))
            }
        }
        return nil
    }

    static func lastGPUHang() async -> String {
        let result = await CommandRunner.run(
            "/usr/bin/log",
            ["show", "--last", "5m", "--style", "compact",
             "--predicate", "eventMessage CONTAINS \"GPU hang\""],
            timeout: 18
        )
        guard result.status == 0, result.output.contains("GPU hang:") else { return "最近未发现" }
        return "最近 5 分钟发现 GPU hang"
    }
}
