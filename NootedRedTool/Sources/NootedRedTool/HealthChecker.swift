import Foundation

enum HealthChecker {
    static func evaluate(_ info: MachineInfo, kexts: [KextFileInfo],
                         efi: EFIDiscovery, openCore: OpenCoreInfo?,
                         installedProfile: InstalledProfileSummary?) -> [HealthItem] {
        var items: [HealthItem] = []

        // 1. NootedRed 主 kext
        let nootedLoaded = info.kextVersion != "未加载"
        items.append(HealthItem(
            id: "kext-main",
            title: "NootedRed 主 kext",
            detail: nootedLoaded ? "内核已加载 NootedRed 主 kext。" : "未检测到已加载的 NootedRed 主 kext。",
            value: info.kextVersion,
            level: nootedLoaded ? .pass : .fail,
            remedy: nootedLoaded ? nil : "确认 EFI/OC/Kexts 中有 NootedRed.kext，并在 config.plist 的 Kernel > Add 中启用。",
            page: .kexts
        ))

        // 2. 用户态补丁
        let patchLoaded = info.userPatchVersion != "未加载"
        let pages = Int(info.appliedPages) ?? 0
        let patchLevel: HealthLevel
        let patchDetail: String
        if !patchLoaded {
            patchLevel = .fail
            patchDetail = "未检测到已加载的 NootedRedUserPatch。"
        } else if pages == 0 {
            patchLevel = .info
            patchDetail = "UserPatch 已加载；页面计数是启动快照，可能晚于实际 patch，以硬件解码 / Metal / GL 实测为准。"
        } else if pages >= 13 {
            patchLevel = .pass
            patchDetail = "13 个用户态补丁页已应用。"
        } else {
            patchLevel = .warning
            patchDetail = "只应用了 \(pages) 页，可能有页面未匹配。"
        }
        items.append(HealthItem(
            id: "userpatch",
            title: "用户态补丁",
            detail: patchDetail,
            value: patchLoaded ? "\(pages) 页 / \(info.appliedSites) sites" : "未加载",
            level: patchLevel,
            remedy: patchLoaded ? nil : "确认 NootedRedUserPatch.kext 已安装并在 config.plist 中启用，且主 kext 已加载。",
            page: .kexts
        ))

        // 3. 图形设备
        let gpuOK = info.gpu != "—"
        items.append(HealthItem(
            id: "gpu",
            title: "图形设备",
            detail: gpuOK ? "系统已识别 AMD 图形设备。" : "未从 System Profiler 读取到 GPU 信息。",
            value: info.gpu,
            level: gpuOK ? .pass : .warning,
            remedy: gpuOK ? nil : "确认 BIOS 中核显已启用、显存分配（UMA Frame Buffer）正常。",
            page: nil
        ))

        // 4. SIP
        let sipOK = info.sip.lowercased().contains("disabled")
        items.append(HealthItem(
            id: "sip",
            title: "SIP",
            detail: sipOK ? "SIP 已关闭，符合常见 hackintosh 配置。" : "SIP 可能仍然启用；部分 kext 注入方式会受影响。",
            value: info.sip,
            level: sipOK ? .pass : .warning,
            remedy: sipOK ? nil : "如需注入 kext，请在 config.plist 的 NVRAM > Add 中设置 csr-active-config 关闭 SIP。",
            page: nil
        ))

        // 5. EFI 分区
        let efiMounted = efi.mounted != nil
        let efiDetail: String
        let efiValue: String
        let efiLevel: HealthLevel
        if let mounted = efi.mounted {
            efiLevel = .pass
            efiDetail = "EFI 分区已挂载，可读取并更新 OpenCore 配置。"
            efiValue = "\(mounted.partition.deviceIdentifier) · \(mounted.partition.displayName)"
        } else if efi.partitions.isEmpty {
            efiLevel = .fail
            efiDetail = "未检测到任何 EFI 分区；可能是纯外置启动或磁盘结构异常。"
            efiValue = "未检测到"
        } else {
            efiLevel = .warning
            efiDetail = "检测到 \(efi.partitions.count) 个 EFI 分区，但当前未挂载。"
            efiValue = efi.partitions.map(\.id).joined(separator: " / ")
        }
        items.append(HealthItem(
            id: "efi",
            title: "EFI 分区挂载",
            detail: efiDetail,
            value: efiValue,
            level: efiLevel,
            remedy: efiMounted ? nil : "在「EFI 分区」页挂载 OpenCore 所在的 EFI 分区。",
            page: efiMounted ? nil : .efi
        ))

        // 6. OpenCore 配置
        if !efiMounted {
            items.append(HealthItem(
                id: "opencore",
                title: "OpenCore 配置",
                detail: "EFI 未挂载，暂无法检查 config.plist。",
                value: "待挂载",
                level: .info,
                remedy: "挂载 EFI 后重新检查。",
                page: .efi
            ))
        } else if let openCore, openCore.bootloader == .clover {
            items.append(HealthItem(
                id: "opencore",
                title: "引导器配置",
                detail: "检测到 Clover 配置；本工具只支持 OpenCore（EFI/OC）的读取与写入。",
                value: "Clover",
                level: .warning,
                remedy: "如需写入 OffsetProfile 或管理 kext，请改用 OpenCore 引导。",
                page: .efi
            ))
        } else if let openCore {
            let hasNooted = openCore.hasNootedRed
            let hasPatch = openCore.hasUserPatch
            let level: HealthLevel = hasNooted && hasPatch ? .pass : .warning
            var detail = "config.plist 可读取，Kernel > Add 共 \(openCore.kextEntries.count) 项（启用 \(openCore.enabledKextCount) 项）。"
            if !hasNooted { detail += " NootedRed.kext 未启用。" }
            if !hasPatch { detail += " NootedRedUserPatch.kext 未启用。" }
            items.append(HealthItem(
                id: "opencore",
                title: "OpenCore 配置",
                detail: detail,
                value: [openCore.productName, openCore.bootloader.rawValue]
                    .compactMap { $0 }
                    .joined(separator: " · "),
                level: level,
                remedy: hasNooted && hasPatch ? nil : "在 config.plist 的 Kernel > Add 中启用 NootedRed.kext 与 NootedRedUserPatch.kext。",
                page: hasNooted && hasPatch ? nil : .kexts
            ))
        } else {
            items.append(HealthItem(
                id: "opencore",
                title: "OpenCore 配置",
                detail: "EFI 已挂载，但没有找到 EFI/OC/config.plist。",
                value: "未找到",
                level: .fail,
                remedy: "确认挂载的是 OpenCore 引导分区，而不是普通 EFI 分区。",
                page: .efi
            ))
        }

        // 7. EFI kext 文件
        if !efiMounted {
            items.append(HealthItem(
                id: "efi-kexts",
                title: "EFI kext 文件",
                detail: "EFI 未挂载，无法读取 EFI/OC/Kexts。",
                value: "待挂载",
                level: .info,
                remedy: "挂载 EFI 后重新检查。",
                page: .efi
            ))
        } else if openCore?.bootloader == .clover {
            items.append(HealthItem(
                id: "efi-kexts",
                title: "EFI kext 文件",
                detail: "检测到 Clover 引导器；本工具暂不支持读取 Clover 的 kext 目录。",
                value: "Clover",
                level: .info,
                remedy: "如需使用本工具管理 kext，请改用 OpenCore 引导。",
                page: .efi
            ))
        } else if kexts.isEmpty {
            items.append(HealthItem(
                id: "efi-kexts",
                title: "EFI kext 文件",
                detail: "EFI/OC/Kexts 中没有找到任何 kext。",
                value: "空目录",
                level: .fail,
                remedy: "把 NootedRed.kext 与 NootedRedUserPatch.kext 放入 EFI/OC/Kexts。",
                page: .kexts
            ))
        } else {
            let missing = kexts.filter { $0.isNootedRed && $0.state == .missingFile }
            let disabled = kexts.filter { $0.isNootedRed && $0.state == .disabled }
            let notConfigured = kexts.filter { $0.isNootedRed && $0.state == .notInConfig }
            let level: HealthLevel = missing.isEmpty && disabled.isEmpty && notConfigured.isEmpty
                ? .pass : .warning
            var detail = "共 \(kexts.count) 个 kext，已启用 \(kexts.filter { $0.state == .enabled }.count) 个。"
            if !missing.isEmpty { detail += " 缺少文件：\(missing.map(\.name).joined(separator: "、"))。" }
            if !disabled.isEmpty { detail += " 已禁用：\(disabled.map(\.name).joined(separator: "、"))。" }
            if !notConfigured.isEmpty { detail += " 未加入 config：\(notConfigured.map(\.name).joined(separator: "、"))。" }
            items.append(HealthItem(
                id: "efi-kexts",
                title: "EFI kext 文件",
                detail: detail,
                value: kexts.filter(\.isNootedRed).map { "\($0.name): \($0.state.title)" }.joined(separator: "  "),
                level: level,
                remedy: level == .pass ? nil : "在「Kext 管理」页核对文件与 config.plist 条目。",
                page: level == .pass ? nil : .kexts
            ))
        }

        // 8. OffsetProfile
        if let installedProfile {
            let matchesBuild = installedProfile.build == info.build
            items.append(HealthItem(
                id: "offset-profile",
                title: "OffsetProfile",
                detail: matchesBuild
                    ? "EFI 中的 NootedRedUserPatch 已写入与当前系统匹配的 OffsetProfile。"
                    : "EFI 中的 OffsetProfile 构建号为 \(installedProfile.build)，当前系统为 \(info.build)。",
                value: matchesBuild ? "\(installedProfile.pageCount) 页 · 已写入" : "构建不匹配",
                level: matchesBuild ? .pass : .warning,
                remedy: matchesBuild ? nil : "在「驱动解码」页重新解码并写入 EFI。",
                page: matchesBuild ? nil : .decoder
            ))
        } else {
            items.append(HealthItem(
                id: "offset-profile",
                title: "OffsetProfile",
                detail: "EFI 中的 NootedRedUserPatch 尚未写入用户态解码生成的 OffsetProfile。",
                value: "未写入",
                level: .warning,
                remedy: "在「驱动解码」页解码 GL / Metal / VDA 驱动并写入 EFI。",
                page: .decoder
            ))
        }

        // 9. GPU 稳定性
        let hangOK = info.gpuHang == "最近未发现"
        items.append(HealthItem(
            id: "gpu-hang",
            title: "GPU 稳定性",
            detail: hangOK ? "最近 5 分钟没有发现 GPU hang 日志。" : info.gpuHang,
            value: hangOK ? "正常" : "发现记录",
            level: hangOK ? .pass : .fail,
            remedy: hangOK ? nil : "收集诊断信息并提交反馈；可临时用 -NRedNoAccel 排查。",
            page: hangOK ? nil : .diagnostics
        ))

        // 10. VDA 硬件解码
        let vda = info.bootArgs.contains("-NRedVDA")
        items.append(HealthItem(
            id: "vda",
            title: "VDA 硬件解码",
            detail: vda ? "已通过 boot-arg 启用 VDA 用户态补丁。" : "未启用 -NRedVDA；视频硬解可能不可用。",
            value: vda ? "已启用" : "未启用",
            level: vda ? .pass : .info,
            remedy: vda ? nil : "在「启动参数」页开启 VDA 硬件解码并重启。",
            page: vda ? nil : .bootArguments
        ))

        return items
    }
}
