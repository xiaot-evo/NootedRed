import SwiftUI

/// Kext 管理：检查 EFI/OC/Kexts 中的 kext 与 config.plist 的启用状态；保留更新入口。
struct KextsPage: View {
    @EnvironmentObject private var model: AppModel

    private var filteredKexts: [KextFileInfo] {
        let query = model.searchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return model.kexts }
        return model.kexts.filter {
            $0.name.localizedCaseInsensitiveContains(query)
                || $0.path.localizedCaseInsensitiveContains(query)
                || $0.version.localizedCaseInsensitiveContains(query)
                || $0.state.title.localizedCaseInsensitiveContains(query)
        }
    }

    private var enabledCount: Int { model.kexts.filter { $0.state == .enabled }.count }

    var body: some View {
        VStack(alignment: .leading, spacing: ToolkitTheme.pageSpacing) {
            introCard
            headerCard
            if model.efi.mounted != nil {
                if let core = model.openCore {
                    openCoreSummary(core)
                }
                kextListCard
            } else {
                notMountedCard
            }
        }
    }

    // MARK: - 说明

    private var introCard: some View {
        ToolkitPageIntro(
            title: "检查 EFI 中的 kext 状态",
            summary: "对比 EFI/OC/Kexts 目录中的 kext 文件与 config.plist 的 Kernel > Add 条目，检查 NootedRed 相关 kext 是否已启用、文件是否齐全。本页只读，不会修改 config.plist。",
            symbol: "shippingbox",
            prerequisites: [
                "需要先挂载 EFI 分区",
                "Kext 版本来自各 kext 的 Info.plist"
            ],
            steps: [
                "先挂载 EFI 分区",
                "查看 NootedRed 相关 kext 的状态徽章",
                "按提示在 OpenCore 中启用或补齐文件"
            ],
            caution: "如果「文件缺失」或「未加入 config」，NootedRed 不会生效。请用 OpenCore Configurator 等工具修改 config.plist，修改前备份 EFI。"
        )
    }

    private var headerCard: some View {
        ToolkitCard {
            HStack(alignment: .center, spacing: 14) {
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 8) {
                        Text("EFI 中的 kext")
                            .font(.system(size: 15, weight: .bold, design: .rounded))
                        if model.efi.mounted != nil {
                            ToolkitBadge(text: "共 \(model.kexts.count) 项 · 启用 \(enabledCount) 项",
                                         color: ToolkitTheme.accent)
                        }
                    }
                    Text(model.efi.mounted != nil
                         ? "NootedRed 相关 kext 会高亮排在最前面。"
                         : "挂载 EFI 分区后才能读取 EFI/OC/Kexts 与 config.plist。")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Button {
                    model.markUpdateInterface()
                } label: {
                    Label("更新 kext", systemImage: "arrow.down.circle")
                }
                .buttonStyle(ToolkitSecondaryButtonStyle())
                .help("kext 更新接口已预留：本版本不执行写入，更新前需要挂载并备份 EFI")
            }
        }
    }

    // MARK: - OpenCore 摘要

    private func openCoreSummary(_ core: OpenCoreInfo) -> some View {
        ToolkitCard {
            VStack(alignment: .leading, spacing: 10) {
                ToolkitSectionTitle(title: "OpenCore 配置摘要",
                                    subtitle: core.configPath,
                                    symbol: "doc.text.magnifyingglass")
                HStack(alignment: .top, spacing: 26) {
                    VStack(alignment: .leading, spacing: 7) {
                        ToolkitInfoRow(label: "引导器", value: core.bootloader.rawValue)
                        ToolkitInfoRow(label: "ProductName", value: core.productName ?? "未设置")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    VStack(alignment: .leading, spacing: 7) {
                        ToolkitInfoRow(label: "Kernel > Add",
                                       value: "\(core.kextEntries.count) 项 · 启用 \(core.enabledKextCount) 项")
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            Text("NootedRed")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.secondary)
                                .frame(width: 88, alignment: .leading)
                            HStack(spacing: 6) {
                                ToolkitBadge(text: core.hasNootedRed ? "主 kext 已启用" : "主 kext 未启用",
                                             color: core.hasNootedRed ? HealthLevel.pass.color : HealthLevel.warning.color,
                                             symbol: core.hasNootedRed ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                                ToolkitBadge(text: core.hasUserPatch ? "UserPatch 已启用" : "UserPatch 未启用",
                                             color: core.hasUserPatch ? HealthLevel.pass.color : HealthLevel.warning.color,
                                             symbol: core.hasUserPatch ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    // MARK: - 未挂载

    private var notMountedCard: some View {
        ToolkitCard {
            VStack(alignment: .leading, spacing: 12) {
                ToolkitSectionTitle(title: "EFI 未挂载", subtitle: "挂载后才能读取 EFI 中的 kext", symbol: "externaldrive")
                ToolkitEmptyState(
                    symbol: "externaldrive.badge.questionmark",
                    title: "先挂载 EFI 分区",
                    message: notMountedMessage,
                    actionTitle: "一键挂载",
                    actionSymbol: "externaldrive"
                ) {
                    Task { await model.mountPreferredEFI() }
                }
            }
        }
    }

    private var notMountedMessage: String {
        if model.efi.partitions.isEmpty {
            return "当前未检测到 EFI 分区。请先在「EFI 分区」页重新扫描；如果是外置引导，请确认设备已连接。"
        }
        if model.efi.partitions.count == 1 {
            return "检测到 1 个 EFI 分区，点「一键挂载」即可读取其中的 kext 与 OpenCore 配置。"
        }
        return "检测到 \(model.efi.partitions.count) 个 EFI 分区，请到「EFI 分区」页选择正在使用的引导分区。"
    }

    // MARK: - Kext 列表

    private var kextListCard: some View {
        ToolkitCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    ToolkitSectionTitle(title: "Kext 明细",
                                        subtitle: "状态：已启用 / 已禁用 / 未加入 config / 文件缺失",
                                        symbol: "list.bullet.rectangle")
                    Spacer()
                    if !model.searchText.isEmpty {
                        Text("过滤后 \(filteredKexts.count) 个")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                }

                if model.kexts.isEmpty {
                    ToolkitEmptyState(
                        symbol: "shippingbox",
                        title: "EFI/OC/Kexts 中没有 kext",
                        message: "请把 NootedRed.kext 与 NootedRedUserPatch.kext 放入 EFI/OC/Kexts，并在 config.plist 的 Kernel > Add 中登记启用。"
                    )
                } else if filteredKexts.isEmpty {
                    ToolkitEmptyState(
                        symbol: "magnifyingglass",
                        title: "没有匹配的 kext",
                        message: "试试更换搜索词。搜索会匹配名称、路径、版本与状态。"
                    )
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(filteredKexts.enumerated()), id: \.element.id) { index, kext in
                            if index > 0 {
                                Rectangle()
                                    .fill(ToolkitTheme.divider)
                                    .frame(height: 1)
                            }
                            kextRow(kext)
                        }
                    }
                }
            }
        }
    }

    private func kextRow(_ kext: KextFileInfo) -> some View {
        HStack(spacing: 13) {
            Image(systemName: kext.symbol)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(kext.isNootedRed ? ToolkitTheme.accent : Color.secondary)
                .frame(width: 36, height: 36)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill((kext.isNootedRed ? ToolkitTheme.accent : Color.secondary).opacity(0.09)))

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 7) {
                    Text(kext.name)
                        .font(.system(size: 12, weight: .semibold))
                    if kext.isNootedRed {
                        ToolkitBadge(text: "NootedRed", color: ToolkitTheme.accent, symbol: "cpu")
                    }
                    ToolkitBadge(text: kext.state.title, color: stateColor(kext.state), symbol: stateSymbol(kext.state))
                }
                Text(kext.path)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 3) {
                Text(kext.version)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.secondary)
                Text(kext.inConfig ? "已加入 config" : "不在 config 中")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: ToolkitTheme.innerRadius, style: .continuous)
            .fill(kext.isNootedRed ? ToolkitTheme.accent.opacity(0.045) : Color.clear))
    }

    private func stateColor(_ state: KextState) -> Color {
        switch state {
        case .enabled: return HealthLevel.pass.color
        case .disabled: return HealthLevel.warning.color
        case .notInConfig: return HealthLevel.info.color
        case .missingFile: return HealthLevel.fail.color
        }
    }

    private func stateSymbol(_ state: KextState) -> String {
        switch state {
        case .enabled: return "checkmark.circle.fill"
        case .disabled: return "pause.circle.fill"
        case .notInConfig: return "minus.circle.fill"
        case .missingFile: return "xmark.octagon.fill"
        }
    }
}
