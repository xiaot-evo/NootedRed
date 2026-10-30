import AppKit
import Foundation
import SwiftUI

@MainActor
final class AppModel: ObservableObject {
    // 系统状态
    @Published var info = MachineInfo()
    @Published var health: [HealthItem] = []
    @Published var kexts: [KextFileInfo] = []
    @Published var bootState = BootArgumentState()
    @Published var efi = EFIDiscovery.empty
    @Published var openCore: OpenCoreInfo?
    @Published var installedProfile: InstalledProfileSummary?

    // 界面状态
    @Published var selectedPage: AppPage = .overview
    @Published var searchText = ""
    @Published var isRefreshing = false
    @Published var isEFIOperating = false
    @Published var statusMessage = "准备就绪"
    @Published var statusIsError = false
    @Published var lastRefresh = Date()
    @Published var diagnostics = ""
    @Published var showUpdateSheet = false

    // 驱动解码
    @Published var decoderProfile: OffsetProfile?
    @Published var decoderLog = "尚未解码。读取 GL / Metal / VDA 驱动后，会在本机缓存一份 OffsetProfile。"
    @Published var isDecoding = false
    @Published var decoderOutput: URL?
    @Published var profileInstalledPath: String?

    init() {
        if CommandLine.arguments.contains("--parser") || CommandLine.arguments.contains("--decode") {
            selectedPage = .decoder
        }
        refresh()
        if CommandLine.arguments.contains("--parse") || CommandLine.arguments.contains("--decode-run") {
            runDecoder()
        }
    }

    // MARK: - 整体刷新

    func refresh() {
        Task { await performRefresh() }
    }

