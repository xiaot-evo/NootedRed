import SwiftUI

/// 诊断信息：只读展示汇总信息，一键复制，并给出反馈问题时的收集清单。
struct DiagnosticsPage: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: ToolkitTheme.pageSpacing) {
            introCard
            consoleCard
            feedbackCard
        }
    }

    private var introCard: some View {
        ToolkitPageIntro(
            title: "反馈问题时请附上诊断信息",
            summary: "这里汇总系统版本、kext 加载状态、EFI 分区与 OpenCore 配置摘要，便于开发者快速定位问题。复制后可以直接粘贴到 GitHub Issue 或论坛反馈帖。",
            symbol: "terminal",
            prerequisites: [
                "建议先挂载 EFI 分区并完成一次健康检查",
                "诊断信息只读，不包含个人文件内容"
            ],
            steps: [
                "点「复制诊断信息」",
                "粘贴到 Issue 或反馈帖",
                "补充复现步骤与相关日志"
            ],
            caution: "诊断信息包含主机名、系统版本与 EFI 挂载路径，粘贴到公开位置前请自行确认是否包含不希望公开的信息。"
        )
    }

    private var consoleCard: some View {
        ToolkitCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    ToolkitSectionTitle(title: "诊断快照",
                                        subtitle: "页面显示为本地时间 \(ToolkitFormat.localDateTime(model.lastRefresh))，只读",
                                        symbol: "doc.text")
                    Spacer()
                    Button {
                        model.refresh()
                    } label: {
                        Label("重新检查", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(ToolkitSecondaryButtonStyle(compact: true))
                    .disabled(model.isRefreshing)

                    Button {
                        model.copyDiagnostics()
                    } label: {
                        Label("复制诊断信息", systemImage: "doc.on.doc")
                    }
                    .buttonStyle(ToolkitPrimaryButtonStyle())
                }
                Text("提示：诊断文本中的 generated 字段使用 UTC 时间，与页面上方的本地时间相差时区偏移。")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                ToolkitConsole(text: model.diagnostics.isEmpty ? "正在收集诊断信息…" : model.diagnostics,
                               height: 430)
            }
        }
    }

    private var feedbackCard: some View {
        ToolkitCard {
            VStack(alignment: .leading, spacing: 10) {
                ToolkitSectionTitle(title: "反馈问题时建议附带",
                                subtitle: "信息越完整，定位越快", symbol: "text.bubble")
                HStack(alignment: .top, spacing: 26) {
                    feedbackItem("1", "诊断信息", "本页「复制诊断信息」的内容。")
                    feedbackItem("2", "复现步骤", "做了什么、期望结果与实际结果。")
                    feedbackItem("3", "相关日志", "必要时加上 -liludbgall 启动参数，重启后导出日志。")
                    feedbackItem("4", "硬件信息", "核显型号、显存分配与显示器连接方式。")
                }
            }
        }
    }

    private func feedbackItem(_ index: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Text(index)
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .frame(width: 20, height: 20)
                .background(Circle().fill(ToolkitTheme.accentGradient))
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                Text(detail)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
