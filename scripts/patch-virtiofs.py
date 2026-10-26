import pathlib
import sys

checkout = pathlib.Path(sys.argv[1])

def replace(path, old, new):
    target = checkout / path
    content = target.read_text()
    if new in content:
        return
    if content.count(old) != 1:
        raise SystemExit('VirtioFS patch does not apply: ' + path)
    target.write_text(content.replace(old, new))

base = 'Sources/socktainer/'
p = base + 'Clients/ClientVolumeService.swift'
replace(p, 'let result = try await ClientVolume.create(', 'let result = try await GUIVirtioFSVolumes.shared.create(')
replace(p, 'driverOpts: request.Options,', 'options: request.Options,')
replace(p, 'try await ClientVolume.delete(name: name)', 'try await GUIVirtioFSVolumes.shared.delete(name)')
replace(p, 'let results = try await ClientVolume.list()', 'let results = try await GUIVirtioFSVolumes.shared.list()')
replace(p, 'let result = try await ClientVolume.inspect(name)', 'let result = try await GUIVirtioFSVolumes.shared.inspect(name)')
p = base + 'Routes/Containers/ContainerCreateRoute.swift'
content = (checkout / p).read_text()
if 'GUIVirtioFSVolumes.shared.resolve' not in content:
    start = content.index('                    // Check if volume exists by listing all volumes')
    end = content.index('                    resolvedMounts.append(volumeMount)', start)
    content = content[:start] + '''                    let volume = try await GUIVirtioFSVolumes.shared.resolve(
                        name: parsed.name,
                        labels: parsed.isAnonymous ? [ClientVolumeService.anonymousVolumeLabel: "", ContainerResource.VolumeConfiguration.anonymousLabel: ""] : [:])
                    let volumeMount = Filesystem.virtiofs(source: volume.source, destination: parsed.destination, options: parsed.options)
                    copyUpCandidates.append((source: volume.source, destination: parsed.destination))
''' + content[end:]
    (checkout / p).write_text(content)
replace(p, 'for candidate in candidates where VolumeCopyUp.isEmpty(volumeImagePath: candidate.source) {', 'for candidate in candidates {')
replace(p, 'try VolumeCopyUp.populate(\n                    volumeImagePath: candidate.source,\n                    fromRootfs: rootfs.path,\n                    sourcePath: candidate.destination,\n                    logger: logger\n                )', 'try GUIVirtioFSExport.populate(directory: candidate.source, rootfs: rootfs.path, source: candidate.destination)')
for name in ['Routes/Containers/ContainerInspectRoute.swift', 'Routes/Containers/ContainerListRoute.swift', 'Routes/Server/SystemDFRoute.swift']:
    p = base + name
    content = (checkout / p).read_text()
    old = 'case .virtiofs:\n                    mountType = "bind"\n                    mountName = nil'
    if name.endswith('ContainerListRoute.swift'):
        old = old.replace('\n                    ', '\n                        ')
    if name.endswith('SystemDFRoute.swift'):
        old = old.replace('\n                    ', '\n                ')
    indent = old.split('\n')[1].split('mountType')[0]
    new = 'case .virtiofs:\n' + indent + 'mountName = GUIVirtioFSVolumes.name(for: mount.source)\n' + indent + 'mountType = mountName == nil ? "bind" : "volume"'
    replace(p, old, new)
p = base + 'Events/VolumeMountEvents.swift'
content = (checkout / p).read_text().replace('guard case .volume(let name, _, _, _) = mount.type else { continue }', 'guard let name = GUIVirtioFSVolumes.name(for: mount) else { continue }')
content = content.replace('if case .volume = $0.type { return true }', 'if GUIVirtioFSVolumes.name(for: $0) != nil { return true }')
(checkout / p).write_text(content)
p = base + 'Routes/Server/SystemDFRoute.swift'
replace(p, 'if mount.isVolume, let name = mount.volumeName {', 'if let name = GUIVirtioFSVolumes.name(for: mount) {')
replace(p, 'let size = try await ClientVolume.volumeDiskUsage(name: volume.Name)', 'let size = (try? GUIVirtioFSVolumes.diskUsage(volume.Name)) ?? 0')

p = base + 'main.swift'
replace(p, 'var version: Bool = false', 'var version: Bool = false\n\n    @ArgumentParser.Flag(name: .long, help: "Migrate stopped Apple volumes to VirtioFS")\n    var guiMigrateVolumes: Bool = false')
replace(p, 'if options.autoStart {', 'if options.guiMigrateVolumes {\n    try GUIVirtioFSMigration.run()\n    exit(0)\n}\n\nif options.autoStart {')

p = base + 'Routes/Containers/ContainerCreateRoute.swift'
replace(p, 'ContainerCreateRoute.populateEmptyVolumes(copyUpCandidates, for: container, logger: req.logger)', 'try ContainerCreateRoute.populateEmptyVolumes(copyUpCandidates, for: container, logger: req.logger)')
replace(p, 'for container: ContainerSnapshot,\n        logger: Logger\n    ) {', 'for container: ContainerSnapshot,\n        logger: Logger\n    ) throws {')
replace(p, r'logger.warning("[volume-copyup] \(candidate.destination) left empty: \(error)")', r'throw Abort(.internalServerError, reason: "VirtioFS copy-up failed: \(error)")')

p = base + 'Routes/Volumes/VolumeInspectRoute.swift'
replace(p, '} catch {\n            if VolumeNotFound.matches(error)', '} catch {\n            if let abort = error as? AbortError { throw abort }\n            if VolumeNotFound.matches(error)')

for name in ["Routes/Containers/ContainerListRoute.swift", "Routes/Server/SystemDFRoute.swift"]:
    p = base + name
    content = (checkout / p).read_text()
    start = content.index("case .virtiofs:")
    end = content.index("case .tmpfs:", start)
    content = content[:start] + content[start:end].replace("driver = nil", 'driver = mountName == nil ? nil : "local"') + content[end:]
    (checkout / p).write_text(content)
p = base + "Routes/Containers/ContainerInspectRoute.swift"
replace(p, "driver: nil,  // we do not take into account any storage driver at this time", 'driver: mountName == nil ? nil : "local",')
p = base + "Utilities/VolumeNotFound.swift"
replace(p, "import ContainerResource", "import ContainerResource\nimport Vapor")
replace(p, "static func matches(_ error: any Error) -> Bool {", "static func matches(_ error: any Error) -> Bool {\n        if let abort = error as? AbortError, abort.status == .notFound { return true }")
