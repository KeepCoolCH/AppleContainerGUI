import SwiftUI
import AppKit
import Charts
import Foundation
import Darwin

struct ContentView: View {
    @State private var viewModel = ContainerViewModel()

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "shippingbox")
                    .font(.title2)
                Text("AppleContainerGUI")
                    .font(.headline)
                Text("Developed by Kevin Tobler - www.kevintobler.ch")
                    .font(.caption)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 8)

            HStack {
                Button {
                    Task { await viewModel.startAllServices() }
                } label: {
                    Label("Start Container System", systemImage: "play.circle")
                }
                .disabled(viewModel.isServiceRunning)

                Button {
                    Task { await viewModel.stopAllServices() }
                } label: {
                    Label("Stop Container System", systemImage: "stop.circle")
                }
                .disabled(!viewModel.isServiceRunning)
                Spacer()
            }
            .padding(.horizontal, 16)

            TabView {
                ContainersView(viewModel: viewModel)
                    .tabItem { Label("Containers", systemImage: "shippingbox") }
                ImagesView(viewModel: viewModel)
                    .tabItem { Label("Images", systemImage: "square.stack.3d.up") }
                VolumesView(viewModel: viewModel)
                    .tabItem { Label("Volumes", systemImage: "externaldrive") }
                NetworksView(viewModel: viewModel)
                    .tabItem { Label("Networks", systemImage: "network") }
                SearchView(viewModel: viewModel)
                    .tabItem { Label("Image Search", systemImage: "magnifyingglass") }
                CommandView(viewModel: viewModel)
                    .tabItem { Label("Command", systemImage: "terminal") }
                SnapshotsView(viewModel: viewModel)
                    .tabItem { Label("Snapshots", systemImage: "camera") }
                LogsView(viewModel: viewModel)
                    .tabItem { Label("Logs", systemImage: "list.bullet.rectangle") }
            }
        }
        .frame(minWidth: 1180, minHeight: 700)
        .onAppear { viewModel.startup() }
        .alert("Apple Container Not Found", isPresented: Binding(
            get: { viewModel.showInstallPrompt },
            set: { viewModel.showInstallPrompt = $0 }
        )) {
            Button {
                Task { await viewModel.installContainerViaHomebrew() }
            } label: {
                Label("Install via Homebrew", systemImage: "wrench.and.screwdriver")
            }
            Button(role: .cancel) {} label: {
                Label("Cancel", systemImage: "xmark")
            }
        } message: {
            Text("Install Apple Container via Homebrew? If Homebrew is missing, you will get the installation instructions.")
        }
        .alert("Homebrew Missing", isPresented: Binding(
            get: { viewModel.showHomebrewPrompt },
            set: { viewModel.showHomebrewPrompt = $0 }
        )) {
            Button {
                copyToPasteboard(viewModel.homebrewInstallCommand)
                openTerminal()
            } label: {
                Label("Copy Install Command", systemImage: "doc.on.doc")
            }
            Button(role: .cancel) {} label: {
                Label("Cancel", systemImage: "xmark")
            }
        } message: {
            Text("Homebrew is not installed. The install command is ready and can be run in Terminal.")
        }
        .sheet(isPresented: Binding(
            get: { viewModel.showInstallStatus },
            set: { viewModel.showInstallStatus = $0 }
        )) {
            InstallStatusSheet(viewModel: viewModel, isPresented: Binding(
                get: { viewModel.showInstallStatus },
                set: { viewModel.showInstallStatus = $0 }
            ))
        }
    }

    private func copyToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func openTerminal() {
        NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app"), configuration: NSWorkspace.OpenConfiguration())
    }
}

struct InstallStatusSheet: View {
    @Bindable var viewModel: ContainerViewModel
    @Binding var isPresented: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Installation In Progress")
                .font(.headline)
            if viewModel.isInstallingContainer {
                ProgressView()
            }
            if !viewModel.lastCommand.isEmpty {
                Text("Last Command")
                    .font(.headline)
                Text(viewModel.lastCommand)
                    .font(.caption)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            if !viewModel.lastOutput.isEmpty {
                Text("Output")
                    .font(.headline)
                ScrollView {
                    Text(viewModel.lastOutput)
                        .font(.caption)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(maxHeight: 200)
            }
            if !viewModel.lastError.isEmpty {
                Text("Error")
                    .font(.headline)
                ScrollView {
                    Text(viewModel.lastError)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(maxHeight: 200)
            }
        }
        .padding(16)
        .frame(minWidth: 640, minHeight: 420)
        .onChange(of: viewModel.isInstallingContainer) { _, newValue in
            if !newValue {
                isPresented = false
            }
        }
    }
}

struct ContainersView: View {
    @Bindable var viewModel: ContainerViewModel
    @State private var selection: ContainerListItem.ID?
    @State private var isInspectorPresented = false
    @State private var isResourcesPresented = false

