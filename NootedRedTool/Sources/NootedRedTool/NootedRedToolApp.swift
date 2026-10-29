import AppKit
import SwiftUI

/// 处理命令行模式：`--efi-probe` 只读探测 EFI，`--snapshot` 渲染各页面截图。
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        let arguments = CommandLine.arguments
        if ProfileCLI.isRequested(arguments) {
            // Headless analyzer modes: generate/validate an NRPT profile and exit
            // before any application UI is created.
            exit(ProfileCLI.run(arguments: arguments))
        }
        if arguments.contains("--efi-probe") {
            Task { @MainActor in
                let report = await EFIService.cliProbeReport()
                FileHandle.standardOutput.write(Data((report + "\n").utf8))
                exit(0)
            }
        } else if arguments.contains("--snapshot") {
            Task { @MainActor in
                await SnapshotSupport.run()
                exit(0)
            }
        } else if arguments.contains("--self-test") {
            Task { @MainActor in
                let report = await SelfTest.cliReport()
                FileHandle.standardOutput.write(Data((report + "\n").utf8))
                exit(report.contains("SELF-TEST: PASS") ? 0 : 1)
            }
        } else if arguments.contains("--profile-inject-binary") {
            Task.detached {
                do {
                    let index = arguments.firstIndex(of: "--profile-inject-binary")!
                    guard index + 2 < arguments.count else {
                        throw NSError(domain: "NootedRedTool", code: 7,
                                      userInfo: [NSLocalizedDescriptionKey: "需要 Info.plist 和 NRP2 路径"])
                    }
                    let plistPath = arguments[index + 1]
                    let binaryPath = arguments[index + 2]
                    let binary = try Data(contentsOf: URL(fileURLWithPath: binaryPath))
                    guard binary.count >= 28, binary.prefix(4) == Data("NRP3".utf8) else {
                        throw NSError(domain: "NootedRedTool", code: 8,
                                      userInfo: [NSLocalizedDescriptionKey: "不是 NRP3 profile"])
                    }
                    let build = String(decoding: binary[12..<28].prefix { $0 != 0 }, as: UTF8.self)
                    var format = PropertyListSerialization.PropertyListFormat.xml
                    let original = try Data(contentsOf: URL(fileURLWithPath: plistPath))
                    guard var root = try PropertyListSerialization.propertyList(
                            from: original, options: [], format: &format) as? [String: Any],
                          var personalities = root["IOKitPersonalities"] as? [String: Any],
                          var personality = personalities["org.ChefKiss.NootedRedUserPatch"] as? [String: Any]
                    else {
                        throw NSError(domain: "NootedRedTool", code: 9,
                                      userInfo: [NSLocalizedDescriptionKey: "Info.plist personality 缺失"])
                    }
                    personality["NRedOffsetProfile"] = binary
                    personality["NRedSystemBuild"] = build
                    personalities["org.ChefKiss.NootedRedUserPatch"] = personality
                    root["IOKitPersonalities"] = personalities
                    let updated = try PropertyListSerialization.data(fromPropertyList: root, format: .xml, options: 0)
                    try updated.write(to: URL(fileURLWithPath: plistPath), options: .atomic)
                    FileHandle.standardOutput.write(Data(("injected \(binary.count) bytes, build \(build)\n").utf8))
                    exit(0)
                } catch {
                    FileHandle.standardError.write(Data(("profile inject failed: \(error.localizedDescription)\n").utf8))
                    exit(1)
                }
            }
        } else if arguments.contains("--profile-write-plist") {
            Task.detached {
                do {
                    let index = arguments.firstIndex(of: "--profile-write-plist")!
                    guard index + 1 < arguments.count else {
                        throw NSError(domain: "NootedRedTool", code: 6,
                                      userInfo: [NSLocalizedDescriptionKey: "缺少 Info.plist 路径"])
                    }
                    let build = await OffsetProfileGenerator.currentBuild()
                    let profile = try await OffsetProfileGenerator.generate(build: build)
                    let path = arguments[index + 1]
                    let original = try Data(contentsOf: URL(fileURLWithPath: path))
                    let updated = try OffsetProfileGenerator.updatedInfoPlistData(original, profile: profile)
                    try updated.write(to: URL(fileURLWithPath: path), options: .atomic)
                    FileHandle.standardOutput.write(Data(("updated \(path)\n").utf8))
                    exit(0)
                } catch {
                    FileHandle.standardError.write(Data(("profile plist update failed: \(error.localizedDescription)\n").utf8))
                    exit(1)
                }
            }
        } else if arguments.contains("--profile-binary") {
            Task.detached {
                do {
                    let build = await OffsetProfileGenerator.currentBuild()
                    let profile = try await OffsetProfileGenerator.generate(build: build)
                    let binary = OffsetProfileGenerator.binaryData(profile)
                    guard !binary.isEmpty else { throw NSError(domain: "NootedRedTool", code: 5,
                                                               userInfo: [NSLocalizedDescriptionKey: "profile 编码失败"]) }
                    let index = arguments.firstIndex(of: "--profile-binary")!
                    let path = index + 1 < arguments.count ? arguments[index + 1] : "/tmp/nred-profile.bin"
                    try binary.write(to: URL(fileURLWithPath: path), options: .atomic)
                    FileHandle.standardOutput.write(Data(("wrote \(path) (\(binary.count) bytes)\n").utf8))
                    exit(0)
                } catch {
                    FileHandle.standardError.write(Data(("profile binary failed: \(error.localizedDescription)\n").utf8))
                    exit(1)
                }
            }
        } else if arguments.contains("--profile-save") {
            Task.detached {
                do {
                    let build = await OffsetProfileGenerator.currentBuild()
                    let profile = try await OffsetProfileGenerator.generate(build: build)
                    let url = try OffsetProfileGenerator.save(profile)
                    FileHandle.standardOutput.write(Data(("saved \(url.path)\n").utf8))
                    exit(0)
                } catch {
                    FileHandle.standardError.write(Data(("profile save failed: \(error.localizedDescription)\n").utf8))
                    exit(1)
                }
            }
        } else if arguments.contains("--profile-test") {
            Task.detached {
                do {
                    let build = await OffsetProfileGenerator.currentBuild()
                    let profile = try await OffsetProfileGenerator.generate(build: build)
                    var lines: [String] = ["build=\(profile.build) pages=\(profile.pages.count) sites=\(profile.siteCount)"]
                    for page in profile.pages {
                        lines.append("\(page.driver) page=\(String(format: "0x%llX", page.pageFileOffset)) sites=\(page.sites.count)")
                    }
                    FileHandle.standardOutput.write(Data((lines.joined(separator: "\n") + "\n").utf8))
                    exit(0)
                } catch {
                    FileHandle.standardError.write(Data(("profile failed: \(error.localizedDescription)\n").utf8))
                    exit(1)
                }
            }
        } else if arguments.contains("--discover-dump") {
            Task.detached {
                do {
                    try SiteDiscovery.debugDump()
                    exit(0)
                } catch {
                    FileHandle.standardError.write(Data(("dump failed: \(error.localizedDescription)\n").utf8))
                    exit(1)
                }
            }
        } else if arguments.contains("--discover-test") {
            Task.detached {
                do {
                    let specs = try SiteDiscovery.discover()
                    var lines: [String] = []
                    for spec in specs {
                        lines.append("\(spec.driver) page=\(String(format: "0x%llX", spec.pageOffset)) sites=\(spec.sites.count)")
                        for site in spec.sites {
                            lines.append("  site=\(String(format: "0x%X", site.offset)) find=\(site.find) replace=\(site.replace)")
                        }
                    }
                    FileHandle.standardOutput.write(Data((lines.joined(separator: "\n") + "\n").utf8))
                    exit(0)
                } catch {
                    FileHandle.standardError.write(Data(("discover failed: \(error.localizedDescription)\n").utf8))
                    exit(1)
                }
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

@main
struct NootedRedToolApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            ToolkitRootView()
                .environmentObject(model)
                .frame(minWidth: 1120, minHeight: 720)
        }
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unified(showsTitle: false))
        .defaultSize(width: 1280, height: 840)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("重新检查") { model.refresh() }
                    .keyboardShortcut("r", modifiers: .command)
                Button("挂载 / 管理 EFI 分区") { model.openPage(.efi) }
                    .keyboardShortcut("e", modifiers: .command)
            }
            CommandGroup(after: .sidebar) {
                ForEach(AppPage.allCases) { page in
                    Button(page.title) { model.openPage(page) }
                        .keyboardShortcut(page.shortcut, modifiers: .command)
                }
            }
            CommandGroup(after: .pasteboard) {
                Button("复制诊断信息") { model.copyDiagnostics() }
                    .keyboardShortcut("c", modifiers: [.command, .shift])
            }
        }
    }
}
