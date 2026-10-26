import Foundation
import Observation
import SwiftUI
import AppKit

struct ContainerListItem: Identifiable, Hashable {
    let id: String
    let name: String
    let image: String
    let state: String
    let ports: [ContainerPortMapping]
    let raw: [String: JSONValue]
}

extension ContainerListItem {
    var portsDisplay: String {
        guard !ports.isEmpty else { return "-" }
        return ports
            .map { mapping in
                let host = mapping.hostPort.isEmpty ? "?" : mapping.hostPort
                return host
            }
            .joined(separator: ", ")
    }

    var portsDisplayFull: String {
        guard !ports.isEmpty else { return "-" }
        return ports
            .map { mapping in
                let host = mapping.hostPort.isEmpty ? "?" : mapping.hostPort
                let container = mapping.containerPort.isEmpty ? "?" : mapping.containerPort
                return "\(host):\(container)"
            }
            .joined(separator: ", ")
    }

    var firstPortURL: URL? {
        guard let first = ports.first, !first.hostPort.isEmpty else { return nil }
        return URL(string: "http://localhost:\(first.hostPort)")
    }

    var portLinks: [ContainerPortLink] {
        ports.compactMap { mapping in
            guard !mapping.hostPort.isEmpty else { return nil }
            let host = mapping.hostPort
            let container = mapping.containerPort.isEmpty ? "?" : mapping.containerPort
            let label = "\(host):\(container)"
            guard let url = URL(string: "http://localhost:\(host)") else { return nil }
            return ContainerPortLink(id: mapping.id, label: label, url: url)
        }
    }
}

struct ContainerPortMapping: Identifiable, Hashable {
    let id: String
    let hostPort: String
    let containerPort: String
    let hostAddress: String
}

struct ContainerPortLink: Identifiable, Hashable {
    let id: String
    let label: String
    let url: URL
}

struct ImageListItem: Identifiable, Hashable {
    var id: String { reference.isEmpty ? digest : reference }
    let digest: String
    let reference: String
    let size: String
    let raw: [String: JSONValue]
}

struct VolumeListItem: Identifiable, Hashable {
    let id: String
    let name: String
    let driver: String
    let raw: [String: JSONValue]
}

struct NetworkListItem: Identifiable, Hashable {
    let id: String
    let name: String
    let driver: String
    let raw: [String: JSONValue]
}

struct SnapshotItem: Identifiable, Hashable {
    let id: String
    let name: String
    let modifiedAt: Date
    let path: String
    let size: String
}

struct LogEntry: Identifiable, Hashable {
    let id: UUID
    let timestamp: Date
    let command: String
    let output: String
    let error: String
}

struct RunPortMapping: Identifiable, Hashable {
    let id: UUID
    var hostPort: String
    var containerPort: String
}

struct RunVolumeMapping: Identifiable, Hashable {
    let id: UUID
    var hostPath: String
    var containerPath: String
    var readOnly: Bool
}

struct RunEnvVar: Identifiable, Hashable {
    let id: UUID
    var key: String
    var value: String
}

struct RunImageConfig: Hashable {
    var name: String
    var detach: Bool
    var cpus: String
    var memory: String
    var overrideEntrypoint: Bool
    var customEntrypointPath: String
    var ports: [RunPortMapping]
    var volumes: [RunVolumeMapping]
    var environment: [RunEnvVar]
    var command: String
    var extraArgs: String
}

struct DockerHubRepository: Identifiable, Hashable, Decodable {
    let registryId: Int?
    let name: String
    let namespace: String?
    let description: String?
    let star_count: Int?
    let pull_count: Int?
    let is_official: Bool?

    var id: String { "\(namespace ?? "library")/\(name)" }

    enum CodingKeys: String, CodingKey {
        case registryId = "id"
        case name
        case namespace
        case description
        case star_count
        case pull_count
        case is_official
        case repo_name
        case short_description
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        registryId = try? container.decode(Int.self, forKey: .registryId)
        star_count = try? container.decode(Int.self, forKey: .star_count)
        pull_count = try? container.decode(Int.self, forKey: .pull_count)
        is_official = try? container.decode(Bool.self, forKey: .is_official)

        let repoName = try? container.decode(String.self, forKey: .repo_name)
        let directName = try? container.decode(String.self, forKey: .name)
        let directNamespace = try? container.decode(String.self, forKey: .namespace)

        if let repoName, repoName.contains("/") {
            let parts = repoName.split(separator: "/", maxSplits: 1).map(String.init)
            namespace = parts.first
            name = parts.count > 1 ? parts[1] : repoName
        } else {
            name = directName ?? repoName ?? "unknown"
            namespace = directNamespace
        }

        if let description = try? container.decode(String.self, forKey: .description) {
            self.description = description
        } else if let short = try? container.decode(String.self, forKey: .short_description) {
            self.description = short
        } else {
            self.description = nil
        }
    }
}

@MainActor
@Observable
final class ContainerViewModel {
    var containers: [ContainerListItem] = []
    var images: [ImageListItem] = []
    var volumes: [VolumeListItem] = []
    var networks: [NetworkListItem] = []
    var snapshots: [SnapshotItem] = []

    var isLoading: Bool = false
    var isServiceRunning: Bool = false
    var lastCommand: String = ""
    var lastOutput: String = ""
    var lastError: String = ""
    var lastRawError: String = ""
    var logEntries: [LogEntry] = []

    var searchQuery: String = ""
    var dockerHubResults: [DockerHubRepository] = []
    var dockerHubError: String = ""
    var dockerHubInfo: String = ""
    var selectedRegistry: RegistryOption = .dockerHub
    var customRegistryHost: String = ""
    var isPullingImage: Bool = false
    var pullStatusText: String = ""
    var isRunningCommand: Bool = false
    var commandStatusText: String = ""
    var lastRunContainerName: String = ""
    var searchPlaceholder: String {
        switch selectedRegistry {
        case .dockerHub:
            return "imagename or owner/image:tag"
        case .github:
            return "owner/image:tag"
        case .quay:
            return "owner/image:tag"
        case .gitlab:
            return "owner/image:tag"
        case .custom:
            return "image:tag"
        }
    }