    var body: some View {
        VStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Button {
                        Task { await viewModel.refreshContainers() }
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                    Button {
                        Task { await viewModel.pruneInactiveContainers() }
                    } label: {
                        Label("Clean Up Inactive", systemImage: "trash")
                    }
                    Button {
                        if let container = selectedContainer {
                            Task { await viewModel.startContainer(container) }
                        }
                    } label: {
                        Label("Start Container", systemImage: "play.fill")
                    }
                    .disabled(selectedContainer == nil)
                    Button {
                        if let container = selectedContainer {
                            Task { await viewModel.stopContainer(container) }
                        }
                    } label: {
                        Label("Stop Container", systemImage: "stop.fill")
                    }
                    .disabled(selectedContainer == nil)
                    Button {
                        if let container = selectedContainer {
                            Task { await viewModel.deleteContainer(container) }
                        }
                    } label: {
                        Label("Delete Container", systemImage: "trash")
                    }
                    .disabled(selectedContainer == nil)
                    Spacer()
                }
                HStack {
                    Button {
                        isResourcesPresented = true
                    } label: {
                        Label("Edit Resources", systemImage: "slider.horizontal.3")
                    }
                        .disabled(selectedContainer == nil)
                    Button {
                        if let container = selectedContainer {
                            Task { await viewModel.updateContainerImage(container) }
                        }
                    } label: {
                        Label("Update Image", systemImage: "arrow.triangle.2.circlepath")
                    }
                    .disabled(selectedContainer == nil)
                    Button {
                        if let container = selectedContainer {
                            Task { await viewModel.openContainerFolder(container) }
                        }
                    } label: {
                        Label("Open Container Folder", systemImage: "folder")
                    }
                    .disabled(selectedContainer == nil)
                    Button {
                        if let container = selectedContainer {
                            Task { await viewModel.openContainerBindMounts(container) }
                        }
                    } label: {
                        Label("Open Bind Mounts", systemImage: "externaldrive")
                    }
                    .disabled(selectedContainer == nil)
                    Button {
                        isInspectorPresented = true
                    } label: {
                        Label("Inspect", systemImage: "info.circle")
                    }
                        .disabled(selectedContainer == nil)
                    Spacer()
                }
            }

            Table(viewModel.containers, selection: $selection) {
                TableColumn("Name") { Text($0.name).font(.body) }
                TableColumn("Image") { Text($0.image).font(.body) }
                    .width(min: 300, ideal: 350)
                TableColumn("State") { container in
                    Text(container.state)
                        .font(.body)
                        .padding(.vertical, 2)
                        .padding(.horizontal, 6)
                        .background(stateBadgeColor(for: container.state))
                        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                }
                .width(min: 50, ideal: 70)
                TableColumn("Ports") { container in
                    if container.portLinks.isEmpty {
                        Text(container.portsDisplayFull)
                            .font(.body)
                    } else {
                        HStack(spacing: 4) {
                            ForEach(Array(container.portLinks.enumerated()), id: \.element.id) { index, link in
                                Link(link.label, destination: link.url)
                                    .font(.body)
                                if index < container.portLinks.count - 1 {
                                    Text(",")
                                        .font(.body)
                                }
                            }
                        }
                    }
                }
                .width(min: 100, ideal: 100)
                TableColumn("ID") { Text($0.id).font(.body) }
            }

            ConsolePanel(viewModel: viewModel)
        }
        .padding(16)
        .sheet(isPresented: $isInspectorPresented) {
            if let container = selectedContainer {
                InspectView(title: "Container \(container.name)", json: container.raw.prettyJSON())
            }
        }
        .sheet(isPresented: $isResourcesPresented) {
            if let container = selectedContainer {
                EditResourcesSheet(
                    viewModel: viewModel,
                    container: container,
                    isPresented: $isResourcesPresented
                )
            }
        }
    }

    private var selectedContainer: ContainerListItem? {
        guard let selection else { return nil }
        return viewModel.containers.first { $0.id == selection }
    }

    private func stateBadgeColor(for state: String) -> Color {
        let lower = state.lowercased()
        if lower.contains("running") {
            return Color.green.opacity(0.18)
        }
        if lower.contains("stopped") || lower.contains("exited") {
            return Color.red.opacity(0.18)
        }
        return Color.clear
    }

}

struct NetworkThroughputPanel: View {
    @Bindable var monitor: NetworkThroughputMonitor

    var body: some View {
        let rawMax = max(1, monitor.samples.map { max($0.rxMbps, $0.txMbps) }.max() ?? 1)
        let maxValue = min(rawMax, 20000)

        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Network Throughput")
                    .font(.headline)
                Spacer()
                Text("Down \(monitor.currentRxMbps, specifier: "%.1f") Mb/s · Up \(monitor.currentTxMbps, specifier: "%.1f") Mb/s")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Text("Interface")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Picker("", selection: $monitor.selectedInterface) {
                    Text("Auto").tag("Auto")
                    ForEach(monitor.availableInterfaces, id: \.self) { name in
                        Text(name).tag(name)
                    }
                }
                .pickerStyle(.menu)
                .onChange(of: monitor.selectedInterface) { _, newValue in
                    monitor.setSelectedInterface(newValue)
                }
                Spacer()
            }

