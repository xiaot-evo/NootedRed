import Foundation

// MARK: - EFI 分区

struct EFIPartition: Identifiable, Hashable {
    /// 稳定的设备标识，例如 `disk0s1`。
    let id: String
    let deviceIdentifier: String
    let volumeName: String
    let sizeBytes: UInt64
    let isInternal: Bool
    let busProtocol: String?
    /// 未挂载时为 nil；已挂载时是卷的挂载点路径。
    let mountPoint: String?
    let filesystem: String?

    init(id: String, deviceIdentifier: String, volumeName: String, sizeBytes: UInt64,
         isInternal: Bool, busProtocol: String? = nil, mountPoint: String? = nil,
         filesystem: String? = nil) {
        self.id = id
        self.deviceIdentifier = deviceIdentifier
        self.volumeName = volumeName
        self.sizeBytes = sizeBytes
        self.isInternal = isInternal
        self.busProtocol = busProtocol
        self.mountPoint = mountPoint
        self.filesystem = filesystem
    }

    var isMounted: Bool {
        guard let mountPoint else { return false }
        return !mountPoint.isEmpty
    }

    var mountURL: URL? {
        guard let mountPoint, !mountPoint.isEmpty else { return nil }
        return URL(fileURLWithPath: mountPoint)
    }

    var displayName: String {
        let trimmed = volumeName.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? deviceIdentifier : trimmed
    }

    var sizeText: String {
        ByteCountFormatter.string(fromByteCount: Int64(sizeBytes), countStyle: .file)
    }

    var locationText: String {
        isInternal ? "内置" : "外置"
    }
}

// MARK: - 已挂载的 EFI

struct MountedEFI: Identifiable, Hashable {
    let partition: EFIPartition
    let rootURL: URL

    var id: String { partition.id }

    var openCoreConfigURL: URL {
        rootURL.appendingPathComponent("EFI/OC/config.plist")
    }

    var kextsDirectoryURL: URL {
        rootURL.appendingPathComponent("EFI/OC/Kexts")
    }

    var hasOpenCoreConfig: Bool {
        FileManager.default.fileExists(atPath: openCoreConfigURL.path)
    }
}

// MARK: - 探测结果

struct EFIDiscovery {
    var partitions: [EFIPartition] = []
    /// 优先选中带 OpenCore 配置的分区，其次取第一个已挂载的 EFI 分区。
    var mounted: MountedEFI?
    var scannedAt = Date()

    static let empty = EFIDiscovery()

    var mountedPartitions: [EFIPartition] { partitions.filter(\.isMounted) }
    var unmountedPartitions: [EFIPartition] { partitions.filter { !$0.isMounted } }
    var hasAnyPartition: Bool { !partitions.isEmpty }

    func partition(withID id: String) -> EFIPartition? {
        partitions.first { $0.id == id }
    }
}

// MARK: - OpenCore

enum BootloaderKind: String {
    case openCore = "OpenCore"
    case clover = "Clover"
    case unknown = "未知"
}

struct OpenCoreKextEntry: Identifiable, Hashable {
    let bundlePath: String
    let enabled: Bool
    let comment: String?

    var id: String { bundlePath }

    var displayName: String {
        let trimmed = comment?.trimmingCharacters(in: .whitespaces) ?? ""
        return trimmed.isEmpty ? bundlePath : trimmed
    }
}

struct OpenCoreInfo {
    let efiRoot: URL
    let bootloader: BootloaderKind
    let configPath: String
    let configModified: Date?
    let configSize: UInt64
    /// `PlatformInfo > Generic > SystemProductName`，用于确认 SMBIOS。
    let productName: String?
    /// `NVRAM > Add > boot-args`，可能与当前 NVRAM 中的值不同。
    let configBootArgs: String?
    let kextEntries: [OpenCoreKextEntry]
    /// `EFI/OC/Kexts` 目录下实际存在的 `*.kext` 名称。
    let kextFiles: [String]

    var enabledKextCount: Int { kextEntries.filter(\.enabled).count }

    func kextEntry(named name: String) -> OpenCoreKextEntry? {
        kextEntries.first { $0.bundlePath.caseInsensitiveCompare(name) == .orderedSame }
    }

    var nootedRedEntry: OpenCoreKextEntry? { kextEntry(named: "NootedRed.kext") }
    var userPatchEntry: OpenCoreKextEntry? { kextEntry(named: "NootedRedUserPatch.kext") }

    var hasNootedRed: Bool { nootedRedEntry?.enabled == true }
    var hasUserPatch: Bool { userPatchEntry?.enabled == true }
}

// MARK: - 操作结果

struct EFIOperationResult {
    let success: Bool
    let message: String
    let detail: String?

    init(success: Bool, message: String, detail: String? = nil) {
        self.success = success
        self.message = message
        self.detail = detail
    }

    static func ok(_ message: String, detail: String? = nil) -> EFIOperationResult {
        EFIOperationResult(success: true, message: message, detail: detail)
    }

    static func failure(_ message: String, detail: String? = nil) -> EFIOperationResult {
        EFIOperationResult(success: false, message: message, detail: detail)
    }
}

// MARK: - 错误

enum EFIServiceError: LocalizedError {
    case diskutilFailed(String)
    case noEFIPartition
    case mountPointMissing(String)
    case openCoreConfigUnreadable(String)
    case unsafeDeviceIdentifier(String)

    var errorDescription: String? {
        switch self {
        case .diskutilFailed(let output):
            return "diskutil 执行失败：\(output)"
        case .noEFIPartition:
            return "未检测到 EFI 分区"
        case .mountPointMissing(let device):
            return "\(device) 挂载后没有找到挂载点"
        case .openCoreConfigUnreadable(let path):
            return "无法读取 OpenCore 配置：\(path)"
        case .unsafeDeviceIdentifier(let value):
            return "不合法的磁盘标识：\(value)"
        }
    }
}
