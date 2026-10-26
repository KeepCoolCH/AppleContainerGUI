import AppKit
import Foundation
import Observation
import ServiceManagement
import Darwin

@MainActor
@Observable
final class DockerSocketService {
    static let shared = DockerSocketService()

    var isRunning = false
    var isBusy = false
    var status = "Stopped"
    var lastError = ""
    var compatibilityWarning = ""
    var diagnosticOutput = ""
    var runtimeVersion = ""
    var apiVersion = ""
    var customRuntime = false
    var socketPath = ""
    var systemSocketTarget = ""
    var startsWithApp: Bool {
        didSet { defaults.set(startsWithApp, forKey: "dockerBridgeStartsWithApp") }
    }
    private var process: Process?
    private var processLog: FileHandle?
    private var monitor: Task<Void, Never>?
    private var restartAttempts = 0
    private var stopping = false
    private var ownedSocketIdentity: (dev_t, ino_t)?
    private let fileManager = FileManager.default
    private let defaults: UserDefaults
    private let storageRoot: URL?
    private let runtime: ManagedRuntime

    var isManaged: Bool { process != nil }
    var managedProcessIdentifier: Int32? { process?.processIdentifier }
    var dockerHost: String { "unix://" + socketPath }
    var connectionCommand: String { Self.shellQuote(runtime.executable("Tools/docker")?.path ?? "docker") + " --config " + Self.shellQuote(runtime.storage.appendingPathComponent("docker-config").path) + " --host " + Self.shellQuote(dockerHost) + " ps" }
    var logURL: URL { supportDirectory.appendingPathComponent("socktainer.log") }
    var supportDirectory: URL {
        storageRoot ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/AppleContainerGUI")
    }
    var privateSocket: String { storageRoot?.appendingPathComponent("sockets/docker.sock").path ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent(".applecontainergui/docker.sock").path }
    var standardSocket: String { fileManager.homeDirectoryForCurrentUser.appendingPathComponent(".socktainer/container.sock").path }
    var launchAtLogin: Bool { SMAppService.mainApp.status == .enabled }

    init(defaults: UserDefaults = .standard, storageRoot: URL? = nil, runtime: ManagedRuntime = .shared) {
        self.defaults = defaults
        self.storageRoot = storageRoot
        self.runtime = runtime
        startsWithApp = defaults.bool(forKey: "dockerBridgeStartsWithApp")
        socketPath = fileManager.homeDirectoryForCurrentUser.appendingPathComponent(".applecontainergui/docker.sock").path
        refreshSystemSocket()
    }

    func executableURL() -> URL? {
        runtime.executable("Tools/socktainer")
    }

    func startup() async {
        if startsWithApp { await start() }
    }