    /// 供快照 / 自动化使用的可等待刷新入口。
    func performRefresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        statusMessage = "正在读取系统状态…"
        statusIsError = false
        await loadState()
        isRefreshing = false
        statusMessage = "状态已更新"
        lastRefresh = Date()
    }

    /// 等待 `refresh()` 启动的首次加载结束。
    func waitUntilReady(timeout: TimeInterval = 30) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !isRefreshing && info.osVersion != "—" { return true }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        return !isRefreshing
    }

    /// 读取 EFI / 系统 / kext / boot-args 并重新计算健康检查。
    private func loadState() async {
        let discovery = await EFIService.discover()
        let coreInfo = discovery.mounted.flatMap { EFIService.openCoreInfo(atRoot: $0.rootURL) }
        let installed = discovery.mounted.flatMap {
            OffsetProfileGenerator.installedProfileSummary(efiRoot: $0.rootURL)
        }

        let newInfo = await SystemProbe.snapshot(efi: discovery, openCore: coreInfo)
        let newKexts = await SystemProbe.currentKexts(efi: discovery, openCore: coreInfo)
        let newArgs = await BootArgumentManager.load()

        efi = discovery
        openCore = coreInfo
        installedProfile = installed
        info = newInfo
        kexts = newKexts
        bootState = newArgs
        health = HealthChecker.evaluate(newInfo, kexts: newKexts, efi: discovery,
                                        openCore: coreInfo, installedProfile: installed)
        diagnostics = Self.makeDiagnostics(info: newInfo, kexts: newKexts, efi: discovery,
                                           openCore: coreInfo, installedProfile: installed,
                                           bootState: newArgs)
        profileInstalledPath = installed?.infoPlistPath
        if decoderProfile == nil, let cached = OffsetProfileGenerator.loadCached(build: newInfo.build) {
            decoderProfile = cached
            decoderLog = """
            已加载本机缓存的 OffsetProfile
            build: \(cached.build)
            页面: \(cached.pageCount)
            sites: \(cached.siteCount)
            """
        }
        lastRefresh = Date()
    }

    // MARK: - EFI 分区

    func refreshEFI() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        statusMessage = "正在扫描 EFI 分区…"
        statusIsError = false
        await loadState()
        isRefreshing = false
        statusMessage = efi.hasAnyPartition
            ? "检测到 \(efi.partitions.count) 个 EFI 分区"
            : "未检测到 EFI 分区"
        lastRefresh = Date()
    }

    @discardableResult
    func mountEFI(_ partition: EFIPartition) async -> Bool {
        guard !isEFIOperating else { return false }
        isEFIOperating = true
        statusMessage = "正在挂载 \(partition.deviceIdentifier)（需要管理员授权）…"
        statusIsError = false
        let result = await EFIService.mount(partition)
        await loadState()
        isEFIOperating = false
        statusMessage = result.message
        statusIsError = !result.success
        lastRefresh = Date()
        return result.success
    }

    @discardableResult
    func unmountEFI(force: Bool = false) async -> Bool {
        guard !isEFIOperating, let mounted = efi.mounted else { return false }
        isEFIOperating = true
        statusMessage = "正在卸载 \(mounted.partition.deviceIdentifier)…"
        statusIsError = false
        let result = await EFIService.unmount(mounted.partition, force: force)
        await loadState()
        isEFIOperating = false
        statusMessage = result.message
        statusIsError = !result.success
        lastRefresh = Date()
        return result.success
    }

    /// 一个明确的主入口：没有挂载 EFI 时，只有唯一分区就直接挂载，否则引导到 EFI 页面。
    @discardableResult
    func mountPreferredEFI() async -> Bool {
        if efi.mounted != nil { return true }
        if efi.partitions.isEmpty { await refreshEFI() }
        guard !efi.partitions.isEmpty else {
            statusMessage = "未检测到 EFI 分区"
            statusIsError = true
            return false
        }
        if efi.partitions.count == 1 {
            return await mountEFI(efi.partitions[0])
        }
        openPage(.efi)
        statusMessage = "检测到多个 EFI 分区，请选择要挂载的一个"
        statusIsError = false
        return false
    }

    /// 写 EFI 之前调用：保证当前有一个可写的 EFI 挂载点。
    func ensureEFIMounted() async -> Bool {
        if efi.mounted != nil { return true }
        if efi.partitions.isEmpty { await refreshEFI() }
        guard !efi.partitions.isEmpty else {
            openPage(.efi)
            statusMessage = "未检测到 EFI 分区，无法写入"
            statusIsError = true
            return false
        }
        if efi.partitions.count == 1 {
            return await mountEFI(efi.partitions[0])
        }
        openPage(.efi)
        statusMessage = "请先在「EFI 分区」页挂载要写入的 EFI 分区"
        statusIsError = true
        return false
    }

    func openEFIInFinder() {
        guard let mounted = efi.mounted else {
            statusMessage = "EFI 未挂载，无法在 Finder 中打开"
            statusIsError = true
            return
        }
        let ocFolder = mounted.rootURL.appendingPathComponent("EFI/OC")
        if FileManager.default.fileExists(atPath: ocFolder.path) {
            NSWorkspace.shared.activateFileViewerSelecting([ocFolder])
            statusMessage = "已在 Finder 中显示 \(ocFolder.path)"
        } else {
            NSWorkspace.shared.open(mounted.rootURL)
            statusMessage = "已在 Finder 中打开 \(mounted.rootURL.path)"
        }
        statusIsError = false
    }

    // MARK: - 启动参数

    func isEnabled(_ feature: BootFeature) -> Bool {
        bootState.knownFlags.contains(feature.flag)
    }

    func setEnabled(_ feature: BootFeature, _ enabled: Bool) {
        if enabled {
            bootState.knownFlags.insert(feature.flag)
        } else {
            bootState.knownFlags.remove(feature.flag)
        }
    }

    func saveBootArgs() {
        let state = bootState
        guard !isRefreshing else { return }
        isRefreshing = true
        statusMessage = "正在写入 NVRAM…"
        statusIsError = false

        Task {
            let result = await BootArgumentManager.save(state)
            if result.status == 0 {
                await loadState()
                statusMessage = "boot-args 已写入 NVRAM；重启后生效"
                statusIsError = false
            } else {
                if CommandRunner.isUserCancellation(result) {
                    statusMessage = "授权被取消，boot-args 未修改"
                } else {
                    statusMessage = "写入失败：\(result.output.isEmpty ? "未知错误" : result.output)"
                }
                statusIsError = true
            }
            isRefreshing = false
        }
    }

    // MARK: - 驱动解码

    func runDecoder() {
        guard !isDecoding else { return }
        isDecoding = true
        statusIsError = false
        decoderLog = "正在读取 GL / Metal / VDA 驱动与 dyld shared cache…"
        statusMessage = "正在解码驱动…"

        Task {
            do {
                let build = await OffsetProfileGenerator.currentBuild()
                decoderLog = "当前构建：\(build)\n正在解析 Mach-O、符号与页偏移…"
                let profile = try await OffsetProfileGenerator.generate(build: build)
                let url = try OffsetProfileGenerator.save(profile)
                decoderProfile = profile
                decoderOutput = url
                decoderLog = """
                解码完成
                build: \(profile.build)
                页面: \(profile.pageCount)
                sites: \(profile.siteCount)
                本机缓存: \(url.path)
                """
                statusMessage = "OffsetProfile 已生成，尚未写入 EFI"
                statusIsError = false
                lastRefresh = Date()
            } catch {
                decoderLog = "解码失败：\(error.localizedDescription)"
                statusMessage = "驱动解码失败"
                statusIsError = true
            }
            isDecoding = false
        }
    }

    func installProfile() {
        guard let profile = decoderProfile else {
            statusMessage = "请先完成一次驱动解码"
            statusIsError = true
            return
        }
        guard !isDecoding else { return }
        isDecoding = true
        statusIsError = false

        Task {
            guard await ensureEFIMounted(), let mounted = efi.mounted else {
                decoderLog += "\n写入中止：EFI 分区未就绪。"
                isDecoding = false
                return
            }
            decoderLog += "\n正在写入 \(mounted.rootURL.path)/EFI/OC/Kexts/NootedRedUserPatch.kext/Contents/Info.plist…"
            statusMessage = "正在写入 EFI（需要管理员授权）…"
            do {
                let install = try await OffsetProfileGenerator.installToEFI(profile, efiRoot: mounted.rootURL)
                profileInstalledPath = install.infoPlistURL.path
                decoderLog += "\n已写入：\(install.infoPlistURL.path)"
                if let backup = install.backupURL {
                    decoderLog += "\n原 Info.plist 已备份到：\(backup.path)"
                } else {
                    decoderLog += "\n警告：原 Info.plist 备份失败，如需回滚请先手动备份 EFI。"
                }
                await loadState()
                statusMessage = "OffsetProfile 已写入 EFI，重启后生效"
                statusIsError = false
                lastRefresh = Date()
            } catch {
                decoderLog += "\n写入失败：\(error.localizedDescription)"
                statusMessage = "写入 EFI 失败：\(error.localizedDescription)"
                statusIsError = true
            }
            isDecoding = false
        }
    }

    // MARK: - 界面辅助

    func openPage(_ page: AppPage) {
        selectedPage = page
        searchText = ""
    }

    func markUpdateInterface() {
        showUpdateSheet = true
        statusMessage = "kext 更新接口已预留，本版本不执行写入"
        statusIsError = false
    }

    func copyDiagnostics() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(diagnostics, forType: .string)
        statusMessage = "诊断信息已复制到剪贴板"
        statusIsError = false
    }

    // MARK: - 诊断快照

    static func makeDiagnostics(info: MachineInfo, kexts: [KextFileInfo], efi: EFIDiscovery,
                                openCore: OpenCoreInfo?, installedProfile: InstalledProfileSummary?,
                                bootState: BootArgumentState) -> String {
        var lines: [String] = []
        let formatter = ISO8601DateFormatter()
        lines.append("NootedRed Toolkit — diagnostic snapshot")
        lines.append("generated: \(formatter.string(from: Date()))")
        lines.append("tool: \(AppInfo.name) \(AppInfo.version)")
        lines.append("")
        lines.append("[system]")
        lines.append("host: \(info.hostname)")
        lines.append("model: \(info.model)")
        lines.append("macOS: \(info.osVersion) (\(info.build))")
        lines.append("kernel: \(info.kernel) / \(info.architecture)")
        lines.append("cpu: \(info.cpu)")
        lines.append("memory: \(info.memory)")
        lines.append("gpu: \(info.gpu)")
        lines.append("sip: \(info.sip)")
        lines.append("")
        lines.append("[nootedred]")
        lines.append("kext: \(info.kextVersion)")
        lines.append("userpatch: \(info.userPatchVersion)")
        lines.append("applied pages: \(info.appliedPages)")
        lines.append("applied sites: \(info.appliedSites)")
        lines.append("boot-args: \(info.bootArgs)")
        lines.append("nvram serialized: \(bootState.serialized)")
        lines.append("gpu hang: \(info.gpuHang)")
        lines.append("")
        lines.append("[efi]")
        lines.append("state: \(info.efiState)")
        lines.append("partitions: \(efi.partitions.count)")
        for partition in efi.partitions {
            let mount = partition.mountPoint ?? "unmounted"
            lines.append("  \(partition.deviceIdentifier) \"\(partition.displayName)\" \(partition.sizeText) "
                         + "\(partition.locationText) mount=\(mount)")
        }
        if let mounted = efi.mounted {
            lines.append("mounted root: \(mounted.rootURL.path)")
        }
        if let openCore {
            lines.append("opencore: \(openCore.configPath)")
            lines.append("bootloader: \(openCore.bootloader.rawValue)")
            lines.append("product: \(openCore.productName ?? "—")")
            lines.append("kernel add entries: \(openCore.kextEntries.count) (enabled \(openCore.enabledKextCount))")
            lines.append("nootedred entries: main=\(openCore.hasNootedRed) userpatch=\(openCore.hasUserPatch)")
            lines.append("config boot-args: \(openCore.configBootArgs ?? "—")")
        } else {
            lines.append("opencore: unavailable")
        }
        if let installedProfile {
            lines.append("offset profile: build \(installedProfile.build), \(installedProfile.pageCount) pages, "
                         + "\(installedProfile.byteCount) bytes")
        } else {
            lines.append("offset profile: not installed")
        }
        lines.append("")
        lines.append("[health]")
        for item in HealthChecker.evaluate(info, kexts: kexts, efi: efi,
                                           openCore: openCore, installedProfile: installedProfile) {
            lines.append("  [\(item.level.rawValue)] \(item.title): \(item.value) — \(item.detail)")
        }
        lines.append("")
        lines.append("[kexts]")
        if kexts.isEmpty {
            lines.append("  none")
        }
        for kext in kexts {
            lines.append("  \(kext.name) \(kext.version) \(kext.state.title) at \(kext.path)")
        }
        return lines.joined(separator: "\n")
    }
}
