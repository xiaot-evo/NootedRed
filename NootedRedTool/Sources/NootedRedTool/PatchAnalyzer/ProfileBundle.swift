import Foundation

// MARK: - Multi-profile bundle manifest

/// Manifest for `--bundle-profiles`. JSON, UTF-8:
///
/// ```json
/// {
///   "schema": 1,
///   "profiles": [
///     { "fixtureRoot": "/path/to/version-fixtures/15.8.2" },
///     { "profile": "/path/to/nred-24H232.nrpt", "fixtureRoot": "/path/to/version-fixtures/15.8.2" }
///   ]
/// }
/// ```
///
/// Every entry produces exactly one `NRedProfiles` array element and the array preserves this
/// explicit manifest order (the kext selects by exact build/APU/device, so order has no selection
/// semantics; preserving it keeps the artifact deterministic). `build`, `apuMask` and `deviceID`
/// are optional overrides that MUST agree with the generated/decoded profile header — they exist
/// only so a caller can assert the expected identity; a mismatch fails generation.
struct ProfileBundleManifest {
    struct Entry {
        let fixtureRoot: String?
        let profilePath: String?
        let buildOverride: String?
        let apuMaskOverride: UInt32?
        let deviceIDOverride: UInt32?
    }

    let entries: [Entry]

    static func load(at url: URL) throws -> ProfileBundleManifest {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw AnalyzerError.io("cannot read bundle manifest \(url.path): \(error.localizedDescription)")
        }
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw AnalyzerError.malformed("bundle manifest is not JSON: \(error.localizedDescription)")
        }
        guard let root = object as? [String: Any] else {
            throw AnalyzerError.malformed("bundle manifest root must be an object")
        }
        if let schema = root["schema"] as? Int, schema != 1 {
            throw AnalyzerError.unsupported("bundle manifest schema \(schema); expected 1")
        }
        guard let rawEntries = root["profiles"] as? [[String: Any]], !rawEntries.isEmpty else {
            throw AnalyzerError.malformed("bundle manifest needs a non-empty 'profiles' array")
        }
        guard rawEntries.count <= NRPTFormat.maxBundleEntries else {
            throw AnalyzerError.validation(
                "bundle has \(rawEntries.count) profiles; maximum is \(NRPTFormat.maxBundleEntries)")
        }
        var entries: [Entry] = []
        for (index, raw) in rawEntries.enumerated() {
            let fixtureRoot = (raw["fixtureRoot"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            let profilePath = (raw["profile"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            guard fixtureRoot != nil || profilePath != nil else {
                throw AnalyzerError.malformed(
                    "bundle profile \(index): 'fixtureRoot' or 'profile' is required")
            }
            let buildOverride = raw["build"] as? String
            if let buildOverride {
                let allowed = CharacterSet(charactersIn:
                    "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz._-")
                guard buildOverride.count >= 1, buildOverride.count <= NRPTFormat.maxBuildBytes,
                      buildOverride.unicodeScalars.allSatisfy({ allowed.contains($0) }) else {
                    throw AnalyzerError.malformed("bundle profile \(index): invalid build override")
                }
            }
            let apuMaskOverride = try u32Field(raw["apuMask"], index: index, name: "apuMask")
            let deviceIDOverride = try u32Field(raw["deviceID"], index: index, name: "deviceID")
            entries.append(Entry(fixtureRoot: fixtureRoot, profilePath: profilePath,
                                 buildOverride: buildOverride,
                                 apuMaskOverride: apuMaskOverride,
                                 deviceIDOverride: deviceIDOverride))
        }
        return ProfileBundleManifest(entries: entries)
    }

    private static func u32Field(_ value: Any?, index: Int, name: String) throws -> UInt32? {
        guard let value else { return nil }
        if let number = value as? NSNumber {
            let unsigned = number.uint64Value
            guard unsigned <= UInt64(UInt32.max), number.int64Value >= 0 else {
                throw AnalyzerError.malformed("bundle profile \(index): \(name) is out of range")
            }
            return UInt32(unsigned)
        }
        if let text = value as? String {
            let cleaned = text.hasPrefix("0x") || text.hasPrefix("0X") ? String(text.dropFirst(2)) : text
            if let parsed = UInt32(cleaned, radix: 16) { return parsed }
            if let parsed = UInt32(cleaned) { return parsed }
        }
        throw AnalyzerError.malformed("bundle profile \(index): \(name) must be an integer or hex string")
    }
}

// MARK: - Bundle evidence

/// Per-profile facts recorded in `nred-profiles-evidence.json`.
struct BundleProfileFacts {
    let build: String
    let apuMask: UInt32
    let deviceID: UInt32
    let profileData: Data
    let source: String
    let revalidated: Bool
    let profile: NRPTProfile

    var sha256: String { ProfileGenerator.sha256(profileData) }
    var modePageCount: Int { profile.pages.filter { $0.mode == .page }.count }
    var modeDyldCount: Int { profile.pages.filter { $0.mode == .dyld }.count }
}

enum ProfileBundleSupport {
    /// Stable, machine-independent source label for evidence: the last path component
    /// (e.g. "15.8.2" for a fixture root, the .nrpt filename for a profile).
    static func sourceLabel(for path: String) -> String {
        URL(fileURLWithPath: path).lastPathComponent
    }

    static func evidenceJSON(facts: [BundleProfileFacts]) throws -> Data {
        let perProfile: [[String: Any]] = facts.map { fact in
            [
                "build": fact.build,
                "apuMask": Hex.value(UInt64(fact.apuMask)),
                "deviceID": Hex.value(UInt64(fact.deviceID)),
                "profileSize": fact.profileData.count,
                "profileSha256": fact.sha256,
                "imageCount": fact.profile.images.count,
                "pageCount": fact.profile.pageCount,
                "siteCount": fact.profile.siteCount,
                "modePageCount": fact.modePageCount,
                "modeDyldCount": fact.modeDyldCount,
                "source": fact.source,
                "offlineValidated": fact.revalidated,
                "images": fact.profile.images.map { image in
                    [
                        "kind": image.kind == .standaloneFile ? "standalone-file" : "dyld-shared-cache",
                        "path": image.path,
                        "unslidVmaddr": Hex.value(image.unslidVMAddress),
                        "vmSize": Hex.value(UInt64(image.vmSize))
                    ]
                }
            ]
        }
        let evidence: [String: Any] = [
            "schema": 1,
            "kind": "NRedProfiles-bundle",
            "profileVersion": Int(NRPTFormat.version),
            "profileCount": facts.count,
            "rootKey": "NRedProfiles",
            "order": "manifest",
            "profiles": perProfile,
            "result": "PASS"
        ]
        do {
            return try JSONSerialization.data(withJSONObject: evidence,
                                              options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        } catch {
            throw AnalyzerError.malformed("cannot serialize bundle evidence: \(error.localizedDescription)")
        }
    }
}