    func start(isAutomatic: Bool = false) async {
        guard !isBusy, process == nil else { return }
        if !isAutomatic { restartAttempts = 0 }
        compatibilityWarning = ""
        isBusy = true
        stopping = false
        lastError = ""
        status = "Checking runtime"
        defer { isBusy = false }
        guard let executable = executableURL() else {
            fail("Install the bundled runtime in the app first.")
            return
        }
        guard let root = runtime.installedRoot else { fail("Install the bundled runtime first."); return }
        do { try await runtime.start(root) }
        catch { fail(error.localizedDescription); return }
        let version = await LocalCommand.run(executable, ["--version"], environment: runtime.environment())
        guard version.code == 0, version.output.lowercased().contains("socktainer") else {
            fail("Cannot execute Socktainer: " + version.error)
            return
        }
        guard !stopping else { return }
        runtimeVersion = version.output.trimmingCharacters(in: .whitespacesAndNewlines)
        customRuntime = version.output.contains("acgui.")
        socketPath = privateSocket
        guard socketPath.utf8.count < 104 else {
            fail("The Unix socket path exceeds the macOS limit of 103 bytes.")
            return
        }
        let api = DockerAPIClient(socketPath: socketPath)
        if (try? await api.ping()) != nil {
            isRunning = true
            status = "Connected to existing service"
            await refreshVersion()
            beginMonitoring()
            return
        }
        if fileManager.fileExists(atPath: socketPath) || (try? fileManager.destinationOfSymbolicLink(atPath: socketPath)) != nil {
            do { try DockerSocketLink.removeStaleSocket(at: socketPath) }
            catch { fail(error.localizedDescription); return }
        }
        do {
            try fileManager.createDirectory(at: supportDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let socketDirectory = URL(fileURLWithPath: socketPath).deletingLastPathComponent()
            if let values = try? socketDirectory.resourceValues(forKeys: [.isSymbolicLinkKey]), values.isSymbolicLink == true {
                throw DockerAPIError(message: "The socket directory must not be a symbolic link")
            }
            try fileManager.createDirectory(at: socketDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: socketDirectory.path)
            if fileManager.fileExists(atPath: logURL.path) {
                let previous = supportDirectory.appendingPathComponent("socktainer.previous.log")
                try? fileManager.removeItem(at: previous)
                try fileManager.moveItem(at: logURL, to: previous)
            }
            fileManager.createFile(atPath: logURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
            let log = try FileHandle(forWritingTo: logURL)
            let child = Process()
            child.executableURL = executable
            child.arguments = ["--no-auto-start", "--no-docker-context", "--volume-sync=fsync"]
            var environment = runtime.environment()
            if customRuntime { environment["APPLE_CONTAINER_GUI_SOCKET"] = socketPath }
            child.environment = environment
            child.standardInput = FileHandle.nullDevice
            child.standardOutput = log
            child.standardError = log
            try child.run()
            process = child
            processLog = log
            status = "Starting Docker API"
            for _ in 0..<45 {
                guard !stopping else { throw CancellationError() }
                try recordOwnedSocket()
                guard child.isRunning else {
                    throw DockerAPIError(message: "Socktainer exited with code \(child.terminationStatus). " + readLogTail())
                }
                if (try? await api.ping()) != nil {
                    isRunning = true
                    status = "Running"
                    compatibilityWarning = readLogTail().split(separator: "\n")
                        .first(where: { $0.contains("Apple Container version mismatch:") })
                        .map { String($0).components(separatedBy: ". This version")[0].trimmingCharacters(in: .whitespaces) } ?? ""
                    await refreshVersion()
                    beginMonitoring()
                    refreshSystemSocket()
                    return
                }
                try await Task.sleep(for: .seconds(1))
            }
            throw DockerAPIError(message: "Socktainer did not become ready. " + readLogTail())
        } catch {
            await stopProcess()
            fail(error.localizedDescription)
        }
    }

    func stop() async {
        guard !isBusy else { return }
        stopping = true
        monitor?.cancel()
        monitor = nil
        guard process != nil else {
            status = "External service is not managed by this app"
            return
        }
        isBusy = true
        await stopProcess()
        isRunning = false
        status = "Stopped"
        restartAttempts = 0
        isBusy = false
    }

    private func stopProcess() async {
        guard let child = process else { return }
        if child.isRunning {
            child.terminate()
            for _ in 0..<50 {
                if !child.isRunning { break }
                try? await Task.sleep(for: .milliseconds(100))
            }
            if child.isRunning { Darwin.kill(child.processIdentifier, SIGKILL) }
            while child.isRunning { try? await Task.sleep(for: .milliseconds(50)) }
        }
        process = nil
        try? processLog?.close()
        processLog = nil
        removeOwnedSocket()
    }

    func prepareForInstallation() async throws {
        await shutdown()
        try DockerSocketLink.removeStaleSocket(at: privateSocket)
    }

    func shutdown() async {
        stopping = true
        monitor?.cancel()
        monitor = nil
        await stopProcess()
        isRunning = false
    }

    func terminateForAppExit() {
        stopping = true
        monitor?.cancel()
        if let child = process, child.isRunning { child.terminate() }
    }

    private func recordOwnedSocket() throws {
        guard ownedSocketIdentity == nil else { return }
        var details = stat()
        if lstat(socketPath, &details) == 0,
           (details.st_mode & S_IFMT) == S_IFSOCK,
           details.st_uid == getuid() {
            ownedSocketIdentity = (details.st_dev, details.st_ino)
            guard chmod(socketPath, 0o600) == 0 else {
                throw DockerAPIError(message: "Cannot restrict Docker socket access to the current user")
            }
        }
    }

    private func removeOwnedSocket() {
        defer { ownedSocketIdentity = nil }
        guard let identity = ownedSocketIdentity else { return }
        var details = stat()
        if lstat(socketPath, &details) == 0,
           (details.st_mode & S_IFMT) == S_IFSOCK,
           details.st_uid == getuid(),
           details.st_dev == identity.0, details.st_ino == identity.1 {
            try? fileManager.removeItem(atPath: socketPath)
        }
    }

    private func beginMonitoring() {
        monitor?.cancel()
        monitor = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(5)) } catch { return }
                guard let self, !self.stopping else { return }
                if let child = self.process, !child.isRunning {
                    await self.stopProcess()
                    self.isRunning = false
                    guard self.restartAttempts < 3 else {
                        self.fail("Socktainer repeatedly exited. Check the runtime log before restarting.")
                        return
                    }
                    self.restartAttempts += 1
                    self.status = "Restarting Socktainer (\(self.restartAttempts)/3)"
                    await self.start(isAutomatic: true)
                    return
                }
                do {
                    try await DockerAPIClient(socketPath: self.socketPath).ping()
                    self.isRunning = true
                    self.status = self.isManaged ? "Running" : "Connected to existing service"
                } catch {
                    self.isRunning = false
                    self.status = "Docker API is not responding"
                }
            }
        }
    }

    func refreshVersion() async {
        do {
            let result = try await DockerAPIClient(socketPath: socketPath).request(path: "/version")
            let version = try result.decode(DockerVersion.self)
            apiVersion = version.ApiVersion
        } catch { lastError = error.localizedDescription }
    }

    func diagnose() async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        var lines = [runtimeVersion, "Socket: \(socketPath)"]
        if let root = runtime.installedRoot {
            let appleVersion = await runtime.command(root, ["--version"])
            lines.append(appleVersion.output.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        if let docker = runtime.executable("Tools/docker") {
            let version = await LocalCommand.run(docker, ["--version"], environment: runtime.environment())
            lines.append("Docker CLI: \(docker.path)")
            lines.append(version.code == 0 ? version.output.trimmingCharacters(in: .whitespacesAndNewlines) : version.error)
        }
        for path in ["/_ping", "/version", "/info", "/containers/json?all=true", "/images/json", "/volumes", "/networks"] {
            do {
                let response = try await DockerAPIClient(socketPath: socketPath).request(path: path)
                lines.append("PASS \(path): HTTP \(response.status)")
            } catch { lines.append("FAIL \(path): \(error.localizedDescription)") }
        }
        diagnosticOutput = lines.joined(separator: "\n")
        refreshSystemSocket()
    }

    func runDocker(_ arguments: [String], timeout: TimeInterval = 300) async -> LocalCommandResult {
        guard let executable = runtime.executable("Tools/docker") else {
            return LocalCommandResult(code: -1, output: "", error: "Install the bundled runtime in the app first.")
        }
        var environment = runtime.environment()
        environment.removeValue(forKey: "DOCKER_CONTEXT")
        environment.removeValue(forKey: "DOCKER_TLS_VERIFY")
        environment.removeValue(forKey: "DOCKER_CERT_PATH")
        environment["DOCKER_HOST"] = dockerHost
        return await LocalCommand.run(executable, ["--host", dockerHost] + arguments, environment: environment, timeout: timeout)
    }

    func createContext() async {
        guard !isBusy, isRunning else { return }
        guard let docker = runtime.executable("Tools/docker") else {
            fail("Install the bundled runtime in the app first.")
            return
        }
        isBusy = true
        defer { isBusy = false }
        let inspect = await LocalCommand.run(docker, ["context", "inspect", "apple-container-gui"], environment: runtime.environment())
        if inspect.code == 0 {
            let contexts = (try? JSONSerialization.jsonObject(with: Data(inspect.output.utf8))) as? [[String: Any]]
            let endpoints = contexts?.first?["Endpoints"] as? [String: Any]
            let endpoint = endpoints?["docker"] as? [String: Any]
            guard endpoint?["Host"] as? String == dockerHost else {
                fail("The apple-container-gui context already points to another endpoint. Rename or remove that context first.")
                return
            }
            status = "Docker context is ready"
            return
        }
        let result = await LocalCommand.run(docker, ["context", "create", "apple-container-gui", "--description", "AppleContainerGUI Socktainer", "--docker", "host=" + dockerHost], environment: runtime.environment())
        if result.code == 0 { status = "Context created: docker --context apple-container-gui ps" }
        else { fail(result.error) }
    }

    func refreshSystemSocket() {
        let target = try? fileManager.destinationOfSymbolicLink(atPath: "/var/run/docker.sock")
        systemSocketTarget = target ?? (fileManager.fileExists(atPath: "/var/run/docker.sock") ? "Existing socket or file" : "Not configured")
    }

    func configureSystemSocket(restore: Bool = false) async {
        guard !isBusy, restore || isRunning else { return }
        isBusy = true
        defer { isBusy = false; refreshSystemSocket() }
        let command = DockerSocketLink.command(target: socketPath, restore: restore)
        let script = "do shell script \(Self.appleScriptQuote(command)) with administrator privileges"
        let result = await LocalCommand.run(URL(fileURLWithPath: "/usr/bin/osascript"), ["-e", script], timeout: 120)
        if result.code == 0 { status = restore ? "Previous Docker socket restored" : "/var/run/docker.sock configured" }
        else { fail(result.error) }
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
        } catch { fail(error.localizedDescription) }
    }

    func readLogTail() -> String {
        guard let file = try? FileHandle(forReadingFrom: logURL) else { return "" }
        defer { try? file.close() }
        let end = (try? file.seekToEnd()) ?? 0
        try? file.seek(toOffset: end > 12000 ? end - 12000 : 0)
        return String(decoding: (try? file.readToEnd()) ?? Data(), as: UTF8.self)
    }

    private func fail(_ message: String) {
        lastError = message
        status = "Action failed"
    }

    static func dockerExecutable() -> URL? {
        ManagedRuntime.shared.executable("Tools/docker")
    }

    static func shellQuote(_ value: String) -> String { DockerSocketLink.quote(value) }
    static func appleScriptQuote(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"").replacingOccurrences(of: "\n", with: "\\n") + "\""
    }
}
