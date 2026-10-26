import pathlib
import shutil
import subprocess
import sys

root = pathlib.Path(__file__).resolve().parents[1]
checkout = pathlib.Path(sys.argv[1]).resolve()
revision = "cdadd189bf6899cb363a18489e31d36e204fd0dd"
actual = subprocess.check_output(["git", "-C", str(checkout), "rev-parse", "HEAD"], text=True).strip()
if actual != revision:
    raise SystemExit(f"Expected Socktainer {revision}, found {actual}")
for source in (root / "RuntimeSupport/Overrides").glob("*.swift"):
    folder = "Routes/Containers" if source.name in {"ContainerTopRoute.swift", "ContainerStatsRoute.swift"} else "Utilities"
    shutil.copyfile(source, checkout / "Sources/socktainer" / folder / source.name)
shutil.copyfile(root / "AppleContainerGUI/ContainerDefaults.swift", checkout / "Sources/socktainer/Utilities/ContainerDefaults.swift")

def replace(relative, old, new):
    path = checkout / relative
    content = path.read_text()
    if new in content:
        return
    if content.count(old) != 1:
        raise SystemExit(f"Patch no longer applies: {relative}")
    path.write_text(content.replace(old, new))

replace("Sources/socktainer/Utilities/SocketUtility.swift",
        '"\\(homeDirectory)/.socktainer"',
        'ProcessInfo.processInfo.environment["APPLE_CONTAINER_GUI_SOCKET"].map { URL(fileURLWithPath: $0).deletingLastPathComponent().path } ?? "\\(homeDirectory)/.socktainer"')
replace("Sources/socktainer/Utilities/SocketUtility.swift",
        '"\\(socketDirectory(homeDirectory: homeDirectory))/container.sock"',
        'ProcessInfo.processInfo.environment["APPLE_CONTAINER_GUI_SOCKET"] ?? "\\(socketDirectory(homeDirectory: homeDirectory))/container.sock"')
replace("Sources/socktainer/Utilities/DockerSocketRelay.swift",
        'return "\\(homeDirectory)/.socktainer/container.sock"',
        'return containerSocketPath(homeDirectory: homeDirectory)')
replace("Sources/socktainer/configure.swift",
        'ContainerStartRoute.registerDNSAliasesOnResume(container: container, dnsServer: dnsServer, logger: app.logger)',
        'ContainerStartRoute.registerDNSAliasesOnResume(container: container, dnsServer: dnsServer, logger: app.logger)\n            await GUIRestartRecovery.resume(container: container, broadcaster: broadcaster, dnsServer: dnsServer, healthManager: healthCheckManager, logger: app.logger)')
print(f"Prepared Socktainer {revision} with AppleContainerGUI extensions")

replace("Package.swift",
        '.product(name: "ContainerNetworkClient", package: "container"),',
        '.product(name: "ContainerNetworkClient", package: "container"),\n                .product(name: "ContainerXPC", package: "container"),')
replace("Sources/socktainer/Routes/Containers/ContainerInspectRoute.swift",
        'ExitCode: container.status == .stopped ? 0 : 0,',
        'ExitCode: hasExited ? Int(recordedExitCode ?? ContainerExitCodeStore.waitFailureSentinel) : 0,')
replace("Sources/socktainer/Routes/Containers/ContainerInspectRoute.swift",
        'Dead: container.status == .stopped && !isPendingRestart,',
        'Dead: false,')
replace("Package.swift", 'container.git", exact: "1.2.2"', 'container.git", exact: "1.6.0"')
replace("Package.swift", 'containerization.git", exact: "0.40.1"', 'containerization.git", exact: "0.52.1"')
replace("Package.swift", '\\(resolvedVersion(for: "container"))', '1.6.0')
replace("Sources/socktainer/Routes/Registry/DistributionJsonRoute.swift", 'RequestScheme.auto.schemeFor', 'RequestScheme.https.schemeFor')
replace("Sources/socktainer/Clients/ClientImageService.swift", 'scheme: .auto,', 'scheme: .https,')
replace("Sources/socktainer/Routes/Registry/DistributionJsonRoute.swift", 'switch error {\n        case .invalidStatus', 'switch error {\n        case .insecureCredentialExchange(let message):\n            return Abort(.unauthorized, reason: message)\n        case .invalidStatus')

