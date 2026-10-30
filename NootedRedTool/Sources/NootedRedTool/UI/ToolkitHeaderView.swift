import SwiftUI

/// 页面头部：标题 / 副标题、按页面显示搜索框、刷新按钮，以及常驻的 EFI 状态胶囊。
struct ToolkitHeaderView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text(model.selectedPage.title)
                    .font(.system(size: 24, weight: .bold, design: .rounded))
                    .lineLimit(1)
                Text(model.selectedPage.subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 12)

            if model.selectedPage.supportsSearch {
                ToolkitSearchField(text: $model.searchText)
            }

            refreshButton
            ToolkitEFIStatusCapsule()
        }
        .padding(.horizontal, ToolkitTheme.pageHorizontalPadding)
        .padding(.top, 20)
        .padding(.bottom, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var refreshButton: some View {
        Button {
            model.refresh()
        } label: {
            if model.isRefreshing {
                ToolkitSpinner(size: 13)
            } else {
                Image(systemName: "arrow.clockwise")
            }
        }
        .buttonStyle(ToolkitIconButtonStyle())
        .disabled(model.isRefreshing)
        .help("重新检查系统状态（⌘R）")
    }
}

/// 常驻的 EFI 状态胶囊：已挂载时进入 EFI 页；未挂载时尝试挂载首选分区。
struct ToolkitEFIStatusCapsule: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Button(action: handleTap) {
            HStack(spacing: 8) {
                ToolkitStatusDot(color: statusColor, size: 8)
                VStack(alignment: .leading, spacing: 0) {
                    Text(primaryText)
                        .font(.system(size: 11, weight: .semibold))
                        .lineLimit(1)
                    Text(secondaryText)
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if model.isEFIOperating {
                    ToolkitSpinner(size: 10)
                } else {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 11)
            .frame(height: 36)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(statusColor.opacity(model.efi.mounted != nil ? 0.10 : 0.12)))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(statusColor.opacity(0.25), lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(model.isEFIOperating)
        .help(helpText)
    }

    private var statusColor: Color {
        if model.efi.mounted != nil { return HealthLevel.pass.color }
        return HealthLevel.warning.color
    }

    private var primaryText: String {
        if let mounted = model.efi.mounted {
            return "EFI \(mounted.partition.deviceIdentifier)"
        }
        if model.efi.partitions.isEmpty {
            return "未检测到 EFI"
        }
        return "EFI 未挂载"
    }

    private var secondaryText: String {
        if let mounted = model.efi.mounted {
            return mounted.partition.displayName
        }
        if model.efi.partitions.isEmpty {
            return "点击扫描"
        }
        return "点击挂载"
    }

    private var helpText: String {
        model.efi.mounted != nil
            ? "打开「EFI 分区」页查看 OpenCore 摘要"
            : "挂载优先 EFI 分区（可能需要管理员授权）"
    }

    private func handleTap() {
        if model.efi.mounted != nil {
            model.openPage(.efi)
        } else {
            Task { await model.mountPreferredEFI() }
        }
    }
}

/// 窗口底部状态栏：显示最近一次操作结果与刷新时间。
struct ToolkitStatusBar: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        HStack(spacing: 8) {
            ToolkitStatusDot(color: model.statusIsError ? HealthLevel.fail.color : HealthLevel.pass.color, size: 6)
            Text(model.statusMessage)
                .font(.system(size: 11))
                .foregroundStyle(model.statusIsError ? HealthLevel.fail.color : Color.secondary)
                .lineLimit(1)
            if model.isRefreshing || model.isDecoding {
                ToolkitSpinner(size: 10)
            }
            Spacer(minLength: 8)
            Text("上次检查 \(ToolkitFormat.time(model.lastRefresh))")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
            Rectangle()
                .fill(ToolkitTheme.divider)
                .frame(width: 1, height: 12)
            Text("\(AppInfo.name) \(AppInfo.version)")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 20)
        .frame(height: 30)
        .background(Color.primary.opacity(0.02))
        .overlay(alignment: .top) {
            Rectangle()
                .fill(ToolkitTheme.divider)
                .frame(height: 1)
        }
    }
}
