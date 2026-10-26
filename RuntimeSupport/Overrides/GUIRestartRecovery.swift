import ContainerAPIClient
import ContainerResource
import ContainerXPC
import Logging

struct GUIRestartRecovery {
    static func resume(
        container: ContainerSnapshot,
        broadcaster: EventBroadcaster,
        dnsServer: SocktainerDNSServer,
        healthManager: HealthCheckManager,
        logger: Logger
    ) async {
        let eventID = DockerContainerID.hexId(for: container)
        let policy = await RestartPolicyManager.effectivePolicy(hexId: eventID, labels: container.configuration.labels)
        let generation = await ContainerRestartState.shared.currentGeneration(id: container.id)
        let epoch = await DieEventOwnership.shared.beginRun(id: container.id)
        await ContainerStartRoute.armRestartObserver(
            nativeId: container.id,
            eventId: eventID,
            image: container.configuration.image.reference,
            name: container.id,
            labels: LabelNormalization.restore(container.configuration.labels),
            ip: ContainerStartRoute.dnsAttachmentIP(in: container),
            refreshCache: true,
            restartPolicy: policy,
            generation: generation,
            runEpoch: epoch,
            broadcaster: broadcaster,
            dnsServer: dnsServer,
            healthManager: healthManager,
            client: ClientContainerService(),
            logger: logger
        )
        Task {
            await recordExit(nativeID: container.id, eventID: eventID, generation: generation) { id in
                let connection = XPCClient(service: "com.apple.container.apiserver")
                defer { connection.close() }
                let request = XPCMessage(route: .containerWait)
                request.set(key: .id, value: id)
                request.set(key: .processIdentifier, value: id)
                let response = try await connection.send(request)
                return Int32(response.int64(key: .exitCode))
            }
        }
    }

    static func recordExit(
        nativeID: String,
        eventID: String,
        generation: Int,
        wait: @escaping @Sendable (String) async throws -> Int32
    ) async {
        let code = await ContainerExitCodeStore.resolveExitCode { try await wait(nativeID) }
        guard await ContainerRestartState.shared.isCurrent(id: nativeID, generation: generation) else { return }
        await ContainerExitCodeStore.shared.set(id: nativeID, code: code)
        await ContainerExitCodeStore.shared.set(id: eventID, code: code)
    }
}

