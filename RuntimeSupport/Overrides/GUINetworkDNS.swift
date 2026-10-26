import ContainerAPIClient
import ContainerResource
import Foundation

final class GUINetworkDNS: @unchecked Sendable {
    static let shared = GUINetworkDNS()
    private let lock = NSLock()
    private var forwarders: Set<String> = []
    private var memberships: [String: Set<String>] = [:]
    private var records: [String: [String: String]] = [:]
    private var extraHosts: [String: [String: String]] = [:]
    private var names: Set<String> = []

    static func refresh() async {
        guard let snapshots = try? await ContainerClient().list() else { return }
        shared.replace(snapshots.map { GUINetworkAttachment.hydrated($0) })
    }

    func replace(_ snapshots: [ContainerSnapshot]) {
        var forwarders: Set<String> = []
        var memberships: [String: Set<String>] = [:]
        var records: [String: [String: String]] = [:]
        var names: Set<String> = []
        var extraHosts: [String: [String: String]] = [:]
        for container in snapshots where container.status == .running {
            let attached = Set(container.networks.map(\.network))
            for endpoint in container.networks {
                memberships[endpoint.ipv4Address.address.description] = attached
            }
            if ClientContainerService.isDNSSidecar(container) {
                forwarders.formUnion(container.networks.map { $0.ipv4Address.address.description })
                continue
            }
            let explicit = GUIExtraHosts.entries(container.configuration)
            for endpoint in container.networks {
                extraHosts[endpoint.ipv4Address.address.description] = explicit.mapValues {
                    $0 == "host-gateway" ? endpoint.ipv4Gateway.description : $0
                }
            }
            names.formUnion(explicit.keys)
            let configured = GUINetworkAttachment.aliases(container.configuration)
            for endpoint in container.networks {
                var aliases = [container.id]
                if let scoped = configured[endpoint.network] { aliases += scoped }
                else if configured.isEmpty, let legacy = container.configuration.labels["socktainer.dns.names"] { aliases += legacy.split(separator: ",").map(String.init) }
                if let service = container.configuration.labels["com.docker.compose.service"] { aliases.append(service) }
                for alias in aliases where !alias.isEmpty {
                    let key = alias.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
                    records[endpoint.network, default: [:]][key] = endpoint.ipv4Address.address.description
                    names.insert(key)
                }
            }
        }
        lock.lock()
        self.forwarders = forwarders
        self.memberships = memberships
        self.records = records
        self.names = names
        self.extraHosts = extraHosts
        lock.unlock()
    }

    func address(name: String, source: String) -> [UInt8]? {
        lock.lock()
        defer { lock.unlock() }
        if let address = extraHosts[source]?[name] { return address.split(separator: ".").compactMap { UInt8($0) } }
        for network in (memberships[source] ?? []).sorted() {
            if let address = records[network]?[name] { return address.split(separator: ".").compactMap { UInt8($0) } }
        }
        return nil
    }

    func contains(_ name: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return names.contains(name)
    }

    func decodePacket(_ bytes: [UInt8], source: String) -> (packet: [UInt8], source: String) {
        guard bytes.count >= 12, bytes.count <= 4096 else { return ([], source) }
        lock.lock()
        defer { lock.unlock() }
        if Array(bytes.prefix(4)) == [65, 67, 71, 56] {
            guard bytes.count >= 20 else { return ([], source) }
            let forwarded = bytes[4..<8].map(String.init).joined(separator: ".")
            guard forwarders.contains(source),
                  !(memberships[source] ?? []).isDisjoint(with: memberships[forwarded] ?? []) else { return ([], source) }
            return (Array(bytes.dropFirst(8)), forwarded)
        }
        guard memberships[source]?.isEmpty == false else { return ([], source) }
        return (bytes, source)
    }

    static func decode(_ bytes: [UInt8], source: String) -> (packet: [UInt8], source: String) {
        shared.decodePacket(bytes, source: source)
    }
}
