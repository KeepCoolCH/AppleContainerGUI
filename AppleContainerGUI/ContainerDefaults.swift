import Foundation

nonisolated struct ContainerDefaults: Codable, Equatable, Sendable {
    var cpus: Int
    var memoryMiB: Int

    static var maximumCPUs: Int { max(1, ProcessInfo.processInfo.processorCount) }
    static var maximumMemoryMiB: Int { max(256, Int(ProcessInfo.processInfo.physicalMemory / (1024 * 1024)) - 128) }
    static var standard: ContainerDefaults {
        ContainerDefaults(cpus: min(maximumCPUs, ((maximumCPUs + 3) / 4) * 2), memoryMiB: min(maximumMemoryMiB, max(256, Int(ProcessInfo.processInfo.physicalMemory / (4 * 1024 * 1024)))))
    }

    var memoryInBytes: UInt64 { UInt64(memoryMiB) * 1024 * 1024 }

    func validate() throws {
        guard (1...1024).contains(cpus), (256...16_777_216).contains(memoryMiB) else {
            throw NSError(domain: "ContainerDefaults", code: 1, userInfo: [NSLocalizedDescriptionKey: "Use 1–1024 CPUs and 256–16777216 MiB of memory."])
        }
    }

    static func load(from url: URL) throws -> ContainerDefaults? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let value = try JSONDecoder().decode(ContainerDefaults.self, from: Data(contentsOf: url))
        try value.validate()
        return value
    }

    func save(to url: URL) throws {
        try validate()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }

    func resolveCPUs(requestedNanoCpus: Int?) -> Int {
        guard let requestedNanoCpus, requestedNanoCpus > 0 else { return cpus }
        return max(1, requestedNanoCpus / 1_000_000_000)
    }

    func resolveMemory(requestedBytes: Int?) -> UInt64 {
        guard let requestedBytes, requestedBytes > 0 else { return memoryInBytes }
        return UInt64(requestedBytes)
    }
}
