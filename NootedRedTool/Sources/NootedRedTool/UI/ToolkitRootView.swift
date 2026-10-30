import SwiftUI

/// 应用主界面：分组侧边栏 + 页面头部 + 可滚动内容区 + 底部状态栏。
///
/// 页面本身只负责内容排版，滚动由根视图统一负责，避免嵌套滚动。
struct ToolkitRootView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        HStack(spacing: 0) {
            ToolkitSidebarView()
                .frame(width: 236)
            Rectangle()
                .fill(Color.primary.opacity(0.08))
                .frame(width: 1)
            VStack(spacing: 0) {
                ToolkitHeaderView()
                Rectangle()
                    .fill(ToolkitTheme.divider)
                    .frame(height: 1)
                pageContainer
                if SnapshotSupport.isRequested {
                    // 快照固定 1280×840：占满剩余高度，让底部状态栏仍贴在窗口底部。
                    Spacer(minLength: 0)
                }
                ToolkitStatusBar()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(ToolkitBackgroundView())
        .sheet(isPresented: $model.showUpdateSheet) {
            ToolkitUpdateSheet()
                .environmentObject(model)
        }
    }

    @ViewBuilder
    private var pageContainer: some View {
        if SnapshotSupport.isRequested {
            // 离屏渲染（--snapshot）无法渲染 ScrollView：快照时直接排版内容并裁到可视高度。
            pageBody
                .padding(.horizontal, ToolkitTheme.pageHorizontalPadding)
                .padding(.top, ToolkitTheme.pageSpacing)
                .padding(.bottom, 26)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .frame(height: 726, alignment: .topLeading)
                .clipped()
        } else {
            ScrollView {
                pageBody
                    .padding(.horizontal, ToolkitTheme.pageHorizontalPadding)
                    .padding(.top, ToolkitTheme.pageSpacing)
                    .padding(.bottom, 26)
            }
            .scrollIndicators(.hidden)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private var pageBody: some View {
        switch model.selectedPage {
        case .overview:
            OverviewPage()
        case .health:
            HealthPage()
        case .efi:
            EFIPage()
        case .decoder:
            DecoderPage()
        case .kexts:
            KextsPage()
        case .bootArguments:
            BootArgumentsPage()
        case .diagnostics:
            DiagnosticsPage()
        }
    }
}
