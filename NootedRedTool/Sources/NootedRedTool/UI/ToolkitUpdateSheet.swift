import SwiftUI

/// Kext 更新占位面板：说明接口预留、不执行写入，并提示挂载 / 备份 EFI。
struct ToolkitUpdateSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                        .fill(ToolkitTheme.accentGradient)
                    Image(systemName: "shippingbox.and.arrow.backward")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(.white)
                }
                .frame(width: 50, height: 50)

                VStack(alignment: .leading, spacing: 3) {
                    Text("Kext 更新（接口预留）")
                        .font(.system(size: 19, weight: .bold, design: .rounded))
                    Text("本版本不执行写入，仅保留更新入口与流程说明")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }

            ToolkitCallout(
                text: "正式更新流程需要：先挂载 EFI 分区、备份整个 EFI、选择 NootedRed 发布包、校验版本与签名、替换 NootedRed 与 NootedRedUserPatch，最后校验 config.plist 并重启。",
                symbol: "lock.shield.fill"
            )

            VStack(alignment: .leading, spacing: 8) {
                Text("更新步骤（规划中）")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.secondary)
                updateStep(1, "挂载 EFI 分区", "在「EFI 分区」页确认挂载的是正在使用的 OpenCore 引导分区。")
                updateStep(2, "备份 EFI", "复制整个 EFI 目录到本机或外置磁盘，出问题时可以还原。")
                updateStep(3, "替换 kext", "用新版本替换 EFI/OC/Kexts 中的 NootedRed.kext 与 NootedRedUserPatch.kext。")
                updateStep(4, "写入 OffsetProfile", "系统构建变化后，需要重新驱动解码并写入 EFI。")
                updateStep(5, "重启验证", "重启后到「健康检查」确认 kext 版本与补丁页数。")
            }

            HStack(spacing: 10) {
                Label("不在此版本执行写入", systemImage: "lock.shield")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    dismiss()
                    model.openPage(.efi)
                } label: {
                    Text("前往 EFI 分区")
                }
                .buttonStyle(ToolkitSecondaryButtonStyle())
                Button {
                    dismiss()
                } label: {
                    Text("关闭")
                }
                .buttonStyle(ToolkitPrimaryButtonStyle())
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 560)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func updateStep(_ index: Int, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Text("\(index)")
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .foregroundStyle(ToolkitTheme.accent)
                .frame(width: 18, height: 18)
                .background(Circle().fill(ToolkitTheme.accent.opacity(0.10)))
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                Text(detail)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }
}
