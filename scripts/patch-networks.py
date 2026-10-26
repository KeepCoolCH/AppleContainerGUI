import pathlib
import sys
import subprocess

checkout = pathlib.Path(sys.argv[1])
root = pathlib.Path(__file__).resolve().parents[1]

def replace(path, old, new):
    target = checkout / path
    content = target.read_text()
    if new in content:
        return
    if content.count(old) == 0:
        raise SystemExit(f'Network patch does not apply: {path}: {old[:90]}')
    target.write_text(content.replace(old,new))

for name in ['Connect','Disconnect']:
    replace(f'Sources/socktainer/Routes/Networks/Network{name}Route.swift','Response(status: .ok)',f'try await GUINetworkAPI.handle(req, disconnect: {str(name == "Disconnect").lower()})')
p='Sources/socktainer/Clients/ClientContainerService.swift'
replace(p,'Self.withoutDNSSidecars(try await containerClient.withClient { try await $0.list() })','Self.withoutDNSSidecars(try await containerClient.withClient { try await $0.list() }).map { GUINetworkAttachment.hydrated($0) }')
replace(p,'return Self.isDNSSidecar(snapshot) ? nil : snapshot','return Self.isDNSSidecar(snapshot) ? nil : GUINetworkAttachment.hydrated(snapshot)')
p='Sources/socktainer/Routes/Containers/ContainerCreateRoute.swift'
replace(p, 'var containerLabels = LabelNormalization.sanitize(originalLabels)', 'var containerLabels = LabelNormalization.sanitize(originalLabels)\n            containerLabels[GUINetworkAttachment.aliasesLabel] = String(decoding: try JSONEncoder().encode(body.NetworkingConfig?.EndpointsConfig?.mapValues { $0.Aliases ?? [] } ?? [:]), as: UTF8.self)')
p='Sources/socktainer/Routes/Containers/ContainerStartRoute.swift'
replace(p,'if let dnsServer,\n            let snapshot = startedSnapshot,','await GUINetworkDNS.refresh()\n        if let dnsServer,\n            let snapshot = startedSnapshot,')
p='Sources/socktainer/configure.swift'
replace(p,'await GUIDNSCleanup.shared.start(manager: dnsManager)','await GUIDNSCleanup.shared.start(manager: dnsManager)\n    Task {\n        while !Task.isCancelled {\n            await GUINetworkDNS.refresh()\n            do { try await Task.sleep(for: .seconds(2)) } catch { return }\n        }\n    }')
p='Sources/socktainer/DNS/NetworkDNSManager.swift'
replace(p,'static let containerPrefix = "socktainer-dns-"','static let containerPrefix = "socktainer-dns-v8-"')
p='Sources/socktainer/DNS/EmbeddedDNSImage.swift'
replace(p,'static let tag = SocktainerDNSImage.reference','static let tag = "socktainer-dns:acgui8"')
p='Sources/socktainer/DNS/SocktainerDNSServer.swift'
replace(p,'repeating: 0, count: 512','repeating: 0, count: 65536')
replace(p,'let packet = Array(buf[0..<n])','let received = GUINetworkDNS.decode(Array(buf[0..<n]), source: String(cString: inet_ntoa(clientAddr.sin_addr)))\n            let packet = received.packet\n            let sourceIP = received.source')
replace(p, 'let sourceIP = received.source', 'let sourceIP = received.source\n            guard packet.count >= 12, admission.begin(source: sourceIP) else { continue }')
replace(p, 'private func serverLoop(port: Int) {', 'private let admission = GUIDNSAdmission()\n\n    private func serverLoop(port: Int) {')
replace(p, 'DispatchQueue.global(qos: .userInitiated).async {', 'DispatchQueue.global(qos: .userInitiated).async {\n                defer { self.admission.end(source: sourceIP) }')
replace(p,'handleLocalQuery(packet) {','handleLocalQuery(packet, sourceIP: sourceIP) {')
replace(p, 'if let local = handleLocalQuery(packet, sourceIP: sourceIP) {', 'if let local = handleLocalQuery(packet, sourceIP: sourceIP) {\n                defer { admission.end(source: sourceIP) }')
replace(p,'self.handleQuery(packet) else','self.handleQuery(packet, sourceIP: sourceIP) else')
replace(p,'private func handleLocalQuery(_ packet: [UInt8])','private func handleLocalQuery(_ packet: [UInt8], sourceIP: String? = nil)')
replace(p,'private func handleQuery(_ packet: [UInt8])','private func handleQuery(_ packet: [UInt8], sourceIP: String? = nil)')
target=checkout/p
content=target.read_text()
if "sourceIP != nil && GUINetworkDNS" not in content:
    content=content.replace('let isSingleLabel = !normalized.contains(".")','let isSingleLabel = !normalized.contains(".") || (sourceIP != nil && GUINetworkDNS.shared.contains(normalized))').replace('let ip = entries[normalized]','let ip = sourceIP == nil ? entries[normalized] : GUINetworkDNS.shared.address(name: normalized, source: sourceIP!)').replace('let known = entries[normalized] != nil','let known = sourceIP == nil ? entries[normalized] != nil : GUINetworkDNS.shared.contains(normalized)')
