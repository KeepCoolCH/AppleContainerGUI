import Foundation
import CryptoKit
import Darwin

nonisolated struct RuntimeManifest: Codable, Sendable {
    let schemaVersion: Int
    let bundleVersion: String
    let appleContainerVersion: String
    let socktainerVersion: String
    let dockerVersion: String
    let composeVersion: String
    let vminitImage: String
    let builderImage: String
    let files: [String: String]
}

nonisolated struct ManagedRuntime: Sendable {
    static let shared = ManagedRuntime()
    let payload: URL
    let storage: URL
    let dataRoot: URL

    init(payload: URL = Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/RuntimePayload"), storage: URL? = nil, dataRoot: URL? = nil) {
        let support = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        self.payload = payload
        self.storage = storage ?? support.appendingPathComponent("AppleContainerGUI")
        self.dataRoot = dataRoot ?? support.appendingPathComponent("com.apple.container")
    }

    func manifest(at root: URL? = nil) throws -> RuntimeManifest {
        let value = try JSONDecoder().decode(RuntimeManifest.self, from: Data(contentsOf: (root ?? payload).appendingPathComponent("manifest.json")))
        guard value.schemaVersion == 1, !value.bundleVersion.isEmpty,
              value.bundleVersion.range(of: "^[A-Za-z0-9._-]+$", options: .regularExpression) != nil,
              value.bundleVersion != ".", value.bundleVersion != ".." else {
            throw DockerAPIError(message: "Invalid bundled runtime manifest")
        }
        return value
    }

    var installedRoot: URL? {
        guard let manifest = try? manifest() else { return nil }
        let root = storage.appendingPathComponent("Runtimes/" + manifest.bundleVersion)
        guard let expected = try? Data(contentsOf: payload.appendingPathComponent("manifest.json")),
              let receipt = try? Data(contentsOf: root.appendingPathComponent("ready.json")), expected == receipt else { return nil }
        return root
    }

    func executable(_ relative: String) -> URL? {
        guard let root = installedRoot else { return nil }
        let url = root.appendingPathComponent(relative)
        guard FileManager.default.isExecutableFile(atPath: url.path),
              let trusted = try? manifest(),
              (try? verifyFile(relative, in: root, manifest: trusted)) != nil else { return nil }
        return url
    }

    func environment(root: URL? = nil) -> [String: String] {
        let root = root ?? installedRoot
        let inherited = ProcessInfo.processInfo.environment
        let allowed = ["HOME", "USER", "LOGNAME", "TMPDIR", "LANG", "LC_ALL", "HTTP_PROXY", "HTTPS_PROXY", "NO_PROXY", "http_proxy", "https_proxy", "no_proxy"]
        var env = inherited.filter { allowed.contains($0.key) }
        env["HOME"] = FileManager.default.homeDirectoryForCurrentUser.path
        env["PATH"] = (root.map { $0.appendingPathComponent("Tools").path + ":" + $0.appendingPathComponent("AppleContainer/bin").path + ":" } ?? "") + "/usr/bin:/bin:/usr/sbin:/sbin"
        env["CONTAINER_APP_ROOT"] = dataRoot.path
        env["CONTAINER_INSTALL_ROOT"] = root?.appendingPathComponent("AppleContainer").path
        env["APPLE_CONTAINER_GUI_VOLUMES"] = storage.appendingPathComponent("Volumes").path
        env["DOCKER_CONFIG"] = storage.appendingPathComponent("docker-config").path
        return env
    }

    func verify(_ root: URL) throws {
        let manifest = try manifest(at: root)
        let required = ["AppleContainer/bin/container", "AppleContainer/bin/container-apiserver", "Tools/docker", "Tools/socktainer", "Tools/cli-plugins/docker-compose", "Boot/vmlinux", "Boot/vminit.tar", "Boot/builder.tar"]
        guard required.allSatisfy({ manifest.files[$0] != nil }) else { throw DockerAPIError(message: "Runtime package is incomplete") }
        for path in manifest.files.keys {
            try verifyFile(path, in: root, manifest: manifest)
        }
    }

    func verifyFile(_ path: String, in root: URL, manifest: RuntimeManifest) throws {
        guard let digest = manifest.files[path] else { throw DockerAPIError(message: "Invalid runtime path: " + path) }
        try verifyFile(path, in: root, expected: digest)
    }

    private func verifyFile(_ path: String, in root: URL, expected digest: String) throws {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.split(separator: "/").contains(".."),
              digest.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil else {
            throw DockerAPIError(message: "Invalid runtime path or checksum: " + path)
        }
        let url = root.appendingPathComponent(path)
        guard url.resolvingSymlinksInPath().path.hasPrefix(root.resolvingSymlinksInPath().path + "/") else {
            throw DockerAPIError(message: "Runtime file escapes its package: " + path)
        }
        let descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { throw DockerAPIError(message: "Cannot open runtime file: " + path) }
        var details = stat()
        guard fstat(descriptor, &details) == 0, (details.st_mode & S_IFMT) == S_IFREG else {
            Darwin.close(descriptor)
            throw DockerAPIError(message: "Runtime file is not a regular file: " + path)
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var hash = SHA256()
        while let data = try handle.read(upToCount: 1024 * 1024), !data.isEmpty { hash.update(data: data) }
        let actual = hash.finalize().map { String(format: "%02x", $0) }.joined()
        guard actual == digest else { throw DockerAPIError(message: "Runtime checksum mismatch: " + path) }
    }

    func verifyPayload() throws {
        if FileManager.default.fileExists(atPath: payload.appendingPathComponent("runtime.zip").path) {
            let expected = try String(contentsOf: payload.appendingPathComponent("archive.sha256"), encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            try verifyFile("runtime.zip", in: payload, expected: expected)
            _ = try manifest()
        } else {
            try verify(payload)
        }
    }

    func stagePayload(at stage: URL) async throws {
        try verifyPayload()
        let fm = FileManager.default
        if fm.fileExists(atPath: payload.appendingPathComponent("runtime.zip").path) {
            try fm.createDirectory(at: stage, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            let result = await LocalCommand.run(URL(fileURLWithPath: "/usr/bin/ditto"),
                                               ["-x", "-k", payload.appendingPathComponent("runtime.zip").path, stage.path],
                                               timeout: 300)
            guard result.code == 0 else { throw DockerAPIError(message: "Cannot unpack bundled runtime: " + result.error) }
        } else {
            try fm.copyItem(at: payload, to: stage)
        }
        try verifyInstalled(stage)
    }

    func verifyInstalled(_ root: URL) throws {
        guard try Data(contentsOf: root.appendingPathComponent("manifest.json")) == Data(contentsOf: payload.appendingPathComponent("manifest.json")) else {
            throw DockerAPIError(message: "The installed runtime manifest has changed. Reinstall the bundled runtime.")
        }
        try verify(root)
    }

    func command(_ root: URL, _ arguments: [String], timeout: TimeInterval = 120) async -> LocalCommandResult {
        do { try verifyFile("AppleContainer/bin/container", in: root, manifest: manifest()) }
        catch { return LocalCommandResult(code: -1, output: "", error: error.localizedDescription) }
        return await LocalCommand.run(root.appendingPathComponent("AppleContainer/bin/container"), arguments, environment: environment(root: root), timeout: timeout)
    }

    func start(_ root: URL) async throws {
        try verifyInstalled(root)
        let domain = "gui/\(getuid())"
        let service = domain + "/com.apple.container.apiserver"
        let active = await LocalCommand.run(URL(fileURLWithPath: "/bin/launchctl"), ["print", service])
        let executable = root.appendingPathComponent("AppleContainer/bin/container-apiserver").path
        if active.code == 0 {
            guard active.output.contains("program = " + executable + "\n") else {
                throw DockerAPIError(message: "Another Apple Container installation is running. Stop its container system before starting the bundled runtime.")
            }
        } else {
            let directory = dataRoot.appendingPathComponent("apiserver")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let plist = directory.appendingPathComponent("apiserver.plist")
            let value: [String: Any] = ["Label": "com.apple.container.apiserver", "ProgramArguments": [executable, "start"], "EnvironmentVariables": environment(root: root), "LimitLoadToSessionType": ["Aqua", "Background", "System"], "RunAtLoad": true, "MachServices": ["com.apple.container.apiserver": true]]
            try PropertyListSerialization.data(fromPropertyList: value, format: .xml, options: 0).write(to: plist, options: .atomic)
            let result = await LocalCommand.run(URL(fileURLWithPath: "/bin/launchctl"), ["bootstrap", domain, plist.path])
            guard result.code == 0 else { throw DockerAPIError(message: "Cannot start bundled Apple Container: " + result.error) }
        }
        for _ in 0..<30 {
            let health = await command(root, ["list", "--format", "json"], timeout: 5)
            if health.code == 0 { return }
            try await Task.sleep(for: .seconds(1))
        }
        throw DockerAPIError(message: "Bundled Apple Container did not become ready")
    }

    func install(progress: @Sendable (String) async -> Void) async throws {
        let fm = FileManager.default
        try fm.createDirectory(at: storage, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let lock = Darwin.open(storage.appendingPathComponent("runtime-install.lock").path, O_CREAT | O_RDWR, 0o600)
        guard lock >= 0 else { throw DockerAPIError(message: "Cannot open runtime installation lock") }
        defer { Darwin.close(lock) }
        guard flock(lock, LOCK_EX | LOCK_NB) == 0 else { throw DockerAPIError(message: "Runtime installation is already in progress in another app instance") }
        defer { flock(lock, LOCK_UN) }
        await progress("Verifying bundled components")
        try verifyPayload()
        let info = try manifest()
        let runtimes = storage.appendingPathComponent("Runtimes")
        try fm.createDirectory(at: runtimes, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let target = runtimes.appendingPathComponent(info.bundleVersion)
        if !fm.fileExists(atPath: target.path) {
            await progress("Copying Apple Container, Docker CLI, Compose and Socktainer")
            let stage = runtimes.appendingPathComponent(".install-" + UUID().uuidString)
            defer { try? fm.removeItem(at: stage) }
            try await stagePayload(at: stage)
            try fm.moveItem(at: stage, to: target)
        } else {
            guard try Data(contentsOf: target.appendingPathComponent("manifest.json")) == Data(contentsOf: payload.appendingPathComponent("manifest.json")) else {
                throw DockerAPIError(message: "Installed runtime version does not match this app package")
            }
            try verify(target)
        }
        let pending = storage.appendingPathComponent("runtime-resume.json")
        var resume = (try? JSONDecoder().decode([String].self, from: Data(contentsOf: pending))) ?? []
        let existing = await LocalCommand.run(URL(fileURLWithPath: "/bin/launchctl"), ["print", "gui/\(getuid())/com.apple.container.apiserver"])
        let expected = target.appendingPathComponent("AppleContainer/bin/container-apiserver").path
        let legacy = dataRoot.appendingPathComponent("volumes")
        let volumeFolders = (try? fm.contentsOfDirectory(at: legacy, includingPropertiesForKeys: nil)) ?? []
        let needsMigration = volumeFolders.filter { !$0.lastPathComponent.hasPrefix(".") }.contains { !fm.fileExists(atPath: storage.appendingPathComponent("Volumes/.legacy/" + $0.lastPathComponent).path) }
        if needsMigration || (existing.code == 0 && !existing.output.contains("program = " + expected + "\n")) {
            if existing.code == 0 {
                let list = await command(target, ["list", "--all", "--format", "json"])
                guard list.code == 0, let data = list.output.data(using: .utf8), let containers = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                    throw DockerAPIError(message: "Cannot inspect containers before volume migration: " + list.error)
                }
                let running = containers.filter { ($0["status"] as? [String: Any])?["state"] as? String == "running" }.compactMap { $0["id"] as? String }
                resume = Array(Set(resume + running)).sorted()
                try JSONEncoder().encode(resume).write(to: pending, options: .atomic)
                for id in running {
                    await progress("Stopping " + id + " for runtime setup")
                    let stop = await command(target, ["stop", id])
                    if stop.code != 0 {
                        let directory = dataRoot.appendingPathComponent("containers").appendingPathComponent(id)
                        guard !fm.fileExists(atPath: directory.path), stop.error.contains("Code=260"), stop.error.contains("config.json") else {
                            throw DockerAPIError(message: stop.error)
                        }
                        let cleanup = await command(target, ["delete", "--force", id])
                        guard cleanup.code == 0 else { throw DockerAPIError(message: cleanup.error) }
                        resume.removeAll { $0 == id }
                        try JSONEncoder().encode(resume).write(to: pending, options: .atomic)
                    }
                }
                let stop = await command(target, ["system", "stop"])
                guard stop.code == 0 else { throw DockerAPIError(message: stop.error) }
            }
            if needsMigration {
                await progress("Migrating disk volumes to shared VirtioFS directories")
                let migration = await LocalCommand.run(target.appendingPathComponent("Tools/socktainer"), ["--gui-migrate-volumes"], environment: environment(root: target), timeout: 3600)
                guard migration.code == 0 else { throw DockerAPIError(message: migration.error + "\n" + migration.output) }
            }
        }
        await progress("Starting bundled Apple Container " + info.appleContainerVersion)
        try await start(target)
        for (file, name) in [("vminit.tar", "VM base image"), ("builder.tar", "BuildKit image")] {
            await progress("Installing " + name + " from the app")
            let result = await command(target, ["image", "load", "--input", target.appendingPathComponent("Boot/" + file).path], timeout: 600)
            guard result.code == 0 else { throw DockerAPIError(message: name + ": " + result.error) }
        }
        await progress("Configuring bundled Linux kernel")
        let kernel = await command(target, ["system", "kernel", "set", "--binary", target.appendingPathComponent("Boot/vmlinux").path, "--arch", "arm64", "--force"])
        guard kernel.code == 0 else { throw DockerAPIError(message: kernel.error) }
        let config = storage.appendingPathComponent("docker-config")
        try fm.createDirectory(at: config, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let settings: [String: Any] = ["cliPluginsExtraDirs": [target.appendingPathComponent("Tools/cli-plugins").path]]
        try JSONSerialization.data(withJSONObject: settings).write(to: config.appendingPathComponent("config.json"), options: .atomic)
        try Data(contentsOf: payload.appendingPathComponent("manifest.json")).write(to: target.appendingPathComponent("ready.json"), options: .atomic)
        await progress("Runtime installed locally")
    }

    func restoreContainers(progress: @Sendable (String) async -> Void) async throws {
        guard let root = installedRoot else { throw DockerAPIError(message: "Install the runtime before restoring containers") }
        let pending = storage.appendingPathComponent("runtime-resume.json")
        guard FileManager.default.fileExists(atPath: pending.path) else { return }
        let resume = try JSONDecoder().decode([String].self, from: Data(contentsOf: pending))
        let list = await command(root, ["list", "--all", "--format", "json"])
        guard list.code == 0, let data = list.output.data(using: .utf8), let containers = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw DockerAPIError(message: "Cannot inspect containers before restoring: " + list.error)
        }
        let running = Set(containers.filter { ($0["status"] as? [String: Any])?["state"] as? String == "running" }.compactMap { $0["id"] as? String })
        let available = Set(containers.compactMap { $0["id"] as? String })
        for id in resume where available.contains(id) && !running.contains(id) {
            await progress("Restoring " + id)
            let start = await command(root, ["start", id])
            guard start.code == 0 else { throw DockerAPIError(message: "Runtime installed, but container restart failed: " + id + "\n" + start.error) }
        }
        try FileManager.default.removeItem(at: pending)
    }
}
