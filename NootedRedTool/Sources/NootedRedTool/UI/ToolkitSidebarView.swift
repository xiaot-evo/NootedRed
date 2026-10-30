import SwiftUI

/// 左侧分组侧边栏：按 AppPageGroup 组织功能入口，底部显示 kext / EFI / 版本状态。
struct ToolkitSidebarView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            brand
            VStack(alignment: .leading, spacing: 1) {
                ForEach(AppPageGroup.allCases) { group in
                    groupHeader(group)
                    ForEach(AppPage.pages(in: group)) { page in
                        navButton(page)
                    }
                }
            }
            .padding(.top, 2)
            Spacer(minLength: 8)
            footer
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(.thinMaterial)
    }

    // MARK: - 品牌

    private var brand: some View {
        HStack(spacing: 11) {
            ZStack {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(ToolkitTheme.accentGradient)
                Image(systemName: "display")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: 38, height: 38)

            VStack(alignment: .leading, spacing: 1) {
                Text(AppInfo.brand)
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                Text("TOOLKIT")
                    .font(.system(size: 9, weight: .semibold))
                    .tracking(1.6)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 22)
        .padding(.bottom, 18)
    }

    // MARK: - 分组

    private func groupHeader(_ group: AppPageGroup) -> some View {
        Text(group.title)
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(.tertiary)
            .tracking(1.1)
            .padding(.horizontal, 22)
            .padding(.top, 14)
            .padding(.bottom, 5)
    }

    private func navButton(_ page: AppPage) -> some View {
        let selected = model.selectedPage == page
        return Button {
            model.openPage(page)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: page.symbol)
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 18)
                Text(page.title)
                    .font(.system(size: 13, weight: .medium))
                Spacer(minLength: 4)
                navBadge(for: page)
            }
            .foregroundStyle(selected ? Color.white : Color.primary.opacity(0.82))
            .padding(.horizontal, 12)
            .frame(height: 34)
            .background {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(selected
                          ? AnyShapeStyle(ToolkitTheme.accentGradientHorizontal)
                          : AnyShapeStyle(Color.clear))
            }
            .padding(.horizontal, 10)
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(page.subtitle)
    }

    @ViewBuilder
    private func navBadge(for page: AppPage) -> some View {
        switch page {
        case .health:
            let failures = model.health.filter { $0.level == .fail }.count
            if failures > 0 {
                Text("\(failures)")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5)
                    .frame(minWidth: 16, minHeight: 16)
                    .background(Capsule().fill(HealthLevel.fail.color))
            }
        case .efi:
            ToolkitStatusDot(color: efiStatusColor, size: 7)
        case .kexts:
            if !model.efi.partitions.isEmpty, model.kexts.contains(where: { $0.isNootedRed && $0.state != .enabled }) {
                ToolkitStatusDot(color: HealthLevel.warning.color, size: 7)
            }
        default:
            EmptyView()
        }
    }

    // MARK: - 底部状态

    private var efiStatusColor: Color {
        if model.efi.mounted != nil { return HealthLevel.pass.color }
        return HealthLevel.warning.color
    }

    private var efiStatusText: String {
        if let mounted = model.efi.mounted {
            return "EFI 已挂载 · \(mounted.partition.deviceIdentifier)"
        }
        if model.efi.partitions.isEmpty {
            return "EFI 未检测到"
        }
        return "EFI 未挂载（\(model.efi.partitions.count) 个候选）"
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                ToolkitStatusDot(color: model.info.kextVersion == "未加载"
                                 ? HealthLevel.warning.color : HealthLevel.pass.color, size: 6)
                Text(model.info.kextVersion == "未加载"
                     ? "NootedRed 未加载" : "NootedRed \(model.info.kextVersion)")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            HStack(spacing: 6) {
                ToolkitStatusDot(color: efiStatusColor, size: 6)
                Text(efiStatusText)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Text("\(AppInfo.name) \(AppInfo.version)")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 16)
        .padding(.top, 4)
    }
}
