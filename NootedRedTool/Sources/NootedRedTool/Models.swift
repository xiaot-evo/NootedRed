import Foundation
import SwiftUI

// MARK: - 应用信息

enum AppInfo {
    static let name = "NootedRed Toolkit"
    static let brand = "NootedRed"
    static let version = "0.2.0"
    static let tagline = "本机 NootedRed 检查与部署工具"
}

// MARK: - 页面层级

enum AppPageGroup: String, CaseIterable, Identifiable {
    case system
    case efiAndPatches
    case configuration
    case support

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return "系统"
        case .efiAndPatches: return "EFI 与补丁"
        case .configuration: return "系统配置"
        case .support: return "支持"
        }
    }
}

enum AppPage: String, CaseIterable, Identifiable {
    case overview
    case health
    case efi
    case decoder
    case kexts
    case bootArguments
    case diagnostics

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: return "总览"
        case .health: return "健康检查"
        case .efi: return "EFI 分区"
        case .decoder: return "驱动解码"
        case .kexts: return "Kext 管理"
        case .bootArguments: return "启动参数"
        case .diagnostics: return "诊断信息"
        }
    }

    var subtitle: String {
        switch self {
        case .overview: return "系统、驱动、EFI 与补丁状态一览"
        case .health: return "逐项检查 kext、GPU、EFI 与稳定性"
        case .efi: return "挂载 EFI 分区，读取 OpenCore 配置"
        case .decoder: return "解码 GL / Metal / VDA / GVA 驱动，生成 OffsetProfile"
        case .kexts: return "查看 EFI 中的 kext 版本与启用状态"
        case .bootArguments: return "勾选功能写入 NVRAM boot-args"
        case .diagnostics: return "复制可提交到问题反馈的系统信息"
        }
    }

    var symbol: String {
        switch self {
        case .overview: return "rectangle.3.group"
        case .health: return "heart.text.square"
        case .efi: return "externaldrive.badge.checkmark"
        case .decoder: return "chevron.left.forwardslash.chevron.right"
        case .kexts: return "shippingbox"
        case .bootArguments: return "slider.horizontal.3"
        case .diagnostics: return "terminal"
        }
    }

    var group: AppPageGroup {
        switch self {
        case .overview, .health: return .system
        case .efi, .decoder, .kexts: return .efiAndPatches
        case .bootArguments: return .configuration
        case .diagnostics: return .support
        }
    }

    var supportsSearch: Bool {
        switch self {
        case .health, .decoder, .kexts, .bootArguments: return true
        case .overview, .efi, .diagnostics: return false
        }
    }

    var shortcut: KeyEquivalent {
        switch self {
        case .overview: return "1"
        case .health: return "2"
        case .efi: return "3"
        case .decoder: return "4"
        case .kexts: return "5"
        case .bootArguments: return "6"
        case .diagnostics: return "7"
        }
    }

    static func pages(in group: AppPageGroup) -> [AppPage] {
        allCases.filter { $0.group == group }
    }
}

// MARK: - 健康检查

enum HealthLevel: String, CaseIterable {
    case pass
    case warning
    case fail
    case info

    var title: String {
        switch self {
        case .pass: return "通过"
        case .warning: return "注意"
        case .fail: return "异常"
        case .info: return "信息"
        }
    }

    var color: Color {
        switch self {
        case .pass: return Color(red: 0.20, green: 0.72, blue: 0.44)
        case .warning: return Color(red: 0.96, green: 0.62, blue: 0.16)
        case .fail: return Color(red: 0.91, green: 0.29, blue: 0.31)
        case .info: return Color(red: 0.30, green: 0.55, blue: 0.95)
        }
    }

    var symbol: String {
        switch self {
        case .pass: return "checkmark.seal.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .fail: return "xmark.octagon.fill"
        case .info: return "info.circle.fill"
        }
    }
}

struct HealthItem: Identifiable {
    let id: String
    let title: String
    let detail: String
    let value: String
    let level: HealthLevel
    let remedy: String?
    let page: AppPage?

    init(id: String, title: String, detail: String, value: String, level: HealthLevel,
         remedy: String? = nil, page: AppPage? = nil) {
        self.id = id
        self.title = title
        self.detail = detail
        self.value = value
        self.level = level
        self.remedy = remedy
        self.page = page
    }
}

// MARK: - 机器信息

struct MachineInfo {
    var hostname = "—"
    var model = "—"
    var osVersion = "—"
    var build = "—"
    var kernel = "—"
    var architecture = "—"
    var cpu = "—"
    var memory = "—"
    var gpu = "—"
    var kextVersion = "未加载"
    var userPatchVersion = "未加载"
    var appliedPages = "—"
    var appliedSites = "—"
    var bootArgs = "—"
    var sip = "—"