            Chart(monitor.samples) { sample in
                LineMark(
                    x: .value("Time", sample.timestamp),
                    y: .value("Down", sample.rxMbps)
                )
                .foregroundStyle(.blue)

                LineMark(
                    x: .value("Time", sample.timestamp),
                    y: .value("Up", sample.txMbps)
                )
                .foregroundStyle(.green)
            }
            .chartYAxisLabel("Mb/s")
            .chartYScale(domain: 0...maxValue * 1.1)
            .frame(height: 140)
        }
        .padding(12)
        .background(Color.secondary.opacity(0.12))
        .cornerRadius(8)
    }
}

struct NetworkThroughputSample: Identifiable, Hashable {
    let id: UUID
    let timestamp: Date
    let rxMbps: Double
    let txMbps: Double
}

@MainActor
@Observable
final class NetworkThroughputMonitor: NSObject, @unchecked Sendable {
    var samples: [NetworkThroughputSample] = []
    var currentRxMbps: Double = 0
    var currentTxMbps: Double = 0
    var availableInterfaces: [String] = []
    var selectedInterface: String = "Auto"

    private var timer: Timer?
    private var lastBytes: (rx: UInt64, tx: UInt64)?
    private var lastTimestamp: Date?
    private var interfaceName: String?
    private var zeroSamplesCount: Int = 0

    func start() {
        if timer != nil { return }
        refreshInterfaces()
        interfaceName = pickPrimaryInterface()
        lastBytes = readBytes()
        lastTimestamp = Date()
        let newTimer = Timer(timeInterval: 1.0, target: self, selector: #selector(handleTimer(_:)), userInfo: nil, repeats: true)
        RunLoop.main.add(newTimer, forMode: .common)
        timer = newTimer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    @objc private func handleTimer(_ timer: Timer) {
        tick()
    }

    func refreshInterfaces() {
        availableInterfaces = allInterfaces() ?? []
        if selectedInterface != "Auto", !availableInterfaces.contains(selectedInterface) {
            selectedInterface = "Auto"
        }
        if selectedInterface != "Auto" {
            interfaceName = selectedInterface
        }
    }

    func setSelectedInterface(_ value: String) {
        selectedInterface = value
        if value == "Auto" {
            interfaceName = pickPrimaryInterface()
        } else {
            interfaceName = value
        }
        lastBytes = readBytes()
        lastTimestamp = Date()
    }

    private func tick() {
        if selectedInterface == "Auto", (interfaceName == nil || interfaceName == "lo0") {
            interfaceName = pickPrimaryInterface()
        }
        guard let previous = lastBytes, let lastTime = lastTimestamp else {
            lastBytes = readBytes()
            lastTimestamp = Date()
            return
        }
        guard let current = readBytes() else {
            interfaceName = pickPrimaryInterface()
            lastBytes = readBytes()
            lastTimestamp = Date()
            appendSample(rxMbps: 0, txMbps: 0)
            return
        }

        let now = Date()
        let dt = now.timeIntervalSince(lastTime)
        guard dt > 0 else { return }

        let rxDelta = Double(current.rx &- previous.rx) * 8.0 / dt / 1_000_000.0
        let txDelta = Double(current.tx &- previous.tx) * 8.0 / dt / 1_000_000.0

        if rxDelta > 20000 || txDelta > 20000 {
            lastBytes = current
            lastTimestamp = now
            appendSample(rxMbps: 0, txMbps: 0)
            return
        }

        currentRxMbps = max(0, rxDelta)
        currentTxMbps = max(0, txDelta)

        appendSample(rxMbps: currentRxMbps, txMbps: currentTxMbps)
        if currentRxMbps == 0 && currentTxMbps == 0 {
            zeroSamplesCount += 1
            if zeroSamplesCount >= 5 {
                if selectedInterface == "Auto" {
                    interfaceName = pickPrimaryInterface()
                }
                zeroSamplesCount = 0
            }
        } else {
            zeroSamplesCount = 0
        }

        lastBytes = current
        lastTimestamp = now
    }

    private func pickPrimaryInterface() -> String? {
        guard let interfaces = allInterfaces() else { return nil }
        let candidates = interfaces.filter { readBytes(for: $0) != nil }
        guard !candidates.isEmpty else { return interfaces.first }
        var bestInterface: String?
        var bestDelta: UInt64 = 0

        let baseline = candidates.reduce(into: [String: (rx: UInt64, tx: UInt64)]()) { partial, name in
            if let bytes = readBytes(for: name) {
                partial[name] = bytes
            }
        }

        usleep(150_000)

        for name in candidates {
            guard let before = baseline[name], let after = readBytes(for: name) else { continue }
            let delta = (after.rx &- before.rx) + (after.tx &- before.tx)
            if delta > bestDelta {
                bestDelta = delta
                bestInterface = name
            }
        }

        return bestInterface ?? candidates.first
    }

    private func allInterfaces() -> [String]? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { freeifaddrs(first) }

        var names: [String] = []
        var ptr = first
        while true {
            let name = String(cString: ptr.pointee.ifa_name)
            let flags = Int32(ptr.pointee.ifa_flags)
            if (flags & IFF_LOOPBACK) == 0, !names.contains(name) {
                names.append(name)
            }
            if let next = ptr.pointee.ifa_next {
                ptr = next
            } else {
                break
            }
        }
        return names
    }

    private func readBytes() -> (rx: UInt64, tx: UInt64)? {
        guard let name = interfaceName else { return nil }
        return readBytes(for: name)
    }

    private func readBytes(for name: String) -> (rx: UInt64, tx: UInt64)? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { freeifaddrs(first) }

        var ptr = first
        while true {
            let ifa = ptr.pointee
            let ifaName = String(cString: ifa.ifa_name)
            if ifaName == name,
               let addr = ifa.ifa_addr,
               addr.pointee.sa_family == UInt8(AF_LINK),
               let data = ifa.ifa_data {
                let ifdata = data.load(as: if_data.self)
                return (rx: UInt64(ifdata.ifi_ibytes), tx: UInt64(ifdata.ifi_obytes))
            }
            if let next = ifa.ifa_next {
                ptr = next
            } else {
                break
            }
        }
        return nil
    }

