import ContainerAPIClient
import ContainerNetworkClient
import ContainerResource
import Foundation
import Vapor

actor GUINetworkAttachment {
    static let shared = GUINetworkAttachment()
    static let aliasesLabel = "socktainer.network.aliases"
    private var changing: Set<String> = []

    struct Transaction: Codable {
        var files: [String: Data]
        var wasRunning: Bool
    }

    static func recover() async {
        guard let containers = try? await ContainerClient().list() else { return }
        for container in containers {
            let root = directory(container.id)
            let journal = root.appendingPathComponent("gui-network-transaction.json")
            guard let data = try? Data(contentsOf: journal) else { continue }
            do {
                let transaction = try JSONDecoder().decode(Transaction.self, from: data)
                if container.status == .stopped {
                    for (name, original) in transaction.files where ["config.json", "runtime-configuration.json"].contains(name) {
                        try original.write(to: root.appendingPathComponent(name), options: .atomic)
                    }
                    if transaction.wasRunning { try await ClientContainerService().start(id: container.id, detachKeys: nil) }
                }
                try FileManager.default.removeItem(at: journal)
            } catch { Logger(label: "socktainer.network").error("Network transaction recovery failed for \(container.id): \(error)") }
        }
    }

    static func directory(_ id: String) -> URL {
        URL(fileURLWithPath: ProcessInfo.processInfo.environment["CONTAINER_APP_ROOT"] ?? NSHomeDirectory() + "/Library/Application Support/com.apple.container").appendingPathComponent("containers").appendingPathComponent(id)
    }

    static func hydrated(_ snapshot: ContainerSnapshot) -> ContainerSnapshot {
        var result = snapshot
        let root = directory(snapshot.id)
        if let data = try? Data(contentsOf: root.appendingPathComponent("config.json")),
           let config = try? JSONDecoder().decode(ContainerConfiguration.self, from: data), config.id == snapshot.id {
            result.configuration = config
        } else if let data = try? Data(contentsOf: root.appendingPathComponent("runtime-configuration.json")),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let value = object["containerConfiguration"],
                  let encoded = try? JSONSerialization.data(withJSONObject: value),
                  let config = try? JSONDecoder().decode(ContainerConfiguration.self, from: encoded), config.id == snapshot.id {
            result.configuration = config
        }
        return result
    }

    static func aliases(_ configuration: ContainerConfiguration) -> [String: [String]] {
        guard let value = configuration.labels[aliasesLabel], let data = value.data(using: .utf8),
              let aliases = try? JSONDecoder().decode([String: [String]].self, from: data) else { return [:] }
        return aliases
    }

    func change(network: String, container reference: String, aliases: [String], disconnect: Bool, force: Bool, request: Request) async throws {
        let service = ClientContainerService()
        guard let initial = try await service.getContainer(id: reference) else { throw Abort(.notFound, reason: "No such container: \(reference)") }
        guard !ClientContainerService.isDNSSidecar(initial) else { throw Abort(.conflict, reason: "Internal DNS container") }
        guard changing.insert(initial.id).inserted else { throw Abort(.conflict, reason: "Container network configuration is already changing") }
        defer { changing.remove(initial.id) }
        await GUIDNSCleanup.shared.beginCreation()
        defer { Task { await GUIDNSCleanup.shared.endCreation() } }
        guard let target = try await ClientNetworkService().getNetwork(id: network, logger: request.logger) else { throw Abort(.notFound, reason: "No such network: \(network)") }
        guard !["host", "none"].contains(target.Name) else { throw Abort(.badRequest, reason: "This network cannot be attached") }
        var config = initial.configuration
        let exists = config.networks.contains { $0.network == target.Name }
        if disconnect && !exists {
            if force { return }
            throw Abort(.notFound, reason: "Container is not connected to network \(target.Name)")
        }
        if !disconnect && exists { throw Abort(.conflict, reason: "Endpoint already exists in network \(target.Name)") }
        guard initial.status == .running || initial.status == .stopped else { throw Abort(.conflict, reason: "Container is changing state") }
        let directory = Self.directory(initial.id)
        let optionsURL = directory.appendingPathComponent("options.json")
        let runtimeURL = directory.appendingPathComponent("runtime-configuration.json")
        let runtime = (try? Data(contentsOf: runtimeURL)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let options = (try? Data(contentsOf: optionsURL)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? runtime?["options"] as? [String: Any] ?? [:]
        guard options["autoRemove"] as? Bool != true || initial.status != .running else {
            throw Abort(.conflict, reason: "Apple Container needs a restart to change networks; running auto-remove containers cannot be restarted safely")
        }
        var mapping = Self.aliases(config)
        if disconnect {
            config.networks.removeAll { $0.network == target.Name }
            mapping.removeValue(forKey: target.Name)
        } else {
            config.networks.append(AttachmentConfiguration(network: target.Name, options: AttachmentOptions(hostname: config.id)))
            mapping[target.Name] = aliases
        }
        config.labels[Self.aliasesLabel] = String(decoding: try JSONEncoder().encode(mapping), as: UTF8.self)
        if let manager = request.application.storage[NetworkDNSManagerKey.self],
           let named = ContainerStartRoute.sidecarNetwork(configuredNetworks: config.networks.map(\.network), roleLabel: nil) ?? GUIExtraHosts.network(config) {
            let address = try await manager.ensureDNSContainer(networkId: named)
            let old = config.dns
            config.dns = ContainerConfiguration.DNSConfiguration(nameservers: [address], domain: old?.domain, searchDomains: old?.searchDomains ?? [], options: old?.options ?? [])
        } else {
            config.dns = ContainerConfiguration.DNSConfiguration(nameservers: [], domain: nil, searchDomains: [], options: [])
        }
        let running = initial.status == .running
        var backups: [(URL, Data)] = []
        for filename in ["config.json", "runtime-configuration.json"] {
            let url = directory.appendingPathComponent(filename)
            if FileManager.default.fileExists(atPath: url.path) { backups.append((url, try Data(contentsOf: url))) }
        }
        guard !backups.isEmpty else { throw Abort(.internalServerError, reason: "Container configuration is unavailable") }
        let journal = directory.appendingPathComponent("gui-network-transaction.json")
        let transaction = Transaction(files: Dictionary(uniqueKeysWithValues: backups.map { ($0.0.lastPathComponent, $0.1) }), wasRunning: running)
        try JSONEncoder().encode(transaction).write(to: journal, options: .atomic)
        if running {
            try await service.stop(id: initial.id, signal: nil, timeout: 10)
            for _ in 0..<100 {
                if try await service.getContainer(id: initial.id)?.status == .stopped { break }
                try await Task.sleep(for: .milliseconds(100))
            }
            guard try await service.getContainer(id: initial.id)?.status == .stopped else { throw Abort(.conflict, reason: "Container did not stop for network update") }
        }
        do {
            let encoded = try JSONEncoder().encode(config)
            let object = try JSONSerialization.jsonObject(with: encoded)
            for (url, original) in backups {
                if url.lastPathComponent == "config.json" {
                    try encoded.write(to: url, options: .atomic)
                } else {
                    var runtime = try JSONSerialization.jsonObject(with: original) as! [String: Any]
                    runtime["containerConfiguration"] = object
                    try JSONSerialization.data(withJSONObject: runtime, options: [.sortedKeys]).write(to: url, options: .atomic)
                }
            }
            if running { try await restart(id: initial.id, request: request) }
            await GUINetworkDNS.refresh()
            try FileManager.default.removeItem(at: journal)
            if let broadcaster = request.application.storage[EventBroadcasterKey.self] {
                await broadcaster.broadcast(DockerEvent.make(type: "network", action: disconnect ? "disconnect" : "connect", actorID: target.Id, attributes: ["name": target.Name, "container": DockerContainerID.hexId(for: initial)]))
            }
        } catch {
            let failure = error
            if let current = try? await service.getContainer(id: initial.id), current.status == .running {
                try await service.stop(id: initial.id, signal: nil, timeout: 10)
            }
            for (url, original) in backups { try original.write(to: url, options: .atomic) }
            if running {
                do { try await restart(id: initial.id, request: request) }
                catch { throw Abort(.internalServerError, reason: "Network update failed; previous configuration restored but restart failed: \(error)") }
            }
            try FileManager.default.removeItem(at: journal)
            throw Abort(.internalServerError, reason: "Network update rolled back: \(failure)")
        }
    }

    private func restart(id: String, request: Request) async throws {
        let service = ClientContainerService()
        try await service.start(id: id, detachKeys: nil)
        guard let snapshot = await ContainerStartRoute.performPostStartSetup(id: id, client: service, dnsServer: request.application.storage[SocktainerDNSServerKey.self], healthManager: request.application.storage[HealthCheckManagerKey.self], logger: request.logger) else {
            throw Abort(.internalServerError, reason: "Container did not restart")
        }
        if let broadcaster = request.application.storage[EventBroadcasterKey.self],
           let dns = request.application.storage[SocktainerDNSServerKey.self],
           let health = request.application.storage[HealthCheckManagerKey.self] {
            await GUIRestartRecovery.resume(container: snapshot, broadcaster: broadcaster, dnsServer: dns, healthManager: health, logger: request.logger)
        }
    }
}

struct GUINetworkConnectBody: Content {
    var Container: String
    var EndpointConfig: ContainerEndpointSettings?
    var Force: Bool?
}

struct GUINetworkAPI {
    static func handle(_ request: Request, disconnect: Bool) async throws -> Response {
        guard let network = request.parameters.get("id") else { throw Abort(.badRequest, reason: "Missing network ID") }
        let body = try request.content.decode(GUINetworkConnectBody.self)
        if let endpoint = body.EndpointConfig {
            guard endpoint.IPAMConfig?.IPv4Address?.isEmpty ?? true,
                  endpoint.IPAMConfig?.IPv6Address?.isEmpty ?? true,
                  endpoint.IPAMConfig?.LinkLocalIPs?.isEmpty ?? true,
                  endpoint.IPAddress?.isEmpty ?? true, endpoint.GlobalIPv6Address?.isEmpty ?? true,
                  endpoint.Links?.isEmpty ?? true, endpoint.DriverOpts?.isEmpty ?? true else {
                throw Abort(.badRequest, reason: "Static endpoint addresses, links and driver options are not supported by Apple Container")
            }
        }
        do {
            try await GUINetworkAttachment.shared.change(network: network, container: body.Container, aliases: body.EndpointConfig?.Aliases ?? [], disconnect: disconnect, force: body.Force ?? false, request: request)
        } catch ClientContainerError.notFound {
            throw Abort(.notFound, reason: "No such container: \(body.Container)")
        } catch ClientContainerError.ambiguousId {
            throw Abort(.badRequest, reason: "Container reference is ambiguous")
        }
        return Response(status: .ok)
    }
}