replace("Sources/socktainer/Routes/Containers/ContainerInspectRoute.swift", 'let containerState: ContainerState = ContainerState(', 'let recordedExitCode = await ContainerExitCodeStore.shared.get(id: container.id)\n            let hasExited = container.status == .stopped || (recordedExitCode.map { $0 >= 0 } ?? false)\n            let containerState: ContainerState = ContainerState(')
replace("Sources/socktainer/Routes/Containers/ContainerInspectRoute.swift", 'Status: isPendingRestart ? "restarting" : container.status.mobyState,', 'Status: isPendingRestart ? "restarting" : (hasExited ? "exited" : container.status.mobyState),')
replace("Sources/socktainer/Routes/Containers/ContainerInspectRoute.swift", 'Running: container.status == .running,', 'Running: container.status == .running && !hasExited,')
replace("Sources/socktainer/Routes/Containers/ContainerCreateRoute.swift", '(body.Hostname?.isEmpty == false) ? body.Hostname! : "\\(id)-\\(UUID().uuidString.lowercased())"', '(body.Hostname?.isEmpty == false) ? body.Hostname! : id')
subprocess.run([sys.executable, str(root / "scripts/patch-virtiofs.py"), str(checkout)], check=True)

p = "Sources/socktainer/Routes/Containers/ContainerCreateRoute.swift"
replace(p, "let requestedMemory = body.HostConfig?.Memory", 'let guiDefaults: ContainerDefaults? = try ContainerDefaults.load(from: GUIVirtioFSVolumes.root.deletingLastPathComponent().appendingPathComponent("container-defaults.json")) ?? .standard\n            let requestedMemory = body.HostConfig?.Memory')
replace(p, "if let memoryBytes = ContainerResourceResolution.memoryInBytes(", "if let memoryBytes = guiDefaults?.resolveMemory(requestedBytes: requestedMemory) ?? ContainerResourceResolution.memoryInBytes(")
replace(p, "if let cpus = ContainerResourceResolution.cpus(", "if let cpus = guiDefaults?.resolveCPUs(requestedNanoCpus: requestedNanoCpus) ?? ContainerResourceResolution.cpus(")
replace(p, "needsConfiguredDefaults\n                ? await", "needsConfiguredDefaults && guiDefaults == nil\n                ? await")

p = "Sources/socktainer/DNS/NetworkDNSManager.swift"
replace(p, "config.resources.cpus = sidecarCPUs\n        config.resources.memoryInBytes = sidecarMemoryInBytes", 'let defaults = try ContainerDefaults.load(from: GUIVirtioFSVolumes.root.deletingLastPathComponent().appendingPathComponent("container-defaults.json")) ?? .standard\n        config.resources.cpus = defaults.cpus\n        config.resources.memoryInBytes = defaults.memoryInBytes')

p = "Sources/socktainer/Routes/Containers/ContainerCreateRoute.swift"
replace(p, '{ req in\n            let query', '{ req in\n            await GUIDNSCleanup.shared.beginCreation()\n            defer { Task { await GUIDNSCleanup.shared.endCreation() } }\n            let query')
replace("Sources/socktainer/configure.swift", 'app.storage[NetworkDNSManagerKey.self] = dnsManager', 'app.storage[NetworkDNSManagerKey.self] = dnsManager\n    await GUIDNSCleanup.shared.start(manager: dnsManager)\n    app.lifecycle.use(GUIDNSCleanupLifecycle())')
subprocess.run([sys.executable, str(root / "scripts/patch-networks.py"), str(checkout)], check=True)

subprocess.run([sys.executable, str(root / "scripts/patch-image-provenance.py"), str(checkout)], check=True)

replace("Sources/socktainer/Routes/Containers/ContainerCreateRoute.swift",
        'let requestedStopSignal = body.StopSignal',
        'if !(body.HostConfig?.SecurityOpt ?? []).isEmpty { throw Abort(.badRequest, reason: "SecurityOpt is not supported by this Apple Container backend; the requested security policy cannot be enforced") }\n            if let limit = body.HostConfig?.PidsLimit, limit > 0 { throw Abort(.badRequest, reason: "PidsLimit is not supported by this Apple Container backend") }\n            let requestedStopSignal = body.StopSignal')

replace("Package.swift", '    dependencies: [\n        .package', '    dependencies: [\n        .package(url: "https://github.com/facebook/zstd.git", exact: "1.5.7"),\n        .package')
replace("Package.swift", '                .product(name: "ContainerizationArchive", package: "containerization"),', '                .product(name: "ContainerizationArchive", package: "containerization"),\n                .product(name: "libzstd", package: "zstd"),')
p = "Sources/socktainer/Utilities/ContainerImageUtility.swift"
target = checkout / p
value = target.read_text()
start = value.find('            let decompressedPath = try ArchiveReader.decompressZstd(tarPath)')
if start >= 0:
    end = value.index('            let destination = blobsDir.appendingPathComponent(digest)', start)
    value = value[:start] + '            let diffID = try GUIZstd.digest(tarPath, limit: maxExpandedLayerSize)\n' + value[end:]
    target.write_text(value)
replace("Sources/socktainer/Utilities/ContainerImageUtility.swift",
        '            guard let (entry, _) = iterator.next() else { continue }',
        '            guard let (entry, _) = iterator.next() else {\n                do { try reader.throwIfStreamFailed() } catch { return false }\n                continue\n            }')