    private func appendSample(rxMbps: Double, txMbps: Double) {
        let now = Date()
        samples.append(
            NetworkThroughputSample(
                id: UUID(),
                timestamp: now,
                rxMbps: rxMbps,
                txMbps: txMbps
            )
        )
        if samples.count > 30 {
            samples.removeFirst(samples.count - 30)
        }
    }
}

struct EditResourcesSheet: View {
    @Bindable var viewModel: ContainerViewModel
    let container: ContainerListItem
    @Binding var isPresented: Bool

    @State private var cpus: String = ""
    @State private var memory: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Edit Resources")
                .font(.headline)
            Text(container.name)
                .font(.caption)
                .foregroundStyle(.secondary)

            Form {
                Section("Resources") {
                    VStack(spacing: 8) {
                        TextField("CPUs (e.g. 2, 4, 8)", text: $cpus)
                        TextField("Memory (e.g. 2g, 4096m)", text: $memory)
                    }
                }
                Section("Info") {
                    Text("This action stops, deletes, and recreates the container with the new resources.")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            HStack {
                Button {
                    isPresented = false
                } label: {
                    Label("Cancel", systemImage: "xmark")
                }
                Spacer()
                Button {
                    Task { await viewModel.recreateContainerWithResources(container, cpus: cpus, memory: memory) }
                    isPresented = false
                } label: {
                    Label("Apply", systemImage: "checkmark")
                }
            }
        }
        .padding(16)
        .frame(minWidth: 640, minHeight: 360)
        .onAppear {
            let current = viewModel.currentResources(for: container)
            cpus = current.cpus
            memory = current.memory
        }
    }
}

struct ImagesView: View {
    @Bindable var viewModel: ContainerViewModel
    @State private var selection: ImageListItem.ID?
    @State private var pullReference: String = ""
    @State private var isInspectorPresented = false
    @State private var runImage: ImageListItem?

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Button {
                    Task { await viewModel.refreshImages() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                Button {
                    if let image = selectedImage {
                        if viewModel.isImageInUse(image) {
                            viewModel.reportImageInUseError(image)
                        } else {
                            Task { await viewModel.deleteImage(image) }
                        }
                    }
                } label: {
                    Label("Delete", systemImage: "trash")
                }
                .disabled(selectedImage == nil)
                Button {
                    if let image = selectedImage {
                        runImage = image
                    }
                } label: {
                    Label("Run", systemImage: "play.circle")
                }
                .disabled(selectedImage == nil)
                Button {
                    if let image = selectedImage {
                        Task { await viewModel.updateImage(image) }
                    }
                } label: {
                    Label("Update Image", systemImage: "arrow.triangle.2.circlepath")
                }
                .disabled(selectedImage == nil)
                Button {
                    isInspectorPresented = true
                } label: {
                    Label("Inspect", systemImage: "info.circle")
                }
                .disabled(selectedImage == nil)
                Spacer()
            }

            Table(viewModel.images, selection: $selection) {
                TableColumn("Reference") { Text($0.reference) }
                TableColumn("Size") { Text($0.size) }
                TableColumn("Digest") { Text($0.id).font(.caption) }
            }

            ConsolePanel(viewModel: viewModel)
        }
        .padding(16)
        .sheet(isPresented: $isInspectorPresented) {
            if let image = selectedImage {
                InspectView(title: "Image \(image.reference)", json: image.raw.prettyJSON())
            }
        }
        .sheet(item: $runImage) { image in
            RunImageSheet(
                viewModel: viewModel,
                imageReference: image.reference
            )
        }
    }

    private var selectedImage: ImageListItem? {
        guard let selection else { return nil }
        return viewModel.images.first { $0.id == selection }
    }
}

