import SwiftUI

/// 启动参数：按功能分组勾选 boot-args，保存写入 NVRAM，并展示当前只读值。
struct BootArgumentsPage: View {
    @EnvironmentObject private var model: AppModel

    private var query: String {
        model.searchText.trimmingCharacters(in: .whitespaces)
    }

    private func features(in group: BootGroup) -> [BootFeature] {
        let all = BootFeature.features(in: group)
        guard !query.isEmpty else { return all }
        return all.filter {
            $0.title.localizedCaseInsensitiveContains(query)
                || $0.detail.localizedCaseInsensitiveContains(query)
                || $0.flag.localizedCaseInsensitiveContains(query)
        }
    }

    private var enabledCount: Int {
        BootFeature.catalog.filter { model.isEnabled($0) }.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: ToolkitTheme.pageSpacing) {
            introCard
            currentCard
            groupsCard
        }
    }

    // MARK: - 说明

    private var introCard: some View {
        ToolkitPageIntro(
            title: "用勾选的方式管理 boot-args",
            summary: "boot-args 是 OpenCore / NVRAM 中的启动参数。本页把 NootedRed 常用的功能开关整理成清单，勾选后写入 NVRAM，重启后生效。",
            symbol: "slider.horizontal.3",
            prerequisites: [
                "写入 NVRAM 需要管理员授权",
                "保存后必须重启才会生效",
                "建议先了解每个开关的作用"
            ],
            steps: [
                "只勾选当前需要的功能",
                "点「保存 boot-args」并输入管理员密码",
                "重启后在「健康检查」确认已生效"
            ],
            caution: "写入 NVRAM 属于危险操作：错误的 boot-args 可能导致无法进入系统。修改前请确认清楚每一项的含义，并保留可用的 OpenCore 救援引导。"
        )
    }

    // MARK: - 当前值

    private var currentCard: some View {
        ToolkitCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    ToolkitSectionTitle(title: "当前 boot-args",
                                        subtitle: "只读展示 NVRAM 中的实际值（不是已勾选值）",
                                        symbol: "terminal")
                    Spacer()
                    Button {
                        model.saveBootArgs()
                    } label: {
                        if model.isRefreshing {
                            HStack(spacing: 6) {
                                ToolkitSpinner(size: 11, color: .white)
                                Text("写入中…")
                            }
                        } else {
                            Label("保存 boot-args", systemImage: "square.and.arrow.down")
                        }
                    }
                    .buttonStyle(ToolkitPrimaryButtonStyle())
                    .disabled(model.isRefreshing)
                }

                HStack(spacing: 8) {
                    Text(model.bootState.serialized.isEmpty ? "（当前未设置 boot-args）" : model.bootState.serialized)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(model.bootState.serialized.isEmpty ? Color.secondary : Color.primary.opacity(0.82))
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                    Spacer(minLength: 0)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: ToolkitTheme.innerRadius, style: .continuous)
                    .fill(Color(nsColor: .textBackgroundColor).opacity(0.75)))

                HStack(spacing: 10) {
                    ToolkitBadge(text: "已勾选 \(enabledCount) 项", color: ToolkitTheme.accent)
                    if !model.bootState.otherArguments.isEmpty {
                        Text("其他参数：\(model.bootState.otherArguments.joined(separator: " "))")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    Text("保存后重启生效")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    // MARK: - 功能分组

    private var groupsCard: some View {
        ToolkitCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline) {
                    ToolkitSectionTitle(title: "功能开关",
                                        subtitle: "按用途分组：功能补丁、调试、日志、救援回滚",
                                        symbol: "switch.2")
                    Spacer()
                    if !query.isEmpty {
                        let matches = BootFeature.catalog.filter { features(in: $0.group).contains($0) }
                        Text("匹配 \(matches.count) 项")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                }

                let visibleGroups = BootGroup.allCases.filter { !features(in: $0).isEmpty }
                if visibleGroups.isEmpty {
                    ToolkitEmptyState(
                        symbol: "magnifyingglass",
                        title: "没有匹配的启动参数",
                        message: "试试搜索功能名称、说明或 flag，例如「VDA」「日志」「-NRedOff」。"
                    )
                } else {
                    ForEach(Array(visibleGroups.enumerated()), id: \.element.id) { index, group in
                        if index > 0 {
                            Rectangle()
                                .fill(ToolkitTheme.divider)
                                .frame(height: 1)
                        }
                        groupSection(group)
                    }
                }
            }
        }
    }

    private func groupSection(_ group: BootGroup) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: group.symbol)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(ToolkitTheme.accent)
                Text(group.title)
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                Text(group.detail)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.top, 2)

            VStack(spacing: 0) {
                ForEach(Array(features(in: group).enumerated()), id: \.element.id) { index, feature in
                    if index > 0 {
                        Rectangle()
                            .fill(ToolkitTheme.divider)
                            .frame(height: 1)
                    }
                    featureRow(feature)
                }
            }
            .padding(.horizontal, 12)
            .background(RoundedRectangle(cornerRadius: ToolkitTheme.innerRadius, style: .continuous)
                .fill(ToolkitTheme.subtleFill))
        }
    }

    private func featureRow(_ feature: BootFeature) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: feature.symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(ToolkitTheme.accent)
                .frame(width: 30, height: 30)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(ToolkitTheme.accent.opacity(0.08)))

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(feature.title)
                        .font(.system(size: 12, weight: .semibold))
                    Text(feature.flag)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.primary.opacity(0.05)))
                }
                Text(feature.detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let risk = feature.risk {
                    HStack(alignment: .top, spacing: 5) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundStyle(HealthLevel.warning.color)
                            .padding(.top, 1)
                        Text(risk)
                            .font(.system(size: 10))
                            .foregroundStyle(HealthLevel.warning.color.opacity(0.9))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            Spacer(minLength: 8)

            Toggle("", isOn: Binding(
                get: { model.isEnabled(feature) },
                set: { model.setEnabled(feature, $0) }
            ))
            .labelsHidden()
            .toggleStyle(ToolkitSwitchToggleStyle())
            .help("切换 \(feature.flag)")
        }
        .padding(.vertical, 9)
    }
}
