import ContainerResource
import Darwin
import Foundation
import Vapor

enum GUIExtraHosts {
    static let label = "socktainer.extra-hosts"

    static func parse(_ entries: [String]) throws -> [String: String] {
        var result: [String: String] = [:]
        for entry in entries {
            guard let separator = entry.firstIndex(where: { $0 == ":" || $0 == "=" }) else {
                throw Abort(.badRequest, reason: "Invalid extra host: expected hostname:address")
            }
            let name = String(entry[..<separator]).lowercased()
            let address = String(entry[entry.index(after: separator)...])
            guard !name.isEmpty, name.utf8.count <= 253,
                  name.utf8.allSatisfy({ (45...46).contains($0) || (48...57).contains($0) || (97...122).contains($0) || $0 == 95 }) else {
                throw Abort(.badRequest, reason: "Invalid extra host name")
            }
            var ipv4 = in_addr()
            guard address == "host-gateway" || inet_pton(AF_INET, address, &ipv4) == 1 else {
                throw Abort(.badRequest, reason: "ExtraHosts currently supports IPv4 addresses and host-gateway")
            }
            result[name.trimmingCharacters(in: CharacterSet(charactersIn: "."))] = address
        }
        return result
    }

    static func entries(_ config: ContainerConfiguration) -> [String: String] {
        guard let data = config.labels[label]?.data(using: .utf8) else { return [:] }
        return (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
    }

    static func network(_ config: ContainerConfiguration) -> String? {
        guard !entries(config).isEmpty else { return nil }
        return config.networks.first { !["host", "none"].contains($0.network) }?.network
    }
}