struct RunImageSheet: View {
    @Bindable var viewModel: ContainerViewModel
    let imageReference: String
    @Environment(\.dismiss) private var dismiss

    @State private var name: String = ""
    @State private var detach: Bool = true
    @State private var cpus: String = ""
    @State private var memory: String = ""
    @State private var overrideEntrypoint: Bool = false
    @State private var customEntrypointPath: String = ""
    @State private var ports: [RunPortMapping] = []
    @State private var volumes: [RunVolumeMapping] = []
    @State private var environment: [RunEnvVar] = []
    @State private var command: String = ""
    @State private var extraArgs: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Run Image")
                .font(.headline)
            Text(imageReference)
                .font(.caption)
                .foregroundStyle(.secondary)

            Form {
                Section("General") {
                    TextField("Container name (optional)", text: $name)
                    Toggle("Run in background (detached)", isOn: $detach)
                    VStack(spacing: 8) {
                        TextField("CPUs (e.g. 2, 4, 8)", text: $cpus)
                        TextField("Memory (e.g. 2g, 4096m)", text: $memory)
                    }
                    Toggle("Override entrypoint (disable chown) if container doesn't start", isOn: $overrideEntrypoint)
                        .onChange(of: overrideEntrypoint) { _, newValue in
                            guard newValue else { return }
                            Task {
                                if let path = await viewModel.generateChownFreeEntrypoint(for: imageReference) {
                                    customEntrypointPath = path
                                }
                            }
                        }
                    if overrideEntrypoint {
                        Text("Note: If you override the entrypoint, make sure a command is set.")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Section("Ports") {
                    ForEach($ports) { $port in
                        HStack {
                            TextField("Host port", text: $port.hostPort)
                                .textFieldStyle(.roundedBorder)
                            Text(":")
                            TextField("Container port", text: $port.containerPort)
                                .textFieldStyle(.roundedBorder)
                            Button {
                                ports.removeAll { $0.id == port.id }
                            } label: {
                                Label("Remove", systemImage: "minus.circle")
                            }
                        }
                    }
                    Button {
                        ports.append(.init(id: UUID(), hostPort: "", containerPort: ""))
                    } label: {
                        Label("Add Port", systemImage: "plus.circle")
                    }
                }

                Section("Volumes") {
                    ForEach($volumes) { $volume in
                        HStack {
                            TextField("Host path", text: $volume.hostPath)
                                .textFieldStyle(.roundedBorder)
                            Text(":")
                            TextField("Container path", text: $volume.containerPath)
                                .textFieldStyle(.roundedBorder)
                            Toggle("Read-only", isOn: $volume.readOnly)
                                .toggleStyle(.checkbox)
                            Button {
                                volumes.removeAll { $0.id == volume.id }
                            } label: {
                                Label("Remove", systemImage: "minus.circle")
                            }
                        }
                    }
                    Button {
                        volumes.append(.init(id: UUID(), hostPath: "", containerPath: "", readOnly: false))
                    } label: {
                        Label("Add Volume", systemImage: "plus.circle")
                    }
                }

                Section("Environment") {
                    ForEach($environment) { $env in
                        HStack {
                            TextField("Key", text: $env.key)
                                .textFieldStyle(.roundedBorder)
                            Text("=")
                            TextField("Value", text: $env.value)
                                .textFieldStyle(.roundedBorder)
                            Button {
                                environment.removeAll { $0.id == env.id }
                            } label: {
                                Label("Remove", systemImage: "minus.circle")
                            }
                        }
                    }
                    Button {
                        environment.append(.init(id: UUID(), key: "", value: ""))
                    } label: {
                        Label("Add Env Var", systemImage: "plus.circle")
                    }
                }

                Section("Command") {
                    TextField("Override command (optional)", text: $command)
                }

                Section("Advanced") {
                    TextField("Extra args (optional)", text: $extraArgs)
                        .textFieldStyle(.roundedBorder)
                }
            }

            HStack {
                Button {
                    dismiss()
                } label: {
                    Label("Cancel", systemImage: "xmark")
                }
                Spacer()
                Button {
                    let config = RunImageConfig(
                        name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                        detach: detach,
                        cpus: cpus,
                        memory: memory,
                        overrideEntrypoint: overrideEntrypoint,
                        customEntrypointPath: customEntrypointPath,
                        ports: ports,
                        volumes: volumes,
                        environment: environment,
                        command: command,
                        extraArgs: extraArgs
                    )
                    Task { await viewModel.runImage(reference: imageReference, config: config) }
                    dismiss()
                } label: {
                    Label("Run", systemImage: "play.circle")
                }
            }
        }
        .padding(16)
        .frame(minWidth: 860, minHeight: 520)
        .onAppear {
            if name.isEmpty {
                name = suggestedName(from: imageReference)
            }
        }
    }

