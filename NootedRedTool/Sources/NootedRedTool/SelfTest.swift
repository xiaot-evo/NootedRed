import Foundation

/// 无界面自检：`NootedRedTool --self-test`。
///
/// 覆盖不需要管理员授权的关键路径：OffsetProfile 二进制编码、Info.plist 注入、
/// 写入结果回读、EFI 命令安全校验、健康检查文案分支。用于 CI / 无交互验证。
enum SelfTest {
    struct CheckResult {
        let name: String
        let passed: Bool
        let detail: String?

        init(_ name: String, _ passed: Bool, _ detail: String? = nil) {
            self.name = name
            self.passed = passed
            self.detail = detail
        }
    }

    static func cliReport() async -> String {
        let results = await run()
        var lines: [String] = []
        for result in results {
            if result.passed {
                lines.append("PASS: \(result.name)")
            } else {
                let detail = result.detail.map { " — \($0)" } ?? ""
                lines.append("FAIL: \(result.name)\(detail)")
            }
        }
        let failed = results.filter { !$0.passed }.count
        if failed == 0 {
            lines.append("SELF-TEST: PASS (\(results.count) checks)")
        } else {
            lines.append("SELF-TEST: FAIL (\(failed)/\(results.count) failed)")
        }
        return lines.joined(separator: "\n")
    }