target.write_text(content)
p='Sources/socktainer/Routes/Containers/ContainerInspectRoute.swift'
replace(p,'(attachment.network, ContainerEndpointSettings.live(attachment))','(attachment.network, guiEndpoint(ContainerEndpointSettings.live(attachment), network: attachment.network, container: container))')
replace(p,'(attachment.network, ContainerEndpointSettings.configured(networkID: attachment.network))','(attachment.network, guiEndpoint(ContainerEndpointSettings.configured(networkID: attachment.network), network: attachment.network, container: container))')
replace(p,'private static func networkEndpoints(for container:', 'private static func guiEndpoint(_ endpoint: ContainerEndpointSettings, network: String, container: ContainerSnapshot) -> ContainerEndpointSettings {\n        var result = endpoint\n        result.Aliases = GUINetworkAttachment.aliases(container.configuration)[network]\n        return result\n    }\n\n    private static func networkEndpoints(for container:')
data=(root/'RuntimeSupport/DNS/image.tar.gz').read_bytes()
c='static const unsigned char socktainer_dns_targz[] = {' + ','.join(str(x) for x in data) + '};\n#include "CSocktainerDNSImage.h"\nconst unsigned char *socktainer_dns_image_bytes(void) { return socktainer_dns_targz; }\nunsigned int socktainer_dns_image_len(void) { return sizeof(socktainer_dns_targz); }\n'
embedded = checkout/'.build/checkouts/dns-forwarder/Sources/CSocktainerDNSImage/embedded_dns_image.c'
if not embedded.exists():
    subprocess.run(["swift", "package", "resolve"], cwd=checkout, check=True)
embedded.chmod(0o644)
embedded.write_text(c)

p=checkout/'Sources/socktainer/Routes/Networks/NetworkConnectRoute.swift'
content=p.read_text()
content='\n'.join(line for line in content.split('\n') if not line.strip().startswith('//'))
p.write_text(content)
p='Sources/socktainer/Clients/ClientNetworkService.swift'
replace(p, 'for attachment in container.networks {', 'if container.networks.isEmpty && container.configuration.networks.contains(where: { $0.network == network.Name }) {\n                    containersForNetwork[container.id] = NetworkContainer(Name: container.id, EndpointID: nil, MacAddress: nil, IPv4Address: "", IPv6Address: nil)\n                }\n                for attachment in container.networks {')
p='Sources/socktainer/Routes/Networks/NetworkDeleteRoute.swift'
replace(p, 'let resolvedId = summary?.Id ?? id', 'let resolvedId = summary?.Id ?? id\n            guard summary?.Containers?.isEmpty != false else { throw Abort(.conflict, reason: "Network has active endpoints") }')
replace(p, '} catch {\n            if error.localizedDescription', '} catch let abort as Abort {\n            throw abort\n        } catch {\n            if error.localizedDescription')
p=checkout/'Sources/socktainer/DNS/NetworkDNSManager.swift'
content=p.read_text()
start=content.index('    func cleanupDNSContainer(')
end=content.index('    // A recreated sidecar',start)
content=content[:start]+'''    func cleanupDNSContainer(networkId: String) async {
        let client = ContainerClient()
        guard let containers = try? await client.list() else { return }
        for snapshot in containers where ClientContainerService.isDNSSidecar(snapshot) && snapshot.configuration.labels[Self.networkLabel] == networkId {
            do {
                if snapshot.status == .running { try await client.stop(id: snapshot.id) }
                try await client.delete(id: snapshot.id)
            } catch { log.warning("Could not remove DNS helper \\(snapshot.id): \\(error)") }
        }
    }

'''+content[end:]
p.write_text(content)
replace('Sources/socktainer/Models/RESTConfig.swift', 'let Aliases: [String]?', 'var Aliases: [String]?')
replace('Sources/socktainer/configure.swift', 'let dnsManager = NetworkDNSManager(', 'await GUINetworkAttachment.recover()\n    let dnsManager = NetworkDNSManager(')

p='Sources/socktainer/Routes/Containers/ContainerCreateRoute.swift'
replace(p, 'containerConfiguration.publishedPorts = publishedPorts', 'containerConfiguration.publishedPorts = publishedPorts\n            let extraHosts = try GUIExtraHosts.parse(body.HostConfig?.ExtraHosts ?? [])\n            if !extraHosts.isEmpty && (isHostMode || body.HostConfig?.NetworkMode == "none") { throw Abort(.badRequest, reason: "ExtraHosts requires a routed network") }')
replace(p, 'containerLabels[GUINetworkAttachment.aliasesLabel] =', 'containerLabels[GUIExtraHosts.label] = String(decoding: try JSONEncoder().encode(extraHosts), as: UTF8.self)\n            containerLabels[GUINetworkAttachment.aliasesLabel] =')
replace(p, '} else if let firstNetwork = firstNamedNetwork,', '} else if let firstNetwork = firstNamedNetwork ?? (extraHosts.isEmpty ? nil : containerConfiguration.networks.first?.network),')
p='Sources/socktainer/Routes/Containers/ContainerStartRoute.swift'
replace(p, 'roleLabel: container.configuration.labels[NetworkDNSManager.roleLabel]\n            )', 'roleLabel: container.configuration.labels[NetworkDNSManager.roleLabel]\n            ) ?? GUIExtraHosts.network(container.configuration)')
p='Sources/socktainer/Models/RESTConfig.swift'
replace(p, 'let ExtraHosts: [String]?', 'var ExtraHosts: [String]?')
p='Sources/socktainer/Routes/Containers/ContainerInspectRoute.swift'
replace(p, 'let hostConfig: HostConfig = HostConfig(restartPolicy: restartPolicy)', 'var hostConfig: HostConfig = HostConfig(restartPolicy: restartPolicy)\n            hostConfig.ExtraHosts = GUIExtraHosts.entries(container.configuration).sorted { $0.key < $1.key }.map { "\\($0.key):\\($0.value)" }')
