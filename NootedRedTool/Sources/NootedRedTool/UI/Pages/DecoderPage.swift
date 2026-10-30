import SwiftUI

/// 驱动解码：说明 GL / MTL / VDA / GVA 的作用，解码并写入 OffsetProfile。
struct DecoderPage: View {
    @EnvironmentObject private var model: AppModel
    @State private var showInstallAlert = false

    private var filteredPages: [OffsetPage] {
        guard let profile = model.decoderProfile else { return [] }
        let query = model.searchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return profile.pages }
        return profile.pages.filter { page in
            page.driver.localizedCaseInsensitiveContains(query)
                || ToolkitFormat.hex(page.pageFileOffset).localizedCaseInsensitiveContains(query)
                || page.sites.contains { ($0.function ?? "").localizedCaseInsensitiveContains(query) }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: ToolkitTheme.pageSpacing) {
            introCard
            driverScopeCard
            actionCard
            resultCard
            logCard
        }
        .alert("写入 EFI", isPresented: $showInstallAlert) {
            Button("取消", role: .cancel) {}
            Button("确认写入") {
                model.installProfile()
            }
        } message: {
            Text("将把当前 OffsetProfile 写入 EFI 中 NootedRedUserPatch.kext 的 Info.plist，并需要管理员授权。写入前请确认已备份 EFI 分区，且当前 macOS 构建与 NootedRedUserPatch 匹配。")
        }
    }

    // MARK: - 说明

    private var introCard: some View {
        ToolkitPageIntro(
            title: "驱动解码，生成 OffsetProfile",
            summary: "读取本机 AMD 的 GL / Metal / VDA / GVA 驱动与 dyld 共享缓存，定位需要修补的页偏移，生成给 NootedRedUserPatch 使用的 OffsetProfile。解码只读取本机文件，不会修改系统。",
            symbol: "chevron.left.forwardslash.chevron.right",
            prerequisites: [
                "macOS 构建版本与 NootedRedUserPatch 匹配",
                "写入 EFI 前需要先挂载 EFI 分区",
                "写入前请备份 EFI 分区"
            ],
            steps: [
                "点「开始解码」，等待日志完成",
                "核对页数与 sites 数量",
                "写入 EFI，重启后生效"
            ],
            caution: "OffsetProfile 只对当前 macOS 构建有效。升级系统后需要重新解码并重新写入，否则用户态补丁可能不会生效。"
        )
    }

    // MARK: - 解码范围

    private var driverScopeCard: some View {
        ToolkitCard {
            VStack(alignment: .leading, spacing: 12) {
                ToolkitSectionTitle(title: "解码范围", subtitle: "四类驱动分别负责不同的图形与视频功能", symbol: "square.stack.3d.up")
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 10) {
                    driverScope("GL", "OpenGL", "AMDRadeonX5000GLDriver", "修复 HwInfo / DualQuad 页面，改善 OpenGL 应用与游戏兼容性。", "square.stack.3d.up")
                    driverScope("MTL", "Metal", "AMDRadeonX5000MTLDriver", "修补 Control 与 HwInfo 页面，让 Metal 正确识别驱动能力。", "circle.hexagongrid")
                    driverScope("VDA", "视频解码", "AMDRadeonVADriver2", "修正多页偏移，启用 H.264 / HEVC 硬件解码。", "play.rectangle")
                    driverScope("GVA", "视频加速", "AppleGVA", "修补视频硬解通路，配合 NootedRedUserPatch 生效。", "photo")
                }
            }
        }
    }

    private func driverScope(_ tag: String, _ title: String, _ component: String,
                             _ detail: String, _ symbol: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(ToolkitTheme.accent)
                .frame(width: 28, height: 28)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(ToolkitTheme.accent.opacity(0.09)))
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(tag)
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundStyle(ToolkitTheme.accent)
                    Text(title)
                        .font(.system(size: 11, weight: .semibold))
                }
                Text(component)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.tertiary)
                Text(detail)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: ToolkitTheme.innerRadius, style: .continuous).fill(ToolkitTheme.subtleFill))
    }

    // MARK: - 操作

    private var actionCard: some View {
        ToolkitCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .center) {
                    ToolkitSectionTitle(title: "解码与写入",
                                        subtitle: model.isDecoding ? "正在解码，请勿关闭窗口…" : "解码完成后把结果写入 EFI",
                                        symbol: "bolt.fill")
                    Spacer()
                    HStack(spacing: 8) {
                        Button {
                            model.runDecoder()
                        } label: {
                            if model.isDecoding {
                                HStack(spacing: 6) {
                                    ToolkitSpinner(size: 11, color: .white)
                                    Text("解码中…")
                                }
                            } else {
                                Label(model.decoderProfile == nil ? "开始解码" : "重新解码", systemImage: "play.fill")
                            }
                        }
                        .buttonStyle(ToolkitPrimaryButtonStyle())
                        .disabled(model.isDecoding)

                        if model.efi.mounted == nil {
                            Button {
                                Task { await model.mountPreferredEFI() }
                            } label: {
                                Label("先挂载 EFI", systemImage: "externaldrive")
                            }
                            .buttonStyle(ToolkitSecondaryButtonStyle())
                            .disabled(model.isDecoding || model.isEFIOperating)
                        } else {
                            Button {
                                showInstallAlert = true
                            } label: {
                                Label("写入 EFI", systemImage: "arrow.down.to.line")
                            }
                            .buttonStyle(ToolkitSecondaryButtonStyle())
                            .disabled(model.isDecoding || model.decoderProfile == nil)
                        }
                    }
                }

                if let profile = model.decoderProfile {
                    HStack(spacing: 10) {
                        resultStat("页面", "\(profile.pageCount)")
                        resultStat("sites", "\(profile.siteCount)")
                        resultStat("build", profile.build)
                        resultStat("生成时间", ToolkitFormat.isoLocal(profile.generatedAt))
                        Spacer(minLength: 8)
                        if let output = model.decoderOutput {
                            Label(output.lastPathComponent, systemImage: "checkmark.circle")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(HealthLevel.pass.color)
                                .lineLimit(1)
                        }
                    }
                } else {
                    ToolkitCallout(
                        text: "还没有解码结果。点「开始解码」读取本机 GL / Metal / VDA 驱动，首次解码可能需要几十秒。",
                        symbol: "info.circle.fill"
                    )
                }

                if model.efi.mounted == nil {
                    ToolkitCallout(
                        text: "写入 EFI 前需要挂载 EFI 分区。挂载需要管理员授权，写入前请先备份 EFI。",
                        symbol: "exclamationmark.triangle.fill",
                        color: HealthLevel.warning.color
                    )
                } else if let installed = model.installedProfile {
                    ToolkitCallout(
                        text: "EFI 中已有 OffsetProfile：build \(installed.build) · \(installed.pageCount) 页。若刚重新解码，可以再次写入覆盖。",
                        symbol: "checkmark.seal.fill",
                        color: HealthLevel.pass.color
                    )
                }
            }
        }
    }

    private func resultStat(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.tertiary)
            Text(value)
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .padding(.horizontal, 12)
        .frame(height: 42)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(ToolkitTheme.subtleFill))
    }

    // MARK: - 结果表

    private var resultCard: some View {
        ToolkitCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    ToolkitSectionTitle(title: "解码结果",
                                        subtitle: "pageVM 与 pageFileOffset 是用户态补丁定位所需的信息",
                                        symbol: "tablecells")
                    Spacer()
                    if !model.searchText.isEmpty {
                        Text("过滤后 \(filteredPages.count) 页")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                }

                if model.decoderProfile == nil {
                    ToolkitEmptyState(
                        symbol: "chevron.left.forwardslash.chevron.right",
                        title: "还没有解码结果",
                        message: "完成一次驱动解码后，这里会列出每个驱动页的 pageVM、pageFileOffset 与 sites 数量。",
                        actionTitle: "开始解码",
                        actionSymbol: "play.fill"
                    ) {
                        model.runDecoder()
                    }
                } else {
                    VStack(spacing: 0) {
                        tableHeader
                        ForEach(Array(filteredPages.enumerated()), id: \.element.id) { index, page in
                            if index > 0 {
                                Rectangle()
                                    .fill(ToolkitTheme.divider)
                                    .frame(height: 1)
                            }
                            pageRow(page)
                        }
                        if filteredPages.isEmpty {
                            Text("没有匹配「\(model.searchText)」的页面")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 14)
                        }
                    }
                    .background(RoundedRectangle(cornerRadius: ToolkitTheme.innerRadius, style: .continuous).fill(ToolkitTheme.subtleFill))
                }
            }
        }
    }

    private var tableHeader: some View {
        HStack(spacing: 12) {
            Text("驱动页面")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("pageVM")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.secondary)
                .frame(width: 120, alignment: .trailing)
            Text("pageFileOffset")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.secondary)
                .frame(width: 120, alignment: .trailing)
            Text("sites")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.secondary)
                .frame(width: 50, alignment: .trailing)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.primary.opacity(0.03))
    }

    private func pageRow(_ page: OffsetPage) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                Text(page.driver)
                    .font(.system(size: 11, weight: .semibold))
                if let first = page.sites.first, let function = first.function {
                    Text(function)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(ToolkitFormat.hex(page.pageVM))
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 120, alignment: .trailing)
            Text(ToolkitFormat.hex(page.pageFileOffset))
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 120, alignment: .trailing)
            Text("\(page.sites.count)")
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 50, alignment: .trailing)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - 日志

    private var logCard: some View {
        ToolkitCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    ToolkitSectionTitle(title: "解码日志", subtitle: "排查解码失败时先看这里", symbol: "text.alignleft")
                    Spacer()
                    if model.decoderOutput != nil {
                        Button {
                            model.openPage(.diagnostics)
                        } label: {
                            Text("查看诊断信息")
                        }
                        .buttonStyle(ToolkitSecondaryButtonStyle(compact: true))
                    }
                }
                ToolkitConsole(text: model.decoderLog, height: 150)
                Text("本机缓存：\(outputPathText)")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
    }

    private var outputPathText: String {
        model.decoderOutput?.path ?? "尚未生成"
    }
}
