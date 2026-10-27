import SwiftUI
import AppKit

struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    @State private var searchText = ""

    var body: some View {
        HStack(spacing: 0) {
            SidebarView()
                .frame(width: 224)
            Rectangle()
                .fill(Color.primary.opacity(0.07))
                .frame(width: 1)
            VStack(spacing: 0) {
                HeaderView(searchText: $searchText)
                Group {
                    if model.isRefreshing && model.info.osVersion == "—" {
                        loadingView
                    } else {
                        ScrollView {
                            detail
                                .padding(.horizontal, 28)
                                .padding(.top, 18)
                                .padding(.bottom, 28)
                        }
                        .scrollIndicators(.hidden)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(BackgroundView())
        .frame(minWidth: 1040, minHeight: 700)
        .sheet(isPresented: $model.showUpdateSheet) {
            UpdatePlaceholderSheet()
                .environmentObject(model)
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch model.selectedPage {
        case .overview:
            OverviewView(info: model.info, health: model.health)
        case .health:
            HealthView(items: filteredHealth)
        case .parser:
            ParserView()
        case .parameters:
            ParametersView()
        case .updater:
            UpdaterView()
        case .diagnostics:
            DiagnosticsView()
        }
    }

    private var loadingView: some View {
        VStack(spacing: 16) {
            ProgressView()
                .controlSize(.large)
            Text("正在检查系统状态…")
                .font(.system(size: 13, weight: .medium))
            Text("读取 kext、GPU、EFI 与最近 GPU 日志")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var filteredHealth: [HealthItem] {
        guard !searchText.isEmpty else { return model.health }
        return model.health.filter {
            $0.title.localizedCaseInsensitiveContains(searchText)
                || $0.detail.localizedCaseInsensitiveContains(searchText)
                || $0.value.localizedCaseInsensitiveContains(searchText)
        }
    }
}

private struct BackgroundView: View {
    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
            LinearGradient(
                colors: [
                    Color(red: 0.91, green: 0.94, blue: 1.0).opacity(0.55),
                    Color(nsColor: .windowBackgroundColor),
                    Color(red: 0.96, green: 0.92, blue: 1.0).opacity(0.35)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .blur(radius: 1)
        }
        .ignoresSafeArea()
    }
}

private struct SidebarView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 11) {
                ZStack {
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .fill(LinearGradient(colors: [Color(red: 0.18, green: 0.42, blue: 0.98),
                                                      Color(red: 0.55, green: 0.32, blue: 0.96)],
                                             startPoint: .topLeading,
                                             endPoint: .bottomTrailing))
                    Image(systemName: "display")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.white)
                }
                .frame(width: 38, height: 38)

                VStack(alignment: .leading, spacing: 1) {
                    Text("NootedRed")
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                    Text("Toolkit")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)
                        .tracking(1.2)
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 22)
            .padding(.bottom, 24)

            section("系统")
            navButton(.overview)
            navButton(.health)

            section("配置")
            navButton(.parser)
            navButton(.parameters)
            navButton(.updater)

            section("工具")
            navButton(.diagnostics)

            Spacer()

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 7) {
                    Circle()
                        .fill(model.info.kextVersion == "未加载" ? HealthLevel.warning.color : HealthLevel.pass.color)
                        .frame(width: 7, height: 7)
                    Text(model.info.kextVersion == "未加载" ? "NootedRed 未加载" : "NootedRed \(model.info.kextVersion)")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                Text("v0.1.0 · 本机工具")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 18)
        }
        .background(.thinMaterial.opacity(0.72))
    }

    private func section(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(.tertiary)
            .textCase(.uppercase)
            .tracking(1.1)
            .padding(.horizontal, 22)
            .padding(.top, 14)
            .padding(.bottom, 6)
    }

    private func navButton(_ page: AppPage) -> some View {
        Button {
            model.selectedPage = page
        } label: {
            HStack(spacing: 10) {
                Image(systemName: page.symbol)
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 18)
                Text(page.title)
                    .font(.system(size: 13, weight: .medium))
                Spacer()
                if page == .health, model.health.contains(where: { $0.level == .fail }) {
                    Circle().fill(HealthLevel.fail.color).frame(width: 6, height: 6)
                }
            }
            .foregroundStyle(model.selectedPage == page ? Color.white : Color.primary.opacity(0.82))
            .padding(.horizontal, 12)
            .frame(height: 34)
            .background {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(model.selectedPage == page
                          ? AnyShapeStyle(LinearGradient(colors: [Color(red: 0.20, green: 0.42, blue: 0.98),
                                                                   Color(red: 0.44, green: 0.32, blue: 0.94)],
                                                         startPoint: .leading,
                                                         endPoint: .trailing))
                          : AnyShapeStyle(Color.clear))
            }
            .padding(.horizontal, 10)
        }
        .buttonStyle(.plain)
    }
}

