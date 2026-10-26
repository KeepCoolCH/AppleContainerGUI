import ContainerAPIClient
import ContainerPersistence
import Vapor
import ContainerizationOCI
import Foundation
import CryptoKit

struct GUIImageProvenance {
    struct Receipt: Codable {
        let reference: String
        let localDigest: String
        let registryDigest: String
    }

    static var directory: URL {
        GUIVirtioFSVolumes.root.deletingLastPathComponent().appendingPathComponent("image-origins")
    }

    static func receiptURL(_ image: ClientImage) -> URL {
        directory.appendingPathComponent(SHA256.hash(data: Data(image.reference.utf8)).map { String(format: "%02x", $0) }.joined() + ".json")
    }

    static func resolve(_ reference: String, systemConfig: ContainerSystemConfig) async throws -> ClientImage {
        if let image = try? await ClientImage.get(reference: reference, containerSystemConfig: systemConfig) { return image }
        let digest = reference.hasPrefix("sha256:") ? String(reference.dropFirst(7)) : reference
        guard (12...64).contains(digest.count), digest.allSatisfy({ $0.isHexDigit }) else {
            throw Abort(.notFound, reason: "No such image: \(reference)")
        }
        var matches: [String: ClientImage] = [:]
        for image in try await ClientImage.list() {
            if image.digest.replacingOccurrences(of: "sha256:", with: "").hasPrefix(digest) { matches[image.digest] = image }
            guard let index = try? await image.index() else { continue }
            for descriptor in index.manifests {
                guard let platform = descriptor.platform,
                      let manifest = try? await image.manifest(for: platform),
                      manifest.config.digest.replacingOccurrences(of: "sha256:", with: "").hasPrefix(digest) else { continue }
                matches[manifest.config.digest] = image
            }
        }
        guard matches.count == 1, let image = matches.values.first else {
            throw Abort(matches.isEmpty ? .notFound : .conflict, reason: "Image ID is missing or ambiguous: \(reference)")
        }
        return image
    }

    static func recordPull(_ image: ClientImage) async throws {
        let index = try await image.index()
        let registryDigest = ["true", "1"].contains(index.annotations?[AnnotationKeys.containerizationIndexIndirect]?.lowercased() ?? "")
            ? index.manifests.first?.digest : image.digest
        guard let registryDigest else { return }
        let receipt = Receipt(reference: image.reference, localDigest: image.digest, registryDigest: registryDigest)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(receipt).write(to: receiptURL(image), options: .atomic)
    }

    static func repoDigests(_ image: ClientImage) -> [String] {
        guard let data = try? Data(contentsOf: receiptURL(image)),
              let receipt = try? JSONDecoder().decode(Receipt.self, from: data),
              receipt.reference == image.reference, receipt.localDigest == image.digest,
              let reference = try? Reference.parse(image.reference) else { return [] }
        return ["\(reference.name)@\(receipt.registryDigest)"]
    }

    static func isAncestor(layers: [String], history: [Data], childLayers: [String], childHistory: [Data]) -> Bool {
        !layers.isEmpty && !history.isEmpty && history.count + 1 == childHistory.count
            && layers.count <= childLayers.count
            && Array(childLayers.prefix(layers.count)) == layers
            && Array(childHistory.prefix(history.count)) == history
    }

    static func parent(of image: ClientImage, platform: Platform) async -> String {
        guard let child = try? await image.config(for: platform),
              let images = try? await ClientImage.list() else { return "" }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let childHistory = try? (child.history ?? []).map({ try encoder.encode($0) }) else { return "" }
        var matches: [(String, Int)] = []
        for candidate in images where candidate.digest != image.digest {
            guard let config = try? await candidate.config(for: platform),
                  let history = try? (config.history ?? []).map({ try encoder.encode($0) }),
                  isAncestor(layers: config.rootfs.diffIDs, history: history, childLayers: child.rootfs.diffIDs, childHistory: childHistory),
                  let manifest = try? await candidate.manifest(for: platform) else { continue }
            matches.append((manifest.config.digest, history.count))
        }
        guard let longest = matches.map(\.1).max() else { return "" }
        let closest = Set(matches.filter { $0.1 == longest }.map(\.0))
        return closest.count == 1 ? closest.first! : ""
    }
}