    private func suggestedName(from reference: String) -> String {
        let withoutRegistry = reference.split(separator: "/").last.map(String.init) ?? reference
        return withoutRegistry.replacingOccurrences(of: ":", with: "-")
    }
}

struct VolumesView: View {
    @Bindable var viewModel: ContainerViewModel
    @State private var selection: VolumeListItem.ID?
    @State private var newName: String = ""
    @State private var isInspectorPresented = false
    @State private var showFixPermissions = false
    @State private var selectedFixContainerId: ContainerListItem.ID?

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                TextField("New volume name", text: $newName)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 260)
                Button {
                    let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { return }
                    Task {
                        await viewModel.createVolume(name: trimmed)
                    }
                } label: {
                    Label("Create", systemImage: "plus.circle")
                }
                Button {
                    Task { await viewModel.refreshVolumes() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                Button {
                    if let volume = selectedVolume {
                        Task { await viewModel.deleteVolume(volume) }
                    }
                } label: {
                    Label("Delete", systemImage: "trash")
                }
                .disabled(selectedVolume == nil)
                Button {
                    if let volume = selectedVolume {
                        Task { await viewModel.openVolumeInFinder(volume) }
                    }
                } label: {
                    Label("Open in Finder", systemImage: "folder")
                }
                .disabled(selectedVolume == nil)
                Button {
                    if selectedVolume != nil {
                        let running = viewModel.containers.first { $0.state.lowercased().contains("running") }
                        selectedFixContainerId = running?.id ?? viewModel.containers.first?.id
                        showFixPermissions = true
                    }
                } label: {
                    Label("Fix Permissions", systemImage: "key.fill")
                }
                .disabled(selectedVolume == nil || viewModel.containers.isEmpty)
                Button {
                    isInspectorPresented = true
                } label: {
                    Label("Inspect", systemImage: "info.circle")
                }
                .disabled(selectedVolume == nil)
                Spacer()
            }

            Table(viewModel.volumes, selection: $selection) {
                TableColumn("Name") { Text($0.name) }
                TableColumn("Driver") { Text($0.driver) }
            }

            ConsolePanel(viewModel: viewModel)
        }
        .padding(16)
        .sheet(isPresented: $isInspectorPresented) {
            if let volume = selectedVolume {
                InspectView(title: "Volume \(volume.name)", json: volume.raw.prettyJSON())
            }
        }
        .sheet(isPresented: $showFixPermissions) {
            if let volume = selectedVolume {
                FixVolumePermissionsSheet(
                    viewModel: viewModel,
                    volume: volume,
                    selectedContainerId: $selectedFixContainerId,
                    isPresented: $showFixPermissions
                )
            }
        }
    }

    private var selectedVolume: VolumeListItem? {
        guard let selection else { return nil }
        return viewModel.volumes.first { $0.id == selection }
    }
}

struct SnapshotsView: View {
    @Bindable var viewModel: ContainerViewModel
    @State private var selection: SnapshotItem.ID?

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Button {
                    viewModel.refreshSnapshots()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                Button {
                    if let snapshot = selectedSnapshot {
                        viewModel.deleteSnapshot(snapshot)
                    }
                } label: {
                    Label("Delete Snapshot", systemImage: "trash")
                }
                .disabled(selectedSnapshot == nil)
                Button {
                    viewModel.deleteAllSnapshots()
                } label: {
                    Label("Delete All", systemImage: "trash.slash")
                }
                .disabled(viewModel.snapshots.isEmpty)
                Spacer()
            }

            Table(viewModel.snapshots, selection: $selection) {
                TableColumn("Name") { Text($0.name) }
                TableColumn("Modified") { snapshot in
                    Text(snapshot.modifiedAt.formatted(date: .abbreviated, time: .shortened))
                }
                TableColumn("Size") { snapshot in
                    Text(snapshot.size)
                }
            }

            ConsolePanel(viewModel: viewModel)
        }
        .padding(16)
        .onAppear { viewModel.refreshSnapshots() }
    }

    private var selectedSnapshot: SnapshotItem? {
        guard let selection else { return nil }
        return viewModel.snapshots.first { $0.id == selection }
    }
}

struct FixVolumePermissionsSheet: View {
    @Bindable var viewModel: ContainerViewModel
    let volume: VolumeListItem
    @Binding var selectedContainerId: ContainerListItem.ID?
    @Binding var isPresented: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Fix Volume Permissions")
                .font(.headline)
            Text("Volume: \(volume.name)")
                .font(.caption)
                .foregroundStyle(.secondary)

