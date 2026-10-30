import Foundation
import SwiftUI

// MARK: - 主题

/// 全局视觉常量：强调色渐变、卡片圆角与填充、统一的间距。
enum ToolkitTheme {
    static let accent = Color(red: 0.24, green: 0.42, blue: 0.96)
    static let accentStart = Color(red: 0.20, green: 0.42, blue: 0.98)
    static let accentEnd = Color(red: 0.55, green: 0.32, blue: 0.96)
    static let accentGradient = LinearGradient(
        colors: [accentStart, accentEnd],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
    static let accentGradientHorizontal = LinearGradient(
        colors: [accentStart, accentEnd],
        startPoint: .leading,
        endPoint: .trailing
    )

    static let cardFill = Color(nsColor: .controlBackgroundColor).opacity(0.72)
    static let cardStroke = Color.primary.opacity(0.06)
    static let subtleFill = Color.primary.opacity(0.05)
    static let divider = Color.primary.opacity(0.07)

    static let cardRadius: CGFloat = 16
    static let innerRadius: CGFloat = 10
    static let pageHorizontalPadding: CGFloat = 30
    static let pageSpacing: CGFloat = 18
}

// MARK: - 背景

/// 浅色渐变背景，延续旧版设计语言。
struct ToolkitBackgroundView: View {
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

// MARK: - 卡片

/// 统一的圆角卡片容器。
struct ToolkitCard<Content: View>: View {
    private let padding: CGFloat
    private let content: Content

    init(padding: CGFloat = 18, @ViewBuilder content: () -> Content) {
        self.padding = padding
        self.content = content()
    }

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: ToolkitTheme.cardRadius, style: .continuous)
                    .fill(ToolkitTheme.cardFill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: ToolkitTheme.cardRadius, style: .continuous)
                    .stroke(ToolkitTheme.cardStroke, lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.035), radius: 10, y: 4)
    }
}

/// 卡片内的浅色区块，用于嵌套信息（不要再套一层完整卡片）。
struct ToolkitInset<Content: View>: View {
    private let fill: Color
    private let content: Content

    init(fill: Color = ToolkitTheme.subtleFill, @ViewBuilder content: () -> Content) {
        self.fill = fill
        self.content = content()
    }

    var body: some View {
        content
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: ToolkitTheme.innerRadius, style: .continuous).fill(fill))
    }
}

// MARK: - 区块标题

struct ToolkitSectionTitle: View {
    let title: String
    var subtitle: String? = nil
    var symbol: String? = nil

    var body: some View {
        HStack(alignment: .center, spacing: 9) {
            if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(ToolkitTheme.accent)
                    .frame(width: 28, height: 28)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(ToolkitTheme.accent.opacity(0.10)))
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

// MARK: - 徽章 / 状态点

struct ToolkitBadge: View {
    let text: String
    var color: Color = ToolkitTheme.accent
    var symbol: String? = nil

    var body: some View {
        HStack(spacing: 4) {
            if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: 9, weight: .bold))
            }
            Text(text)
                .font(.system(size: 10, weight: .semibold))
                .lineLimit(1)
        }
        .foregroundStyle(color)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Capsule().fill(color.opacity(0.11)))
    }
}

struct ToolkitStatusDot: View {
    var color: Color
    var size: CGFloat = 8

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
    }
}

/// 把 HealthLevel 直接转成文字徽章。
struct ToolkitLevelBadge: View {
    let level: HealthLevel

    var body: some View {
        ToolkitBadge(text: level.title, color: level.color, symbol: level.symbol)
    }
}

// MARK: - 指标与信息行

struct ToolkitMetricTile: View {
    let title: String
    let value: String
    var symbol: String = "circle"
    var color: Color = ToolkitTheme.accent
    var footnote: String? = nil

    var body: some View {
        HStack(spacing: 11) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(color)
                .frame(width: 32, height: 32)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(color.opacity(0.10)))
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                if let footnote {
                    Text(footnote)
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: ToolkitTheme.innerRadius, style: .continuous).fill(ToolkitTheme.subtleFill))
    }
}

struct ToolkitInfoRow: View {
    let label: String
    let value: String
    var mono = false
    var valueColor: Color? = nil

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 88, alignment: .leading)
            Text(value)
                .font(.system(size: mono ? 11 : 12, weight: .medium,
                              design: mono ? .monospaced : .rounded))
                .foregroundStyle(valueColor ?? Color.primary.opacity(0.86))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
    }
}

// MARK: - 按钮样式

struct ToolkitPrimaryButtonStyle: ButtonStyle {
    var compact = false

    func makeBody(configuration: Configuration) -> some View {
        StyledBody(configuration: configuration, compact: compact)
    }

    private struct StyledBody: View {
        @Environment(\.isEnabled) private var isEnabled
        let configuration: ButtonStyleConfiguration
        let compact: Bool

