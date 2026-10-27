import Foundation

enum HealthChecker {
    static func evaluate(_ info: MachineInfo, kexts: [KextFileInfo]) -> [HealthItem] {
        var items: [HealthItem] = []

        let nootedLoaded = info.kextVersion != "未加载"
        items.append(HealthItem(
            title: "NootedRed 主 kext",
            detail: nootedLoaded ? "已由内核加载。" : "未检测到已加载的 NootedRed 主 kext。",
            value: info.kextVersion,
            level: nootedLoaded ? .pass : .fail
        ))

        let patchLoaded = info.userPatchVersion != "未加载"
        let pages = Int(info.appliedPages) ?? 0
        let patchLevel: HealthLevel
        let patchDetail: String
        if !patchLoaded {
            patchLevel = .fail
            patchDetail = "未检测到 NootedRedUserPatch 已加载。"
        } else if pages == 0 {
            patchLevel = .warning
            patchDetail = "UserPatch 已加载，但尚未报告应用页；打开应用后再检查。"
        } else if pages >= 13 {
            patchLevel = .pass
            patchDetail = "13 个用户态补丁页已应用。"
        } else {
            patchLevel = .warning
            patchDetail = "只应用了 \(pages) 页，可能有页面未匹配。"
        }
        items.append(HealthItem(
            title: "用户态补丁",
            detail: patchDetail,
            value: patchLoaded ? "\(pages) 页 / \(info.appliedSites) sites" : "未加载",
            level: patchLevel
        ))

        let gpuOK = info.gpu != "—"
        items.append(HealthItem(
            title: "图形设备",
            detail: gpuOK ? "系统已识别 AMD 图形设备。" : "未从 System Profiler 读取到 GPU 信息。",
            value: info.gpu,
            level: gpuOK ? .pass : .warning
        ))

        let sipOK = info.sip.lowercased().contains("disabled")
        items.append(HealthItem(
            title: "SIP",
            detail: sipOK ? "SIP 已关闭，符合常见 hackintosh 配置。" : "SIP 可能仍然启用；部分 kext 注入方式会受影响。",
            value: info.sip,
            level: sipOK ? .pass : .warning
        ))

        let efiOK = info.efiState == "已挂载"
        items.append(HealthItem(
            title: "EFI 配置",
            detail: efiOK ? "EFI 已挂载，可读取 OpenCore 配置。" : "EFI 未挂载。更新 kext 或修改 OpenCore 参数前需要挂载。",
            value: info.efiState,
            level: efiOK ? .pass : .warning
        ))

        let hangOK = info.gpuHang == "最近未发现"
        items.append(HealthItem(
            title: "GPU 稳定性",
            detail: hangOK ? "最近 5 分钟没有发现 GPU hang 日志。" : info.gpuHang,
            value: hangOK ? "正常" : "发现记录",
            level: hangOK ? .pass : .fail
        ))

        let bootArgs = info.bootArgs
        let vda = bootArgs.contains("-NRedVDA")
        items.append(HealthItem(
            title: "VDA 硬件解码",
            detail: vda ? "已通过 boot-arg 启用 VDA 用户态补丁。" : "未启用 -NRedVDA；视频硬解可能不可用。",
            value: vda ? "已启用" : "未启用",
            level: vda ? .pass : .info
        ))

        let versionsMatch = kexts.allSatisfy { $0.version != "—" }
        items.append(HealthItem(
            title: "EFI kext 文件",
            detail: versionsMatch ? "可在 EFI 中读取 NootedRed kext 版本。" : "EFI 未挂载或 kext 文件缺失。",
            value: kexts.map { "\($0.name): \($0.version)" }.joined(separator: "  "),
            level: versionsMatch ? .pass : .warning
        ))

        return items
    }
}
