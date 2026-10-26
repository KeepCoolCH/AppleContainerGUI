import ContainerResource
import Foundation
import Darwin

struct GUIVirtioFSMigration {
    static func run() throws {
        let check = Process()
        check.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        check.arguments = ["print", "gui/\(getuid())/com.apple.container.apiserver"]
        check.standardOutput = FileHandle.nullDevice
        check.standardError = FileHandle.nullDevice
        try check.run()
        check.waitUntilExit()
        guard check.terminationStatus != 0 else { throw failure("Stop Apple Container before migrating volumes") }
        let fm = FileManager.default
        let dataRoot = URL(fileURLWithPath: ProcessInfo.processInfo.environment["CONTAINER_APP_ROOT"] ?? NSHomeDirectory() + "/Library/Application Support/com.apple.container")
        try fm.createDirectory(at: GUIVirtioFSVolumes.root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let lock = Darwin.open(GUIVirtioFSVolumes.root.appendingPathComponent(".migration.lock").path, O_CREAT | O_RDWR, 0o600)
        guard lock >= 0 else { throw failure("Cannot create migration lock") }
        defer { Darwin.close(lock) }
        guard flock(lock, LOCK_EX | LOCK_NB) == 0 else { throw failure("Another volume migration is running") }
        defer { flock(lock, LOCK_UN) }
        let backup = GUIVirtioFSVolumes.root.deletingLastPathComponent().appendingPathComponent("VolumeMigrationBackups/" + UUID().uuidString)
        try fm.createDirectory(at: backup, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let volumesRoot = dataRoot.appendingPathComponent("volumes")
        let folders = (try? fm.contentsOfDirectory(at: volumesRoot, includingPropertiesForKeys: nil)) ?? []
        var converted: [String: String] = [:]
        for folder in folders where !folder.lastPathComponent.hasPrefix(".") {
            let original = try decodeVolume(Data(contentsOf: folder.appendingPathComponent("entity.json")))
            try GUIVirtioFSVolumes.validate(original.name)
            if GUIVirtioFSVolumes.retired(original.name), (try? GUIVirtioFSVolumes.read(original.name)) == nil { continue }
            guard original.format == "ext4" else { throw failure("Unsupported legacy volume format: " + original.format) }
            let target = GUIVirtioFSVolumes.root.appendingPathComponent(original.name)
            if fm.fileExists(atPath: target.path) {
                converted[original.name] = try GUIVirtioFSVolumes.read(original.name).source
                continue
            }
            let stage = GUIVirtioFSVolumes.root.appendingPathComponent(".migrate-" + UUID().uuidString)
            defer { try? fm.removeItem(at: stage) }
            try fm.createDirectory(at: stage.appendingPathComponent("data"), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
            print("Copying volume " + original.name)
            try GUIVirtioFSExport.populate(directory: stage.appendingPathComponent("data").path, rootfs: original.source, source: "/")
            let replacement = VolumeConfiguration(name: original.name, driver: "local", format: "virtiofs", source: target.appendingPathComponent("data").path, creationDate: original.creationDate, labels: original.labels, options: [:])
            try GUIVirtioFSVolumes.write(replacement, at: stage)
            try fm.moveItem(at: stage, to: target)
            converted[original.name] = replacement.source
        }
        let containersRoot = dataRoot.appendingPathComponent("containers")
        let containers = (try? fm.contentsOfDirectory(at: containersRoot, includingPropertiesForKeys: nil)) ?? []
        var changes: [(URL, Data, Data)] = []
        for directory in containers where !directory.lastPathComponent.hasPrefix(".") {
            for filename in ["config.json", "runtime-configuration.json"] {
                let file = directory.appendingPathComponent(filename)
                guard fm.fileExists(atPath: file.path) else { continue }
                let previous = try Data(contentsOf: file)
                guard var object = try JSONSerialization.jsonObject(with: previous) as? [String: Any] else { throw failure("Invalid container configuration: " + file.path) }
                var configuration = filename == "config.json" ? object : (object["containerConfiguration"] as? [String: Any] ?? [:])
                let mounts = configuration["mounts"] as? [[String: Any]] ?? []
                var changed = false
                configuration["mounts"] = try mounts.map { mount -> [String: Any] in
                    let type = mount["type"] as? [String: Any] ?? [:]
                    if let volume = type["volume"] as? [String: Any], let name = volume["name"] as? String {
                        guard let source = converted[name] else { throw failure("Missing migrated volume " + name) }
                        var result = mount
                        result["type"] = ["virtiofs": [:]]
                        result["source"] = source
                        changed = true
                        return result
                    }
                    return mount
                }
                guard changed else { continue }
                if filename == "config.json" { object = configuration } else { object["containerConfiguration"] = configuration }
                let saved = backup.appendingPathComponent(directory.lastPathComponent + "/" + filename)
                try fm.createDirectory(at: saved.deletingLastPathComponent(), withIntermediateDirectories: true)
                try previous.write(to: saved, options: .atomic)
                let updated = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
                changes.append((file, previous, updated))
            }
        }
        var applied: [(URL, Data)] = []
        do {
            for (file, previous, updated) in changes {
                try updated.write(to: file, options: .atomic)
                applied.append((file, previous))
            }
            let retired = GUIVirtioFSVolumes.root.appendingPathComponent(".legacy")
            try fm.createDirectory(at: retired, withIntermediateDirectories: true)
            for name in converted.keys { try Data(name.utf8).write(to: retired.appendingPathComponent(name), options: .atomic) }
        } catch {
            for (file, previous) in applied.reversed() { try previous.write(to: file, options: .atomic) }
            throw error
        }
        print("Migrated \(converted.count) volumes and \(changes.count) configuration files. Original disk images retained. Configuration backup: \(backup.path)")
    }

    static func decodeVolume(_ data: Data) throws -> VolumeConfiguration {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let value = try? decoder.decode(VolumeConfiguration.self, from: data) { return value }
        return try JSONDecoder().decode(VolumeConfiguration.self, from: data)
    }

    static func failure(_ message: String) -> NSError {
        NSError(domain: "VirtioFSMigration", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
