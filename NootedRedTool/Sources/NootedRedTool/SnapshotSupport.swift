import AppKit
import SwiftUI

/// 把每个页面离屏渲染成 PNG，用于在无截图权限的环境里检查布局与文案。
/// 用法：`NootedRedTool --snapshot /path/to/output`
@MainActor
enum SnapshotSupport {
    static var isRequested: Bool {
        CommandLine.arguments.contains("--snapshot")
    }

    static var outputDirectory: URL {
        let arguments = CommandLine.arguments
        if let index = arguments.firstIndex(of: "--snapshot"), index + 1 < arguments.count,
           !arguments[index + 1].hasPrefix("-") {
            return URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
        }
        return FileManager.default.temporaryDirectory
            .appendingPathComponent("nootedred-snapshots", isDirectory: true)
    }

    static func run() async {
        let directory = outputDirectory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let model = AppModel()
        _ = await model.waitUntilReady()

        for page in AppPage.allCases {
            model.selectedPage = page
            model.searchText = ""
            try? await Task.sleep(nanoseconds: 400_000_000)
            render(model: model, page: page, directory: directory)
        }
        print("SNAPSHOTS: \(directory.path)")
    }

    private static func render(model: AppModel, page: AppPage, directory: URL) {
        let content = ToolkitRootView()
            .environmentObject(model)
            .frame(width: 1280, height: 840)
        let renderer = ImageRenderer(content: content)
        renderer.scale = 2
        guard let image = renderer.nsImage,
              let tiff = image.tiffRepresentation,
              let representation = NSBitmapImageRep(data: tiff),
              let png = representation.representation(using: .png, properties: [:]) else {
            print("SNAPSHOT FAILED: \(page.rawValue)")
            return
        }
        let url = directory.appendingPathComponent("\(page.rawValue).png")
        do {
            try png.write(to: url)
            print("SNAPSHOT: \(url.path)")
        } catch {
            print("SNAPSHOT FAILED: \(page.rawValue) — \(error.localizedDescription)")
        }
    }
}