    static func run() async -> [CheckResult] {
        var checks: [CheckResult] = []
        let profile = sampleProfile()
        let binary = OffsetProfileGenerator.binaryData(profile)
        let bytes = [UInt8](binary)

        // 1. NRP2 profile 二进制头
        checks.append(CheckResult("profile 二进制 magic 为 NRP3",
                                  Data(binary.prefix(4)) == Data("NRP3".utf8)))
        if bytes.count >= 64 {
            let pageCount = Int(bytes[8]) | (Int(bytes[9]) << 8)
            let siteCount = Int(bytes[10]) | (Int(bytes[11]) << 8)
            let build = String(decoding: bytes[12..<28].prefix { $0 != 0 }, as: UTF8.self)
            checks.append(CheckResult("profile 二进制页数为 2", pageCount == 2, "实际 \(pageCount)"))
            checks.append(CheckResult("profile 二进制站点数为 2", siteCount == 2, "实际 \(siteCount)"))
            checks.append(CheckResult("profile 二进制构建号为 24H232", build == "24H232", "实际 \(build)"))

            let payload = binary.subdata(in: 64..<binary.count)
            let storedChecksum = UInt32(bytes[40]) | (UInt32(bytes[41]) << 8)
                | (UInt32(bytes[42]) << 16) | (UInt32(bytes[43]) << 24)
            let computed = OffsetProfileGenerator.fnv1a32(payload)
            checks.append(CheckResult("profile 二进制 FNV-1a 校验正确", storedChecksum == computed,
                                      "记录 \(String(format: "0x%08X", storedChecksum)) "
                                      + "计算 \(String(format: "0x%08X", computed))"))
        } else {
            checks.append(CheckResult("profile 二进制长度合法", false, "只有 \(bytes.count) 字节"))
        }

        // 2. FNV-1a 已知向量
        checks.append(CheckResult("FNV-1a 32 已知向量匹配",
                                  OffsetProfileGenerator.fnv1a32(Data("hello".utf8)) == 0x4F9F2CAB))

        // 3. 十六进制补丁串解析
        let hex = OffsetProfileGenerator.data(fromHex: "c7477804000000")
        checks.append(CheckResult("十六进制补丁串解析", hex.count == 7 && hex.first == 0xC7,
                                  "长度 \(hex.count)"))

        // 4. Info.plist personality 注入
        do {
            let original = try makeFakeInfoPlist()
            let updated = try OffsetProfileGenerator.updatedInfoPlistData(original, profile: profile)
            let parsed = try PropertyListSerialization.propertyList(
                from: updated, options: [], format: nil) as? [String: Any]
            let personalities = parsed?["IOKitPersonalities"] as? [String: Any]
            let personality = personalities?["org.ChefKiss.NootedRedUserPatch"] as? [String: Any]
            let injected = personality?["NRedOffsetProfile"] as? Data
            checks.append(CheckResult("Info.plist 注入 NRedOffsetProfile", injected == binary))
            checks.append(CheckResult("Info.plist 保留其他 personality",
                                      personalities?["OtherPersonality"] != nil))
            checks.append(CheckResult("Info.plist 保留其他顶层键",
                                      parsed?["OSBundleLibraries"] != nil))
        } catch {
            checks.append(CheckResult("Info.plist 注入 NRedOffsetProfile", false, error.localizedDescription))
        }

        // 5. 从 EFI 目录回读 profile 摘要
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("nrt-selftest-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }
        do {
            let kextDirectory = temporaryRoot
                .appendingPathComponent("EFI/OC/Kexts/NootedRedUserPatch.kext/Contents", isDirectory: true)
            try FileManager.default.createDirectory(at: kextDirectory, withIntermediateDirectories: true)
            let original = try makeFakeInfoPlist()
            let updated = try OffsetProfileGenerator.updatedInfoPlistData(original, profile: profile)
            try updated.write(to: kextDirectory.appendingPathComponent("Info.plist"))

            let summary = OffsetProfileGenerator.installedProfileSummary(efiRoot: temporaryRoot)
            checks.append(CheckResult("回读 EFI 中的 OffsetProfile",
                                      summary?.build == profile.build
                                      && summary?.pageCount == profile.pages.count,
                                      summary.map { "build \($0.build) · \($0.pageCount) 页" } ?? "未读到"))
            let missing = OffsetProfileGenerator.installedProfileSummary(
                efiRoot: temporaryRoot.appendingPathComponent("not-an-efi"))
            checks.append(CheckResult("缺少 profile 时回读为 nil", missing == nil))
        } catch {
            checks.append(CheckResult("回读 EFI 中的 OffsetProfile", false, error.localizedDescription))
        }

        // 6. shell 单引号转义（防止恶意卷名逃逸成 root 命令）
        let quoted = CommandRunner.shellSingleQuoted("/Volumes/x';id;'/EFI/OC")
        checks.append(CheckResult("shell 参数单引号转义",
                                  quoted == "'/Volumes/x'\\'';id;'\\''/EFI/OC'", quoted))
        let installCommand = OffsetProfileGenerator.installCommand(
            temporaryInfoPlist: "/tmp/nootedred info.plist",
            targetInfoPlist: "/Volumes/x';id;'/EFI/OC/Kexts/NootedRedUserPatch.kext/Contents/Info.plist")
        checks.append(CheckResult("写入 EFI 命令转义卷名中的引号",
                                  !installCommand.contains("x';id;'")
                                  && installCommand.contains("'/Volumes/x'\\'';id;'\\''")))

        // 7. EFI 命令安全校验（不会触发授权弹窗）
        let evil = EFIPartition(id: "disk0s1; rm -rf /", deviceIdentifier: "disk0s1; rm -rf /",
                                volumeName: "evil", sizeBytes: 0, isInternal: true)
        let mountResult = await EFIService.mount(evil)
        checks.append(CheckResult("不合法设备标识禁止挂载",
                                  !mountResult.success && mountResult.message.contains("不合法"),
                                  mountResult.message))
        let unmountResult = await EFIService.unmount(evil)
        checks.append(CheckResult("不合法设备标识禁止卸载",
                                  !unmountResult.success && unmountResult.message.contains("不合法"),
                                  unmountResult.message))

        // 8. 健康检查的 EFI / OffsetProfile 分支
        let unmounted = EFIDiscovery(
            partitions: [EFIPartition(id: "disk0s1", deviceIdentifier: "disk0s1",
                                      volumeName: "NO NAME", sizeBytes: 1_073_741_824, isInternal: true)]
        )
        var info = MachineInfo()
        info.build = "24H232"
        info.osVersion = "15.8.2"
        info.gpu = "AMD Radeon"
        info.sip = "System Integrity Protection status: disabled."
        info.kextVersion = "0.9.1"
        info.userPatchVersion = "0.9.1"
        info.appliedPages = "13"
        info.appliedSites = "18"
        info.bootArgs = "-NRedVDA"
        info.gpuHang = "最近未发现"
        let unmountedItems = HealthChecker.evaluate(info, kexts: [], efi: unmounted,
                                                    openCore: nil, installedProfile: nil)
        let efiItem = unmountedItems.first { $0.id == "efi" }
        checks.append(CheckResult("未挂载 EFI 的健康项为注意且给出建议",
                                  efiItem?.level == .warning && efiItem?.remedy != nil))
        checks.append(CheckResult("未写入 OffsetProfile 的健康项为注意",
                                  unmountedItems.first { $0.id == "offset-profile" }?.level == .warning))
        checks.append(CheckResult("健康检查共 10 项且 id 唯一",
                                  unmountedItems.count == 10
                                  && Set(unmountedItems.map(\.id)).count == unmountedItems.count,
                                  "实际 \(unmountedItems.count) 项"))

        let mounted = EFIDiscovery(partitions: unmounted.partitions,
                                   mounted: MountedEFI(partition: unmounted.partitions[0],
                                                       rootURL: temporaryRoot))
        let openCore = OpenCoreInfo(
            efiRoot: temporaryRoot,
            bootloader: .openCore,
            configPath: temporaryRoot.appendingPathComponent("EFI/OC/config.plist").path,
            configModified: Date(),
            configSize: 1024,
            productName: "MacPro7,1",
            configBootArgs: "-v",
            kextEntries: [
                OpenCoreKextEntry(bundlePath: "NootedRed.kext", enabled: true, comment: nil),
                OpenCoreKextEntry(bundlePath: "NootedRedUserPatch.kext", enabled: true, comment: nil)
            ],
            kextFiles: ["NootedRed.kext", "NootedRedUserPatch.kext"]
        )
        let patchKext = KextFileInfo(id: "NootedRedUserPatch.kext", name: "NootedRedUserPatch.kext",
                                     bundlePath: "NootedRedUserPatch.kext", version: "0.9.1",
                                     path: "/tmp/NootedRedUserPatch.kext", enabled: true,
                                     inConfig: true, fileExists: true, isNootedRed: true,
                                     symbol: "square.stack.3d.up")
        let installed = InstalledProfileSummary(build: "24H232", pageCount: 2, byteCount: binary.count,
                                                infoPlistPath: "/tmp/Info.plist", modifiedAt: Date())
        let mountedItems = HealthChecker.evaluate(info, kexts: [patchKext], efi: mounted,
                                                  openCore: openCore, installedProfile: installed)
        checks.append(CheckResult("已挂载 EFI 的健康项为通过",
                                  mountedItems.first { $0.id == "efi" }?.level == .pass))
        checks.append(CheckResult("OpenCore 配置齐全时为通过",
                                  mountedItems.first { $0.id == "opencore" }?.level == .pass))
        checks.append(CheckResult("OffsetProfile 构建匹配时为通过",
                                  mountedItems.first { $0.id == "offset-profile" }?.level == .pass))

        // 9. 页面层级与启动参数清单完整性
        checks.append(CheckResult("页面数量与分组覆盖",
                                  AppPage.allCases.count == 7
                                  && AppPageGroup.allCases.allSatisfy { !AppPage.pages(in: $0).isEmpty }
                                  && AppPageGroup.allCases.reduce(0) { $0 + AppPage.pages(in: $1).count } == 7))
        let flags = BootFeature.catalog.map(\.flag)
        checks.append(CheckResult("启动参数清单无重复且覆盖四个分组",
                                  Set(flags).count == flags.count
                                  && BootGroup.allCases.allSatisfy { !BootFeature.features(in: $0).isEmpty },
                                  "共 \(flags.count) 项"))
        checks.append(CheckResult("应用版本号已设置", !AppInfo.version.isEmpty))

        return checks
    }

    // MARK: - 测试数据

    private static func sampleProfile() -> OffsetProfile {
        let site = OffsetSite(siteInPage: 0x81, find: "c7477804000000", replace: "c7477801000000",
                              function: "someFunction", displacement: 0x10)
        let pages = [
            OffsetPage(driver: "GL HwInfo", pageVM: 0x1000_0000, pageFileOffset: 0xE000, pageHash: 0x1111, sites: [site]),
            OffsetPage(driver: "VDA page0", pageVM: 0x2000_0000, pageFileOffset: 0x1000, pageHash: 0x2222, sites: [site])
        ]
        return OffsetProfile(format: 1, build: "24H232", parserVersion: OffsetProfileGenerator.parserVersion,
                             generatedAt: "2026-10-28T00:00:00Z", pages: pages)
    }

    private static func makeFakeInfoPlist() throws -> Data {
        let dictionary: [String: Any] = [
            "OSBundleLibraries": ["as.vit9696.Lilu": "1.7.0"],
            "IOKitPersonalities": [
                "org.ChefKiss.NootedRedUserPatch": ["IOClass": "NootedRedUserPatch"],
                "OtherPersonality": ["IOClass": "Other"]
            ]
        ]
        return try PropertyListSerialization.data(fromPropertyList: dictionary, format: .xml, options: 0)
    }
}