        var body: some View {
            configuration.label
                .font(.system(size: compact ? 11 : 12, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, compact ? 10 : 14)
                .frame(height: compact ? 26 : 32)
                .background(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(ToolkitTheme.accentGradient)
                )
                .opacity(isEnabled ? (configuration.isPressed ? 0.82 : 1) : 0.42)
                .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
    }
}

struct ToolkitSecondaryButtonStyle: ButtonStyle {
    var compact = false
    var tint: Color = ToolkitTheme.accent

    func makeBody(configuration: Configuration) -> some View {
        StyledBody(configuration: configuration, compact: compact, tint: tint)
    }

    private struct StyledBody: View {
        @Environment(\.isEnabled) private var isEnabled
        let configuration: ButtonStyleConfiguration
        let compact: Bool
        let tint: Color

        var body: some View {
            configuration.label
                .font(.system(size: compact ? 11 : 12, weight: .semibold))
                .foregroundStyle(tint)
                .padding(.horizontal, compact ? 10 : 14)
                .frame(height: compact ? 26 : 32)
                .background(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(tint.opacity(0.09))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .stroke(tint.opacity(0.18), lineWidth: 1)
                )
                .opacity(isEnabled ? (configuration.isPressed ? 0.72 : 1) : 0.42)
                .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
    }
}

/// 顶栏与列表行里的小图标按钮。
struct ToolkitIconButtonStyle: ButtonStyle {
    var size: CGFloat = 30

    func makeBody(configuration: Configuration) -> some View {
        StyledBody(configuration: configuration, size: size)
    }

    private struct StyledBody: View {
        @Environment(\.isEnabled) private var isEnabled
        let configuration: ButtonStyleConfiguration
        let size: CGFloat

        var body: some View {
            configuration.label
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.primary.opacity(0.72))
                .frame(width: size, height: size)
                .background(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(Color.primary.opacity(configuration.isPressed ? 0.11 : 0.055))
                )
                .opacity(isEnabled ? 1 : 0.4)
                .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
    }
}

/// 自定义 Toggle 外观：系统 switch 在离屏渲染里不可用，这里用纯 SwiftUI 绘制。
struct ToolkitSwitchToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 8) {
            configuration.label
            Button {
                configuration.isOn.toggle()
            } label: {
                Capsule()
                    .fill(configuration.isOn ? ToolkitTheme.accent : Color.primary.opacity(0.18))
                    .frame(width: 36, height: 20)
                    .overlay(alignment: configuration.isOn ? .trailing : .leading) {
                        Circle()
                            .fill(Color.white)
                            .frame(width: 16, height: 16)
                            .padding(2)
                            .shadow(color: .black.opacity(0.12), radius: 1, y: 1)
                    }
            }
            .buttonStyle(.plain)
        }
    }
}

// MARK: - 加载指示

/// 离屏渲染不支持 ProgressView，用静态图标 + 旋转动画替代。
struct ToolkitSpinner: View {
    var size: CGFloat = 12
    var color: Color = ToolkitTheme.accent
    @State private var animating = false

    var body: some View {
        Image(systemName: "arrow.triangle.2.circlepath")
            .font(.system(size: size, weight: .semibold))
            .foregroundStyle(color)
            .rotationEffect(.degrees(animating ? 360 : 0))
            .animation(.linear(duration: 0.9).repeatForever(autoreverses: false), value: animating)
            .onAppear { animating = true }
    }
}

// MARK: - 搜索框

/// 搜索框。`--snapshot` 离屏渲染不支持 TextField，因此快照下渲染成静态外观。
struct ToolkitSearchField: View {
    @Binding var text: String
    var placeholder: String = "搜索"