private struct HeaderView: View {
    @EnvironmentObject private var model: AppModel
    @Binding var searchText: String

    var body: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(model.selectedPage.title)
                    .font(.system(size: 24, weight: .bold, design: .rounded))
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                TextField("搜索", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .frame(width: 130)
            }
            .padding(.horizontal, 11)
            .frame(height: 30)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.055)))

            Button {
                model.refresh()
            } label: {
                Image(systemName: model.isRefreshing ? "arrow.triangle.2.circlepath" : "arrow.clockwise")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 30, height: 30)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.055)))
            }
            .buttonStyle(.plain)
            .rotationEffect(.degrees(model.isRefreshing ? 180 : 0))
            .animation(.linear(duration: 0.8).repeatForever(autoreverses: false), value: model.isRefreshing)

            Button {
                model.markUpdateInterface()
            } label: {
                Label("更新", systemImage: "arrow.down.circle")
                    .font(.system(size: 12, weight: .semibold))
                    .padding(.horizontal, 12)
                    .frame(height: 30)
            }
            .buttonStyle(.borderedProminent)
            .tint(Color(red: 0.24, green: 0.42, blue: 0.96))
        }
        .padding(.horizontal, 28)
        .padding(.top, 20)
        .padding(.bottom, 12)
    }

    private var subtitle: String {
        switch model.selectedPage {
        case .overview: return "系统、驱动与补丁状态一览"
        case .health: return "检查 kext、GPU、VDA 与 EFI 配置"
        case .parser: return "解析 GL / dyld cache，生成 OffsetProfile"
        case .parameters: return "勾选功能，写入 boot-args"
        case .updater: return "EFI kext 版本与更新接口"
        case .diagnostics: return "可复制到问题反馈的诊断信息"
        }
    }
}

private struct OverviewView: View {
    @EnvironmentObject private var model: AppModel
    let info: MachineInfo
    let health: [HealthItem]

