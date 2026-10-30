import SwiftUI

/// EFI 分区：挂载 / 卸载、查看 OpenCore 摘要、浏览候选 EFI 分区。
struct EFIPage: View {
    @EnvironmentObject private var model: AppModel
    @State private var showUnmountAlert = false
    @State private var showForceUnmountAlert = false
    @State private var pendingMountID: String?

    var body: some View {
        VStack(alignment: .leading, spacing: ToolkitTheme.pageSpacing) {
            introCard
            if let mounted = model.efi.mounted {
                mountedCard(mounted)
            } else {
                notMountedCard
            }
            partitionsCard
        }
        .alert("卸载 EFI 分区", isPresented: $showUnmountAlert) {
            Button("取消", role: .cancel) {}
            Button("卸载", role: .destructive) {
                Task {
                    let success = await model.unmountEFI()
                    // 授权被取消时不必提示强制卸载；只有卷仍被占用才提供 force 选项。
                    if !success && !model.statusMessage.contains("取消") {
                        showForceUnmountAlert = true
                    }
                }
            }
        } message: {
            Text("卸载后工具将无法继续读取或写入 EFI。请先关闭正在编辑 EFI 的窗口，并确认修改已经保存。")
        }
        .alert("卸载失败", isPresented: $showForceUnmountAlert) {
            Button("取消", role: .cancel) {}
            Button("强制卸载", role: .destructive) {
                Task { await model.unmountEFI(force: true) }
            }
        } message: {
            Text("EFI 卷可能仍被其他程序占用。强制卸载会立即断开文件系统，请先保存所有修改，再尝试强制卸载。")
        }
    }

    // MARK: - 说明

    private var introCard: some View {
        ToolkitPageIntro(
            title: "挂载 EFI 分区，读取 OpenCore 配置",
            summary: "挂载 EFI 分区后，工具才能读取 EFI/OC/config.plist、检查 EFI/OC/Kexts 中的 kext，并把 OffsetProfile 写入 NootedRedUserPatch。所有写入操作都会以管理员权限执行。",
            symbol: "externaldrive.badge.checkmark",
            prerequisites: [
                "确认 OpenCore 所在的 EFI 分区（通常是 diskXs1）",
                "挂载与写入需要输入管理员密码授权",
                "写入前请先备份整个 EFI 分区"
            ],
            steps: [
                "在下方「候选分区」中点「挂载」",
                "核对已挂载卡片里的 OpenCore 摘要",
                "完成后点「卸载」，避免误改配置"
            ],
            caution: "挂载 EFI 不会修改磁盘内容；但随后修改 config.plist 或写入 kext 有导致无法开机的风险，操作前请备份 EFI，并确保有可用的 OpenCore 救援引导。"
        )
    }

    // MARK: - 未挂载状态

