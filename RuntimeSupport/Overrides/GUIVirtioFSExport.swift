import ContainerizationEXT4
import Foundation
import SystemPackage
import CryptoKit
import Darwin

struct GUIVirtioFSExport {
    struct Entry: Codable {
        let path: String
        let uid: UInt32
        let gid: UInt32
        let mode: UInt16
        let sha256: String?
    }

    static func populate(directory: String, rootfs: String, source: String) throws {
        let folder = URL(fileURLWithPath: directory)
        let lock = Darwin.open(folder.deletingLastPathComponent().appendingPathComponent("copyup.lock").path, O_CREAT | O_RDWR, 0o600)
        guard lock >= 0 else { throw CocoaError(.fileWriteUnknown) }
        defer { Darwin.close(lock) }
        guard flock(lock, LOCK_EX) == 0 else { throw CocoaError(.fileWriteUnknown) }
        defer { flock(lock, LOCK_UN) }
        guard try FileManager.default.contentsOfDirectory(atPath: directory).isEmpty else { return }
        let reader = try EXT4.EXT4Reader(blockDevice: FilePath(rootfs))
        let path = FilePath(source)
        guard reader.exists(path, followSymlinks: true) else { return }
        let (_, inode) = try reader.stat(path)
        guard inode.isDirectory else { return }
        let stage = folder.deletingLastPathComponent().appendingPathComponent(".copyup-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: stage) }
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: false)
        var linked: [EXT4.InodeNumber: URL] = [:]
        var entries: [Entry] = []
        try copy(reader: reader, source: path, target: stage, relative: ".", linked: &linked, entries: &entries)
        guard Darwin.rename(stage.path, folder.path) == 0 else { throw CocoaError(.fileWriteUnknown) }
        try JSONEncoder().encode(entries).write(to: folder.deletingLastPathComponent().appendingPathComponent("linux-metadata.json"), options: .atomic)
    }

    static func copy(reader: EXT4.EXT4Reader, source: FilePath, target: URL, relative: String, linked: inout [EXT4.InodeNumber: URL], entries: inout [Entry]) throws {
        let (number, inode) = try reader.stat(source, followSymlinks: false)
        var checksum: String?
        if inode.isDirectory {
            if !FileManager.default.fileExists(atPath: target.path) { try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false) }
            for name in try reader.listDirectory(source) where name != "." && name != ".." {
                guard !name.contains("/"), !name.contains("\0") else { throw CocoaError(.fileReadCorruptFile) }
                let next = target.appendingPathComponent(name)
                guard !FileManager.default.fileExists(atPath: next.path), (try? FileManager.default.destinationOfSymbolicLink(atPath: next.path)) == nil else { throw CocoaError(.fileWriteFileExists) }
                try copy(reader: reader, source: source.join(name), target: next, relative: relative + "/" + name, linked: &linked, entries: &entries)
            }
        } else if inode.isSymlink {
            let link: String
            if inode.size < 60 {
                var block = inode.block
                link = withUnsafeBytes(of: &block) { String(decoding: $0.prefix(Int(inode.size)), as: UTF8.self) }
            } else {
                link = String(decoding: try reader.readFile(at: source, followSymlinks: false), as: UTF8.self)
            }
            try FileManager.default.createSymbolicLink(atPath: target.path, withDestinationPath: link)
        } else if inode.isRegularFile {
            if let first = linked[number], inode.linksCount > 1 {
                try FileManager.default.linkItem(at: first, to: target)
            } else {
                guard FileManager.default.createFile(atPath: target.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw CocoaError(.fileWriteUnknown) }
                let file = try FileHandle(forWritingTo: target)
                defer { try? file.close() }
                var offset: UInt64 = 0
                var hash = SHA256()
                var buffer = [UInt8](repeating: 0, count: 1024 * 1024)
                while offset < UInt64(inode.size) {
                    let count = try buffer.withUnsafeMutableBytes { raw in
                        try reader.readFile(at: source, into: UnsafeMutableRawBufferPointer(rebasing: raw.prefix(min(raw.count, Int(UInt64(inode.size) - offset)))), offset: offset, followSymlinks: false)
                    }
                    guard count > 0 else { throw CocoaError(.fileReadCorruptFile) }
                    let data = Data(buffer.prefix(count))
                    hash.update(data: data)
                    try file.write(contentsOf: data)
                    offset += UInt64(count)
                }
                try file.synchronize()
                checksum = hash.finalize().map { String(format: "%02x", $0) }.joined()
                linked[number] = target
            }
        } else {
            throw NSError(domain: "VirtioFSMigration", code: 1, userInfo: [NSLocalizedDescriptionKey: "Unsupported special file at " + relative + ". Original volume retained."])
        }
        if !inode.isSymlink {
            try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: inode.mode & 0o7777), .modificationDate: Date(timeIntervalSince1970: TimeInterval(inode.mtime))], ofItemAtPath: target.path)
        }
        entries.append(Entry(path: relative, uid: inode.fullUid, gid: inode.fullGid, mode: inode.mode, sha256: checksum))
    }
}