    private var failures: Int { health.filter { $0.level == .fail }.count }
    private var warnings: Int { health.filter { $0.level == .warning }.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            hero
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)],
                      spacing: 14) {
                stat("NootedRed", info.kextVersion, "cpu", .blue)
                stat("UserPatch", info.appliedPages == "—" ? "未加载" : "\(info.appliedPages) 页", "square.stack.3d.up", .purple)
                stat("GPU", info.gpu, "display", .teal)
                stat("macOS", "\(info.osVersion) (\(info.build))", "apple.logo", .indigo)
            }
            healthCard
            quickActions
        }
    }

    private var hero: some View {
        HStack(spacing: 20) {
            ZStack {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(LinearGradient(colors: [Color(red: 0.20, green: 0.42, blue: 0.98),
                                                  Color(red: 0.52, green: 0.31, blue: 0.94)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                Image(systemName: "cpu")
                    .font(.system(size: 34, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: 78, height: 78)

            VStack(alignment: .leading, spacing: 6) {
                Text(info.hostname)
                    .font(.system(size: 19, weight: .bold, design: .rounded))
                Text("\(info.model)  ·  \(info.cpu)")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    badge("macOS \(info.osVersion)", color: .blue)
                    badge(info.architecture, color: .gray)
                    badge(info.memory, color: .teal)
                }
            }
            Spacer()
            statusPill
        }
        .padding(22)
        .background(cardBackground)
    }

    private var statusPill: some View {
        VStack(spacing: 5) {
            Image(systemName: failures == 0 ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                .font(.system(size: 24))
                .foregroundStyle(failures == 0 ? HealthLevel.pass.color : HealthLevel.fail.color)
            Text(failures == 0 ? "状态正常" : "\(failures) 项异常")
                .font(.system(size: 11, weight: .semibold))
            Text(warnings == 0 ? "无警告" : "\(warnings) 项注意")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.045)))
    }

    private var healthCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("健康检查")
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                Spacer()
                Text("\(health.filter { $0.level == .pass }.count)/\(health.count) 通过")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            ForEach(health.prefix(5)) { item in
                HStack(spacing: 10) {
                    Circle().fill(item.level.color).frame(width: 7, height: 7)
                    Text(item.title)
                        .font(.system(size: 12, weight: .medium))
                    Spacer()
                    Text(item.value)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .padding(.vertical, 2)
            }
        }
        .padding(18)
        .background(cardBackground)
    }

    private var quickActions: some View {
        HStack(spacing: 12) {
            action("重新检查", "arrow.clockwise", .blue) { model.refresh() }
            action("参数管理", "slider.horizontal.3", .purple) { model.selectedPage = .parameters }
            action("诊断信息", "doc.on.doc", .teal) { model.selectedPage = .diagnostics }
        }
    }

    private func action(_ title: String, _ symbol: String, _ color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: symbol)
                Text(title)
            }
            .font(.system(size: 12, weight: .semibold))
            .frame(maxWidth: .infinity)
            .frame(height: 36)
        }
        .buttonStyle(.plain)
        .foregroundStyle(color)
        .background(RoundedRectangle(cornerRadius: 10).fill(color.opacity(0.08)))
    }

    private func stat(_ title: String, _ value: String, _ symbol: String, _ color: Color) -> some View {
        HStack(spacing: 13) {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(color)
                .frame(width: 34, height: 34)
                .background(RoundedRectangle(cornerRadius: 9).fill(color.opacity(0.10)))
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .lineLimit(1)
            }
            Spacer()
        }
        .padding(14)
        .background(cardBackground)
    }

    private func badge(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .medium))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(color.opacity(0.10)))
            .foregroundStyle(color)
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(Color(nsColor: .controlBackgroundColor).opacity(0.72))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.primary.opacity(0.06), lineWidth: 1))
            .shadow(color: .black.opacity(0.035), radius: 10, y: 4)
    }
}

