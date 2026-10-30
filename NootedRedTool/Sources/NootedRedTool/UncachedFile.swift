import Darwin
import Foundation

/// Reads driver/cache files without the unified buffer cache.
///
/// The running UserPatch kext deliberately patches the pager data that backs
/// dyld-cache pages.  Those patched pages can also be visible through the
/// normal file cache, which makes profile generation race with the live patch:
/// one read can contain the original bytes and the next read the patched bytes.
/// F_NOCACHE keeps profile generation on the on-disk bytes.
enum UncachedFile {
    static func openHandle(_ url: URL) throws -> FileHandle {
        let fd = open(url.path, O_RDONLY)
        guard fd >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno),
                          userInfo: [NSLocalizedDescriptionKey: "open failed: \(url.path)"])
        }
        _ = fcntl(fd, F_NOCACHE, 1)
        return FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    }

    static func read(_ url: URL) throws -> Data {
        let handle = try openHandle(url)
        defer { try? handle.close() }
        return try handle.readToEnd() ?? Data()
    }
}
