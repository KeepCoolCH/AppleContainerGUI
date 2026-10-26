import ContainerAPIClient
import Foundation
import Vapor

actor GUIDNSCleanup {
    static let shared = GUIDNSCleanup()
    private var activeCreations = 0
    private var maintenance: Task<Void, Never>?
    private var unusedSince: [String: Date] = [:]
    private var monitor: Task<Void, Never>?

    func beginCreation() async {
        while let maintenance { await maintenance.value }
        activeCreations += 1
    }

    func endCreation() {
        activeCreations -= 1
    }

    func start(manager: NetworkDNSManager) {
        guard monitor == nil else { return }
        monitor = Task {
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(15)) } catch { return }
                await sweep(manager: manager)
            }
        }
    }

    func stop() {
        monitor?.cancel()
        monitor = nil
    }

    static func unusedNetworks(helpers: Set<String>, referencedNetworks: Set<String>) -> Set<String> {
        helpers.subtracting(referencedNetworks)
    }

    private func sweep(manager: NetworkDNSManager) async {
        guard activeCreations == 0, maintenance == nil else { return }
        let task = Task { await self.removeUnused(manager: manager) }
        maintenance = task
        await task.value
        maintenance = nil
    }

    private func removeUnused(manager: NetworkDNSManager) async {
        let client = ContainerClient()
        guard let listed = try? await client.list() else { unusedSince = [:]; return }
        let containers = listed.map { GUINetworkAttachment.hydrated($0) }
        let helpers = Set(containers.filter { ClientContainerService.isDNSSidecar($0) }.compactMap {
            $0.configuration.labels[NetworkDNSManager.networkLabel]
        })
        let referenced = Set(containers.filter { !ClientContainerService.isDNSSidecar($0) }.flatMap {
            $0.configuration.networks.map(\.network) + $0.networks.map(\.network)
        })
        let unused = Self.unusedNetworks(helpers: helpers, referencedNetworks: referenced)
        unusedSince = unusedSince.filter { unused.contains($0.key) }
        for network in unused {
            let now = Date()
            guard let since = unusedSince[network] else { unusedSince[network] = now; continue }
            guard now.timeIntervalSince(since) >= 60, !Task.isCancelled else { continue }
            guard let observed = try? await client.list() else { unusedSince = [:]; return }
            let latest = observed.map { GUINetworkAttachment.hydrated($0) }
            guard !latest.contains(where: {
                !ClientContainerService.isDNSSidecar($0) &&
                ($0.configuration.networks.contains { $0.network == network } || $0.networks.contains { $0.network == network })
            }) else { unusedSince.removeValue(forKey: network); continue }
            await manager.cleanupDNSContainer(networkId: network)
            unusedSince.removeValue(forKey: network)
        }
    }
}

struct GUIDNSCleanupLifecycle: LifecycleHandler {
    func shutdown(_ application: Application) {
        Task { await GUIDNSCleanup.shared.stop() }
    }
}