private struct HealthView: View {
    let items: [HealthItem]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            summary
            ForEach(items) { item in
                HStack(alignment: .top, spacing: 13) {
                    ZStack {
                        Circle().fill(item.level.color.opacity(0.12)).frame(width: 30, height: 30)
                        Image(systemName: icon(for: item.level))
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(item.level.color)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(item.title)
                                .font(.system(size: 13, weight: .semibold))
                            Spacer()
                            Text(item.level.title)
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(item.level.color)
                        }
                        Text(item.detail)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        if item.value != "—" {
                            Text(item.value)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.tertiary)
                                .lineLimit(2)
                        }
                    }
                }
                .padding(15)
                .background(RoundedRectangle(cornerRadius: 13).fill(Color(nsColor: .controlBackgroundColor).opacity(0.68)))
                .overlay(RoundedRectangle(cornerRadius: 13).stroke(Color.primary.opacity(0.055), lineWidth: 1))
            }
        }
    }

    private var summary: some View {
        HStack(spacing: 12) {
            ForEach([HealthLevel.pass, .warning, .fail], id: \.rawValue) { level in
                HStack(spacing: 7) {
                    Circle().fill(level.color).frame(width: 8, height: 8)
                    Text("\(level.title) \(items.filter { $0.level == level }.count)")
                        .font(.system(size: 11, weight: .medium))
                }
                .padding(.horizontal, 12)
                .frame(height: 30)
                .background(RoundedRectangle(cornerRadius: 9).fill(level.color.opacity(0.08)))
            }
            Spacer()
        }
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

private struct ParserView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("用户态解析")
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                    Text("解析 GLDriver 与 dyld shared cache，生成 pageOffset + siteInPage 的 OffsetProfile。")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    model.runParser()
                } label: {
                    Label(model.isParsing ? "解析中…" : "开始解析", systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
                .tint(Color(red: 0.24, green: 0.42, blue: 0.96))
                .disabled(model.isParsing)
            }

            HStack(spacing: 10) {
                parserBadge("GL", "doc.text")
                parserBadge("MTL", "square.stack.3d.up")
                parserBadge("VDA", "play.rectangle")
                parserBadge("GVA", "photo")
                Spacer()
                Text("一次性解析 · 结果缓存")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }

            if model.isParsing {
                HStack(spacing: 12) {
                    ProgressView().controlSize(.small)
                    Text("正在解析 Mach-O / 符号 / page offsets…")
                        .font(.system(size: 11, weight: .medium))
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 12).fill(Color.blue.opacity(0.06)))
            }

            if let profile = model.parsedProfile {
                HStack(spacing: 12) {
                    resultStat("pages", "\(profile.pageCount)")
                    resultStat("sites", "\(profile.siteCount)")
                    resultStat("build", profile.build)
                    Spacer()
                    if let output = model.parserOutput {
                        Label(output.lastPathComponent, systemImage: "checkmark.circle")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(HealthLevel.pass.color)
                    }
                    if model.profileInstalledPath != nil {
                        Label("已安装到系统", systemImage: "checkmark.seal")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(HealthLevel.pass.color)
                    } else {
                        Button {
                            model.installProfile()
                        } label: {
                            Label("安装到系统缓存", systemImage: "arrow.down.to.line")
                                .font(.system(size: 10, weight: .semibold))
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .tint(Color(red: 0.24, green: 0.42, blue: 0.96))
                        .disabled(model.isParsing)
                    }
                }

                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        Text("页面").font(.system(size: 10, weight: .bold)).foregroundStyle(.secondary)
                        Spacer()
                        Text("pageFileOffset").font(.system(size: 10, weight: .bold)).foregroundStyle(.secondary)
                        Spacer()
                        Text("sites").font(.system(size: 10, weight: .bold)).foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(Color.primary.opacity(0.035))

                    ForEach(profile.pages) { page in
                        HStack {
                            Text(page.driver)
                                .font(.system(size: 11, weight: .medium))
                            Spacer()
                            Text(String(format: "0x%llX", page.pageFileOffset))
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text("\(page.sites.count)")
                                .font(.system(size: 10, weight: .medium, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 14)
                        .frame(height: 30)
                        Divider().opacity(0.4)
                    }
                }
                .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .controlBackgroundColor).opacity(0.66)))
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("解析日志")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.tertiary)
                    .textCase(.uppercase)
                TextEditor(text: .constant(model.parserLog))
                    .font(.system(size: 11, design: .monospaced))
                    .padding(10)
                    .frame(height: 150)
                    .background(RoundedRectangle(cornerRadius: 11).fill(Color(nsColor: .textBackgroundColor).opacity(0.8)))
                    .overlay(RoundedRectangle(cornerRadius: 11).stroke(Color.primary.opacity(0.06), lineWidth: 1))
            }
        }
    }

    private func parserBadge(_ title: String, _ symbol: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: symbol).font(.system(size: 9, weight: .semibold))
            Text(title).font(.system(size: 10, weight: .semibold))
        }
        .padding(.horizontal, 9)
        .frame(height: 25)
        .background(Capsule().fill(Color.primary.opacity(0.05)))
        .foregroundStyle(.secondary)
    }

    private func resultStat(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.system(size: 9, weight: .semibold)).foregroundStyle(.tertiary)
            Text(value).font(.system(size: 14, weight: .bold, design: .rounded))
        }
        .padding(.horizontal, 12)
        .frame(height: 42)
        .background(RoundedRectangle(cornerRadius: 9).fill(Color.primary.opacity(0.045)))
    }
}

private struct ParametersView: View {
    @EnvironmentObject private var model: AppModel

    private var groups: [String] {
        Array(Set(BootFeature.catalog.map(\.group))).sorted()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("启动参数")
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                    Text("勾选功能后写入 NVRAM boot-args；重启生效。")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("保存并重启参数") {
                    model.saveBootArgs()
                }
                .buttonStyle(.borderedProminent)
                .tint(Color(red: 0.24, green: 0.42, blue: 0.96))
                .disabled(model.isRefreshing)
            }