    private var notMountedCard: some View {
        ToolkitCard {
            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Text("EFI 分区未挂载")
                            .font(.system(size: 15, weight: .bold, design: .rounded))
                        ToolkitBadge(text: "未挂载", color: HealthLevel.warning.color)
                    }
                    Text(notMountedDetail)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if model.installedProfile != nil {
                        Text("EFI 中已写入的 OffsetProfile 需要挂载后才能查看。")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    }
                }
                Spacer(minLength: 12)
                Button {
                    Task { await model.mountPreferredEFI() }
                } label: {
                    Label("一键挂载", systemImage: "arrow.up.forward.app")
                }
                .buttonStyle(ToolkitPrimaryButtonStyle())
                .disabled(model.isEFIOperating)
            }
        }
    }

    private var notMountedDetail: String {
        if model.efi.partitions.isEmpty {
            return "当前未检测到 EFI 分区。若使用外置引导或磁盘结构特殊，请点下方「重新扫描」；也可以先在「磁盘工具」中确认 EFI 分区存在。"
        }
        if model.efi.partitions.count == 1 {
            return "检测到 1 个 EFI 分区。点「一键挂载」会直接挂载它，并在完成后自动读取 OpenCore 配置。"
        }
        return "检测到 \(model.efi.partitions.count) 个 EFI 分区。请先在下方列表中确认正在使用的引导分区，再单独挂载，避免读写错误的 EFI。"
    }

    // MARK: - 已挂载卡片

    private func mountedCard(_ mounted: MountedEFI) -> some View {
        ToolkitCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline) {
                    ToolkitSectionTitle(title: "已挂载 EFI 分区",
                                        subtitle: "可以读取 OpenCore 配置，也可以写入 OffsetProfile",
                                        symbol: "externaldrive.badge.checkmark")
                    Spacer()
                    ToolkitBadge(text: "已挂载", color: HealthLevel.pass.color, symbol: "checkmark.circle.fill")
                }

                HStack(alignment: .top, spacing: 26) {
                    VStack(alignment: .leading, spacing: 7) {
                        ToolkitInfoRow(label: "设备号", value: mounted.partition.deviceIdentifier, mono: true)
                        ToolkitInfoRow(label: "卷名", value: mounted.partition.displayName)
                        ToolkitInfoRow(label: "大小", value: mounted.partition.sizeText)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    VStack(alignment: .leading, spacing: 7) {
                        ToolkitInfoRow(label: "类别", value: mounted.partition.locationText
                                       + (mounted.partition.busProtocol.map { " · \($0)" } ?? ""))
                        ToolkitInfoRow(label: "文件系统", value: mounted.partition.filesystem ?? "—")
                        ToolkitInfoRow(label: "挂载路径", value: mounted.rootURL.path, mono: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                Rectangle()
                    .fill(ToolkitTheme.divider)
                    .frame(height: 1)

                openCoreSection

                Rectangle()
                    .fill(ToolkitTheme.divider)
                    .frame(height: 1)

                HStack(spacing: 10) {
                    Button {
                        model.openEFIInFinder()
                    } label: {
                        Label("在 Finder 中显示", systemImage: "folder")
                    }
                    .buttonStyle(ToolkitSecondaryButtonStyle())

                    Button {
                        showUnmountAlert = true
                    } label: {
                        Label("卸载", systemImage: "eject")
                    }
                    .buttonStyle(ToolkitSecondaryButtonStyle(tint: HealthLevel.fail.color))
                    .disabled(model.isEFIOperating)

                    Button {
                        Task { await model.refreshEFI() }
                    } label: {
                        Label("重新扫描", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(ToolkitSecondaryButtonStyle())
                    .disabled(model.isRefreshing)

                    if model.isEFIOperating {
                        HStack(spacing: 7) {
                            ToolkitSpinner(size: 11)
                            Text("正在操作 EFI…")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                    }

                    Spacer(minLength: 0)

                    if let installed = model.installedProfile {
                        HStack(spacing: 7) {
                            Image(systemName: "checkmark.seal.fill")
                                .font(.system(size: 11))
                                .foregroundStyle(HealthLevel.pass.color)
                            Text("EFI 中已写入 OffsetProfile：build \(installed.build) · \(installed.pageCount) 页")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    } else {
                        HStack(spacing: 7) {
                            Image(systemName: "exclamationmark.circle")
                                .font(.system(size: 11))
                                .foregroundStyle(HealthLevel.warning.color)
                            Text("EFI 中尚未写入 OffsetProfile")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    // MARK: - OpenCore 摘要

    @ViewBuilder
    private var openCoreSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            ToolkitSectionTitle(title: "OpenCore 摘要",
                                subtitle: "挂载后读取 EFI/OC/config.plist 得到",
                                symbol: "doc.text.magnifyingglass")

            if let core = model.openCore {
                HStack(alignment: .top, spacing: 26) {
                    VStack(alignment: .leading, spacing: 7) {
                        ToolkitInfoRow(label: "引导器", value: core.bootloader.rawValue)
                        ToolkitInfoRow(label: "配置文件", value: core.configPath, mono: true)
                        ToolkitInfoRow(label: "ProductName", value: core.productName ?? "未设置")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    VStack(alignment: .leading, spacing: 7) {
                        ToolkitInfoRow(label: "Kernel > Add",
                                       value: "\(core.kextEntries.count) 项 · 启用 \(core.enabledKextCount) 项")
                        ToolkitInfoRow(label: "boot-args", value: core.configBootArgs ?? "未设置", mono: true)
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            Text("NootedRed")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.secondary)
                                .frame(width: 88, alignment: .leading)
                            HStack(spacing: 6) {
                                kextEntryBadge(core.nootedRedEntry, presentTitle: "已启用")
                                kextEntryBadge(core.userPatchEntry, presentTitle: "UserPatch 已启用")
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                ToolkitCallout(
                    text: "已挂载，但未在 EFI/OC 找到 config.plist。请确认挂载的是 OpenCore 引导分区，而不是普通 EFI 分区。",
                    symbol: "exclamationmark.triangle.fill",
                    color: HealthLevel.warning.color
                )
            }
        }
    }

    /// NootedRed / UserPatch 在 config.plist 中的启用状态徽章。
    private func kextEntryBadge(_ entry: OpenCoreKextEntry?, presentTitle: String) -> some View {
        if let entry {
            if entry.enabled {
                return ToolkitBadge(text: presentTitle, color: HealthLevel.pass.color, symbol: "checkmark.circle.fill")
            }
            return ToolkitBadge(text: "已禁用", color: HealthLevel.warning.color, symbol: "pause.circle.fill")
        }
        return ToolkitBadge(text: "未加入 config", color: HealthLevel.info.color, symbol: "minus.circle.fill")
    }

    // MARK: - 候选分区

    private var partitionsCard: some View {
        ToolkitCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    ToolkitSectionTitle(title: "候选 EFI 分区",
                                        subtitle: model.efi.hasAnyPartition
                                            ? "共 \(model.efi.partitions.count) 个分区，请选择正在使用的引导分区"
                                            : "尚未扫描到 EFI 分区",
                                        symbol: "externaldrive")
                    Spacer()
                    Button {
                        Task { await model.refreshEFI() }
                    } label: {
                        Label("重新扫描", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(ToolkitSecondaryButtonStyle(compact: true))
                    .disabled(model.isRefreshing)
                }

                if model.efi.partitions.isEmpty {
                    ToolkitEmptyState(
                        symbol: "externaldrive.badge.questionmark",
                        title: "未检测到 EFI 分区",
                        message: "可能是以下原因：从外置设备启动、磁盘使用特殊分区结构、或需要先在「磁盘工具」确认 EFI 分区存在。点击「重新扫描」会重新枚举所有磁盘。",
                        actionTitle: "重新扫描"
                    ) {
                        Task { await model.refreshEFI() }
                    }
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(model.efi.partitions.enumerated()), id: \.element.id) { index, partition in
                            if index > 0 {
                                Rectangle()
                                    .fill(ToolkitTheme.divider)
                                    .frame(height: 1)
                            }
                            partitionRow(partition)
                        }
                    }
                }
            }
        }
    }

    private func partitionRow(_ partition: EFIPartition) -> some View {
        HStack(spacing: 13) {
            Image(systemName: partition.isMounted ? "externaldrive.fill" : "externaldrive")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(partition.isMounted ? HealthLevel.pass.color : ToolkitTheme.accent)
                .frame(width: 36, height: 36)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill((partition.isMounted ? HealthLevel.pass.color : ToolkitTheme.accent).opacity(0.09)))

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(partition.deviceIdentifier)
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    Text(partition.displayName)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                    ToolkitBadge(text: partition.locationText, color: .secondary)
                    if let filesystem = partition.filesystem, !filesystem.isEmpty {
                        ToolkitBadge(text: filesystem, color: .secondary)
                    }
                    if partition.isMounted {
                        ToolkitBadge(text: "已挂载", color: HealthLevel.pass.color, symbol: "checkmark.circle.fill")
                    }
                }
                HStack(spacing: 8) {
                    Text(partition.sizeText)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    if let bus = partition.busProtocol, !bus.isEmpty {
                        Text("· \(bus)")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    }
                    if let mountPoint = partition.mountPoint, !mountPoint.isEmpty {
                        Text("· \(mountPoint)")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                    if !partition.isMounted {
                        Text("· 挂载后可读取 OpenCore 信息")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    }
                }
            }

            Spacer(minLength: 8)

            if partition.isMounted {
                if model.efi.mounted?.partition.id == partition.id {
                    Text("当前使用")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(ToolkitTheme.accent)
                        .padding(.horizontal, 9)
                        .frame(height: 26)
                        .background(Capsule().fill(ToolkitTheme.accent.opacity(0.09)))
                }
            } else {
                Button {
                    pendingMountID = partition.id
                    Task {
                        _ = await model.mountEFI(partition)
                        pendingMountID = nil
                    }
                } label: {
                    if pendingMountID == partition.id && model.isEFIOperating {
                        HStack(spacing: 6) {
                            ToolkitSpinner(size: 10, color: .white)
                            Text("挂载中")
                        }
                    } else {
                        Label("挂载", systemImage: "arrow.up.forward.app")
                    }
                }
                .buttonStyle(ToolkitPrimaryButtonStyle(compact: true))
                .disabled(model.isEFIOperating)
            }
        }
        .padding(.vertical, 10)
    }
}
