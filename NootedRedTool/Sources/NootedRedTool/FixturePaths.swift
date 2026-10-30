import Foundation

/// Allows the parser to run against an extracted macOS fixture tree.
///
/// Set `NRED_FIXTURE_ROOT` to a directory containing:
///   System/Library/Extensions/AMDRadeonX5000GLDriver.bundle/Contents/MacOS/AMDRadeonX5000GLDriver
///   System/Volumes/Preboot/Cryptexes/OS/System/Library/dyld/
/// or:
///   System/Library/dyld/
enum FixturePaths {
    static let root: URL? = {
        guard let value = ProcessInfo.processInfo.environment["NRED_FIXTURE_ROOT"],
              !value.isEmpty else { return nil }
        return URL(fileURLWithPath: value, isDirectory: true)
    }()

    static var dyldDirectory: URL {
        if let root {
            let preboot = root.appendingPathComponent(
                "System/Volumes/Preboot/Cryptexes/OS/System/Library/dyld",
                isDirectory: true
            )
            if FileManager.default.fileExists(atPath: preboot.path) { return preboot }
            return root.appendingPathComponent("System/Library/dyld", isDirectory: true)
        }
        return URL(fileURLWithPath: "/System/Volumes/Preboot/Cryptexes/OS/System/Library/dyld")
    }

    static var glDriverPath: String {
        if let root {
            return root.appendingPathComponent(
                "System/Library/Extensions/AMDRadeonX5000GLDriver.bundle/Contents/MacOS/AMDRadeonX5000GLDriver"
            ).path
        }
        return "/System/Library/Extensions/AMDRadeonX5000GLDriver.bundle/Contents/MacOS/AMDRadeonX5000GLDriver"
    }

    static var buildVersion: String? {
        guard let root else { return nil }
        let plistURL = root.appendingPathComponent("System/Library/CoreServices/SystemVersion.plist")
        guard let data = try? Data(contentsOf: plistURL),
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let dictionary = plist as? [String: Any],
              let build = dictionary["ProductBuildVersion"] as? String else { return nil }
        return build
    }
}
