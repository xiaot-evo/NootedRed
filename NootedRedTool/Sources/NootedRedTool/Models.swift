import Foundation
import SwiftUI

enum HealthLevel: String {
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
}

struct HealthItem: Identifiable {
    let id = UUID()
    let title: String
    let detail: String
    let value: String
    let level: HealthLevel
}

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
    var efiState = "未挂载"
    var efiConfig = "—"
    var gpuHang = "未检查"
}

struct BootFeature: Identifiable, Hashable {
    let id: String
    let flag: String
    let title: String
    let detail: String
    let group: String
    let symbol: String

    static let catalog: [BootFeature] = [
        BootFeature(id: "vda", flag: "-NRedVDA", title: "VDA 硬件解码",
                    detail: "启用 VADriver2/AppleGVA 用户态补丁。", group: "功能", symbol: "play.rectangle"),
        BootFeature(id: "glfix", flag: "-NRedGLFix", title: "GL 语义修复",
                    detail: "启用 GL HwInfo / DualQuad 修复。", group: "功能", symbol: "square.stack.3d.up"),
        BootFeature(id: "noaccel", flag: "-NRedNoAccel", title: "仅 Framebuffer",
                    detail: "禁用加速，仅保留显示输出，用于排障。", group: "调试", symbol: "display"),
        BootFeature(id: "beta", flag: "-NRedBeta", title: "Beta 功能",
                    detail: "启用实验性补丁。", group: "调试", symbol: "testtube.2"),
        BootFeature(id: "debug", flag: "-NRedDebug", title: "NootedRed 调试日志",
                    detail: "输出更多 DBGLOG 信息。", group: "日志", symbol: "ladybug"),
        BootFeature(id: "liludbg", flag: "-liludbgall", title: "Lilu 调试日志",
                    detail: "启用 Lilu 全量调试输出。", group: "日志", symbol: "ant"),
        BootFeature(id: "off", flag: "-NRedOff", title: "禁用 NootedRed",
                    detail: "临时关闭主 kext，仅用于救援。", group: "救援", symbol: "power"),
        BootFeature(id: "uoff", flag: "-NRedUserPatchOff", title: "禁用用户态补丁",
                    detail: "关闭 NootedRedUserPatch。", group: "救援", symbol: "shield.slash")
    ]
}

struct KextFileInfo: Identifiable {
    let id = UUID()
    let name: String
    let version: String
    let path: String
    let enabled: Bool
    let symbol: String
}

enum AppPage: Hashable, CaseIterable {
    case overview
    case health
    case parser
    case parameters
    case updater
    case diagnostics

    var title: String {
        switch self {
        case .overview: return "总览"
        case .health: return "健康检查"
        case .parser: return "用户态解析"
        case .parameters: return "参数管理"
        case .updater: return "Kext 更新"
        case .diagnostics: return "诊断"
        }
    }

    var symbol: String {
        switch self {
        case .overview: return "rectangle.3.group"
        case .health: return "heart.text.square"
        case .parser: return "chevron.left.forwardslash.chevron.right"
        case .parameters: return "slider.horizontal.3"
        case .updater: return "arrow.triangle.2.circlepath"
        case .diagnostics: return "terminal"
        }
    }
}