    // EFI 状态（由 EFIService 探测得到，不再写死挂载点）
    var efiState = "未检测"
    var efiDevice = "—"
    var efiVolumeName = "—"
    var efiPartitionCount = 0
    var efiConfig = "—"

    var gpuHang = "未检查"
}

// MARK: - 启动参数

enum BootGroup: String, CaseIterable, Identifiable {
    case features
    case debug
    case logging
    case rescue

    var id: String { rawValue }

    var title: String {
        switch self {
        case .features: return "功能补丁"
        case .debug: return "调试"
        case .logging: return "日志"
        case .rescue: return "救援与回滚"
        }
    }

    var detail: String {
        switch self {
        case .features: return "日常使用需要的补丁开关。"
        case .debug: return "排障时临时使用，平时保持关闭。"
        case .logging: return "仅在提交问题反馈时开启，日志量较大。"
        case .rescue: return "图形驱动异常时用于恢复系统。"
        }
    }

    var symbol: String {
        switch self {
        case .features: return "puzzlepiece.extension"
        case .debug: return "wrench.and.screwdriver"
        case .logging: return "ladybug"
        case .rescue: return "lifepreserver"
        }
    }
}

struct BootFeature: Identifiable, Hashable {
    let id: String
    let flag: String
    let title: String
    let detail: String
    let risk: String?
    let group: BootGroup
    let symbol: String

    var hasRisk: Bool { risk != nil }

    static func features(in group: BootGroup) -> [BootFeature] {
        catalog.filter { $0.group == group }
    }

    static let catalog: [BootFeature] = [
        BootFeature(id: "vda", flag: "-NRedVDA", title: "VDA 硬件解码",
                    detail: "为 VADriver2 / AppleGVA 应用用户态页面补丁，启用 H.264 / HEVC 视频硬解。",
                    risk: "需要 EFI 中已安装并启用 NootedRedUserPatch.kext。",
                    group: .features, symbol: "play.rectangle"),
        BootFeature(id: "glfix", flag: "-NRedGLFix", title: "GL 语义修复",
                    detail: "修复 GL HwInfo / DualQuad 页面补丁，改善 OpenGL 应用与游戏的兼容性。",
                    risk: nil, group: .features, symbol: "square.stack.3d.up"),
        BootFeature(id: "noaccel", flag: "-NRedNoAccel", title: "仅 Framebuffer",
                    detail: "禁用 GPU 加速，只保留显示输出，用于定位加速相关的黑屏或花屏。",
                    risk: "开启后 Metal / OpenGL 不可用，仅用于排障。",
                    group: .debug, symbol: "display"),
        BootFeature(id: "beta", flag: "-NRedBeta", title: "Beta 功能",
                    detail: "允许在非正式版 macOS 构建上加载实验性补丁。",
                    risk: "实验功能，可能不稳定。",
                    group: .debug, symbol: "testtube.2"),
        BootFeature(id: "debug", flag: "-NRedDebug", title: "NootedRed 调试日志",
                    detail: "输出 NootedRed 的 DBGLOG 调试信息，供问题定位使用。",
                    risk: "日志量较大，问题解决后请关闭。",
                    group: .logging, symbol: "ladybug"),
        BootFeature(id: "liludbg", flag: "-liludbgall", title: "Lilu 全量日志",
                    detail: "开启 Lilu 及其插件的完整调试输出。",
                    risk: "日志量很大，仅在反馈问题时开启。",
                    group: .logging, symbol: "ant"),
        BootFeature(id: "off", flag: "-NRedOff", title: "禁用 NootedRed",
                    detail: "启动时跳过 NootedRed 主 kext，用于回滚与救援。",
                    risk: "GPU 加速驱动不会加载，系统可能没有图形加速。",
                    group: .rescue, symbol: "power"),
        BootFeature(id: "uoff", flag: "-NRedUserPatchOff", title: "禁用用户态补丁",
                    detail: "跳过 NootedRedUserPatch 的页面补丁，用于排查补丁兼容性。",
                    risk: nil, group: .rescue, symbol: "shield.slash")
    ]
}

// MARK: - Kext

enum KextState: String {
    case enabled
    case disabled
    case notInConfig
    case missingFile

    var title: String {
        switch self {
        case .enabled: return "已启用"
        case .disabled: return "已禁用"
        case .notInConfig: return "未加入 config"
        case .missingFile: return "文件缺失"
        }
    }

    var isHealthy: Bool { self == .enabled }
}

struct KextFileInfo: Identifiable, Hashable {
    let id: String
    let name: String
    let bundlePath: String
    let version: String
    let path: String
    let enabled: Bool
    let inConfig: Bool
    let fileExists: Bool
    let isNootedRed: Bool
    let symbol: String

    var state: KextState {
        if !fileExists && inConfig { return .missingFile }
        if !inConfig { return .notInConfig }
        return enabled ? .enabled : .disabled
    }
}