    var body: some View {
        Group {
            if SnapshotSupport.isRequested {
                HStack(spacing: 6) {
                    searchIcon
                    Text(text.isEmpty ? placeholder : text)
                        .font(.system(size: 12))
                        .foregroundStyle(text.isEmpty ? Color.secondary : Color.primary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
            } else {
                HStack(spacing: 6) {
                    searchIcon
                    TextField(placeholder, text: $text)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                    if !text.isEmpty {
                        Button {
                            text = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 11))
                                .foregroundStyle(.tertiary)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(.horizontal, 10)
        .frame(width: 180, height: 30)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.primary.opacity(0.055)))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(Color.primary.opacity(0.05), lineWidth: 1))
    }

    private var searchIcon: some View {
        Image(systemName: "magnifyingglass")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
    }
}

// MARK: - 说明卡

/// 每个页面顶部的统一说明卡：一句话介绍 + 前置条件 + 操作步骤 +（可选）风险提示。
struct ToolkitPageIntro: View {
    let title: String
    let summary: String
    var symbol: String = "info.circle"
    var prerequisites: [String] = []
    var steps: [String] = []
    var caution: String? = nil

    var body: some View {
        ToolkitCard {
            HStack(alignment: .top, spacing: 16) {
                ZStack {
                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                        .fill(ToolkitTheme.accentGradient)
                    Image(systemName: symbol)
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(.white)
                }
                .frame(width: 46, height: 46)

                VStack(alignment: .leading, spacing: 10) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(title)
                            .font(.system(size: 16, weight: .bold, design: .rounded))
                        Text(summary)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .lineSpacing(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    if !prerequisites.isEmpty || !steps.isEmpty {
                        HStack(alignment: .top, spacing: 30) {
                            if !prerequisites.isEmpty {
                                introBlock(title: "前置条件", symbol: "checklist",
                                           lines: prerequisites, numbered: false)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            if !steps.isEmpty {
                                introBlock(title: "操作步骤", symbol: "list.number",
                                           lines: steps, numbered: true)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }

                    if let caution {
                        HStack(alignment: .top, spacing: 7) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(HealthLevel.warning.color)
                            Text(caution)
                                .font(.system(size: 11))
                                .foregroundStyle(Color.primary.opacity(0.72))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(9)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(HealthLevel.warning.color.opacity(0.09)))
                    }
                }
            }
        }
    }

    private func introBlock(title: String, symbol: String, lines: [String], numbered: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label {
                Text(title)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.tertiary)
                    .textCase(.uppercase)
                    .tracking(0.6)
            } icon: {
                Image(systemName: symbol)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                HStack(alignment: .top, spacing: 6) {
                    if numbered {
                        Text("\(index + 1).")
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                            .foregroundStyle(ToolkitTheme.accent)
                            .frame(width: 14, alignment: .trailing)
                    } else {
                        Circle()
                            .fill(Color.primary.opacity(0.25))
                            .frame(width: 4, height: 4)
                            .padding(.top, 5)
                    }
                    Text(line)
                        .font(.system(size: 11))
                        .foregroundStyle(Color.primary.opacity(0.72))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

// MARK: - 空状态

struct ToolkitEmptyState: View {
    let symbol: String
    let title: String
    let message: String
    var actionTitle: String? = nil
    var actionSymbol: String = "arrow.clockwise"
    var action: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(ToolkitTheme.accent.opacity(0.09))
                    .frame(width: 48, height: 48)
                Image(systemName: symbol)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(ToolkitTheme.accent.opacity(0.85))
            }
            Text(title)
                .font(.system(size: 14, weight: .bold, design: .rounded))
            Text(message)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 520)
            if let actionTitle, let action {
                Button(action: action) {
                    Label(actionTitle, systemImage: actionSymbol)
                }
                .buttonStyle(ToolkitSecondaryButtonStyle())
                .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 22)
    }
}

// MARK: - 过滤 chip

struct ToolkitFilterChip: View {
    let title: String
    let color: Color
    let count: Int?
    let isSelected: Bool
    let action: () -> Void

    init(title: String, color: Color, count: Int? = nil, isSelected: Bool, action: @escaping () -> Void) {
        self.title = title
        self.color = color
        self.count = count
        self.isSelected = isSelected
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Circle()
                    .fill(color)
                    .frame(width: 7, height: 7)
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                if let count {
                    Text("\(count)")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundStyle(isSelected ? color : Color.secondary)
                }
            }
            .foregroundStyle(isSelected ? color : Color.primary.opacity(0.68))
            .padding(.horizontal, 11)
            .frame(height: 28)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isSelected ? color.opacity(0.14) : Color.primary.opacity(0.045)))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(isSelected ? color.opacity(0.45) : Color.clear, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 日志控制台

/// 只读日志框：应用内使用 TextEditor，`--snapshot` 离屏渲染时退回纯文本，保证截图可见。
struct ToolkitConsole: View {
    let text: String
    var height: CGFloat = 150

    var body: some View {
        Group {
            if SnapshotSupport.isRequested {
                VStack(alignment: .leading, spacing: 0) {
                    Text(text)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Color.primary.opacity(0.80))
                        .lineSpacing(2)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
                .padding(10)
                .frame(height: height, alignment: .topLeading)
                .clipped()
            } else {
                TextEditor(text: .constant(text))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Color.primary.opacity(0.80))
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .frame(height: height)
            }
        }
        .background(RoundedRectangle(cornerRadius: ToolkitTheme.innerRadius, style: .continuous)
            .fill(Color(nsColor: .textBackgroundColor).opacity(0.75)))
        .overlay(RoundedRectangle(cornerRadius: ToolkitTheme.innerRadius, style: .continuous)
            .stroke(ToolkitTheme.cardStroke, lineWidth: 1))
    }
}

// MARK: - 提示条

struct ToolkitCallout: View {
    let text: String
    var symbol: String = "info.circle.fill"
    var color: Color = ToolkitTheme.accent

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(color)
            Text(text)
                .font(.system(size: 11))
                .foregroundStyle(Color.primary.opacity(0.72))
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(color.opacity(0.075)))
    }
}

// MARK: - 格式化

enum ToolkitFormat {
    static func time(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }

    static func dateTime(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .shortened)
    }

    static func localDateTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: date)
    }

    /// 把契约里的 ISO8601（UTC）时间戳格式化成界面上更自然的本地时间。
    static func isoLocal(_ raw: String) -> String {
        guard !raw.isEmpty else { return "—" }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        if let date = formatter.date(from: raw) {
            return localDateTime(date)
        }
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: raw) {
            return localDateTime(date)
        }
        return raw
    }

    static func hex(_ value: UInt64) -> String {
        String(format: "0x%llX", value)
    }
}
