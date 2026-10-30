import SwiftUI

/// 健康检查：按等级筛选、搜索、展示检查项与处理建议。
struct HealthPage: View {
    @EnvironmentObject private var model: AppModel
    @State private var filter: HealthLevel?

    private var filteredItems: [HealthItem] {
        var items = model.health
        if let filter {
            items = items.filter { $0.level == filter }
        }
        let query = model.searchText.trimmingCharacters(in: .whitespaces)
        if !query.isEmpty {
            items = items.filter {
                $0.title.localizedCaseInsensitiveContains(query)
                    || $0.detail.localizedCaseInsensitiveContains(query)
                    || $0.value.localizedCaseInsensitiveContains(query)
            }
        }
        return items
    }

    var body: some View {
        VStack(alignment: .leading, spacing: ToolkitTheme.pageSpacing) {
            ToolkitPageIntro(
                title: "逐项检查，按颜色处理",
                summary: "检查 NootedRed 主 kext、UserPatch、GPU、EFI 分区、OpenCore 配置与启动参数是否符合预期。每一项都附带处理建议，点「前往处理」可直达对应功能页。",
                symbol: "heart.text.square",
                prerequisites: [
                    "建议先挂载 EFI 分区，否则 EFI 与 kext 项只能给出「待挂载」提示",
                    "修改 EFI 或 boot-args 后重新检查一次"
                ],
                steps: [
                    "先处理红色「异常」项",
                    "再处理橙色「注意」项",
                    "全部通过后保留一份诊断信息"
                ]
            )
            summaryCard
            itemsCard
        }
    }

    // MARK: - 摘要与筛选

    private var summaryCard: some View {
        ToolkitCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    ToolkitSectionTitle(title: "检查结果", subtitle: "共 \(model.health.count) 项，按等级筛选", symbol: "checklist")
                    Spacer()
                    if !model.searchText.isEmpty {
                        Text("搜索「\(model.searchText)」：\(filteredItems.count) 项")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                }

                HStack(spacing: 8) {
                    ToolkitFilterChip(title: "全部", color: ToolkitTheme.accent,
                                      count: model.health.count,
                                      isSelected: filter == nil) {
                        filter = nil
                    }
                    ForEach(HealthLevel.allCases, id: \.rawValue) { level in
                        ToolkitFilterChip(title: level.title, color: level.color,
                                          count: model.health.filter { $0.level == level }.count,
                                          isSelected: filter == level) {
                            filter = filter == level ? nil : level
                        }
                    }
                    Spacer(minLength: 0)
                }
            }
        }
    }

    // MARK: - 检查项列表

    private var itemsCard: some View {
        ToolkitCard {
            VStack(alignment: .leading, spacing: 0) {
                if filteredItems.isEmpty {
                    ToolkitEmptyState(
                        symbol: "checkmark.seal",
                        title: model.health.isEmpty ? "正在检查…" : "没有符合条件的检查项",
                        message: model.health.isEmpty
                            ? "正在读取系统状态，请稍候。"
                            : "试试清除搜索词或切换筛选条件。"
                    )
                } else {
                    ForEach(Array(filteredItems.enumerated()), id: \.element.id) { index, item in
                        if index > 0 {
                            Rectangle()
                                .fill(ToolkitTheme.divider)
                                .frame(height: 1)
                                .padding(.vertical, 4)
                        }
                        healthRow(item)
                    }
                }
            }
        }
    }

    private func healthRow(_ item: HealthItem) -> some View {
        HStack(alignment: .top, spacing: 13) {
            ZStack {
                Circle()
                    .fill(item.level.color.opacity(0.13))
                    .frame(width: 32, height: 32)
                Image(systemName: icon(for: item.level))
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(item.level.color)
            }

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text(item.title)
                        .font(.system(size: 13, weight: .semibold))
                    ToolkitLevelBadge(level: item.level)
                    Spacer(minLength: 4)
                    if item.value != "—" {
                        Text(item.value)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .multilineTextAlignment(.trailing)
                    }
                }

                Text(item.detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if let remedy = item.remedy {
                    HStack(alignment: .top, spacing: 7) {
                        Image(systemName: "lightbulb.fill")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(HealthLevel.warning.color)
                            .padding(.top, 1)
                        Text(remedy)
                            .font(.system(size: 11))
                            .foregroundStyle(Color.primary.opacity(0.72))
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 6)
                        if let page = item.page {
                            Button {
                                model.openPage(page)
                            } label: {
                                Label("前往处理", systemImage: "arrow.right")
                            }
                            .buttonStyle(ToolkitSecondaryButtonStyle(compact: true))
                        }
                    }
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(HealthLevel.warning.color.opacity(0.075)))
                }
            }
        }
        .padding(.vertical, 10)
    }

    private func icon(for level: HealthLevel) -> String {
        switch level {
        case .pass: return "checkmark"
        case .warning: return "exclamationmark"
        case .fail: return "xmark"
        case .info: return "info"
        }
    }
}
