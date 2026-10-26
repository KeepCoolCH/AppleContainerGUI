import ContainerAPIClient
import ContainerResource
import Foundation
import Vapor
import Darwin

actor GUIVirtioFSVolumes {
    static let shared = GUIVirtioFSVolumes()
    static var root: URL {
        URL(fileURLWithPath: canonicalPath(ProcessInfo.processInfo.environment["APPLE_CONTAINER_GUI_VOLUMES"] ?? NSHomeDirectory() + "/Library/Application Support/AppleContainerGUI/Volumes"))
    }

    static func canonicalPath(_ path: String) -> String {
        if let pointer = realpath(path, nil) {
            defer { free(pointer) }
            return String(cString: pointer)
        }
        let url = URL(fileURLWithPath: path)
        let parent = url.deletingLastPathComponent().path
        if parent == path { return path }
        return URL(fileURLWithPath: canonicalPath(parent)).appendingPathComponent(url.lastPathComponent).path
    }

    static func retired(_ name: String) -> Bool {
        FileManager.default.fileExists(atPath: root.appendingPathComponent(".legacy/" + name).path)
    }

    static func validate(_ name: String) throws {
        guard name.range(of: "^[A-Za-z0-9][A-Za-z0-9_.-]*$", options: .regularExpression) != nil, name.utf8.count <= 200 else {
            throw Abort(.badRequest, reason: "Invalid volume name")
        }
    }

    static func read(_ name: String) throws -> VolumeConfiguration {
        try validate(name)
        let directory = root.appendingPathComponent(name)
        guard canonicalPath(directory.path) == directory.path else {
            throw Abort(.conflict, reason: "Volume directory must not be a symlink")
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let volume = try decoder.decode(VolumeConfiguration.self, from: Data(contentsOf: directory.appendingPathComponent("metadata.json")))
        guard volume.name == name, volume.format == "virtiofs", volume.source == directory.appendingPathComponent("data").path,
              canonicalPath(volume.source) == volume.source else {
            throw Abort(.conflict, reason: "Invalid VirtioFS volume metadata: " + name)
        }
        return volume
    }

    static func name(for source: String) -> String? {
        let url = URL(fileURLWithPath: source)
        guard url.lastPathComponent == "data", url.deletingLastPathComponent().deletingLastPathComponent().path == root.path,
              let volume = try? read(url.deletingLastPathComponent().lastPathComponent), volume.source == url.path else { return nil }
        return volume.name
    }

    static func name(for mount: Filesystem) -> String? {
        if case .volume(let name, _, _, _) = mount.type { return name }
        if case .virtiofs = mount.type { return name(for: mount.source) }
        return nil
    }

    static func write(_ volume: VolumeConfiguration, at directory: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(volume).write(to: directory.appendingPathComponent("metadata.json"), options: .atomic)
    }

    static func managed() throws -> [VolumeConfiguration] {
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { !$0.lastPathComponent.hasPrefix(".") }
            .map { try read($0.lastPathComponent) }
    }

    func list() async throws -> [VolumeConfiguration] {
        let volumes = try Self.managed()
        let names = Set(volumes.map(\.name))
        return volumes + (try await ClientVolume.list()).filter { !names.contains($0.name) && !Self.retired($0.name) }
    }

    func inspect(_ name: String) async throws -> VolumeConfiguration {
        try Self.validate(name)
        if FileManager.default.fileExists(atPath: Self.root.appendingPathComponent(name).path) { return try Self.read(name) }
        if Self.retired(name) { throw Abort(.notFound, reason: "No such volume: " + name) }
        return try await ClientVolume.inspect(name)
    }

    func resolve(name: String, labels: [String: String] = [:]) async throws -> VolumeConfiguration {
        try await create(name: name, driver: "local", options: [:], labels: labels)
    }

    func create(name: String?, driver: String?, options: [String: String]?, labels: [String: String]) async throws -> VolumeConfiguration {
        let name = (name?.isEmpty == false) ? name! : UUID().uuidString.lowercased()
        try Self.validate(name)
        guard driver == nil || driver == "" || driver == "local" else { throw Abort(.badRequest, reason: "Only the local VirtioFS volume driver is supported") }
        guard options == nil || options!.isEmpty else { throw Abort(.badRequest, reason: "Driver options are not supported for managed VirtioFS volumes") }
        let target = Self.root.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: target.path) { return try Self.read(name) }
        if !Self.retired(name), try await ClientVolume.list().contains(where: { $0.name == name }) {
            throw Abort(.conflict, reason: "Volume " + name + " uses an Apple disk image. Migrate volumes in AppleContainerGUI before attaching it.")
        }
        try FileManager.default.createDirectory(at: Self.root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let stage = Self.root.appendingPathComponent(".create-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: stage) }
        try FileManager.default.createDirectory(at: stage.appendingPathComponent("data"), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
        let volume = VolumeConfiguration(name: name, format: "virtiofs", source: target.appendingPathComponent("data").path, labels: labels)
        try Self.write(volume, at: stage)
        do { try FileManager.default.moveItem(at: stage, to: target) }
        catch {
            if FileManager.default.fileExists(atPath: target.path) { return try Self.read(name) }
            throw error
        }
        return volume
    }

    func delete(_ name: String) async throws {
        let volume = try await inspect(name)
        guard volume.format == "virtiofs" else { throw Abort(.conflict, reason: "Legacy disk volumes are retained as migration backups") }
        let containers = try await ContainerClient().list()
        guard !containers.contains(where: { $0.configuration.mounts.contains(where: { Self.name(for: $0) == name }) }) else {
            throw Abort(.conflict, reason: "Volume is in use: " + name)
        }
        try FileManager.default.removeItem(at: Self.root.appendingPathComponent(name))
    }

    static func diskUsage(_ name: String) throws -> UInt64 {
        let volume = try read(name)
        let iterator = FileManager.default.enumerator(at: URL(fileURLWithPath: volume.source), includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey])
        var size: UInt64 = 0
        while let file = iterator?.nextObject() as? URL {
            let values = try file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            if values.isRegularFile == true { size += UInt64(values.fileSize ?? 0) }
        }
        return size
    }
}
