import Foundation
import SwiftUI

@MainActor
final class AppModel: ObservableObject {
    @Published var info = MachineInfo()
    @Published var health: [HealthItem] = []
    @Published var kexts: [KextFileInfo] = []
    @Published var bootState = BootArgumentState()
    @Published var selectedPage: AppPage = .overview
    @Published var isRefreshing = false
    @Published var statusMessage = "准备就绪"
    @Published var diagnostics = ""
    @Published var showUpdateSheet = false
    @Published var lastRefresh = Date()
    @Published var parsedProfile: OffsetProfile?
    @Published var parserLog = "尚未解析。"
    @Published var isParsing = false
    @Published var parserOutput: URL?
    @Published var profileInstalledPath: String?

    init() {
        if CommandLine.arguments.contains("--parser") {
            selectedPage = .parser
        }
        refresh()
        if CommandLine.arguments.contains("--parse") {
            runParser()
        }
    }

    func refresh() {
        guard !isRefreshing else { return }
        isRefreshing = true
        statusMessage = "正在读取系统状态…"

        Task {
            async let machine = SystemProbe.snapshot()
            async let files = SystemProbe.currentKexts()
            async let args = BootArgumentManager.load()

            let newInfo = await machine
            let newKexts = await files
            let newArgs = await args

            self.info = newInfo
            self.kexts = newKexts
            self.bootState = newArgs
            self.health = HealthChecker.evaluate(newInfo, kexts: newKexts)
            self.diagnostics = Self.makeDiagnostics(info: newInfo, kexts: newKexts)
            self.lastRefresh = Date()
            self.isRefreshing = false
            self.statusMessage = "状态已更新"
        }
    }

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
        isRefreshing = true
        statusMessage = "正在写入 NVRAM…"

        Task {
            let result = await BootArgumentManager.save(state)
            if result.status == 0 {
                statusMessage = "boot-args 已写入；重启后生效"
                self.bootState = await BootArgumentManager.load()
            } else {
                statusMessage = "写入失败：\(result.output.isEmpty ? "授权被取消" : result.output)"
            }
            self.isRefreshing = false
        }
    }

    func runParser() {
        guard !isParsing else { return }
        isParsing = true
        parserLog = "正在读取 GL / dyld shared cache…"
        statusMessage = "用户态解析中…"

        Task {
            do {
                let build = await OffsetProfileGenerator.currentBuild()
                parserLog = "当前 build: \(build)\n正在解析 Mach-O 和 page offsets…"
                let profile = try await OffsetProfileGenerator.generate(build: build)
                let url = try OffsetProfileGenerator.save(profile)
                self.parsedProfile = profile
                self.parserOutput = url
                self.parserLog = """
                解析完成
                build: \(profile.build)
                pages: \(profile.pageCount)
                sites: \(profile.siteCount)
                saved: \(url.path)
                """
                self.statusMessage = "OffsetProfile 已生成"
            } catch {
                self.parserLog = "解析失败：\(error.localizedDescription)"
                self.statusMessage = "用户态解析失败"
            }
            self.isParsing = false
        }
    }

    func installProfile() {
        guard let profile = parsedProfile else { return }
        isParsing = true
        parserLog += "\n正在写入 EFI NootedRedUserPatch Info.plist…"

        Task {
            do {
                let url = try await OffsetProfileGenerator.installToSystem(profile)
                self.profileInstalledPath = url.path
                self.parserLog += "\n已写入：\(url.path)\n已清理旧的 /var/db/nootedred 安装。"
                self.statusMessage = "OffsetProfile 已写入 EFI"
            } catch {
                self.parserLog += "\n安装失败：\(error.localizedDescription)"
                self.statusMessage = "OffsetProfile 安装失败"
            }
            self.isParsing = false
        }
    }

    func markUpdateInterface() {
        statusMessage = "kext 更新接口已预留"
        showUpdateSheet = true
    }

    static func makeDiagnostics(info: MachineInfo, kexts: [KextFileInfo]) -> String {
        var lines: [String] = []
        lines.append("NootedRed Tool — diagnostic snapshot")
        lines.append("host: \(info.hostname)")
        lines.append("model: \(info.model)")
        lines.append("macOS: \(info.osVersion) (\(info.build))")
        lines.append("kernel: \(info.kernel) / \(info.architecture)")
        lines.append("cpu: \(info.cpu)")
        lines.append("memory: \(info.memory)")
        lines.append("gpu: \(info.gpu)")
        lines.append("kext: \(info.kextVersion)")
        lines.append("userpatch: \(info.userPatchVersion)")
        lines.append("applied pages: \(info.appliedPages)")
        lines.append("applied sites: \(info.appliedSites)")
        lines.append("boot-args: \(info.bootArgs)")
        lines.append("sip: \(info.sip)")
        lines.append("efi: \(info.efiState)")
        lines.append("gpu hang: \(info.gpuHang)")
        lines.append("")
        for kext in kexts {
            lines.append("kext \(kext.name) version \(kext.version) at \(kext.path)")
        }
        return lines.joined(separator: "\n")
    }
}