    func startup() {
        Task(priority: .utility) {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(150))
            if !isContainerAvailable() {
                return
            }
            Task(priority: .utility) {
                try? await Task.sleep(for: .milliseconds(200))
                await updateServiceStatus()
            }
            await refreshContainers(updateLastCommand: false, updateLastRunning: false)

            Task(priority: .utility) {
                try? await Task.sleep(for: .milliseconds(350))
                await startAutostartContainersIfNeeded()
                await refreshContainers(updateLastCommand: false, updateLastRunning: true)
            }

            Task(priority: .utility) {
                try? await Task.sleep(for: .milliseconds(300))
                await refreshImages(updateLastCommand: false)
            }
            Task(priority: .utility) {
                try? await Task.sleep(for: .milliseconds(450))
                await refreshVolumes(updateLastCommand: false)
            }
            Task(priority: .utility) {
                try? await Task.sleep(for: .milliseconds(600))
                await refreshNetworks(updateLastCommand: false)
            }
        }
    }

    @ObservationIgnored private var refreshingResources: Set<String> = []
    @ObservationIgnored private var isLiveRefreshing = false

    func observeResources() async {
        while !Task.isCancelled {
            do { try await Task.sleep(for: .seconds(3)) } catch { return }
            guard !RuntimeInstaller.shared.isInstalling,
                  RuntimeInstaller.shared.isInstalled,
                  DockerSocketService.shared.isRunning,
                  !isLoading, !isDeletingResource, !isRunningCommand,
                  !isPullingImage, refreshingResources.isEmpty else { continue }
            isLiveRefreshing = true
            await refreshContainers(updateLastCommand: false, updateLastRunning: false)
            if !Task.isCancelled { await refreshImages(updateLastCommand: false) }
            if !Task.isCancelled { await refreshVolumes(updateLastCommand: false) }
            if !Task.isCancelled { await refreshNetworks(updateLastCommand: false) }
            isLiveRefreshing = false
        }
    }

    func refreshAll() async {
        isLoading = true
        defer { isLoading = false }
        await updateServiceStatus()
        await refreshContainers(updateLastCommand: false)
        await refreshImages(updateLastCommand: false)
        await refreshVolumes(updateLastCommand: false)
        await refreshNetworks(updateLastCommand: false)
        refreshSnapshots()
    }

    func startAllServices() async {
        if await ensureSystemStarted() { await DockerSocketService.shared.start() }
        await updateServiceStatus()
    }

    func clearLogs() {
        logEntries.removeAll()
    }

    private func appendLog(command: String, output: String, error: String) {
        let entry = LogEntry(id: UUID(), timestamp: Date(), command: command, output: output, error: error)
        logEntries.append(entry)
        if logEntries.count > 1000 {
            logEntries.removeFirst(logEntries.count - 1000)
        }
    }

    private nonisolated static func prettyPrintedJSONIfPossible(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("{") || trimmed.hasPrefix("[") else { return text }
        guard let data = trimmed.data(using: .utf8) else { return text }
        guard let object = try? JSONSerialization.jsonObject(with: data) else { return text }
        guard let pretty = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]) else {
            return text
        }
        return String(data: pretty, encoding: .utf8) ?? text
    }

    private nonisolated static func decodeJSONObjectArray(_ text: String) async -> [[String: JSONValue]]? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                guard let data = text.data(using: .utf8),
                      let decoded = try? JSONDecoder().decode([JSONValue].self, from: data) else {
                    continuation.resume(returning: nil)
                    return
                }
                let objects = decoded.compactMap { value -> [String: JSONValue]? in
                    if case .object(let object) = value { return object }
                    return nil
                }
                continuation.resume(returning: objects)
            }
        }
    }

    private func ensureSystemStarted() async -> Bool {
        let first = await ContainerCLI.shared.run(["system", "start"])
        lastCommand = "container system start"
        lastOutput = first.stdout
        lastRawError = first.stderr
        lastError = userFacingError(for: first)
        appendLog(command: lastCommand, output: lastOutput, error: lastRawError)

        if await waitForSystemRunning(timeoutSeconds: 6) {
            lastOutput = [lastOutput, "Service started."].filter { !$0.isEmpty }.joined(separator: "\n")
            appendLog(command: lastCommand, output: lastOutput, error: lastRawError)
            return true
        }

        try? await Task.sleep(nanoseconds: 2_000_000_000)
        let second = await ContainerCLI.shared.run(["system", "start"])
        lastCommand = "container system start"
        lastOutput = second.stdout
        lastRawError = second.stderr
        lastError = userFacingError(for: second)
        appendLog(command: lastCommand, output: lastOutput, error: lastRawError)

        let started = await waitForSystemRunning(timeoutSeconds: 6)
        if started {
            lastOutput = [lastOutput, "Service started."].filter { !$0.isEmpty }.joined(separator: "\n")
            appendLog(command: lastCommand, output: lastOutput, error: lastRawError)
        }
        return started
    }

    private func waitForSystemRunning(timeoutSeconds: Int) async -> Bool {
        let maxAttempts = max(1, timeoutSeconds * 2)
        for _ in 0..<maxAttempts {
            let status = await ContainerCLI.shared.run(["system", "status"])
            if ContainerSystemStatus.isRunning(stdout: status.stdout, stderr: status.stderr, exitCode: status.exitCode) {
                isServiceRunning = true
                return true
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        isServiceRunning = false
        return false
    }

    private func updateServiceStatus() async {
        let status = await ContainerCLI.shared.run(["system", "status"])
        isServiceRunning = ContainerSystemStatus.isRunning(stdout: status.stdout, stderr: status.stderr, exitCode: status.exitCode)
    }

    func stopAllServices() async {
        await DockerSocketService.shared.stop()
        await runSimpleCommand(args: ["system", "stop"], label: "container system stop")
        lastOutput = [lastOutput, "Service stopped."].filter { !$0.isEmpty }.joined(separator: "\n")
        appendLog(command: lastCommand, output: lastOutput, error: lastRawError)
        await updateServiceStatus()
    }

    func pruneInactiveContainers() async {
        await runSimpleCommand(args: ["prune"], label: "container prune")
        await refreshContainers(updateLastCommand: false)
        await cleanupEntrypointScripts(remainingContainers: containers)
    }

    func refreshContainers(updateLastCommand: Bool = true, updateLastRunning: Bool = true) async {
        guard refreshingResources.insert("containers").inserted else { return }
        defer { refreshingResources.remove("containers") }
        let handle: ([[String: JSONValue]]) -> Void = { [self] objects in
            let visible = objects.filter { object in
                guard case .object(let configuration) = object["configuration"],
                      case .object(let labels) = configuration["labels"] else { return true }
                return labels["socktainer.role"] != .string("dns")
            }.sorted { lhs, rhs in
                @MainActor func key(_ value: [String: JSONValue]) -> String {
                    if case .object(let config) = value["configuration"] { return config.stringValue(for: ["id", "name"]) ?? "" }
                    return value.stringValue(for: ["id", "name"]) ?? ""
                }
                return key(lhs) < key(rhs)
            }
            guard self.containers.map(\.raw) != visible else { return }
            self.containers = visible.map { object in
                let configurationObject: [String: JSONValue]
                if case .object(let config) = object["configuration"] {
                    configurationObject = config
                } else {
                    configurationObject = [:]
                }

                let name = configurationObject.stringValue(for: ["id", "name", "Name"])
                    ?? object.stringValue(for: ["name", "Name", "names", "Names", "container_name", "containerName", "ContainerName", "id", "ID"])
                    ?? UUID().uuidString
                let id = configurationObject.stringValue(for: ["id", "ID"])
                    ?? object.stringValue(for: ["container_id", "containerID", "id", "ID"])
                    ?? name

                let image: String = {
                    if case .object(let imageObject) = configurationObject["image"] {
                        return imageObject.stringValue(for: ["reference", "name", "Image", "image"]) ?? ""
                    }
                    return configurationObject.stringValue(for: ["image", "Image"])
                        ?? object.stringValue(for: ["image", "Image", "image_name", "ImageName"])
                        ?? ""
                }()
                let ports = parsePorts(from: configurationObject)
                let state: String
                if case .object(let status) = object["status"] {
                    state = status.stringValue(for: ["state", "State"]) ?? ""
                } else {
                    state = object.stringValue(for: ["state", "State", "status", "Status"]) ?? ""
                }
                return ContainerListItem(id: id, name: name, image: image, state: state, ports: ports, raw: object)
            }
        }

        let success = await runListCommand(
            args: ["list", "--all", "--format", "json"],
            commandLabel: "container list --all --format json",
            onSuccess: handle,
            updateLastCommand: updateLastCommand
        )

        if success {
            if !isLiveRefreshing { await cleanupEntrypointScripts(remainingContainers: containers) }
            if updateLastRunning {
                let running = containers
                    .filter { $0.state.lowercased().contains("running") }
                    .map { $0.name.isEmpty ? $0.id : $0.name }
                saveLastRunningContainers(Set(running))
            }
        }
    }

    func refreshImages(updateLastCommand: Bool = true) async {
        guard refreshingResources.insert("images").inserted else { return }
        defer { refreshingResources.remove("images") }
        let handle: ([[String: JSONValue]]) -> Void = { [self] objects in
            let ordered = objects.sorted { lhs, rhs in
                @MainActor func key(_ value: [String: JSONValue]) -> String {
                    if case .object(let config) = value["configuration"] { return config.stringValue(for: ["name"]) ?? "" }
                    return value.stringValue(for: ["reference", "name", "id"]) ?? ""
                }
                return key(lhs) < key(rhs)
            }
            guard self.images.map(\.raw) != ordered else { return }
            self.images = ordered.map { object in
                let configuration: [String: JSONValue]
                if case .object(let value) = object["configuration"] { configuration = value } else { configuration = [:] }
                let reference = configuration.stringValue(for: ["name", "reference"])
                    ?? object.stringValue(for: ["reference", "Reference", "name"]) ?? ""
                let digest = object.stringValue(for: ["digest", "Digest", "id", "ID"]) ?? UUID().uuidString
                let size = imageSizeString(from: object)
                return ImageListItem(digest: digest, reference: reference, size: size, raw: object)
            }
        }

        _ = await runListCommand(
            args: ["image", "list", "--format", "json"],
            commandLabel: "container image list --format json",
            onSuccess: handle,
            updateLastCommand: updateLastCommand
        )
    }

    func refreshVolumes(updateLastCommand: Bool = true) async {
        guard refreshingResources.insert("volumes").inserted else { return }
        defer { refreshingResources.remove("volumes") }
        let bridge = DockerSocketService.shared
        if !bridge.isRunning && !isLiveRefreshing { await bridge.start() }
        guard bridge.isRunning else { if !isLiveRefreshing { lastError = bridge.lastError }; return }
        do {
            let response = try await DockerAPIClient(socketPath: bridge.socketPath).request(path: "/volumes")
            let value = try JSONDecoder().decode(JSONValue.self, from: response.body)
            guard case .object(let object) = value, case .array(let values) = object["Volumes"] else { return }
            let refreshed: [VolumeListItem] = values.compactMap { value in
                guard case .object(let raw) = value, let name = raw.stringValue(for: ["Name"]) else { return nil }
                return VolumeListItem(id: name, name: name, driver: raw.stringValue(for: ["Driver"]) ?? "local", raw: raw)
            }
            let ordered = refreshed.sorted { $0.name < $1.name }
            if volumes != ordered { volumes = ordered }
            if updateLastCommand { lastCommand = "docker volume ls"; lastError = "" }
        } catch { if !isLiveRefreshing { lastError = error.localizedDescription } }
    }

    func refreshNetworks(updateLastCommand: Bool = true) async {
        guard refreshingResources.insert("networks").inserted else { return }
        defer { refreshingResources.remove("networks") }
        let handle: ([[String: JSONValue]]) -> Void = { [self] objects in
            let ordered = objects.sorted { ($0.stringValue(for: ["name", "id"]) ?? "") < ($1.stringValue(for: ["name", "id"]) ?? "") }
            guard self.networks.map(\.raw) != ordered else { return }
            self.networks = ordered.map { object in
                let name = object.stringValue(for: ["name", "Name", "id", "ID"]) ?? UUID().uuidString
                let driver = object.stringValue(for: ["driver", "Driver"]) ?? ""
                return NetworkListItem(id: name, name: name, driver: driver, raw: object)
            }
        }

        _ = await runListCommand(
            args: ["network", "list", "--format", "json"],
            commandLabel: "container network list --format json",
            onSuccess: handle,
            updateLastCommand: updateLastCommand
        )
    }

    func startContainer(_ container: ContainerListItem) async {
        let target = container.name.isEmpty ? container.id : container.name
        await runSimpleCommand(args: ["start", target], label: "container start \(target)")
        await refreshContainers(updateLastCommand: false)
    }

    func stopContainer(_ container: ContainerListItem) async {
        let target = container.name.isEmpty ? container.id : container.name
        await runSimpleCommand(args: ["stop", target], label: "container stop \(target)")
        await refreshContainers(updateLastCommand: false)
    }

    func deleteContainer(_ container: ContainerListItem) async {
        let target = container.name.isEmpty ? container.id : container.name
        guard await deleteResource(.containers, name: target) else { return }
        containers.removeAll { $0.id == container.id }
        await cleanupEntrypointScripts(remainingContainers: containers)
        removeAutostartContainer(named: target)
        var running = loadLastRunningContainers()
        running.remove(target)
        saveLastRunningContainers(running)
    }

    private func startAutostartContainersIfNeeded() async {
        let names = loadAutostartContainers()
        guard !names.isEmpty else { return }
        let lastRunning = loadLastRunningContainers()
        let hasLastRunning = hasStoredLastRunningContainers()
        let desired = hasLastRunning ? names.intersection(lastRunning) : names
        var remaining = Set<String>()

        for name in desired {
            if let container = containers.first(where: { $0.name == name || $0.id == name }) {
                remaining.insert(name)
                if container.state.lowercased() != "running" {
                    await runSimpleCommand(args: ["start", name], label: "container start \(name)")
                }
            }
        }

        saveAutostartContainers(remaining)
    }

    private func loadAutostartContainers() -> Set<String> {
        let values = UserDefaults.standard.stringArray(forKey: "AutoStartContainers") ?? []
        return Set(values)
    }

    private func loadLastRunningContainers() -> Set<String> {
        let values = UserDefaults.standard.stringArray(forKey: "LastRunningContainers") ?? []
        return Set(values)
    }

    private func hasStoredLastRunningContainers() -> Bool {
        UserDefaults.standard.object(forKey: "LastRunningContainers") != nil
    }

    private func saveAutostartContainers(_ names: Set<String>) {
        UserDefaults.standard.set(Array(names), forKey: "AutoStartContainers")
    }

    private func saveLastRunningContainers(_ names: Set<String>) {
        UserDefaults.standard.set(Array(names), forKey: "LastRunningContainers")
    }

    private func registerAutostartContainer(named name: String) {
        var names = loadAutostartContainers()
        names.insert(name)
        saveAutostartContainers(names)
    }

    private func removeAutostartContainer(named name: String) {
        var names = loadAutostartContainers()
        if names.remove(name) != nil {
            saveAutostartContainers(names)
        }
    }

    func pullImage(_ reference: String) async {
        isPullingImage = true
        pullStatusText = "Pulling \(reference)…"
        let result = await runStreamingCommand(
            args: ["image", "pull", reference],
            label: "container image pull \(reference)"
        ) { [weak self] chunk in
            self?.updatePullStatus(with: chunk)
        } onError: { [weak self] chunk in
            self?.updatePullStatus(with: chunk)
        }
        lastCommand = "container image pull \(reference)"
        lastOutput = Self.prettyPrintedJSONIfPossible(result.stdout)
        lastRawError = result.stderr
        lastError = userFacingError(for: result)
        isPullingImage = false
        pullStatusText = ""
        await refreshImages(updateLastCommand: false)
    }

    func deleteImage(_ image: ImageListItem) async {
        let target = image.reference.isEmpty ? image.id : image.reference
        guard await deleteResource(.images, name: target) else { return }
        images.removeAll { $0.id == image.id && $0.reference == image.reference }
    }

    func updateImage(_ image: ImageListItem) async {
        let reference = image.reference.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !reference.isEmpty else { return }
        let listDigest = imageListDigest(from: image.raw) ?? image.digest
        await updateImageByReference(
            reference,
            localDigest: listDigest,
            containerDigest: nil
        )
    }

    func updateContainerImage(_ container: ContainerListItem) async {
        guard !container.image.isEmpty else { return }
        let localDigest = images.first(where: { $0.reference == container.image })?.id
        let containerDigest = containerImageDigest(for: container)
        await updateImageByReference(
            container.image,
            localDigest: localDigest,
            containerDigest: containerDigest
        )
    }

    func openContainerFolder(_ container: ContainerListItem) async {
        let containerId = containerStorageId(for: container)
        let base = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library")
            .appendingPathComponent("Application Support")
            .appendingPathComponent("com.apple.container")
            .appendingPathComponent("containers")
        let candidates = [
            base.appendingPathComponent(containerId),
            base.appendingPathComponent(container.name),
            base.appendingPathComponent(container.id)
        ]
        if let match = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }) {
            lastCommand = "open container folder \(containerId)"
            lastOutput = match.path
            lastRawError = ""
            lastError = ""
            appendLog(command: lastCommand, output: lastOutput, error: lastRawError)
            NSWorkspace.shared.activateFileViewerSelecting([match])
            return
        }
        lastCommand = "open container folder \(containerId)"
        lastOutput = ""
        lastRawError = "Unable to resolve container folder."
        lastError = "Unable to resolve container folder."
        appendLog(command: lastCommand, output: lastOutput, error: lastRawError)
    }

    func openContainerBindMounts(_ container: ContainerListItem) async {
        let mounts = parseVolumes(from: container.raw)
        let bindPaths = mounts
            .map { $0.hostPath }
            .filter { $0.hasPrefix("/") || $0.hasPrefix("~") }
            .map { NSString(string: $0).expandingTildeInPath }
        guard !bindPaths.isEmpty else {
            lastCommand = "open bind mounts \(container.name)"
            lastOutput = ""
            lastRawError = "No host bind mounts found for this container."
            lastError = "No host bind mounts found for this container."
            appendLog(command: lastCommand, output: lastOutput, error: lastRawError)
            return
        }
        let urls = bindPaths.map { URL(fileURLWithPath: $0) }
        lastCommand = "open bind mounts \(container.name)"
        lastOutput = bindPaths.joined(separator: "\n")
        lastRawError = ""
        lastError = ""
        appendLog(command: lastCommand, output: lastOutput, error: lastRawError)
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    private func updateImageByReference(
        _ reference: String,
        localDigest: String?,
        containerDigest: String?
    ) async {
        var resolvedLocalDigest = localDigest
        if resolvedLocalDigest == nil {
            resolvedLocalDigest = await localImageManifestDigest(for: reference)
        }
        let remoteResult = await fetchRemoteDigest(for: reference)
        if let remoteDigest = remoteResult.digest {
            if let resolvedLocalDigest, resolvedLocalDigest == remoteDigest {
                lastCommand = "image update check \(reference)"
                lastOutput = "Image is up to date: \(reference)"
                lastRawError = ""
                lastError = ""
                appendLog(command: lastCommand, output: lastOutput, error: lastRawError)
                return
            }
            if let containerDigest, containerDigest == remoteDigest {
                lastCommand = "image update check \(reference)"
                lastOutput = "Image is up to date: \(reference)"
                lastRawError = ""
                lastError = ""
                appendLog(command: lastCommand, output: lastOutput, error: lastRawError)
                return
            }
            lastCommand = "container image pull \(reference)"
            lastOutput = "Updating image: \(reference)"
            lastRawError = ""
            lastError = ""
            appendLog(command: lastCommand, output: lastOutput, error: lastRawError)
            await runSimpleCommand(args: ["image", "pull", reference], label: "container image pull \(reference)")
            await refreshImages(updateLastCommand: false)
            return
        }

        lastCommand = "image update check \(reference)"
        if let error = remoteResult.error, !error.isEmpty {
            lastOutput = "Unable to verify remote digest (\(error)). Pulling \(reference)…"
        } else {
            lastOutput = "Unable to verify remote digest. Pulling \(reference)…"
        }
        lastRawError = ""
        lastError = ""
        appendLog(command: lastCommand, output: lastOutput, error: lastRawError)
        await runSimpleCommand(args: ["image", "pull", reference], label: "container image pull \(reference)")
        await refreshImages(updateLastCommand: false)
    }

    private func localImageManifestDigest(for reference: String) async -> String? {
        let result = await ContainerCLI.shared.run(["image", "inspect", reference, "--format", "json"])
        guard let data = result.stdout.data(using: .utf8) else { return nil }
        guard let decoded = try? JSONDecoder().decode(JSONValue.self, from: data) else { return nil }
        let object: [String: JSONValue]
        switch decoded {
        case .object(let dict):
            object = dict
        case .array(let array):
            guard let first = array.first, case .object(let dict) = first else { return nil }
            object = dict
        default:
            return nil
        }

        if let digest = object.stringValue(for: ["digest", "Digest"]) {
            return digest
        }
        if case .object(let descriptor) = object["descriptor"],
           let digest = descriptor.stringValue(for: ["digest", "Digest"]) {
            return digest
        }
        if case .object(let image) = object["image"] {
            if let digest = image.stringValue(for: ["digest", "Digest"]) {
                return digest
            }
            if case .object(let descriptor) = image["descriptor"],
               let digest = descriptor.stringValue(for: ["digest", "Digest"]) {
                return digest
            }
        }
        return nil
    }

    private func imageListDigest(from raw: [String: JSONValue]) -> String? {
        if let digest = raw.stringValue(for: ["digest", "Digest"]) {
            return digest
        }
        if case .object(let descriptor) = raw["descriptor"],
           let digest = descriptor.stringValue(for: ["digest", "Digest"]) {
            return digest
        }
        if case .object(let image) = raw["image"] {
            if let digest = image.stringValue(for: ["digest", "Digest"]) {
                return digest
            }
            if case .object(let descriptor) = image["descriptor"],
               let digest = descriptor.stringValue(for: ["digest", "Digest"]) {
                return digest
            }
        }
        return nil
    }

    private func containerImageDigest(for container: ContainerListItem) -> String? {
        guard case .object(let configuration) = container.raw["configuration"] else { return nil }
        guard case .object(let imageObject) = configuration["image"] else { return nil }
        guard case .object(let descriptor) = imageObject["descriptor"] else { return nil }
        return descriptor.stringValue(for: ["digest", "Digest"])
    }

    private func containerStorageId(for container: ContainerListItem) -> String {
        if case .object(let configuration) = container.raw["configuration"],
           let id = configuration.stringValue(for: ["id", "ID", "name", "Name"]) {
            return id
        }
        if !container.id.isEmpty { return container.id }
        return container.name
    }

    private func fetchRemoteDigest(for reference: String) async -> (digest: String?, error: String?) {
        guard let parsed = parseImageReference(reference) else {
            return (nil, "invalid reference")
        }
        let registryHost = parsed.registryHost == "docker.io" ? "registry-1.docker.io" : parsed.registryHost
        let repo = registryHost == "registry-1.docker.io" && !parsed.repository.contains("/")
            ? "library/\(parsed.repository)"
            : parsed.repository
        guard let url = URL(string: "https://\(registryHost)/v2/\(repo)/manifests/\(parsed.reference)") else {
            return (nil, "invalid URL")
        }

        let acceptHeader = "application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json, application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.v2+json"

        func requestDigest(with token: String?) async -> (digest: String?, error: String?) {
            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.setValue(acceptHeader, forHTTPHeaderField: "Accept")
            if let token, !token.isEmpty {
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            }
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse else {
                    return (nil, "no response")
                }
                if http.statusCode == 401 {
                    let auth = http.value(forHTTPHeaderField: "WWW-Authenticate") ?? ""
                    return (nil, auth.isEmpty ? "authentication required" : auth)
                }
                if http.statusCode == 404 {
                    return (nil, "not found")
                }
                guard (200...299).contains(http.statusCode) else {
                    return (nil, "HTTP \(http.statusCode)")
                }
                if let header = http.value(forHTTPHeaderField: "Docker-Content-Digest"), !header.isEmpty {
                    return (header, nil)
                }
                if let digest = digestFromManifestData(data) {
                    return (digest, nil)
                }
                return (nil, "digest missing")
            } catch {
                return (nil, error.localizedDescription)
            }
        }

        let initial = await requestDigest(with: nil)
        if let digest = initial.digest {
            return (digest, nil)
        }
        if let error = initial.error {
            if let token = await fetchRegistryToken(from: error, repository: repo) {
                return await requestDigest(with: token)
            }
            if registryHost == "registry-1.docker.io",
               let token = await fetchRegistryToken(from: "Bearer realm=\"https://auth.docker.io/token\",service=\"registry.docker.io\",scope=\"repository:\(repo):pull\"", repository: repo) {
                return await requestDigest(with: token)
            }
        }
        return initial
    }

    private func parseImageReference(_ reference: String) -> (registryHost: String, repository: String, reference: String)? {
        let trimmed = reference.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let registryHost: String
        let remainder: String
        if hasRegistryHost(trimmed) {
            let parts = trimmed.split(separator: "/", maxSplits: 1).map(String.init)
            registryHost = parts.first ?? "docker.io"
            remainder = parts.count > 1 ? parts[1] : ""
        } else {
            registryHost = "docker.io"
            remainder = trimmed
        }

        let repository: String
        let ref: String
        if let atIndex = remainder.firstIndex(of: "@") {
            repository = String(remainder[..<atIndex])
            ref = String(remainder[remainder.index(after: atIndex)...])
        } else {
            let lastColon = remainder.lastIndex(of: ":")
            let lastSlash = remainder.lastIndex(of: "/")
            if let lastColon, (lastSlash == nil || lastColon > lastSlash!) {
                repository = String(remainder[..<lastColon])
                ref = String(remainder[remainder.index(after: lastColon)...])
            } else {
                repository = remainder
                ref = "latest"
            }
        }

        guard !repository.isEmpty else { return nil }
        return (registryHost, repository, ref)
    }

    private func digestFromManifestData(_ data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let config = json["config"] as? [String: Any],
           let digest = config["digest"] as? String {
            return digest
        }
        if let manifests = json["manifests"] as? [[String: Any]] {
            if let match = manifests.first(where: { manifest in
                guard let platform = manifest["platform"] as? [String: Any] else { return false }
                let arch = (platform["architecture"] as? String)?.lowercased() ?? ""
                let os = (platform["os"] as? String)?.lowercased() ?? ""
                return arch == "arm64" && os == "linux"
            }), let digest = match["digest"] as? String {
                return digest
            }
            if let first = manifests.first, let digest = first["digest"] as? String {
                return digest
            }
        }
        return nil
    }

    private func fetchRegistryToken(from authHeader: String, repository: String) async -> String? {
        guard let params = parseAuthHeader(authHeader) else { return nil }
        guard let realm = params["realm"] else { return nil }
        var components = URLComponents(string: realm)
        var queryItems = components?.queryItems ?? []
        if let service = params["service"] {
            queryItems.append(URLQueryItem(name: "service", value: service))
        }
        let scope = params["scope"] ?? "repository:\(repository):pull"
        queryItems.append(URLQueryItem(name: "scope", value: scope))
        components?.queryItems = queryItems
        guard let url = components?.url else { return nil }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else { return nil }
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            if let token = object?["token"] as? String { return token }
            if let token = object?["access_token"] as? String { return token }
            return nil
        } catch {
            return nil
        }
    }

    private func parseAuthHeader(_ header: String) -> [String: String]? {
        let trimmed = header.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.lowercased().hasPrefix("bearer ") else { return nil }
        let raw = trimmed.dropFirst("bearer ".count)
        var params: [String: String] = [:]
        for part in raw.split(separator: ",") {
            let pair = part.split(separator: "=", maxSplits: 1)
            guard pair.count == 2 else { continue }
            let key = pair[0].trimmingCharacters(in: .whitespacesAndNewlines)
            var value = pair[1].trimmingCharacters(in: .whitespacesAndNewlines)
            if value.hasPrefix("\"") && value.hasSuffix("\"") {
                value = String(value.dropFirst().dropLast())
            }
            params[key] = value
        }
        return params.isEmpty ? nil : params
    }

    private func removeEntrypointScriptIfNeeded(for container: ContainerListItem) {
        let override = extractEntrypointOverride(from: container.raw)
        guard override.isEnabled, !override.customPath.isEmpty else { return }

        let path = override.customPath
        guard path.contains("/AppleContainerGUI/entrypoints/") else { return }
        let fileURL = URL(fileURLWithPath: path)
        guard fileURL.lastPathComponent.hasPrefix("entrypoint_") else { return }

        let isInUse = containers.contains { other in
            guard other.id != container.id else { return false }
            let otherOverride = extractEntrypointOverride(from: other.raw)
            return otherOverride.customPath == path
        }
        guard !isInUse else { return }

        try? FileManager.default.removeItem(at: fileURL)
    }

    private func collectEntrypointOverrides(in containers: [ContainerListItem]) -> [String] {
        containers.compactMap { container in
            let override = extractEntrypointOverride(from: container.raw)
            guard override.isEnabled, !override.customPath.isEmpty else { return nil }
            return override.customPath
        }
    }

    private func resolveEntrypointPath(for container: ContainerListItem, target: String) async -> String? {
        let current = extractEntrypointOverride(from: container.raw)
        if current.isEnabled, !current.customPath.isEmpty {
            return current.customPath
        }

        let result = await ContainerCLI.shared.run(["inspect", target])
        guard result.exitCode == 0, let data = result.stdout.data(using: .utf8) else { return nil }
        guard let decoded = try? JSONDecoder().decode([JSONValue].self, from: data) else { return nil }
        guard let first = decoded.first, case .object(let object) = first else { return nil }
        let override = extractEntrypointOverride(from: object)
        guard override.isEnabled, !override.customPath.isEmpty else { return nil }
        return override.customPath
    }

    private func cleanupEntrypointScripts(remainingContainers: [ContainerListItem]) async {
        let used = await collectEntrypointOverridesFromInspect(remainingContainers)
        guard let dirURL = entrypointsDirectoryURL() else { return }
        let fileManager = FileManager.default
        guard let items = try? fileManager.contentsOfDirectory(at: dirURL, includingPropertiesForKeys: nil) else { return }

        for fileURL in items where fileURL.lastPathComponent.hasPrefix("entrypoint_") {
            let path = fileURL.path
            guard !used.contains(path) else { continue }
            try? fileManager.removeItem(at: fileURL)
        }
    }

    private func collectEntrypointOverridesFromInspect(_ containers: [ContainerListItem]) async -> Set<String> {
        var used = Set<String>()
        for container in containers {
            let target = container.name.isEmpty ? container.id : container.name
            let result = await ContainerCLI.shared.run(["inspect", target])
            guard result.exitCode == 0, let data = result.stdout.data(using: .utf8) else { continue }
            guard let decoded = try? JSONDecoder().decode([JSONValue].self, from: data) else { continue }
            guard let first = decoded.first, case .object(let object) = first else { continue }
            let override = extractEntrypointOverride(from: object)
            guard override.isEnabled, !override.customPath.isEmpty else { continue }
            used.insert(override.customPath)
        }
        return used
    }

    func createVolume(name: String) async {
        await runSimpleCommand(args: ["volume", "create", name], label: "container volume create \(name)")
        await refreshVolumes(updateLastCommand: false)
    }

    func deleteVolume(_ volume: VolumeListItem) async {
        guard await deleteResource(.volumes, name: volume.name) else { return }
        volumes.removeAll { $0.id == volume.id }
    }

    func openVolumeInFinder(_ volume: VolumeListItem) async {
        let path: String?
        if let resolved = resolveVolumeMountpoint(from: volume.raw) {
            path = resolved
        } else {
            path = await fetchVolumeMountpoint(name: volume.name)
        }
        if let path, FileManager.default.fileExists(atPath: path) {
            lastCommand = "open volume \(volume.name)"
            lastOutput = path + (path.hasSuffix(".img") ? "\nApple Container stores this volume as a Linux disk image. Finder shows the storage file; access its contents through the mounted path inside a container." : "")
            lastRawError = ""
            lastError = ""
            appendLog(command: lastCommand, output: lastOutput, error: lastRawError)
            let url = URL(fileURLWithPath: path)
            NSWorkspace.shared.activateFileViewerSelecting([url])
            return
        }

        lastCommand = "open volume \(volume.name)"
        lastOutput = ""
        lastRawError = "Unable to resolve volume mount path."
        lastError = "Unable to resolve volume mount path."
        appendLog(command: lastCommand, output: lastOutput, error: lastRawError)
    }

    func fixVolumePermissions(volume: VolumeListItem, container: ContainerListItem) async {
        await fixNamedVolumePermissions(volumeName: volume.name, container: container)
    }

    private func fixNamedVolumePermissions(volumeName: String, container: ContainerListItem) async {
        let directory = ManagedRuntime.shared.storage.appendingPathComponent("Volumes").appendingPathComponent(volumeName)
        if FileManager.default.fileExists(atPath: directory.appendingPathComponent("metadata.json").path) {
            lastCommand = "volume ownership " + volumeName
            lastOutput = "VirtioFS maps file ownership through macOS. Container chown cannot reliably change Linux UID/GID. Manage host access in Finder: " + directory.appendingPathComponent("data").path
            lastRawError = ""
            lastError = ""
            appendLog(command: lastCommand, output: lastOutput, error: lastRawError)
            return
        }
        let target = container.name.isEmpty ? container.id : container.name
        let uidGid = await resolveUidGid(containerName: target)
        guard let uidGid else {
            lastCommand = "container exec \(target) id"
            lastOutput = ""
            lastRawError = "Unable to read UID/GID from container. Make sure it is running."
            lastError = "Unable to read UID/GID from container. Make sure it is running."
            appendLog(command: lastCommand, output: lastOutput, error: lastRawError)
            return
        }
        let effectiveUidGid = await resolveWebUidGidIfNeeded(containerName: target, fallback: uidGid)

        let trimmed = volumeName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("/") else {
            lastCommand = "volume fix permissions"
            lastOutput = ""
            lastRawError = "Invalid volume name. Please use a named volume (no slashes)."
            lastError = "Invalid volume name. Please use a named volume (no slashes)."
            appendLog(command: lastCommand, output: lastOutput, error: lastRawError)
            return
        }

        guard let destination = volumeMountDestination(for: trimmed, in: container) else {
            lastCommand = "volume fix permissions"
            lastOutput = ""
            lastRawError = "Selected volume is not mounted in the chosen container."
            lastError = "Selected volume is not mounted in the chosen container."
            appendLog(command: lastCommand, output: lastOutput, error: lastRawError)
            return
        }

        let command = "container exec \(target) sh -c \"chown -R \(effectiveUidGid.uid):\(effectiveUidGid.gid) \(destination)\""
        lastCommand = command
        lastOutput = "Fixing permissions for volume \(trimmed) in \(target)..."
        lastRawError = ""
        lastError = ""
        appendLog(command: lastCommand, output: lastOutput, error: lastRawError)

        let fixResult = await ContainerCLI.shared.run(["exec", target, "sh", "-c", "chown -R \(effectiveUidGid.uid):\(effectiveUidGid.gid) \(destination)"])
        lastCommand = command
        lastOutput = fixResult.exitCode == 0 ? "Permissions updated." : Self.prettyPrintedJSONIfPossible(fixResult.stdout)
        lastRawError = fixResult.stderr
        lastError = userFacingError(for: fixResult)
        appendLog(command: lastCommand, output: lastOutput, error: lastRawError)
    }

    private func volumeMountDestination(for volumeName: String, in container: ContainerListItem) -> String? {
        guard case .object(let configuration) = container.raw["configuration"],
              case .array(let mounts) = configuration["mounts"] else { return nil }
        for mountValue in mounts {
            guard case .object(let mountObject) = mountValue else { continue }
            let source = mountObject.stringValue(for: ["source", "Source"]) ?? ""
            let destination = mountObject.stringValue(for: ["destination", "Destination", "target", "Target"]) ?? ""
            if source == volumeName {
                return destination
            }
            if source.contains("/volumes/\(volumeName)") {
                return destination
            }
            if source.hasSuffix("/\(volumeName)") || source.hasSuffix("/\(volumeName)/") {
                return destination
            }
        }
        return nil
    }

    private func resolveWebUidGidIfNeeded(containerName: String, fallback: (uid: Int, gid: Int)) async -> (uid: Int, gid: Int) {
        guard fallback.uid == 0 else { return fallback }
        let command = """
        stat -c '%u:%g' /var/www/html 2>/dev/null || \
        stat -c '%u:%g' /var/www 2>/dev/null || \
        stat -c '%u:%g' /usr/share/nginx/html 2>/dev/null || \
        stat -c '%u:%g' /srv/http 2>/dev/null
        """
        let result = await ContainerCLI.shared.run(["exec", containerName, "sh", "-lc", command])
        if result.exitCode == 0 {
            let text = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            if let parsed = parseUidGidFromPair(text) {
                return parsed
            }
        }
        let uid = await resolveNamedUserId(containerName: containerName, arg: "-u")
        let gid = await resolveNamedUserId(containerName: containerName, arg: "-g")
        if let uid, let gid {
            return (uid, gid)
        }
        return fallback
    }

    private func parseUidGidFromPair(_ text: String) -> (uid: Int, gid: Int)? {
        let parts = text.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2, let uid = Int(parts[0]), let gid = Int(parts[1]) else { return nil }
        return (uid, gid)
    }

    private func resolveNamedUserId(containerName: String, arg: String) async -> Int? {
        let result = await ContainerCLI.shared.run(["exec", containerName, "sh", "-lc", "id \(arg) www-data 2>/dev/null"])
        guard result.exitCode == 0 else { return nil }
        let text = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return Int(text)
    }

    private func fetchVolumeMountpoint(name: String) async -> String? {
        let result = await DockerSocketService.shared.runDocker(["volume", "inspect", name])
        guard result.code == 0, let values = try? JSONDecoder().decode([JSONValue].self, from: Data(result.output.utf8)), case .object(let raw) = values.first else { return nil }
        return resolveVolumeMountpoint(from: raw)
    }

    private func resolveVolumeMountpoint(from raw: [String: JSONValue]) -> String? {
        if let path = raw.stringValue(for: ["mountpoint", "Mountpoint", "path", "Path", "source", "Source"]), !path.isEmpty {
            return path
        }
        for key in ["configuration", "Configuration", "config", "Config"] {
            if case .object(let config) = raw[key], let path = resolveVolumeMountpoint(from: config) {
                return path
            }
        }
        return nil
    }

    private func extractNamedVolumes(from args: [String]) -> [String] {
        var names: [String] = []
        var index = 0
        while index < args.count {
            let arg = args[index]
            if arg == "-v" || arg == "--volume" {
                if index + 1 < args.count, let name = namedVolumeFromSpec(args[index + 1]) {
                    names.append(name)
                }
                index += 2
                continue
            }
            if arg.hasPrefix("--volume=") {
                let value = String(arg.dropFirst("--volume=".count))
                if let name = namedVolumeFromSpec(value) {
                    names.append(name)
                }
                index += 1
                continue
            }
            if arg == "--mount" {
                if index + 1 < args.count, let name = namedVolumeFromMount(args[index + 1]) {
                    names.append(name)
                }
                index += 2
                continue
            }
            if arg.hasPrefix("--mount=") {
                let value = String(arg.dropFirst("--mount=".count))
                if let name = namedVolumeFromMount(value) {
                    names.append(name)
                }
                index += 1
                continue
            }
            index += 1
        }
        return Array(Set(names))
    }

    private func extractNamedVolumes(from volumes: [RunVolumeMapping]) -> [String] {
        let names: [String] = volumes.compactMap { mapping in
            let trimmed = mapping.hostPath.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            if trimmed.hasPrefix("/") || trimmed.hasPrefix("~") { return nil }
            if trimmed.contains("/") { return nil }
            return trimmed
        }
        return Array(Set(names))
    }

    private func namedVolumeFromSpec(_ spec: String) -> String? {
        let trimmed = spec.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmed.split(separator: ":", maxSplits: 2).map(String.init)
        guard let source = parts.first, !source.isEmpty else { return nil }
        if source.hasPrefix("/") || source.hasPrefix("~") { return nil }
        if source.contains("/") { return nil }
        return source
    }

    private func namedVolumeFromMount(_ spec: String) -> String? {
        let lower = spec.lowercased()
        guard lower.contains("type=volume") else { return nil }
        let pairs = spec.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        for pair in pairs {
            let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            let key = parts[0].lowercased()
            let value = parts[1]
            if key == "source" || key == "src" {
                if value.hasPrefix("/") || value.hasPrefix("~") { return nil }
                if value.contains("/") { return nil }
                return value
            }
        }
        return nil
    }

    func createNetwork(name: String) async {
        await runSimpleCommand(args: ["network", "create", name], label: "container network create \(name)")
        await refreshNetworks(updateLastCommand: false)
    }

    func deleteNetwork(_ network: NetworkListItem) async {
        guard await deleteResource(.networks, name: network.name) else { return }
        networks.removeAll { $0.id == network.id }
    }

    var isDeletingResource = false

    private func deleteResource(_ resource: DockerAPIClient.Resource, name: String) async -> Bool {
        guard !isDeletingResource else { return false }
        isDeletingResource = true
        defer { isDeletingResource = false }
        lastCommand = "delete " + resource.rawValue + " " + name
        lastOutput = resource == .containers ? "Stopping and removing container..." : "Removing resource..."
        lastRawError = ""
        lastError = ""
        do {
            let bridge = DockerSocketService.shared
            if !bridge.isRunning { await bridge.start() }
            guard bridge.isRunning else { throw DockerAPIError(message: bridge.lastError) }
            var removed = try await DockerAPIClient(socketPath: bridge.socketPath).remove(resource, name: name)
            if !removed, resource != .volumes {
                removed = try await removeNativeEntry(resource, name: name)
            }
            lastOutput = removed ? "Removed " + name + "." : "Already absent in the backend. Removed the stale entry for " + name + "."
            appendLog(command: lastCommand, output: lastOutput, error: "")
            return true
        } catch {
            lastOutput = ""
            lastRawError = error.localizedDescription
            lastError = lastRawError
            appendLog(command: lastCommand, output: "", error: lastRawError)
            return false
        }
    }

    private func removeNativeEntry(_ resource: DockerAPIClient.Resource, name: String) async throws -> Bool {
        let prefix: [String]
        switch resource {
        case .containers: prefix = []
        case .images: prefix = ["image"]
        case .networks: prefix = ["network"]
        case .volumes: return false
        }
        let arguments = prefix + ["delete"] + (resource == .containers ? ["--force"] : []) + [name]
        let result = await ContainerCLI.shared.run(arguments)
        if result.exitCode == 0 { return true }
        let listArguments = prefix + ["list"] + (resource == .containers ? ["--all"] : []) + ["--format", "json"]
        let list = await ContainerCLI.shared.run(listArguments)
        guard list.exitCode == 0, let objects = await Self.decodeJSONObjectArray(list.stdout) else {
            throw DockerAPIError(message: result.stderr + "\n" + list.stderr)
        }
        let stillPresent = objects.contains { object in
            if resource == .containers, case .object(let config) = object["configuration"], config.stringValue(for: ["id", "name"]) == name { return true }
            return ["id", "name", "reference", "digest"].contains { object.stringValue(for: [$0]) == name }
        }
        guard !stillPresent else { throw DockerAPIError(message: result.stderr) }
        return false
    }

    func refreshSnapshots() {
        let base = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library")
            .appendingPathComponent("Application Support")
            .appendingPathComponent("com.apple.container")
            .appendingPathComponent("snapshots")
        guard let items = try? FileManager.default.contentsOfDirectory(at: base, includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey], options: .skipsHiddenFiles) else {
            snapshots = []
            return
        }
        let entries: [SnapshotItem] = items.compactMap { (url: URL) -> SnapshotItem? in
            guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isDirectoryKey]),
                  values.isDirectory == true else { return nil }
            let name = url.lastPathComponent
            let modified = values.contentModificationDate ?? Date.distantPast
            return SnapshotItem(id: name, name: name, modifiedAt: modified, path: url.path, size: "—")
        }.sorted { (lhs: SnapshotItem, rhs: SnapshotItem) in
            lhs.modifiedAt > rhs.modifiedAt
        }
        snapshots = entries
        Task.detached { [entries] in
            let sizes = ContainerViewModel.calculateSnapshotSizes(for: entries)
            await MainActor.run {
                self.snapshots = self.snapshots.map { (item: SnapshotItem) in
                    if let size = sizes[item.id] {
                        return SnapshotItem(id: item.id, name: item.name, modifiedAt: item.modifiedAt, path: item.path, size: size)
                    }
                    return item
                }
            }
        }
    }

    func deleteSnapshot(_ snapshot: SnapshotItem) {
        do {
            do { try FileManager.default.removeItem(atPath: snapshot.path) }
            catch let error as NSError where error.domain == NSCocoaErrorDomain && [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(error.code) {}
            lastCommand = "delete snapshot \(snapshot.name)"
            lastOutput = "Snapshot deleted."
            lastRawError = ""
            lastError = ""
            appendLog(command: lastCommand, output: lastOutput, error: lastRawError)
        } catch {
            lastCommand = "delete snapshot \(snapshot.name)"
            lastOutput = ""
            lastRawError = error.localizedDescription
            lastError = error.localizedDescription
            appendLog(command: lastCommand, output: lastOutput, error: lastRawError)
        }
        refreshSnapshots()
    }

    func deleteAllSnapshots() {
        let current = snapshots
        var failures: [String] = []
        for snapshot in current {
            do { try FileManager.default.removeItem(atPath: snapshot.path) }
            catch let error as NSError where error.domain == NSCocoaErrorDomain && [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(error.code) {}
            catch { failures.append(snapshot.name + ": " + error.localizedDescription) }
        }
        lastCommand = "delete all snapshots"
        lastOutput = "Removed \(current.count - failures.count) snapshot entries."
        lastRawError = failures.joined(separator: "\n")
        lastError = lastRawError
        appendLog(command: lastCommand, output: lastOutput, error: lastRawError)
        refreshSnapshots()
    }

    private nonisolated static func folderSize(at url: URL) -> UInt64 {
        guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey], options: [], errorHandler: nil) else {
            return 0
        }
        var total: UInt64 = 0
        for case let fileURL as URL in enumerator {
            if let size = try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                total += UInt64(size)
            }
        }
        return total
    }

    private nonisolated static func calculateSnapshotSizes(for items: [SnapshotItem]) -> [String: String] {
        var result: [String: String] = [:]
        for item in items {
            let bytes = folderSize(at: URL(fileURLWithPath: item.path))
            let size = formatBytesStatic(Double(bytes))
            result[item.id] = size
        }
        return result
    }

    func pullDockerHubImage(_ reference: String) async {
        if selectedRegistry.requiresOwner && !reference.contains("/") {
            dockerHubInfo = "Please provide owner/image[:tag]."
            return
        }
        let qualified = qualifiedReference(reference, registry: selectedRegistry, customHost: customRegistryHost)
        await pullImage(qualified)
    }

    func pullFromSearchQuery() async {
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }

        if selectedRegistry.requiresOwner && !query.contains("/") {
            dockerHubInfo = "Please provide owner/image[:tag]."
            return
        }

        let reference = qualifiedReference(query, registry: selectedRegistry, customHost: customRegistryHost)
        dockerHubInfo = ""
        await pullImage(reference)
        dockerHubResults = []
        dockerHubError = ""
    }

    func runImage(reference: String, config: RunImageConfig) async {
        let cleanedReference = normalizeImageReference(reference)
        guard !cleanedReference.isEmpty else {
            lastCommand = "container run (invalid reference)"
            lastOutput = ""
            lastRawError = ""
            lastError = "Invalid image reference. Raw: [\(reference)] Sanitized: [\(cleanedReference)]"
            return
        }
        let hostPaths = extractHostPaths(from: config.volumes)
        ensureHostPathsExist(for: config.volumes)
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        var args: [String] = ["run"]
        if config.detach {
            args.append("-d")
        }
        if !config.name.isEmpty {
            args.append(contentsOf: ["--name", config.name])
            lastRunContainerName = config.name
        }
        let cpus = config.cpus.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cpus.isEmpty {
            args.append(contentsOf: ["--cpus", cpus])
        }
        let memory = config.memory.trimmingCharacters(in: .whitespacesAndNewlines)
        if !memory.isEmpty {
            args.append(contentsOf: ["--memory", memory])
        }
        if config.overrideEntrypoint {
            let scriptPath = config.customEntrypointPath.isEmpty
                ? createNoChownEntrypointScript(for: cleanedReference)
                : config.customEntrypointPath
            if let scriptPath, !scriptPath.isEmpty {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                args.append(contentsOf: ["-v", "\(scriptPath):/usr/local/bin/entrypoint.sh"])
                args.append(contentsOf: ["--entrypoint", "/usr/local/bin/entrypoint.sh"])
            }
        }
        for port in config.ports {
            let host = port.hostPort.trimmingCharacters(in: .whitespacesAndNewlines)
            let container = port.containerPort.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !host.isEmpty, !container.isEmpty else { continue }
            args.append(contentsOf: ["-p", "\(host):\(container)"])
        }
        for volume in config.volumes {
            let host = volume.hostPath.trimmingCharacters(in: .whitespacesAndNewlines)
            let container = volume.containerPath.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !host.isEmpty, !container.isEmpty else { continue }
            let suffix = volume.readOnly ? ":ro" : ""
            args.append(contentsOf: ["-v", "\(host):\(container)\(suffix)"])
        }
        for envVar in config.environment {
            let key = envVar.key.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else { continue }
            let value = envVar.value
            args.append(contentsOf: ["-e", "\(key)=\(value)"])
        }
        let extraArgs = DockerSocketService.shared.isRunning ? splitArgumentsRaw(config.extraArgs) : splitArguments(config.extraArgs)
        if !extraArgs.isEmpty {
            args.append(contentsOf: extraArgs)
        }
        args.append(cleanedReference)
        var commandArgs = resolvedCommandArgs(reference: cleanedReference, config: config)
        if commandArgs.isEmpty, config.overrideEntrypoint {
            commandArgs = await detectEntrypointDefaultCommand(for: cleanedReference)
            if commandArgs.isEmpty {
                commandArgs = ["apache2-foreground"]
            }
        }
        if !commandArgs.isEmpty {
            args.append(contentsOf: commandArgs)
        }

        await runSimpleCommand(args: args, label: "container \(args.joined(separator: " "))")
        let containerName: String?
        if config.name.isEmpty {
            containerName = await resolveLatestContainerName()
        } else {
            containerName = config.name
        }
        let permissionSource = lastRawError.isEmpty ? lastOutput : lastRawError
        await handlePermissionHint(from: permissionSource, hostPaths: hostPaths, containerName: containerName)
        await checkLogsForPermissionHint(containerName: containerName, hostPaths: hostPaths)
        await refreshContainers(updateLastCommand: false)
        if let containerName,
           let container = containers.first(where: { $0.name == containerName || $0.id == containerName }),
           container.state.lowercased().contains("running") {
            let namedVolumes = extractNamedVolumes(from: config.volumes)
            for volumeName in namedVolumes {
                await fixNamedVolumePermissions(volumeName: volumeName, container: container)
            }
        }
    }

    private func normalizeImageReference(_ reference: String) -> String {
        var cleaned = reference.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.hasPrefix("\"") && cleaned.hasSuffix("\"") && cleaned.count > 1 {
            cleaned = String(cleaned.dropFirst().dropLast())
        }
        if cleaned.hasPrefix("'") && cleaned.hasSuffix("'") && cleaned.count > 1 {
            cleaned = String(cleaned.dropFirst().dropLast())
        }
        let noWhitespace = cleaned.filter { !$0.isWhitespace }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._/:@")
        let filteredScalars = noWhitespace.unicodeScalars.filter { allowed.contains($0) }
        return String(String.UnicodeScalarView(filteredScalars))
    }

    private func runDockerCommand(_ arguments: [String]) async {
        guard !isRunningCommand else { return }
        guard let first = arguments.first, !first.hasPrefix("-") else {
            lastError = "Use docker followed by a command. The app supplies its own Docker host."
            return
        }
        guard DockerSocketService.dockerExecutable() != nil else {
            lastError = "Docker CLI was not found. Install the Docker CLI to run Docker commands."
            return
        }
        let bridge = DockerSocketService.shared
        if !bridge.isRunning { await bridge.start() }
        guard bridge.isRunning else {
            lastError = bridge.lastError
            return
        }
        isRunningCommand = true
        defer { isRunningCommand = false; commandStatusText = "" }
        commandStatusText = "Running through the Docker API socket"
        lastCommand = "docker " + arguments.map(DockerSocketService.shellQuote).joined(separator: " ")
        lastOutput = ""
        lastError = ""
        lastRawError = ""
        let result = await bridge.runDocker(arguments)
        lastOutput = result.output
        lastRawError = result.error
        lastError = result.code == 0 ? "" : (result.error.isEmpty ? "Docker command exited with code \(result.code)" : result.error)
        appendLog(command: lastCommand, output: lastOutput, error: lastRawError)
        await refreshContainers(updateLastCommand: false)
        await refreshImages(updateLastCommand: false)
    }

    func runCustomCommand(_ rawArguments: String, overrideEntrypoint: Bool = false, customEntrypointPath: String = "") async {
        let rawArgs = splitArgumentsRaw(rawArguments)
        if rawArgs.first == "docker" {
            await runDockerCommand(Array(rawArgs.dropFirst()))
            return
        }
        if let first = rawArgs.first, !["container", "system", "snapshot"].contains(first) {
            await runDockerCommand(rawArgs)
            return
        }
        if rawArgs.first == "container", rawArgs.count > 1, ["run", "create", "volume"].contains(rawArgs[1]) {
            lastError = "Use Docker commands for containers and volumes so data mounts use VirtioFS."
            return
        }
        let restartPolicy = extractRestartPolicy(from: rawArgs)?.lowercased()
        var args = splitArguments(rawArguments)
        guard !args.isEmpty else { return }
        isRunningCommand = true
        commandStatusText = "Running command..."
        defer {
            isRunningCommand = false
            commandStatusText = ""
        }
        if overrideEntrypoint {
            args = applyEntrypointOverrideIfNeeded(to: args, customEntrypointPath: customEntrypointPath)
        }
        let hostPaths = extractHostPaths(from: args)
        ensureHostPathsExist(for: args)
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        if overrideEntrypoint {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
        if overrideEntrypoint {
            let imageIndex = findImageIndex(in: args, startingAt: args.firstIndex(of: "run").map { $0 + 1 } ?? 0)
            let hasCommandArgs = imageIndex.map { $0 + 1 < args.count } ?? false
            if !hasCommandArgs, let imageIndex {
                let imageRef = args[imageIndex]
                var defaults = await detectEntrypointDefaultCommand(for: imageRef)
                if defaults.isEmpty {
                    defaults = ["apache2-foreground"]
                }
                args.append(contentsOf: defaults)
            }
        }

        lastCommand = "container \(rawArguments)"
        lastOutput = ""
        lastRawError = ""
        lastError = ""
        let result = await runStreamingCommand(
            args: args,
            label: lastCommand,
            onOutput: { [weak self] chunk in
                self?.appendCommandOutput(chunk, isError: false)
            },
            onError: { [weak self] chunk in
                self?.appendCommandOutput(chunk, isError: true)
            }
        )
        lastOutput = Self.prettyPrintedJSONIfPossible(result.stdout)
        lastRawError = result.stderr
        lastError = userFacingError(for: result)
        let nameFromArgs = extractContainerName(from: args)
        if let nameFromArgs {
            lastRunContainerName = nameFromArgs
        } else {
            lastRunContainerName = ""
        }
        let containerName: String?
        if let nameFromArgs {
            containerName = nameFromArgs
        } else {
            containerName = await resolveLatestContainerName()
        }
        if restartPolicy == "unless-stopped" {
            if let name = extractContainerName(from: rawArgs) ?? containerName {
                registerAutostartContainer(named: name)
            }
        }
        let permissionSource = lastRawError.isEmpty ? lastOutput : lastRawError
        await handlePermissionHint(from: permissionSource, hostPaths: hostPaths, containerName: containerName)
        await checkLogsForPermissionHint(containerName: containerName, hostPaths: hostPaths)
        if shouldRefreshContainers(for: args) {
            await refreshContainers(updateLastCommand: false)
            await refreshImages(updateLastCommand: false)
            if let containerName {
                let namedVolumes = extractNamedVolumes(from: args)
                if !namedVolumes.isEmpty,
                   let container = containers.first(where: { $0.name == containerName || $0.id == containerName }),
                   container.state.lowercased().contains("running") {
                    for volumeName in namedVolumes {
                        await fixNamedVolumePermissions(volumeName: volumeName, container: container)
                    }
                }
            }
        }
    }

    func searchDockerHub() async {
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            dockerHubResults = []
            dockerHubError = ""
            dockerHubInfo = ""
            return
        }

        if !selectedRegistry.supportsSearch {
            if selectedRegistry.requiresOwner && !query.contains("/") {
                dockerHubInfo = "Owner required (owner/image[:tag])."
            } else {
                dockerHubInfo = "Search is not available. Please use the Pull button."
            }
            dockerHubResults = []
            dockerHubError = ""
            return
        }

        if looksLikeImageReference(query) {
            let reference = qualifiedReference(query, registry: .dockerHub, customHost: "")
            dockerHubInfo = "Reference: \(reference)"
            dockerHubResults = []
            dockerHubError = ""
            return
        }

        dockerHubError = ""
        dockerHubInfo = ""
        do {
            let urlString = "https://hub.docker.com/v2/search/repositories/?query=\(query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")"
            guard let url = URL(string: urlString) else { return }
            let (data, response) = try await URLSession.shared.data(from: url)
            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                dockerHubError = "Docker Hub error: HTTP \(http.statusCode)"
                return
            }
            do {
                let response = try JSONDecoder().decode(DockerHubSearchResponse.self, from: data)
                dockerHubResults = response.results
            } catch {
                let snippet = String(data: data.prefix(200), encoding: .utf8) ?? ""
                dockerHubError = "Response could not be read. \(snippet)"
            }
        } catch {
            dockerHubError = error.localizedDescription
        }
    }

    @discardableResult
    private func runListCommand(
        args: [String],
        commandLabel: String,
        onSuccess: ([[String: JSONValue]]) -> Void,
        updateLastCommand: Bool
    ) async -> Bool {
        let result = await ContainerCLI.shared.run(args)
        if updateLastCommand {
            lastCommand = commandLabel
            lastOutput = Self.prettyPrintedJSONIfPossible(result.stdout)
            lastError = userFacingError(for: result)
            appendLog(command: commandLabel, output: lastOutput, error: result.stderr)
        }

        guard result.exitCode == 0 else { return false }
        guard let objects = await Self.decodeJSONObjectArray(result.stdout) else { return false }
        onSuccess(objects)
        return true
    }

    private func dockerArguments(for arguments: [String]) -> [String]? {
        guard let first = arguments.first else { return nil }
        if ["run", "start", "stop", "exec", "kill", "inspect", "logs"].contains(first) { return arguments }
        if first == "delete" { return ["rm"] + arguments.dropFirst() }
        if ["image", "volume", "network"].contains(first), arguments.count >= 2 {
            var mapped = arguments
            if mapped[1] == "delete" { mapped[1] = "rm" }
            if ["rm", "create", "inspect", "pull"].contains(mapped[1]) { return mapped }
        }
        return nil
    }

    private func runSimpleCommand(args: [String], label: String) async {
        let result: CLIResult
        var commandLabel = label
        if let dockerArgs = dockerArguments(for: args) {
            if !DockerSocketService.shared.isRunning { await DockerSocketService.shared.start() }
            guard DockerSocketService.shared.isRunning else { lastError = DockerSocketService.shared.lastError; return }
            let output = await DockerSocketService.shared.runDocker(dockerArgs)
            result = CLIResult(exitCode: output.code, stdout: output.output, stderr: output.error)
            commandLabel = "docker " + dockerArgs.map(DockerSocketService.shellQuote).joined(separator: " ")
        } else {
            result = await ContainerCLI.shared.run(args)
        }
        lastCommand = commandLabel
        lastOutput = Self.prettyPrintedJSONIfPossible(result.stdout)
        lastRawError = result.stderr
        lastError = userFacingError(for: result)
        appendLog(command: commandLabel, output: lastOutput, error: result.stderr)
    }

    private func userFacingError(for result: CLIResult) -> String {
        guard result.exitCode != 0 else { return "" }
        let stderr = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = stderr.lowercased()

        if lower.contains("operation not permitted") {
            return "Container CLI is blocked. Check that the app sandbox is disabled and the service is running (container system start).\n\nRaw: \(stderr)"
        }
        if lower.contains("xpc connection error") || lower.contains("apiserver") {
            return "Container service is not running or not reachable. Start it with: container system start.\n\nRaw: \(stderr)"
        }
        if lower.contains("no such file or directory") && lower.contains("container") {
            return "Container CLI was not found. Use Install Runtime in the app.\n\nRaw: \(stderr)"
        }
        if lower.contains("notfound") && lower.contains("content with digest") {
            return "The local image store is inconsistent. Stop the service and reset the store, then pull again.\n\nRaw: \(stderr)"
        }


        return stderr.isEmpty ? "Unknown error (exit code \(result.exitCode))." : stderr
    }

    private func updatePullStatus(with chunk: String) {
        let lines = chunk.split(whereSeparator: \.isNewline)
        guard let last = lines.last else { return }
        pullStatusText = String(last)
    }

    private func appendCommandOutput(_ chunk: String, isError: Bool) {
        let maxLength = 40000
        if isError {
            lastRawError.append(chunk)
            if lastRawError.count > maxLength {
                lastRawError = String(lastRawError.suffix(maxLength))
            }
        } else {
            lastOutput.append(chunk)
            if lastOutput.count > maxLength {
                lastOutput = String(lastOutput.suffix(maxLength))
            }
        }
        let lines = chunk.split(whereSeparator: \.isNewline)
        if let last = lines.last {
            commandStatusText = String(last)
        }
    }

    private func runStreamingCommand(
        args: [String],
        label: String,
        onOutput: @escaping (String) -> Void,
        onError: @escaping (String) -> Void
    ) async -> CLIResult {
        let process = Process()
        if let resolved = ContainerCLI.containerExecutableURL() {
            process.executableURL = resolved
            process.arguments = args
        } else {
            return CLIResult(exitCode: -1, stdout: "", stderr: "Install the bundled runtime in the app first.")
        }
        process.environment = ContainerCLI.defaultEnvironment()

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let stdoutBuffer = StreamBuffer()
        let stderrBuffer = StreamBuffer()

        let stdoutHandle = stdoutPipe.fileHandleForReading
        let stderrHandle = stderrPipe.fileHandleForReading

        stdoutHandle.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            Task {
                await stdoutBuffer.append(data)
                if let chunk = String(data: data, encoding: .utf8) {
                    await MainActor.run { onOutput(chunk) }
                }
            }
        }
        stderrHandle.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            Task {
                await stderrBuffer.append(data)
                if let chunk = String(data: data, encoding: .utf8) {
                    await MainActor.run { onError(chunk) }
                }
            }
        }

        do {
            try process.run()
        } catch {
            stdoutHandle.readabilityHandler = nil
            stderrHandle.readabilityHandler = nil
            return CLIResult(exitCode: -1, stdout: "", stderr: error.localizedDescription)
        }

        return await withCheckedContinuation { continuation in
            process.terminationHandler = { process in
                stdoutHandle.readabilityHandler = nil
                stderrHandle.readabilityHandler = nil
                Task {
                    let stdout = String(data: await stdoutBuffer.snapshot(), encoding: .utf8) ?? ""
                    let stderr = String(data: await stderrBuffer.snapshot(), encoding: .utf8) ?? ""
                    let prettyStdout = Self.prettyPrintedJSONIfPossible(stdout)
                    await MainActor.run {
                        self.appendLog(command: label, output: prettyStdout, error: stderr)
                    }
                    continuation.resume(returning: CLIResult(exitCode: process.terminationStatus, stdout: prettyStdout, stderr: stderr))
                }
            }
        }
    }

    private func isContainerAvailable() -> Bool {
        ContainerCLI.containerExecutableURL() != nil
    }

    private func splitArguments(_ input: String) -> [String] {
        filterUnsupportedArgs(splitArgumentsRaw(input))
    }

    private func splitArgumentsRaw(_ input: String) -> [String] {
        let normalized = input
            .replacingOccurrences(of: "\\\r\n", with: " ")
            .replacingOccurrences(of: "\\\n", with: " ")
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")

        var args: [String] = []
        var current = ""
        var inQuotes = false
        var quoteChar: Character = "\""

        for character in normalized {
            if character == "\"" || character == "'" {
                if inQuotes && character == quoteChar {
                    inQuotes = false
                } else if !inQuotes {
                    inQuotes = true
                    quoteChar = character
                } else {
                    current.append(character)
                }
            } else if character.isWhitespace && !inQuotes {
                if !current.isEmpty {
                    args.append(current)
                    current = ""
                }
            } else {
                current.append(character)
            }
        }

        if !current.isEmpty {
            args.append(current)
        }

        return args
    }

    private func filterUnsupportedArgs(_ args: [String]) -> [String] {
        var filtered: [String] = []
        var index = 0
        if args.first == "container" {
            index = 1
        } else if args.count >= 2, args[0] == "docker", args[1] == "run" {
            index = 1
        } else if args.count >= 3, args[0] == "docker", args[1] == "container", args[2] == "run" {
            index = 2
        }
        while index < args.count {
            let arg = args[index]
            if arg == "--restart" {
                index += 2
                continue
            }
            if arg.hasPrefix("--restart=") {
                index += 1
                continue
            }
            filtered.append(arg)
            index += 1
        }
        return filtered
    }

    private func extractRestartPolicy(from args: [String]) -> String? {
        var index = 0
        while index < args.count {
            let arg = args[index]
            if arg == "--restart", index + 1 < args.count {
                return args[index + 1]
            }
            if arg.hasPrefix("--restart=") {
                return String(arg.dropFirst("--restart=".count))
            }
            index += 1
        }
        return nil
    }

    private func shouldRefreshContainers(for args: [String]) -> Bool {
        guard let first = args.first else { return false }
        switch first {
        case "run", "create", "start", "stop", "delete", "rm":
            return true
        default:
            return false
        }
    }

    private func ensureHostPathsExist(for args: [String]) {
        let fileManager = FileManager.default
        var index = 0
        while index < args.count {
            let arg = args[index]
            if arg == "-v" || arg == "--volume" {
                if index + 1 < args.count {
                    createHostPathIfNeeded(from: args[index + 1], fileManager: fileManager)
                }
                index += 2
                continue
            }
            if arg.hasPrefix("-v") && arg.count > 2 {
                let value = String(arg.dropFirst(2))
                createHostPathIfNeeded(from: value, fileManager: fileManager)
                index += 1
                continue
            }
            if arg.hasPrefix("--volume=") {
                let value = String(arg.dropFirst("--volume=".count))
                createHostPathIfNeeded(from: value, fileManager: fileManager)
                index += 1
                continue
            }
            index += 1
        }
    }

    private func createHostPathIfNeeded(from volumeSpec: String, fileManager: FileManager) {
        let trimmed = volumeSpec.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let parts = trimmed.split(separator: ":", maxSplits: 2).map(String.init)
        guard let hostPathRaw = parts.first, !hostPathRaw.isEmpty else { return }

        let hostPath = (hostPathRaw as NSString).expandingTildeInPath
        guard hostPath.hasPrefix("/") else { return }
        if isGeneratedEntrypointPath(hostPath) {
            return
        }

        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: hostPath, isDirectory: &isDirectory) {
            return
        }

        do {
            try fileManager.createDirectory(atPath: hostPath, withIntermediateDirectories: true)
        } catch {
            lastError = "Could not create path: \(hostPath). \(error.localizedDescription)"
        }
    }

    private func ensureHostPathsExist(for volumes: [RunVolumeMapping]) {
        let fileManager = FileManager.default
        for volume in volumes {
            let hostPath = (volume.hostPath as NSString).expandingTildeInPath
            guard hostPath.hasPrefix("/") else { continue }
            if isGeneratedEntrypointPath(hostPath) {
                continue
            }
            var isDirectory: ObjCBool = false
            if fileManager.fileExists(atPath: hostPath, isDirectory: &isDirectory) {
                continue
            }
            do {
                try fileManager.createDirectory(atPath: hostPath, withIntermediateDirectories: true)
            } catch {
                lastError = "Could not create path: \(hostPath). \(error.localizedDescription)"
            }
        }
    }

    private func handlePermissionHint(from errorText: String, hostPaths: [String], containerName: String?) async {
        guard !errorText.isEmpty else { return }
        let lower = errorText.lowercased()
        guard lower.contains("operation not permitted"),
              (lower.contains("chown") || lower.contains("ownership")) else { return }

        let uidGid = await resolveUidGid(containerName: containerName)
        let token = uidGid.map { "\($0.uid):\($0.gid)" } ?? "UID:GID"
        let uniquePaths = Array(Set(hostPaths)).sorted()
        let pathHints = uniquePaths.isEmpty
            ? "sudo chown -R \(token) /path/to/host"
            : uniquePaths.map { "sudo chown -R \(token) \($0)" }.joined(separator: "\n")

        _ = pathHints
        _ = uidGid
    }

    private func checkLogsForPermissionHint(containerName: String?, hostPaths: [String]) async {
        guard let name = containerName, !name.isEmpty else { return }
        let result = await ContainerCLI.shared.run(["logs", name])
        guard result.exitCode == 0 else { return }
        await handlePermissionHint(from: result.stdout, hostPaths: hostPaths, containerName: containerName)
    }

    private func extractHostPaths(from volumes: [RunVolumeMapping]) -> [String] {
        volumes.map { expandPath($0.hostPath) }.filter { $0.hasPrefix("/") }
    }

    private func extractHostPaths(from args: [String]) -> [String] {
        var paths: [String] = []
        var index = 0
        while index < args.count {
            let arg = args[index]
            if arg == "-v" || arg == "--volume" {
                if index + 1 < args.count {
                    if let hostPath = hostPathFromVolumeSpec(args[index + 1]) {
                        paths.append(hostPath)
                    }
                }
                index += 2
                continue
            }
            if arg.hasPrefix("-v") && arg.count > 2 {
                let value = String(arg.dropFirst(2))
                if let hostPath = hostPathFromVolumeSpec(value) {
                    paths.append(hostPath)
                }
                index += 1
                continue
            }
            if arg.hasPrefix("--volume=") {
                let value = String(arg.dropFirst("--volume=".count))
                if let hostPath = hostPathFromVolumeSpec(value) {
                    paths.append(hostPath)
                }
                index += 1
                continue
            }
            index += 1
        }
        return paths
    }

    private func extractContainerName(from args: [String]) -> String? {
        var index = 0
        while index < args.count {
            let arg = args[index]
            if arg == "--name", index + 1 < args.count {
                return args[index + 1]
            }
            if arg.hasPrefix("--name=") {
                return String(arg.dropFirst("--name=".count))
            }
            index += 1
        }
        return nil
    }

    private func resolveUidGid(containerName: String?) async -> (uid: Int, gid: Int)? {
        guard let name = containerName, !name.isEmpty else { return nil }
        let result = await ContainerCLI.shared.run(["exec", name, "id"])
        guard result.exitCode == 0 else { return nil }
        return parseUidGid(from: result.stdout)
    }

    private func resolveLatestContainerName() async -> String? {
        if !lastRunContainerName.isEmpty {
            return lastRunContainerName
        }
        let result = await ContainerCLI.shared.run(["list", "--all", "--format", "json"])
        guard result.exitCode == 0,
              let data = result.stdout.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([JSONValue].self, from: data) else { return nil }

        let objects = decoded.compactMap { value -> [String: JSONValue]? in
            if case .object(let object) = value { return object }
            return nil
        }

        let names = objects.compactMap { object -> String? in
            if case .object(let configuration) = object["configuration"] {
                return configuration.stringValue(for: ["id", "name", "Name"])
            }
            return object.stringValue(for: ["name", "Name", "id", "ID"])
        }

        return names.last
    }

    private func parseUidGid(from text: String) -> (uid: Int, gid: Int)? {
        let pattern = #"uid=(\d+).*gid=(\d+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              match.numberOfRanges >= 3,
              let uidRange = Range(match.range(at: 1), in: text),
              let gidRange = Range(match.range(at: 2), in: text),
              let uid = Int(text[uidRange]),
              let gid = Int(text[gidRange]) else { return nil }
        return (uid, gid)
    }

    private func hostPathFromVolumeSpec(_ spec: String) -> String? {
        let trimmed = spec.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let parts = trimmed.split(separator: ":", maxSplits: 2).map(String.init)
        guard let hostPathRaw = parts.first, !hostPathRaw.isEmpty else { return nil }
        let hostPath = expandPath(hostPathRaw)
        return hostPath.hasPrefix("/") ? hostPath : nil
    }

    private func expandPath(_ path: String) -> String {
        (path as NSString).expandingTildeInPath
    }

    private func resolvedCommandArgs(reference: String, config: RunImageConfig) -> [String] {
        let trimmed = config.command.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            return splitArguments(trimmed)
        }
        if config.overrideEntrypoint {
            return defaultCommandForImage(reference: reference)
        }
        return []
    }

    private func defaultCommandForImage(reference: String) -> [String] {
        let lower = reference.lowercased()
        if lower.contains("httpd") {
            return ["httpd-foreground"]
        }
        if lower.contains("apache") {
            return ["apache2-foreground"]
        }
        return []
    }

    private func detectEntrypointDefaultCommand(for reference: String) async -> [String] {
        guard let script = await extractEntrypointScript(from: reference) else { return [] }
        let lower = script.lowercased()
        if lower.contains("apache2-foreground") {
            return ["apache2-foreground"]
        }
        if lower.contains("httpd-foreground") {
            return ["httpd-foreground"]
        }
        return []
    }

    func generateChownFreeEntrypoint(for reference: String) async -> String? {
        lastError = ""
        let script = await extractEntrypointScript(from: reference)
        guard let script else {
            lastError = "No entrypoint script found."
            return nil
        }
        let filtered = script
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { line in
                let lower = line.lowercased()
                return !lower.contains("chown") && !lower.contains("chgrp")
            }
            .joined(separator: "\n")
        let path = writeEntrypointScript(filtered, for: reference)
        if path != nil { lastError = "" }
        return path
    }

    private func entrypointsDirectoryURL(fileManager: FileManager = .default) -> URL? {
        guard let baseURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        let dirURL = baseURL.appendingPathComponent("AppleContainerGUI/entrypoints", isDirectory: true)
        do {
            try fileManager.createDirectory(at: dirURL, withIntermediateDirectories: true)
        } catch {
            lastError = "Could not create entrypoint folder: \(error.localizedDescription)"
            return nil
        }
        return dirURL
    }

    private func isGeneratedEntrypointPath(_ path: String) -> Bool {
        guard path.contains("/AppleContainerGUI/entrypoints/") else { return false }
        return path.hasSuffix(".sh")
    }

    private func createNoChownEntrypointScript(for reference: String) -> String? {
        let fileManager = FileManager.default
        guard let dirURL = entrypointsDirectoryURL(fileManager: fileManager) else { return nil }

        let safeName = reference
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
        let fileURL = dirURL.appendingPathComponent("entrypoint_\(safeName).sh")

        let script = """
        #!/usr/bin/env bash
        set -e
        exec "$@"
        """

        do {
            if fileManager.fileExists(atPath: fileURL.path) {
                try fileManager.removeItem(at: fileURL)
            }
            try script.write(to: fileURL, atomically: true, encoding: .utf8)
            try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fileURL.path)
        } catch {
            if error.localizedDescription.lowercased().contains("already exists"),
               fileManager.fileExists(atPath: fileURL.path) {
                lastError = ""
                return fileURL.path
            }
            lastError = "Could not write entrypoint file: \(error.localizedDescription)"
            return nil
        }

        lastError = ""
        return fileURL.path
    }

    private func extractEntrypointScript(from reference: String) async -> String? {
        let candidates = [
            "/usr/local/bin/entrypoint.sh",
            "/entrypoint.sh",
            "/docker-entrypoint.sh"
        ]
        let probe = candidates
            .map { "if [ -f \($0) ]; then cat \($0); exit 0; fi" }
            .joined(separator: "; ")
        let cmd = "\(probe); exit 1"
        let result = await ContainerCLI.shared.run(["run", "--rm", "--entrypoint", "sh", reference, "-lc", cmd])
        guard result.exitCode == 0, !result.stdout.isEmpty else { return nil }
        return result.stdout
    }

    private func writeEntrypointScript(_ script: String, for reference: String) -> String? {
        let fileManager = FileManager.default
        guard let dirURL = entrypointsDirectoryURL(fileManager: fileManager) else { return nil }

        let safeName = reference
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
        let fileURL = dirURL.appendingPathComponent("entrypoint_\(safeName).sh")

        let content = script.hasPrefix("#!") ? script : "#!/usr/bin/env bash\nset -e\n\n\(script)"
        do {
            if fileManager.fileExists(atPath: fileURL.path) {
                try fileManager.removeItem(at: fileURL)
            }
            try content.write(to: fileURL, atomically: true, encoding: .utf8)
            try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fileURL.path)
        } catch {
            if fileManager.fileExists(atPath: fileURL.path) {
                lastError = ""
                return fileURL.path
            }
            if error.localizedDescription.lowercased().contains("already exists"),
               fileManager.fileExists(atPath: fileURL.path) {
                lastError = ""
                return fileURL.path
            }
            lastError = "Could not write entrypoint file: \(error.localizedDescription)"
            return nil
        }

        return fileURL.path
    }

    private func applyEntrypointOverrideIfNeeded(to args: [String], customEntrypointPath: String) -> [String] {
        guard let runIndex = args.firstIndex(of: "run") else { return args }
        if args.contains("--entrypoint") || args.contains(where: { $0.hasPrefix("--entrypoint=") }) {
            return args
        }

        let imageIndex = findImageIndex(in: args, startingAt: runIndex + 1)
        guard let imageIndex else { return args }

        let imageRef = args[imageIndex]
        let scriptPath = customEntrypointPath.isEmpty
            ? createNoChownEntrypointScript(for: imageRef)
            : customEntrypointPath
        guard let scriptPath, !scriptPath.isEmpty else {
            return args
        }

        var updated = args
        let hadCommandArgs = imageIndex + 1 < args.count
        updated.insert(contentsOf: ["-v", "\(scriptPath):/usr/local/bin/entrypoint.sh", "--entrypoint", "/usr/local/bin/entrypoint.sh"], at: imageIndex)

        if !hadCommandArgs {
            let defaults = defaultCommandForImage(reference: imageRef)
            if !defaults.isEmpty {
                updated.append(contentsOf: defaults)
            }
        }

        return updated
    }

    func extractImageReference(from rawArguments: String) -> String? {
        let args = splitArguments(rawArguments)
        guard let runIndex = args.firstIndex(of: "run") else { return nil }
        guard let imageIndex = findImageIndex(in: args, startingAt: runIndex + 1) else { return nil }
        return args[imageIndex]
    }

    private func findImageIndex(in args: [String], startingAt start: Int) -> Int? {
        let flagsWithValues: Set<String> = [
            "--name", "-p", "--publish", "-v", "--volume", "--dns", "-e", "--env", "--cpus", "--memory", "--entrypoint"
        ]

        var index = start
        while index < args.count {
            let arg = args[index]
            if flagsWithValues.contains(arg) {
                index += 2
                continue
            }
            if arg.hasPrefix("-") {
                index += 1
                continue
            }
            return index
        }
        return nil
    }

    private func looksLikeImageReference(_ input: String) -> Bool {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.contains(" ") { return false }
        if trimmed.contains(":") { return true }
        if trimmed.contains("/") { return true }
        return false
    }

    private func qualifiedReference(_ reference: String, registry: RegistryOption, customHost: String) -> String {
        let trimmed = reference.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return trimmed }
        if hasRegistryHost(trimmed) { return trimmed }
        switch registry {
        case .dockerHub:
            if trimmed.contains("/") { return "docker.io/\(trimmed)" }
            return "docker.io/library/\(trimmed)"
        case .github:
            if trimmed.contains("/") { return "ghcr.io/\(trimmed)" }
            return "ghcr.io/\(trimmed)"
        case .quay:
            if trimmed.contains("/") { return "quay.io/\(trimmed)" }
            return "quay.io/\(trimmed)"
        case .gitlab:
            if trimmed.contains("/") { return "registry.gitlab.com/\(trimmed)" }
            return "registry.gitlab.com/\(trimmed)"
        case .custom:
            let host = customHost.trimmingCharacters(in: .whitespacesAndNewlines)
            if host.isEmpty { return trimmed }
            return "\(host)/\(trimmed)"
        }
    }

    private func hasRegistryHost(_ reference: String) -> Bool {
        guard let slashIndex = reference.firstIndex(of: "/") else { return false }
        let firstComponent = reference[..<slashIndex]
        return firstComponent.contains(".")
            || firstComponent.contains(":")
            || firstComponent == "localhost"
    }

    private func parsePorts(from configurationObject: [String: JSONValue]) -> [ContainerPortMapping] {
        guard case .array(let portsArray) = configurationObject["publishedPorts"] else { return [] }
        return portsArray.compactMap { value in
            guard case .object(let portObject) = value else { return nil }
            let hostPort = portValueString(from: portObject["hostPort"])
            let containerPort = portValueString(from: portObject["containerPort"])
            let hostAddress = portObject.stringValue(for: ["hostAddress"]) ?? ""
            return ContainerPortMapping(
                id: "\(hostAddress):\(hostPort):\(containerPort):\(portObject.stringValue(for: ["proto"]) ?? "tcp")",
                hostPort: hostPort,
                containerPort: containerPort,
                hostAddress: hostAddress
            )
        }
    }

    private func imageSizeString(from object: [String: JSONValue]) -> String {
        if case .array(let variants) = object["variants"] {
            let sizes = variants.compactMap { value -> Double? in
                guard case .object(let variant) = value, case .number(let size) = variant["size"] else { return nil }
                return size
            }
            if !sizes.isEmpty { return formatBytes(sizes.reduce(0, +)) }
        }
        for key in ["size", "Size", "fullSize", "full_size", "FullSize", "full_size_bytes"] {
            if case .number(let size) = object[key] { return formatBytes(size) }
            if case .string(let value) = object[key], !value.isEmpty {
                return Double(value).map { formatBytes($0) } ?? value
            }
        }
        return ""
    }

    private func formatBytes(_ bytesValue: Double) -> String {
        Self.formatBytesStatic(bytesValue)
    }

    private nonisolated static func formatBytesStatic(_ bytesValue: Double) -> String {
        let bytes = max(0, bytesValue)
        let units = ["B", "KB", "MB", "GB", "TB"]
        var value = bytes
        var unitIndex = 0
        while value >= 1024, unitIndex < units.count - 1 {
            value /= 1024
            unitIndex += 1
        }
        if unitIndex == 0 {
            return "\(Int(value)) \(units[unitIndex])"
        }
        return String(format: "%.1f %@", value, units[unitIndex])
    }

    private func portValueString(from value: JSONValue?) -> String {
        guard let value else { return "" }
        switch value {
        case .number(let number):
            if number.rounded() == number {
                return String(Int(number))
            }
            return String(number)
        case .string(let string):
            return string
        case .bool(let bool):
            return bool ? "true" : "false"
        case .null, .array, .object:
            return ""
        }
    }

    private func imageReference(for container: ContainerListItem) -> String? {
        guard case .object(let configuration) = container.raw["configuration"] else { return nil }
        if case .object(let imageObject) = configuration["image"] {
            return imageObject.stringValue(for: ["reference", "name", "image", "Image"])
        }
        return configuration.stringValue(for: ["image", "Image"])
    }

    private func parseVolumes(from raw: [String: JSONValue]) -> [RunVolumeMapping] {
        guard case .object(let configuration) = raw["configuration"] else { return [] }
        guard case .array(let mounts) = configuration["mounts"] else { return [] }

        return mounts.compactMap { mount in
            guard case .object(let mountObject) = mount else { return nil }
            let hostPath = mountObject.stringValue(for: ["source", "Source"]) ?? ""
            let containerPath = mountObject.stringValue(for: ["destination", "Destination", "target", "Target"]) ?? ""
            let readOnly = mountIsReadOnly(mountObject)
            guard !hostPath.isEmpty, !containerPath.isEmpty else { return nil }
            return RunVolumeMapping(id: UUID(), hostPath: hostPath, containerPath: containerPath, readOnly: readOnly)
        }
    }

    private func extractEntrypointOverride(from raw: [String: JSONValue]) -> (isEnabled: Bool, customPath: String) {
        guard case .object(let configuration) = raw["configuration"] else { return (false, "") }
        guard case .array(let mounts) = configuration["mounts"] else { return (false, "") }

        for mount in mounts {
            guard case .object(let mountObject) = mount else { continue }
            let destination = mountObject.stringValue(for: ["destination", "Destination", "target", "Target"]) ?? ""
            if destination == "/usr/local/bin/entrypoint.sh" {
                let source = mountObject.stringValue(for: ["source", "Source"]) ?? ""
                return (true, source)
            }
        }
        return (false, "")
    }

    private func mountIsReadOnly(_ mountObject: [String: JSONValue]) -> Bool {
        if case .array(let options) = mountObject["options"] {
            for option in options {
                if case .string(let value) = option, value.lowercased() == "ro" || value.lowercased() == "readonly" {
                    return true
                }
            }
        }
        if case .bool(let readOnly) = mountObject["readOnly"] {
            return readOnly
        }
        return false
    }

    private func parseEnvironment(from raw: [String: JSONValue]) -> [RunEnvVar] {
        guard case .object(let configuration) = raw["configuration"] else { return [] }
        guard case .object(let initProcess) = configuration["initProcess"] else { return [] }
        guard case .array(let environment) = initProcess["environment"] else { return [] }

        return environment.compactMap { item in
            guard case .string(let entry) = item else { return nil }
            let parts = entry.split(separator: "=", maxSplits: 1).map(String.init)
            guard let key = parts.first, !key.isEmpty else { return nil }
            let value = parts.count > 1 ? parts[1] : ""
            return RunEnvVar(id: UUID(), key: key, value: value)
        }
    }

    private func parseCommand(from raw: [String: JSONValue]) -> String {
        guard case .object(let configuration) = raw["configuration"] else { return "" }
        guard case .object(let initProcess) = configuration["initProcess"] else { return "" }
        guard case .array(let arguments) = initProcess["arguments"] else { return "" }

        let parts: [String] = arguments.compactMap { value in
            if case .string(let string) = value { return string }
            return nil
        }
        return parts.joined(separator: " ")
    }

    private func numericString(from value: JSONValue?) -> String {
        guard let value else { return "" }
        switch value {
        case .number(let number):
            if number.rounded() == number {
                return String(Int(number))
            }
            return String(number)
        case .string(let string):
            return string
        default:
            return ""
        }
    }

    private func memoryString(from value: JSONValue?) -> String {
        guard let value else { return "" }
        switch value {
        case .number(let number):
            let bytes = Int(number)
            let oneGiB = 1024 * 1024 * 1024
            if bytes % oneGiB == 0 {
                return "\(bytes / oneGiB)g"
            }
            let oneMiB = 1024 * 1024
            if bytes % oneMiB == 0 {
                return "\(bytes / oneMiB)m"
            }
            return String(bytes)
        case .string(let string):
            return string
        default:
            return ""
        }
    }
}

struct DockerHubSearchResponse: Decodable {
    let results: [DockerHubRepository]
}

actor StreamBuffer {
    private var data = Data()

    func append(_ chunk: Data) {
        data.append(chunk)
    }

    func snapshot() -> Data {
        data
    }
}
enum RegistryOption: String, CaseIterable, Identifiable {
    case dockerHub = "docker.io"
    case github = "ghcr.io"
    case quay = "quay.io"
    case gitlab = "registry.gitlab.com"
    case custom = "custom"

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .dockerHub: return "Docker Hub"
        case .github: return "GitHub (GHCR)"
        case .quay: return "Quay"
        case .gitlab: return "GitLab"
        case .custom: return "Custom Registry"
        }
    }

    var requiresOwner: Bool {
        switch self {
        case .dockerHub: return false
        case .github, .quay, .gitlab: return true
        case .custom: return false
        }
    }

    var supportsSearch: Bool {
        switch self {
        case .dockerHub: return true
        case .github, .quay, .gitlab, .custom: return false
        }
    }

    var registryHost: String? {
        switch self {
        case .custom: return nil
        default: return rawValue
        }
    }
}
