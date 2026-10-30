// 生成 NootedRed Toolkit 的 App 图标（AppIcon.icns + 预览 PNG）。
//
// 用法（在 NootedRedTool 目录下）：
//   swiftc -parse-as-library -o /tmp/generate-app-icon Scripts/generate-app-icon.swift
//   /tmp/generate-app-icon
//
// 产物：Assets/AppIcon.icns、Assets/AppIcon-1024.png。

import AppKit

@main
struct GenerateAppIcon {
    /// macOS 图标网格：1024 画布内留出约 10% 边距，圆角按 Big Sur 视觉比例。
    private static let marginRatio: CGFloat = 0.098
    private static let cornerRatio: CGFloat = 0.2237

    private static let gradientStart = NSColor(srgbRed: 0.19, green: 0.42, blue: 0.97, alpha: 1)
    private static let gradientEnd = NSColor(srgbRed: 0.55, green: 0.32, blue: 0.95, alpha: 1)

    static func main() {
        let fileManager = FileManager.default
        let root = URL(fileURLWithPath: fileManager.currentDirectoryPath)
        let assets = root.appendingPathComponent("Assets", isDirectory: true)
        try? fileManager.createDirectory(at: assets, withIntermediateDirectories: true)

        let iconset = root.appendingPathComponent("Assets/AppIcon.iconset", isDirectory: true)
        try? fileManager.removeItem(at: iconset)
        do {
            try fileManager.createDirectory(at: iconset, withIntermediateDirectories: true)
        } catch {
            print("创建 iconset 失败：\(error.localizedDescription)")
            exit(1)
        }

        let variants: [(String, Int)] = [
            ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
            ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
            ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
            ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
            ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024)
        ]
        var failed = false
        for (name, pixels) in variants {
            guard let png = renderPNG(pixels: pixels) else {
                print("渲染 \(name) 失败")
                failed = true
                continue
            }
            do {
                try png.write(to: iconset.appendingPathComponent(name))
            } catch {
                print("写入 \(name) 失败：\(error.localizedDescription)")
                failed = true
            }
        }
        if failed { exit(1) }

        guard let preview = renderPNG(pixels: 1024) else {
            print("渲染 1024 预览图失败")
            exit(1)
        }
        let previewURL = assets.appendingPathComponent("AppIcon-1024.png")
        try? preview.write(to: previewURL)

        // 某些受限环境里子进程不能直接写工作区，先写临时目录再复制。
        let icnsURL = assets.appendingPathComponent("AppIcon.icns")
        let temporaryICNS = FileManager.default.temporaryDirectory
            .appendingPathComponent("nootedred-appicon-\(UUID().uuidString).icns")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
        process.arguments = ["-c", "icns", iconset.path, "-o", temporaryICNS.path]
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            print("iconutil 运行失败：\(error.localizedDescription)")
            exit(1)
        }
        guard process.terminationStatus == 0 else {
            print("iconutil 生成 icns 失败（exit \(process.terminationStatus)）")
            exit(1)
        }
        do {
            try? fileManager.removeItem(at: icnsURL)
            try fileManager.copyItem(at: temporaryICNS, to: icnsURL)
        } catch {
            print("复制 icns 失败：\(error.localizedDescription)")
            exit(1)
        }
        try? fileManager.removeItem(at: temporaryICNS)
        try? fileManager.removeItem(at: iconset)
        print("已生成：\(icnsURL.path)")
        print("已生成：\(previewURL.path)")
    }

    /// 按像素尺寸重新绘制（不是缩放 1024 图），保证小尺寸下字形清晰。
    private static func renderPNG(pixels: Int) -> Data? {
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                         pixelsWide: pixels, pixelsHigh: pixels,
                                         bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        let side = CGFloat(pixels)
        rep.size = NSSize(width: side, height: side)

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        defer { NSGraphicsContext.restoreGraphicsState() }

        NSColor.clear.set()
        NSBezierPath(rect: NSRect(x: 0, y: 0, width: side, height: side)).fill()

        let inset = side * marginRatio
        let body = NSRect(x: inset, y: inset, width: side - 2 * inset, height: side - 2 * inset)
        let radius = body.width * cornerRatio
        let bodyPath = NSBezierPath(roundedRect: body, xRadius: radius, yRadius: radius)

        bodyPath.addClip()
        let gradient = NSGradient(colors: [gradientStart, gradientEnd])
        gradient?.draw(in: body, angle: -45)

        // 顶部高光，让图标有轻微体积感。
        let highlight = NSGradient(colors: [NSColor.white.withAlphaComponent(0.22),
                                            NSColor.white.withAlphaComponent(0)])!
        highlight.draw(in: NSRect(x: body.minX, y: body.midY,
                                  width: body.width, height: body.height / 2), angle: -90)

        // 细内描边，避免在浅色背景上边缘发虚。
        bodyPath.lineWidth = max(1, side * 0.006)
        NSColor.white.withAlphaComponent(0.14).setStroke()
        bodyPath.stroke()

        drawDisplayGlyph(in: body, side: side)
        return rep.representation(using: .png, properties: [:])
    }

    /// 白色显示器字形，与应用内品牌图标一致。
    private static func drawDisplayGlyph(in body: NSRect, side: CGFloat) {
        let configuration = NSImage.SymbolConfiguration(pointSize: body.width * 0.6, weight: .semibold)
        guard let symbol = NSImage(systemSymbolName: "display", accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration) else { return }

        let maxSize = NSSize(width: body.width * 0.56, height: body.height * 0.46)
        let scale = min(maxSize.width / symbol.size.width, maxSize.height / symbol.size.height)
        let drawSize = NSSize(width: symbol.size.width * scale, height: symbol.size.height * scale)
        let drawRect = NSRect(x: body.midX - drawSize.width / 2,
                              y: body.midY - drawSize.height / 2,
                              width: drawSize.width, height: drawSize.height)

        let tinted = NSImage(size: symbol.size)
        tinted.lockFocus()
        NSColor.white.set()
        NSRect(origin: .zero, size: symbol.size).fill()
        symbol.draw(in: NSRect(origin: .zero, size: symbol.size),
                    from: .zero, operation: .destinationIn, fraction: 1)
        tinted.unlockFocus()

        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.20)
        shadow.shadowBlurRadius = side * 0.02
        shadow.shadowOffset = NSSize(width: 0, height: -side * 0.008)
        shadow.set()

        tinted.draw(in: drawRect)
    }
}
