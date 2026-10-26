import Foundation
import Observation

@MainActor
@Observable
final class RuntimeInstaller {
    static let shared = RuntimeInstaller()
    var isInstalling = false
    var isInstalled = ManagedRuntime.shared.installedRoot != nil
    var status = "Apple Container, Socktainer, Docker CLI, Compose and Linux boot files are included in this app."
    var error = ""
    var configureStandardSocket = true
    var versions: String {
        guard let info = try? ManagedRuntime.shared.manifest() else { return "Runtime package missing from this build" }
        return "Apple Container \(info.appleContainerVersion) · Docker \(info.dockerVersion) · Compose \(info.composeVersion)"
    }

    func install() async {
        guard !isInstalling else { return }
        isInstalling = true
        error = ""
        defer { isInstalling = false; isInstalled = ManagedRuntime.shared.installedRoot != nil }
        do {
            try await DockerSocketService.shared.prepareForInstallation()
            try await Task.detached(priority: .userInitiated) {
                try await ManagedRuntime.shared.install { message in
                    await MainActor.run { self.status = message }
                }
            }.value
            status = "Starting Docker API"
            DockerSocketService.shared.startsWithApp = true
            await DockerSocketService.shared.start()
            guard DockerSocketService.shared.isManaged, DockerSocketService.shared.isRunning else {
                throw DockerAPIError(message: DockerSocketService.shared.lastError.isEmpty ? "Another app instance owns the Docker API socket. Quit that instance and start the API here." : DockerSocketService.shared.lastError)
            }
            try await ManagedRuntime.shared.restoreContainers { message in
                await MainActor.run { self.status = message }
            }
            if configureStandardSocket {
                status = "Configuring /var/run/docker.sock"
                await DockerSocketService.shared.configureSystemSocket()
                guard DockerSocketService.shared.systemSocketTarget == DockerSocketService.shared.socketPath else {
                    throw DockerAPIError(message: "Runtime installed. Standard socket setup was not completed. " + DockerSocketService.shared.lastError)
                }
            }
            status = "Ready. All runtime components are installed locally."
        } catch { self.error = error.localizedDescription }
    }
}