            Picker("Container", selection: $selectedContainerId) {
                ForEach(viewModel.containers) { container in
                    Text("\(container.name) (\(container.state))")
                        .tag(container.id as ContainerListItem.ID?)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text("This will run a helper container to chown the volume to the selected container's UID/GID.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Button {
                    isPresented = false
                } label: {
                    Label("Cancel", systemImage: "xmark")
                }
                Spacer()
                Button {
                    guard let id = selectedContainerId,
                          let container = viewModel.containers.first(where: { $0.id == id }) else {
                        return
                    }
                    Task {
                        await viewModel.fixVolumePermissions(volume: volume, container: container)
                        isPresented = false
                    }
                } label: {
                    Label("Apply Fix", systemImage: "wrench.and.screwdriver")
                }
                .disabled(selectedContainerId == nil)
            }
        }
        .padding(16)
        .frame(minWidth: 420)
    }
}

struct NetworksView: View {
    @Bindable var viewModel: ContainerViewModel
    @State private var selection: NetworkListItem.ID?
    @State private var newName: String = ""
    @State private var isInspectorPresented = false
    @State private var throughputMonitor = NetworkThroughputMonitor()

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                TextField("New network name", text: $newName)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 260)
                Button {
                    let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { return }
                    Task { await viewModel.createNetwork(name: trimmed) }
                } label: {
                    Label("Create", systemImage: "plus.circle")
                }
                Button {
                    Task { await viewModel.refreshNetworks() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                Button {
                    if let network = selectedNetwork {
                        Task { await viewModel.deleteNetwork(network) }
                    }
                } label: {
                    Label("Delete", systemImage: "trash")
                }
                .disabled(selectedNetwork == nil)
                Button {
                    isInspectorPresented = true
                } label: {
                    Label("Inspect", systemImage: "info.circle")
                }
                .disabled(selectedNetwork == nil)
                Spacer()
            }

            Table(viewModel.networks, selection: $selection) {
                TableColumn("Name") { Text($0.name) }
                TableColumn("Driver") { Text($0.driver) }
            }

            NetworkThroughputPanel(monitor: throughputMonitor)

            ConsolePanel(viewModel: viewModel)
        }
        .padding(16)
        .sheet(isPresented: $isInspectorPresented) {
            if let network = selectedNetwork {
                InspectView(title: "Network \(network.name)", json: network.raw.prettyJSON())
            }
        }
        .onAppear { throughputMonitor.start() }
        .onDisappear { throughputMonitor.stop() }
    }

    private var selectedNetwork: NetworkListItem? {
        guard let selection else { return nil }
        return viewModel.networks.first { $0.id == selection }
    }
}

