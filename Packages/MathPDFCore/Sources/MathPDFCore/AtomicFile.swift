import Darwin
import Foundation

/// Crash-safe file replacement: after a crash or power loss at any point,
/// `url` holds either the old contents or the new contents in full, never a
/// mix.
public enum AtomicFile {
    /// Marks temp files, so a later load can remove ones a crash left behind.
    public static let tempMarker = ".tmp-"

    /// 1. Write the data to a temp file in the same folder and flush it to the
    ///    disk.
    /// 2. Swap it into place with `FileManager.replaceItemAt` (a rename on
    ///    first write).
    /// 3. Flush the folder so the swap itself is durable.
    ///
    /// `beforeReplace` runs between steps 1 and 2. Tests use it to simulate a
    /// crash there; if it throws, the temp file is left behind exactly as a
    /// killed process would leave it.
    public static func write(
        _ data: Data, to url: URL, beforeReplace: (() throws -> Void)? = nil
    ) throws {
        let folder = url.deletingLastPathComponent()
        let temp = folder.appendingPathComponent(
            ".\(url.lastPathComponent)\(tempMarker)\(UUID().uuidString)")
        try writeDurably(data, to: temp)
        try beforeReplace?()

        do {
            if FileManager.default.fileExists(atPath: url.path) {
                _ = try FileManager.default.replaceItemAt(
                    url, withItemAt: temp)
            } else {
                try FileManager.default.moveItem(at: temp, to: url)
            }
        } catch {
            try? FileManager.default.removeItem(at: temp)
            throw error
        }
        syncFolder(folder)
    }

    private static func writeDurably(_ data: Data, to url: URL) throws {
        let fd = open(url.path, O_WRONLY | O_CREAT | O_EXCL, 0o644)
        guard fd >= 0 else { throw posixError(url) }
        var finished = false
        defer {
            close(fd)
            if !finished { unlink(url.path) }
        }

        try data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            var offset = 0
            while offset < buffer.count {
                let written = Darwin.write(
                    fd, buffer.baseAddress! + offset, buffer.count - offset)
                if written < 0 {
                    if errno == EINTR { continue }
                    throw posixError(url)
                }
                offset += written
            }
        }
        // On macOS, fsync only reaches the drive; F_FULLFSYNC also flushes the
        // drive's cache.
        if fcntl(fd, F_FULLFSYNC) != 0, fsync(fd) != 0 {
            throw posixError(url)
        }
        finished = true
    }

    private static func syncFolder(_ folder: URL) {
        let fd = open(folder.path, O_RDONLY)
        guard fd >= 0 else { return }
        fsync(fd)
        close(fd)
    }

    private static func posixError(_ url: URL) -> Error {
        NSError(
            domain: NSPOSIXErrorDomain, code: Int(errno),
            userInfo: [NSFilePathErrorKey: url.path])
    }
}
