import Foundation

/// EFI 分区的发现、挂载与卸载。
///
/// 探测基于 `diskutil` 的 plist 输出，不解析本地化文本；挂载/卸载通过
/// `CommandRunner.runAsAdmin` 提权执行，操作后重新探测挂载状态来判定成败。
/// 所有提权命令只接受仅含字母与数字的设备标识，避免命令注入。
enum EFIService {
    // MARK: - 常量

    private static let diskutilPath = "/usr/sbin/diskutil"
    private static let commandTimeout: TimeInterval = 20
    private static let verificationAttempts = 10
    private static let verificationInterval: UInt64 = 200_000_000
    private static let openCoreConfigRelativePath = "EFI/OC/config.plist"
    private static let cloverConfigRelativePath = "EFI/CLOVER/config.plist"
    private static let appleNVRAMGUID = "7C436110-AB2A-4BBB-A880-FE41995C9F82"
    private static let allowedDeviceIdentifierCharacters = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789"
    )

    // MARK: - 只读探测

    static func discover() async -> EFIDiscovery {
        var partitions = await scanEFIPartitions()
        if !partitions.contains(where: \.isMounted) {
            // 没有可直接识别的已挂载 ESP 时，扫描非常规挂载点上的 OpenCore 卷。
            let knownIdentifiers = Set(partitions.map(\.deviceIdentifier))
            let knownIDs = Set(partitions.map(\.id))
            let fallback = await fallbackMountedPartitions().filter {
                !knownIdentifiers.contains($0.deviceIdentifier) && !knownIDs.contains($0.id)
            }
            partitions.append(contentsOf: fallback)
        }

        var discovery = EFIDiscovery.empty
        discovery.partitions = sortPartitions(partitions)
        discovery.mounted = preferredMountedEFI(in: discovery.partitions)
        discovery.scannedAt = Date()
        return discovery
    }

    /// 从 `diskutil list -plist` 收集所有 `Content == "EFI"` 的分区，并并发读取详情。
    private static func scanEFIPartitions() async -> [EFIPartition] {
        let candidates = await partitionCandidates()
        guard !candidates.isEmpty else { return [] }

        var partitions = [EFIPartition?](repeating: nil, count: candidates.count)
        await withTaskGroup(of: (Int, EFIPartition?).self) { group in
            for (index, candidate) in candidates.enumerated() {
                group.addTask {
                    (index, await EFIService.loadPartition(for: candidate))
                }
            }
            for await (index, partition) in group {
                partitions[index] = partition
            }
        }
        return partitions.compactMap { $0 }
    }

    private static func partitionCandidates() async -> [PartitionCandidate] {
        let result = await runDiskutil(["list", "-plist"])
        guard result.succeeded, let root = plistDictionary(from: result.output) else { return [] }
        let disks = root["AllDisksAndPartitions"] as? [[String: Any]] ?? []

        var candidates: [PartitionCandidate] = []
        var seen = Set<String>()
        for disk in disks {
            let entries = disk["Partitions"] as? [[String: Any]] ?? []
            for entry in entries {
                guard let content = trimmedString(entry["Content"]),
                      content.caseInsensitiveCompare("EFI") == .orderedSame,
                      let identifier = trimmedString(entry["DeviceIdentifier"]),
                      isValidDeviceIdentifier(identifier),
                      seen.insert(identifier.lowercased()).inserted else { continue }
                candidates.append(PartitionCandidate(
                    deviceIdentifier: identifier,
                    volumeName: trimmedString(entry["VolumeName"]) ?? "",
                    sizeBytes: uint64Value(entry["Size"]) ?? 0
                ))
            }
        }
        return candidates.sorted {
            $0.deviceIdentifier.compare($1.deviceIdentifier, options: [.numeric, .caseInsensitive])
                == .orderedAscending
        }
    }

    private static func loadPartition(for candidate: PartitionCandidate) async -> EFIPartition {
        let info = await diskutilInfo(for: candidate.deviceIdentifier)
        return assemblePartition(candidate: candidate, info: info)
    }

    private static func assemblePartition(candidate: PartitionCandidate, info: [String: Any]?) -> EFIPartition {
        let deviceNodeIdentifier = trimmedString(info?["DeviceNode"]).map {
            URL(fileURLWithPath: $0).lastPathComponent
        }
        let infoIdentifier = trimmedString(info?["DeviceIdentifier"]).flatMap {
            isValidDeviceIdentifier($0) ? $0 : nil
        }
        let nodeIdentifier = deviceNodeIdentifier.flatMap {
            isValidDeviceIdentifier($0) ? $0 : nil
        }
        let identifier = firstNonEmpty(infoIdentifier, nodeIdentifier, candidate.deviceIdentifier)
            ?? candidate.deviceIdentifier

        return EFIPartition(
            id: identifier,
            deviceIdentifier: identifier,
            volumeName: firstNonEmpty(trimmedString(info?["VolumeName"]), candidate.volumeName) ?? "",
            sizeBytes: uint64Value(info?["Size"])
                ?? uint64Value(info?["TotalSize"])
                ?? uint64Value(info?["IOKitSize"])
                ?? candidate.sizeBytes,
            isInternal: boolValue(info?["Internal"]) ?? false,
            busProtocol: trimmedString(info?["BusProtocol"]),
            mountPoint: trimmedString(info?["MountPoint"]),
            filesystem: firstNonEmpty(trimmedString(info?["FilesystemType"]),
                                      trimmedString(info?["FilesystemName"]))
        )
    }

    /// 没有任何可识别的 EFI 分区时，扫描已挂载卷中的 OpenCore 配置作为兜底。
    private static func fallbackMountedPartitions() async -> [EFIPartition] {
        let volumes = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: [.volumeNameKey, .volumeIsInternalKey, .volumeTotalCapacityKey],
            options: []
        ) ?? []

        var partitions: [EFIPartition] = []
        var seenConfigPaths = Set<String>()
        var seenIDs = Set<String>()
        for volumeURL in volumes {
            let configPath = volumeURL.appendingPathComponent(openCoreConfigRelativePath)
                .standardizedFileURL.path
            guard FileManager.default.fileExists(atPath: configPath),
                  seenConfigPaths.insert(configPath).inserted else { continue }
            guard var partition = await fallbackPartition(at: volumeURL) else { continue }
            if !seenIDs.insert(partition.id).inserted {
                // 同名卷（例如两块盘都叫 EFI）时用挂载点区分。
                partition = partition.withID("volume:\(volumeURL.path)")
                guard seenIDs.insert(partition.id).inserted else { continue }
            }
            partitions.append(partition)
        }
        return partitions
    }

    private static func fallbackPartition(at rootURL: URL) async -> EFIPartition? {
        let configURL = rootURL.appendingPathComponent(openCoreConfigRelativePath)
        guard FileManager.default.fileExists(atPath: configURL.path) else { return nil }

        let info = await diskutilInfo(for: rootURL.path)
        let resourceValues = try? rootURL.resourceValues(forKeys: [
            .volumeNameKey, .volumeIsInternalKey, .volumeTotalCapacityKey
        ])

        let volumeName = firstNonEmpty(
            trimmedString(info?["VolumeName"]),
            resourceValues?.volumeName,
            rootURL.lastPathComponent
        ) ?? rootURL.lastPathComponent
        let infoIdentifier = trimmedString(info?["DeviceIdentifier"]).flatMap {
            isValidDeviceIdentifier($0) ? $0 : nil
        }
        let capacity = resourceValues?.volumeTotalCapacity.map { UInt64($0) }

        return EFIPartition(
            id: "volume:\(volumeName)",
            deviceIdentifier: infoIdentifier ?? syntheticDeviceIdentifier(for: rootURL.path),
            volumeName: volumeName,
            sizeBytes: uint64Value(info?["Size"]) ?? capacity ?? 0,
            isInternal: boolValue(info?["Internal"]) ?? resourceValues?.volumeIsInternal ?? false,
            busProtocol: trimmedString(info?["BusProtocol"]),
            mountPoint: rootURL.path,
            filesystem: firstNonEmpty(trimmedString(info?["FilesystemType"]),
                                      trimmedString(info?["FilesystemName"]))
        )
    }

    private static func sortPartitions(_ partitions: [EFIPartition]) -> [EFIPartition] {
        partitions.sorted {
            let comparison = $0.deviceIdentifier.compare($1.deviceIdentifier,
                                                         options: [.numeric, .caseInsensitive])
            if comparison == .orderedSame {
                return $0.id.compare($1.id, options: [.numeric, .caseInsensitive]) == .orderedAscending
            }
            return comparison == .orderedAscending
        }
    }

    /// 优先选择带 OpenCore 配置的已挂载分区，其次取第一个已挂载的 EFI 分区。
    private static func preferredMountedEFI(in partitions: [EFIPartition]) -> MountedEFI? {
        let mounted = partitions.filter(\.isMounted)
        guard !mounted.isEmpty else { return nil }
        let preferred = mounted.first { partition in
            guard let root = partition.mountURL else { return false }
            return hasOpenCoreConfig(at: root)
        } ?? mounted[0]
        guard let root = preferred.mountURL else { return nil }
        return MountedEFI(partition: preferred, rootURL: root)
    }

    private static func hasOpenCoreConfig(at rootURL: URL) -> Bool {
        FileManager.default.fileExists(atPath: rootURL.appendingPathComponent(openCoreConfigRelativePath).path)
    }

    private static func isMountedVolume(atPath path: String) -> Bool {
        let target = URL(fileURLWithPath: path).standardizedFileURL.path
        let volumes = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: nil,
            options: []
        ) ?? []
        return volumes.contains { $0.standardizedFileURL.path == target }
    }

    // MARK: - OpenCore

    static func openCoreInfo(atRoot root: URL) -> OpenCoreInfo? {
        let openCoreConfigURL = root.appendingPathComponent(openCoreConfigRelativePath)
        if let info = loadOpenCoreInfo(at: openCoreConfigURL, efiRoot: root) {
            return info
        }

        let cloverConfigURL = root.appendingPathComponent(cloverConfigRelativePath)
        guard FileManager.default.fileExists(atPath: cloverConfigURL.path) else { return nil }
        let attributes = fileAttributes(at: cloverConfigURL)
        return OpenCoreInfo(
            efiRoot: root,
            bootloader: .clover,
            configPath: cloverConfigURL.path,
            configModified: attributes.modified,
            configSize: attributes.size,
            productName: nil,
            configBootArgs: nil,
            kextEntries: [],
            kextFiles: []
        )
    }

    private static func loadOpenCoreInfo(at configURL: URL, efiRoot: URL) -> OpenCoreInfo? {
        guard let data = try? Data(contentsOf: configURL),
              let config = plistDictionary(from: data) else { return nil }

        let generic = (config["PlatformInfo"] as? [String: Any])?["Generic"] as? [String: Any]
        let kernelAdd = (config["Kernel"] as? [String: Any])?["Add"] as? [[String: Any]] ?? []
        let kextEntries = kernelAdd.compactMap { entry -> OpenCoreKextEntry? in
            guard let bundlePath = trimmedString(entry["BundlePath"]) else { return nil }
            return OpenCoreKextEntry(
                bundlePath: bundlePath,
                enabled: boolValue(entry["Enabled"]) ?? false,
                comment: trimmedString(entry["Comment"])
            )
        }
        let attributes = fileAttributes(at: configURL)

        return OpenCoreInfo(
            efiRoot: efiRoot,
            bootloader: .openCore,
            configPath: configURL.path,
            configModified: attributes.modified,
            configSize: attributes.size,
            productName: trimmedString(generic?["SystemProductName"]),
            configBootArgs: configBootArguments(from: config),
            kextEntries: kextEntries,
            kextFiles: kextFileNames(at: efiRoot)
        )
    }

    /// 读取 `NVRAM > Add` 中的 `boot-args`；兼容直接放置与按 NVRAM GUID 分组两种布局。
    private static func configBootArguments(from config: [String: Any]) -> String? {
        guard let nvram = config["NVRAM"] as? [String: Any],
              let add = nvram["Add"] as? [String: Any] else { return nil }
        if let direct = bootArguments(in: add) { return direct }
        if let appleVariables = add[appleNVRAMGUID] as? [String: Any],
           let value = bootArguments(in: appleVariables) {
            return value
        }
        for key in add.keys.sorted() where key.caseInsensitiveCompare(appleNVRAMGUID) != .orderedSame {
            if let variables = add[key] as? [String: Any], let value = bootArguments(in: variables) {
                return value
            }
        }
        return nil
    }

    private static func bootArguments(in variables: [String: Any]) -> String? {
        guard let raw = variables["boot-args"] else { return nil }
        return trimmedString(raw)
    }

    private static func kextFileNames(at efiRoot: URL) -> [String] {
        let kextsURL = efiRoot.appendingPathComponent("EFI/OC/Kexts")
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: kextsURL.path)) ?? []
        return entries
            .filter { $0.lowercased().hasSuffix(".kext") }
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    private static func fileAttributes(at url: URL) -> (modified: Date?, size: UInt64) {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else {
            return (nil, 0)
        }
        return (attributes[.modificationDate] as? Date,
                (attributes[.size] as? NSNumber)?.uint64Value ?? 0)
    }

    // MARK: - 挂载 / 卸载

    static func mount(_ partition: EFIPartition) async -> EFIOperationResult {
        let device = partition.deviceIdentifier
        guard isValidDeviceIdentifier(device) else {
            return .failure("无法挂载：\(EFIServiceError.unsafeDeviceIdentifier(device).localizedDescription)。"
                            + "请刷新 EFI 分区列表后重试。")
        }
        if partition.isMounted {
            return .ok("\(device) 已经挂载，无需重复操作。",
                       detail: partition.mountPoint.map { "挂载点：\($0)" })
        }

        let command = mountShellCommand(for: partition)
        let result = await CommandRunner.runAsAdmin(command)
        if CommandRunner.isUserCancellation(result) {
            return .failure("授权被取消，\(device) 未挂载。请重试并在系统弹窗中允许授权。")
        }
        if let mounted = await waitForMountState(of: partition, expectedMounted: true) {
            return .ok("已挂载 \(device)。", detail: mounted.mountPoint.map { "挂载点：\($0)" })
        }

        let hint = "请确认磁盘已连接且系统授权已完成；如仍失败，可在终端执行“sudo \(command)”查看具体原因。"
        if result.succeeded {
            return .failure("挂载命令已执行，但 \(device) 仍未显示为已挂载。\(hint)",
                            detail: result.output.isEmpty ? nil : result.output)
        }
        return .failure("挂载 \(device) 失败。\(hint)",
                        detail: result.output.isEmpty ? nil : result.output)
    }

    static func unmount(_ partition: EFIPartition, force: Bool = false) async -> EFIOperationResult {
        let device = partition.deviceIdentifier
        guard isValidDeviceIdentifier(device) else {
            return .failure("无法卸载：\(EFIServiceError.unsafeDeviceIdentifier(device).localizedDescription)。"
                            + "请刷新 EFI 分区列表后重试。")
        }
        if !partition.isMounted {
            return .ok("\(device) 当前未挂载，无需卸载。")
        }

        let command = unmountShellCommand(for: partition, force: force)
        let result = await CommandRunner.runAsAdmin(command)
        if CommandRunner.isUserCancellation(result) {
            return .failure("授权被取消，\(device) 未卸载。请重试并在系统弹窗中允许授权。")
        }
        if await waitForMountState(of: partition, expectedMounted: false) != nil {
            return .ok("已卸载 \(device)。")
        }

        let hint = "可能有程序正在使用该 EFI 分区，请关闭访达窗口或占用它的终端后重试"
            + (force ? "。" : "，或使用强制卸载。")
        if result.succeeded {
            return .failure("卸载命令已执行，但 \(device) 仍显示为已挂载。\(hint)",
                            detail: result.output.isEmpty ? nil : result.output)
        }
        return .failure("卸载 \(device) 失败。\(hint)",
                        detail: result.output.isEmpty ? nil : result.output)
    }

    /// 轮询重新探测，直到目标分区达到期望的挂载状态；超时返回 nil。
    private static func waitForMountState(of partition: EFIPartition,
                                          expectedMounted: Bool) async -> EFIPartition? {
        let targetMountPoint = partition.mountPoint
        for attempt in 0..<verificationAttempts {
            if attempt > 0 {
                try? await Task.sleep(nanoseconds: verificationInterval)
            }
            let discovery = await discover()
            if let current = discovery.partitions.first(where: {
                $0.deviceIdentifier == partition.deviceIdentifier || $0.id == partition.id
            }) {
                if current.isMounted == expectedMounted { return current }
                continue
            }
            // 兜底合成的分区可能不在 diskutil 列表中，改用挂载卷路径判断状态。
            guard let targetMountPoint, !targetMountPoint.isEmpty else { continue }
            if isMountedVolume(atPath: targetMountPoint) == expectedMounted {
                return expectedMounted ? partition : partition.withMountPoint(nil)
            }
        }
        return nil
    }

    // MARK: - 命令行 / 调试

    /// 纯函数：返回将交给 `CommandRunner.runAsAdmin` 的命令文本。
    /// 调用方必须先确认 `deviceIdentifier` 只含字母与数字。
    static func mountShellCommand(for partition: EFIPartition) -> String {
        "diskutil mount \(partition.deviceIdentifier)"
    }

    static func unmountShellCommand(for partition: EFIPartition, force: Bool) -> String {
        force ? "diskutil unmount force \(partition.deviceIdentifier)"
              : "diskutil unmount \(partition.deviceIdentifier)"
    }

    static func cliProbeReport() async -> String {
        let discovery = await discover()
        let openCore = discovery.mounted.flatMap { openCoreInfo(atRoot: $0.rootURL) }

        var lines: [String] = []
        for partition in discovery.partitions {
            let name = partition.volumeName.replacingOccurrences(of: "\"", with: "\\\"")
            lines.append("partition: \(partition.id) name=\"\(name)\" size=\(partition.sizeBytes) "
                         + "mounted=\(yesNo(partition.isMounted)) internal=\(yesNo(partition.isInternal)) "
                         + "mount=\(partition.mountPoint ?? "-")")
        }
        lines.append("mounted-root: \(discovery.mounted?.rootURL.path ?? "-")")
        if let openCore {
            lines.append("opencore: config=\(openCore.configPath) bootloader=\(openCore.bootloader.rawValue) "
                         + "product=\(openCore.productName ?? "-") entries=\(openCore.kextEntries.count) "
                         + "enabled=\(openCore.enabledKextCount) nootedred=\(yesNo(openCore.hasNootedRed)) "
                         + "userpatch=\(yesNo(openCore.hasUserPatch))")
        } else {
            lines.append("opencore: config=- bootloader=unknown product=- entries=0 "
                         + "enabled=0 nootedred=no userpatch=no")
        }
        let commandTarget = discovery.mounted?.partition ?? discovery.partitions.first
        lines.append("mount-command: \(commandTarget.map { mountShellCommand(for: $0) } ?? "-")")
        lines.append("unmount-command: \(commandTarget.map { unmountShellCommand(for: $0, force: false) } ?? "-")")
        lines.append("summary: partitions=\(discovery.partitions.count) "
                     + "mounted=\(discovery.mountedPartitions.count) "
                     + "opencore=\(yesNo(openCore != nil))")
        return lines.joined(separator: "\n")
    }

    // MARK: - 基础工具

    private static func runDiskutil(_ arguments: [String]) async -> CommandResult {
        await CommandRunner.run(diskutilPath, arguments, timeout: commandTimeout)
    }

    /// 只读查询；`target` 可能是设备标识或挂载点路径，参数通过 argv 传给 diskutil，不经过 shell。
    private static func diskutilInfo(for target: String) async -> [String: Any]? {
        let result = await runDiskutil(["info", "-plist", target])
        guard result.succeeded else { return nil }
        return plistDictionary(from: result.output)
    }

    private static func plistDictionary(from text: String) -> [String: Any]? {
        guard let data = text.data(using: .utf8), !data.isEmpty else { return nil }
        return plistDictionary(from: data)
    }

    private static func plistDictionary(from data: Data) -> [String: Any]? {
        guard let object = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) else {
            return nil
        }
        return object as? [String: Any]
    }

    private static func isValidDeviceIdentifier(_ value: String) -> Bool {
        !value.isEmpty && value.unicodeScalars.allSatisfy { allowedDeviceIdentifierCharacters.contains($0) }
    }

    private static func stringValue(_ value: Any?) -> String? {
        switch value {
        case let string as String:
            return string
        case let data as Data:
            return String(data: data, encoding: .utf8)
        case let number as NSNumber:
            return number.stringValue
        default:
            return nil
        }
    }

    private static func trimmedString(_ value: Any?) -> String? {
        guard let string = stringValue(value) else { return nil }
        let trimmed = string.trimmingCharacters(
            in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\0"))
        )
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func uint64Value(_ value: Any?) -> UInt64? {
        if let number = value as? NSNumber { return number.uint64Value }
        if let string = value as? String { return UInt64(string) }
        return nil
    }

    private static func boolValue(_ value: Any?) -> Bool? {
        switch value {
        case let bool as Bool:
            return bool
        case let number as NSNumber:
            return number.boolValue
        case let string as String:
            if let integer = Int(string) { return integer != 0 }
            if string.caseInsensitiveCompare("true") == .orderedSame { return true }
            if string.caseInsensitiveCompare("false") == .orderedSame { return false }
            return nil
        default:
            return nil
        }
    }

    private static func firstNonEmpty(_ values: String?...) -> String? {
        for value in values {
            if let value, !value.isEmpty { return value }
        }
        return nil
    }

    private static func yesNo(_ value: Bool) -> String {
        value ? "yes" : "no"
    }

    /// 仅在 diskutil 无法给出真实设备名时使用的占位标识（仅含字母与数字）。
    private static func syntheticDeviceIdentifier(for path: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in path.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return "volume" + String(hash, radix: 16)
    }

    private struct PartitionCandidate {
        let deviceIdentifier: String
        let volumeName: String
        let sizeBytes: UInt64
    }
}

// MARK: - 私有副本构造

private extension EFIPartition {
    func withMountPoint(_ mountPoint: String?) -> EFIPartition {
        EFIPartition(
            id: id,
            deviceIdentifier: deviceIdentifier,
            volumeName: volumeName,
            sizeBytes: sizeBytes,
            isInternal: isInternal,
            busProtocol: busProtocol,
            mountPoint: mountPoint,
            filesystem: filesystem
        )
    }

    func withID(_ id: String) -> EFIPartition {
        EFIPartition(
            id: id,
            deviceIdentifier: deviceIdentifier,
            volumeName: volumeName,
            sizeBytes: sizeBytes,
            isInternal: isInternal,
            busProtocol: busProtocol,
            mountPoint: mountPoint,
            filesystem: filesystem
        )
    }
}