struct SearchView: View {
    @Bindable var viewModel: ContainerViewModel
    @State private var selection: DockerHubRepository.ID?

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Picker("Registry", selection: $viewModel.selectedRegistry) {
                    ForEach(RegistryOption.allCases) { option in
                        Text(option.displayName).tag(option)
                    }
                }
                .pickerStyle(.menu)
                if viewModel.selectedRegistry == .custom {
                    TextField("Registry Host (e.g. registry.example.com)", text: $viewModel.customRegistryHost)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 260)
                }
                TextField(viewModel.searchPlaceholder, text: $viewModel.searchQuery)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 320)
                    .onSubmit { Task { await viewModel.searchDockerHub() } }
                Button {
                    Task { await viewModel.searchDockerHub() }
                } label: {
                    Label("Search", systemImage: "magnifyingglass")
                }
                Button {
                    if let selectedImage {
                        Task { await viewModel.pullDockerHubImage(selectedImage.id) }
                    } else {
                        Task { await viewModel.pullFromSearchQuery() }
                    }
                } label: {
                    Label("Pull", systemImage: "arrow.down.circle")
                }
                Spacer()
            }

            if !viewModel.dockerHubError.isEmpty {
                Text(viewModel.dockerHubError)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if !viewModel.dockerHubInfo.isEmpty {
                Text(viewModel.dockerHubInfo)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Table(viewModel.dockerHubResults, selection: $selection) {
                TableColumn("Image") { Text($0.id) }
                TableColumn("Stars") { Text("\($0.star_count ?? 0)") }
                TableColumn("Pulls") { Text("\($0.pull_count ?? 0)") }
                TableColumn("Official") { Text($0.is_official == true ? "Yes" : "No") }
            }

            HStack {
                Button {
                    guard let selectedImage else { return }
                    Task { await viewModel.pullDockerHubImage(selectedImage.id) }
                } label: {
                    Label("Pull Selected", systemImage: "arrow.down.circle")
                }
                .disabled(selectedImage == nil)
                Spacer()
            }

            if viewModel.isPullingImage {
                HStack(spacing: 8) {
                    ProgressView()
                    Text(viewModel.pullStatusText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            ConsolePanel(viewModel: viewModel)
        }
        .padding(16)
    }

    private var selectedImage: DockerHubRepository? {
        guard let selection else { return nil }
        return viewModel.dockerHubResults.first { $0.id == selection }
    }
}

struct CommandView: View {
    @Bindable var viewModel: ContainerViewModel
    @State private var arguments: String = ""
    @State private var overrideEntrypoint: Bool = false
    @State private var customEntrypointPath: String = ""
    @State private var lastEntrypointImageRef: String = ""

    var body: some View {
        VStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 8) {
                Text("container")
                    .font(.headline)
                TextField("Arguments (e.g. docker run -d --name myapp -p 8080:80 nginx:latest)", text: $arguments, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(15, reservesSpace: true)
                Button {
                    Task {
                        var entrypointPath = customEntrypointPath
                        if overrideEntrypoint {
                            guard let imageRef = viewModel.extractImageReference(from: arguments) else {
                                viewModel.lastError = "No run command detected. Example: run -d --name myapp image:tag"
                                return
                            }
                            let needsRefresh = entrypointPath.isEmpty
                                || !FileManager.default.fileExists(atPath: entrypointPath)
                                || lastEntrypointImageRef != imageRef
                            if needsRefresh, let path = await viewModel.generateChownFreeEntrypoint(for: imageRef) {
                                entrypointPath = path
                                customEntrypointPath = path
                                lastEntrypointImageRef = imageRef
                            }
                        }
                        await viewModel.runCustomCommand(arguments, overrideEntrypoint: overrideEntrypoint, customEntrypointPath: entrypointPath)
                    }
                } label: {
                    Label("Run", systemImage: "play.circle")
                }
            }
            Toggle("Override entrypoint (disable chown) if container doesn't start", isOn: $overrideEntrypoint)
                .toggleStyle(.checkbox)
                .onChange(of: overrideEntrypoint) { _, newValue in
                    if !newValue {
                        customEntrypointPath = ""
                        lastEntrypointImageRef = ""
                        return
                    }
                    Task {
                        guard let imageRef = viewModel.extractImageReference(from: arguments) else {
                            viewModel.lastError = "No run command detected. Example: run -d --name myapp image:tag"
                            return
                        }
                        if let path = await viewModel.generateChownFreeEntrypoint(for: imageRef) {
                            customEntrypointPath = path
                            lastEntrypointImageRef = imageRef
                        }
                    }
                }

            if viewModel.isRunningCommand {
                HStack(spacing: 8) {
                    ProgressView()
                    Text(viewModel.commandStatusText.isEmpty ? "Running command..." : viewModel.commandStatusText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            }
            Spacer()
            ConsolePanel(viewModel: viewModel)
        }
        .padding(16)
    }
}

struct LogsView: View {
    @Bindable var viewModel: ContainerViewModel
    @State private var selection: LogEntry.ID?

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Button {
                    viewModel.clearLogs()
                } label: {
                    Label("Clear Logs", systemImage: "trash")
                }
                Spacer()
            }

            Table(viewModel.logEntries, selection: $selection) {
                TableColumn("Time") { entry in
                    Text(entry.timestamp, style: .time)
                        .font(.caption)
                }
                TableColumn("Command") { entry in
                    Text(entry.command)
                        .lineLimit(1)
                        .font(.caption)
                }
            }
            .frame(minHeight: 240)

            if let entry = selectedEntry {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Output")
                        .font(.headline)
                    ScrollView {
                        Text(entry.output.isEmpty ? "-" : entry.output)
                            .font(.system(.caption, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                    .frame(maxHeight: 200)

                    if !entry.error.isEmpty {
                        Text("Error")
                            .font(.headline)
                        ScrollView {
                            Text(entry.error)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.red)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                        }
                        .frame(maxHeight: 200)
                    }
                }
                .padding(12)
                .background(Color.secondary.opacity(0.12))
                .cornerRadius(8)
            }

            Spacer()
        }
        .padding(16)
    }

    private var selectedEntry: LogEntry? {
        guard let selection else { return nil }
        return viewModel.logEntries.first { $0.id == selection }
    }
}

struct ConsolePanel: View {
    @Bindable var viewModel: ContainerViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Last Command")
                .font(.headline)
            Text(viewModel.lastCommand)
                .font(.system(.caption, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)

            if !viewModel.lastError.isEmpty {
                Text("Error")
                    .font(.headline)
                Text(viewModel.lastError)
                    .foregroundStyle(.red)
                    .font(.system(.caption, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }

            if !viewModel.lastOutput.isEmpty {
                Text("Output")
                    .font(.headline)
                ScrollView {
                    Text(viewModel.lastOutput)
                        .font(.system(.caption, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(maxHeight: 220)
            }
        }
        .padding(12)
        .background(Color.secondary.opacity(0.12))
        .cornerRadius(8)
    }
}

struct InspectView: View {
    let title: String
    let json: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(title)
                    .font(.headline)
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Label("Close", systemImage: "xmark")
                }
            }
            ScrollView {
                Text(json)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
            }
        }
        .padding(16)
        .frame(minWidth: 520, minHeight: 420)
    }
}

#Preview {
    ContentView()
}