            ForEach(groups, id: \.self) { group in
                VStack(alignment: .leading, spacing: 8) {
                    Text(group)
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.tertiary)
                        .textCase(.uppercase)
                        .tracking(1)
                    ForEach(BootFeature.catalog.filter { $0.group == group }) { feature in
                        HStack(spacing: 12) {
                            Image(systemName: feature.symbol)
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(Color(red: 0.24, green: 0.42, blue: 0.96))
                                .frame(width: 30, height: 30)
                                .background(RoundedRectangle(cornerRadius: 8).fill(Color.blue.opacity(0.08)))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(feature.title)
                                    .font(.system(size: 12, weight: .semibold))
                                Text(feature.detail)
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(feature.flag)
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundStyle(.tertiary)
                            Toggle("", isOn: Binding(
                                get: { model.isEnabled(feature) },
                                set: { model.setEnabled(feature, $0) }
                            ))
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .controlSize(.small)
                        }
                        .padding(.horizontal, 14)
                        .frame(height: 50)
                        .background(RoundedRectangle(cornerRadius: 11).fill(Color(nsColor: .controlBackgroundColor).opacity(0.68)))
                    }
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("当前 boot-args")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.tertiary)
                    .textCase(.uppercase)
                TextEditor(text: Binding(
                    get: { model.bootState.serialized },
                    set: { _ in }
                ))
                .font(.system(size: 11, design: .monospaced))
                .frame(height: 54)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 9).fill(Color.primary.opacity(0.04)))
                .disabled(true)
            }
        }
    }
}

private struct UpdaterView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("EFI kext")
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                    Text("显示当前 EFI 中的版本；更新接口已预留。")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    model.markUpdateInterface()
                } label: {
                    Label("选择更新包", systemImage: "shippingbox.and.arrow.backward")
                }
                .buttonStyle(.borderedProminent)
                .tint(Color(red: 0.24, green: 0.42, blue: 0.96))
            }

            ForEach(model.kexts) { kext in
                HStack(spacing: 14) {
                    Image(systemName: kext.symbol)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(Color(red: 0.24, green: 0.42, blue: 0.96))
                        .frame(width: 40, height: 40)
                        .background(RoundedRectangle(cornerRadius: 10).fill(Color.blue.opacity(0.08)))
                    VStack(alignment: .leading, spacing: 3) {
                        Text(kext.name)
                            .font(.system(size: 13, weight: .semibold))
                        Text(kext.path)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer()
                    Text(kext.version)
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(Color.primary.opacity(0.06)))
                }
                .padding(15)
                .background(RoundedRectangle(cornerRadius: 13).fill(Color(nsColor: .controlBackgroundColor).opacity(0.68)))
                .overlay(RoundedRectangle(cornerRadius: 13).stroke(Color.primary.opacity(0.055), lineWidth: 1))
            }

            VStack(alignment: .leading, spacing: 8) {
                Label("更新接口预留", systemImage: "hammer")
                    .font(.system(size: 12, weight: .semibold))
                Text("后续接入：下载/选择 NootedRed 发布包、校验签名、备份 EFI、替换 kext、记录版本。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 13).fill(Color.blue.opacity(0.055)))
        }
    }
}

private struct DiagnosticsView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("诊断信息")
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(model.diagnostics, forType: .string)
                    model.statusMessage = "诊断信息已复制"
                } label: {
                    Label("复制", systemImage: "doc.on.doc")
                }
                .buttonStyle(.bordered)
            }
            TextEditor(text: .constant(model.diagnostics))
                .font(.system(size: 11, design: .monospaced))
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 13).fill(Color(nsColor: .textBackgroundColor).opacity(0.78)))
                .overlay(RoundedRectangle(cornerRadius: 13).stroke(Color.primary.opacity(0.06), lineWidth: 1))
                .frame(minHeight: 420)
        }
    }
}

private struct UpdatePlaceholderSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                ZStack {
                    RoundedRectangle(cornerRadius: 12).fill(Color.blue.opacity(0.1))
                    Image(systemName: "shippingbox.and.arrow.backward")
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(.blue)
                }
                .frame(width: 52, height: 52)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Kext 更新")
                        .font(.system(size: 20, weight: .bold, design: .rounded))
                    Text("接口预留")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            Text("正式更新流程将包括：选择发布包、校验版本与签名、备份 EFI、替换 NootedRed 与 NootedRedUserPatch、校验 config.plist、提示重启。")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Label("不在此版本执行写入", systemImage: "lock.shield")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("关闭") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 520)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}
