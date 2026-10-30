import SwiftUI

/// 总览：机器信息、健康状态、部署流程、关键指标与快捷入口。
struct OverviewPage: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: ToolkitTheme.pageSpacing) {
            ToolkitPageIntro(
                title: "本机部署状态一览",
                summary: "本页汇总这台 Mac 的 NootedRed 加载状态、EFI 分区、驱动解码与 OffsetProfile 的部署进度。第一次使用建议按「部署流程」从上到下完成。",
                symbol: "rectangle.3.group",
                prerequisites: [
                    "EFI 中已安装 NootedRed.kext 与 NootedRedUserPatch.kext",
                    "知道 OpenCore 所在的 EFI 分区"
                ],
                steps: [
                    "确认主 kext 与 UserPatch 已加载",
                    "挂载 EFI 分区并完成驱动解码",
                    "写入 OffsetProfile 后重新检查"
                ]
            )
            heroCard
            healthSummaryCard
            deployCard
            metricsCard
            shortcutsCard
        }
    }

    // MARK: - 机器信息

    private var heroCard: some View {
        ToolkitCard {
            HStack(spacing: 18) {
                ZStack {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(ToolkitTheme.accentGradient)
                    Image(systemName: "cpu")
                        .font(.system(size: 30, weight: .semibold))
                        .foregroundStyle(.white)
                }
                .frame(width: 72, height: 72)

                VStack(alignment: .leading, spacing: 6) {
                    Text(model.info.hostname)
                        .font(.system(size: 19, weight: .bold, design: .rounded))
                    Text("\(model.info.model)  ·  \(model.info.cpu)")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    HStack(spacing: 6) {
                        ToolkitBadge(text: "macOS \(model.info.osVersion)", color: HealthLevel.info.color)
                        ToolkitBadge(text: model.info.architecture, color: .gray)
                        ToolkitBadge(text: model.info.memory, color: HealthLevel.pass.color)
                        ToolkitBadge(text: model.info.gpu, color: Color(red: 0.13, green: 0.61, blue: 0.60))
                    }
                }

                Spacer(minLength: 8)
                statusPill
            }
        }
    }

    private var failureCount: Int { model.health.filter { $0.level == .fail }.count }
    private var warningCount: Int { model.health.filter { $0.level == .warning }.count }

    private var statusPill: some View {
        VStack(spacing: 5) {
            Image(systemName: failureCount == 0 ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                .font(.system(size: 24))
                .foregroundStyle(failureCount == 0 ? HealthLevel.pass.color : HealthLevel.fail.color)
            Text(failureCount == 0 ? "状态良好" : "\(failureCount) 项异常")
                .font(.system(size: 11, weight: .semibold))
            Text(warningCount == 0 ? "无警告" : "\(warningCount) 项注意")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(ToolkitTheme.subtleFill))
    }

    // MARK: - 部署流程

    private var deployCard: some View {
        ToolkitCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    ToolkitSectionTitle(title: "部署流程", subtitle: "按 1 → 4 顺序完成，工具会自动记录每一步状态", symbol: "list.number")
                    Spacer()
                    Button {
                        model.refresh()
                    } label: {
                        Label("重新检查", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(ToolkitSecondaryButtonStyle(compact: true))
                }

                VStack(spacing: 0) {
                    deployStep(
                        index: 1,
                        title: "挂载 EFI 分区",
                        detail: efiStepDetail,
                        done: model.efi.mounted != nil,
                        actionTitle: model.efi.mounted != nil ? "查看" : "去挂载"
                    ) {
                        if model.efi.mounted != nil {
                            model.openPage(.efi)
                        } else {
                            Task { await model.mountPreferredEFI() }
                        }
                    }
                    stepDivider
                    deployStep(
                        index: 2,
                        title: "驱动解码",
                        detail: decoderStepDetail,
                        done: model.decoderProfile != nil,
                        actionTitle: model.decoderProfile != nil ? "查看" : "去解码"
                    ) {
                        model.openPage(.decoder)
                    }
                    stepDivider
                    deployStep(
                        index: 3,
                        title: "写入 OffsetProfile",
                        detail: profileStepDetail,
                        done: model.installedProfile != nil,
                        actionTitle: model.installedProfile != nil ? "查看" : "去写入"
                    ) {
                        model.openPage(.decoder)
                    }
                    stepDivider
                    deployStep(
                        index: 4,
                        title: "重新检查",
                        detail: "上次检查 \(ToolkitFormat.time(model.lastRefresh))；修改 EFI 或 boot-args 后建议重新检查一次。",
                        done: false,
                        actionTitle: "重新检查"
                    ) {
                        model.refresh()
                    }
                }
            }
        }
    }

    private var efiStepDetail: String {
        if let mounted = model.efi.mounted {
            return "已挂载 \(mounted.partition.deviceIdentifier) · \(mounted.partition.displayName)"
        }
        if model.efi.partitions.isEmpty {
            return "未检测到 EFI 分区；可能是纯外置启动或磁盘结构特殊。"
        }
        return "检测到 \(model.efi.partitions.count) 个候选 EFI 分区，尚未挂载。"
    }

    private var decoderStepDetail: String {
        if let profile = model.decoderProfile {
            return "已解码 \(profile.pageCount) 页 · \(profile.siteCount) sites · build \(profile.build)"
        }
        return "尚未生成 OffsetProfile；解码只读取本机驱动，不会修改系统。"
    }

    private var profileStepDetail: String {
        if let installed = model.installedProfile {
            return "EFI 中已写入：build \(installed.build) · \(installed.pageCount) 页"
        }
        return "尚未写入 EFI；写入前请先备份 EFI 分区。"
    }

    private var stepDivider: some View {
        Rectangle()
            .fill(ToolkitTheme.divider)
            .frame(height: 1)
            .padding(.leading, 46)
    }

    private func deployStep(index: Int, title: String, detail: String, done: Bool,
                            actionTitle: String, action: @escaping () -> Void) -> some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(done ? HealthLevel.pass.color.opacity(0.14) : ToolkitTheme.accent.opacity(0.10))
                    .frame(width: 34, height: 34)
                if done {
                    Image(systemName: "checkmark")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(HealthLevel.pass.color)
                } else {
                    Text("\(index)")
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .foregroundStyle(ToolkitTheme.accent)
                }
            }
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(title)
                        .font(.system(size: 12, weight: .semibold))
                    ToolkitBadge(text: done ? "已完成" : "待处理",
                                 color: done ? HealthLevel.pass.color : HealthLevel.warning.color)
                }
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 8)
            Button(action: action) {
                Text(actionTitle)
            }
            .buttonStyle(ToolkitSecondaryButtonStyle(compact: true, tint: done ? Color.secondary : ToolkitTheme.accent))
        }
        .padding(.vertical, 9)
    }

    // MARK: - 健康摘要

    private var healthSummaryCard: some View {
        ToolkitCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    ToolkitSectionTitle(title: "健康状态", subtitle: "配色：绿色通过、橙色注意、红色异常", symbol: "heart.text.square")
                    Spacer()
                    Button {
                        model.openPage(.health)
                    } label: {
                        Text("查看全部")
                    }
                    .buttonStyle(ToolkitSecondaryButtonStyle(compact: true))
                }

                HStack(spacing: 10) {
                    ForEach(HealthLevel.allCases, id: \.rawValue) { level in
                        levelCount(level)
                    }
                }

                let issues = model.health.filter { $0.level == .fail || $0.level == .warning }
                if issues.isEmpty {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.seal.fill")
                            .foregroundStyle(HealthLevel.pass.color)
                        Text(model.health.isEmpty ? "正在检查…" : "所有检查项目均未发现问题。")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)
                } else {
                    VStack(spacing: 8) {
                        ForEach(issues.prefix(3)) { item in
                            HStack(spacing: 9) {
                                ToolkitStatusDot(color: item.level.color, size: 7)
                                Text(item.title)
                                    .font(.system(size: 11, weight: .medium))
                                Text(item.value)
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                Spacer(minLength: 4)
                                if item.page != nil {
                                    Button {
                                        if let page = item.page { model.openPage(page) }
                                    } label: {
                                        Text("前往处理")
                                    }
                                    .buttonStyle(ToolkitSecondaryButtonStyle(compact: true))
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private func levelCount(_ level: HealthLevel) -> some View {
        let count = model.health.filter { $0.level == level }.count
        return HStack(spacing: 7) {
            ToolkitStatusDot(color: level.color, size: 8)
            Text(level.title)
                .font(.system(size: 11, weight: .medium))
            Text("\(count)")
                .font(.system(size: 14, weight: .bold, design: .rounded))
                .foregroundStyle(level.color)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .frame(height: 40)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(level.color.opacity(0.075)))
    }

    // MARK: - 关键指标

    private var metricsCard: some View {
        ToolkitCard {
            VStack(alignment: .leading, spacing: 12) {
                ToolkitSectionTitle(title: "关键指标", subtitle: "当前系统与补丁的核心状态", symbol: "gauge.with.dots.needle.67percent")
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 3), spacing: 12) {
                    ToolkitMetricTile(title: "NootedRed kext", value: model.info.kextVersion,
                                      symbol: "cpu", color: ToolkitTheme.accent,
                                      footnote: "主 kext 加载版本")
                    ToolkitMetricTile(title: "NootedRedUserPatch", value: model.info.userPatchVersion,
                                      symbol: "square.stack.3d.up", color: ToolkitTheme.accentEnd,
                                      footnote: model.info.appliedPages == "—" ? "用户态补丁未加载" : "已应用 \(model.info.appliedPages) 页")
                    ToolkitMetricTile(title: "GPU", value: model.info.gpu,
                                      symbol: "display", color: Color(red: 0.13, green: 0.61, blue: 0.60),
                                      footnote: "来自系统信息")
                    ToolkitMetricTile(title: "macOS", value: model.info.osVersion,
                                      symbol: "apple.logo", color: Color(red: 0.35, green: 0.38, blue: 0.52),
                                      footnote: "build \(model.info.build)")
                    ToolkitMetricTile(title: "EFI 分区", value: model.info.efiState,
                                      symbol: "externaldrive", color: HealthLevel.warning.color,
                                      footnote: model.efi.mounted != nil ? model.info.efiDevice : "共 \(model.efi.partitions.count) 个候选")
                    ToolkitMetricTile(title: "boot-args", value: bootArgsSummary,
                                      symbol: "slider.horizontal.3", color: HealthLevel.info.color,
                                      footnote: "NVRAM 当前值")
                }
            }
        }
    }

    private var bootArgsSummary: String {
        let text = model.bootState.serialized
        if text.isEmpty { return "未设置" }
        return text.count > 42 ? String(text.prefix(42)) + "…" : text
    }

    // MARK: - 快捷入口

    private var shortcutsCard: some View {
        ToolkitCard {
            VStack(alignment: .leading, spacing: 12) {
                ToolkitSectionTitle(title: "快捷入口", subtitle: "常用功能一键直达", symbol: "bolt.fill")
                HStack(spacing: 10) {
                    shortcut("EFI 分区", "externaldrive.badge.checkmark", "挂载 / 卸载 EFI") { model.openPage(.efi) }
                    shortcut("驱动解码", "chevron.left.forwardslash.chevron.right", "生成 OffsetProfile") { model.openPage(.decoder) }
                    shortcut("Kext 管理", "shippingbox", "检查 EFI 中的 kext") { model.openPage(.kexts) }
                    shortcut("启动参数", "slider.horizontal.3", "写入 NVRAM boot-args") { model.openPage(.bootArguments) }
                    shortcut("诊断信息", "terminal", "复制反馈所需信息") { model.openPage(.diagnostics) }
                }
            }
        }
    }

    private func shortcut(_ title: String, _ symbol: String, _ detail: String,
                          action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 7) {
                    Image(systemName: symbol)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(ToolkitTheme.accent)
                    Text(title)
                        .font(.system(size: 11, weight: .semibold))
                }
                Text(detail)
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(RoundedRectangle(cornerRadius: ToolkitTheme.innerRadius, style: .continuous)
                .fill(ToolkitTheme.accent.opacity(0.06)))
            .overlay(RoundedRectangle(cornerRadius: ToolkitTheme.innerRadius, style: .continuous)
                .stroke(ToolkitTheme.accent.opacity(0.10), lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: ToolkitTheme.innerRadius, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}
