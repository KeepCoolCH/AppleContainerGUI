import SwiftUI
import AppKit

struct DockerSocketView: View {
    @State private var service = DockerSocketService.shared
    @State private var showSocketConfirmation = false
    @State private var showLog = false
    @State private var logText = ""
    @State private var loginEnabled = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Image(systemName: service.isRunning ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(service.isRunning ? .green : .secondary)
                    Text("Docker API via Socktainer").font(.title2)
                    Spacer()
                    if service.isBusy { ProgressView().controlSize(.small) }
                    Text(service.status).foregroundStyle(.secondary)
                }
                HStack {
                    Button("Start", systemImage: "play.fill") { Task { await service.start() } }
                        .disabled(service.isBusy || service.isManaged || service.isRunning)
                    Button("Stop", systemImage: "stop.fill") { Task { await service.stop() } }
                        .disabled(service.isBusy || !service.isManaged)
                    Button("Check API", systemImage: "stethoscope") { Task { await service.diagnose() } }
                        .disabled(service.isBusy || !service.isRunning)
                    Button("Runtime Log", systemImage: "doc.text") {
                        logText = service.readLogTail()
                        showLog = true
                    }
                }
                GroupBox("Runtime") {
                    VStack(alignment: .leading, spacing: 10) {
                        LabeledContent("Executable", value: service.executableURL()?.path ?? "Not installed")
                        if !service.runtimeVersion.isEmpty { Text(service.runtimeVersion).font(.caption) }
                        if !service.apiVersion.isEmpty { LabeledContent("Docker API version", value: service.apiVersion) }
                        HStack {
                            Spacer()
                            Toggle("Start with app", isOn: $service.startsWithApp)
                            Toggle("Launch app at login", isOn: $loginEnabled)
                                .onChange(of: loginEnabled) { _, value in
                                    service.setLaunchAtLogin(value)
                                    loginEnabled = service.launchAtLogin
                                }
                        }
                        .disabled(service.isBusy || service.isManaged)
                        Text("The app manages its own Socktainer process. Closing the window keeps it running in the menu bar. Quitting the app stops the managed API service; containers remain in Apple Container.")
                            .font(.caption).foregroundStyle(.secondary)
                    }.padding(8)
                }
                GroupBox("Connect Docker clients") {
                    VStack(alignment: .leading, spacing: 10) {
                        LabeledContent("Socket", value: service.socketPath)
                        Text(service.connectionCommand).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                        HStack {
                            Button("Copy DOCKER_HOST") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString("export DOCKER_HOST=" + DockerSocketService.shellQuote(service.dockerHost), forType: .string)
                            }
                            Button("Create Docker Context") { Task { await service.createContext() } }
                                .disabled(service.isBusy || !service.isRunning)
                        }
                        Text("The context is saved in the app’s Docker configuration. Use the displayed command with --config and --host from Terminal.")
                            .font(.caption).foregroundStyle(.secondary)
                    }.padding(8)
                }
                GroupBox("Standard Docker socket") {
                    VStack(alignment: .leading, spacing: 10) {
                        LabeledContent("/var/run/docker.sock", value: service.systemSocketTarget)
                        HStack {
                            Button("Use /var/run/docker.sock…") { showSocketConfirmation = true }
                                .disabled(service.isBusy || !service.isRunning || service.systemSocketTarget == service.socketPath)
                            Button("Restore Previous Socket") { Task { await service.configureSystemSocket(restore: true) } }
                                .disabled(service.isBusy || service.systemSocketTarget != service.socketPath)
                        }
                        Text("Changing this link redirects clients using the standard socket. An existing symbolic link is saved for restoration. macOS requires administrator authentication for /var/run.")
                            .font(.caption).foregroundStyle(.secondary)
                    }.padding(8)
                }
                GroupBox("Container access and compatibility") {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Containers created through this API can use -v /var/run/docker.sock:/var/run/docker.sock. Socktainer forwards that connection into the Apple VM. That container can then manage other containers through the Docker API.")
                        Text("Bundled extensions: docker top with default ps arguments, recorded exit codes, and restart monitoring for containers still running after an API service restart.")
                        Text("Partial compatibility: Swarm, Engine plugins, pause/unpause, commit, diff and rename remain unsupported. Network connect/disconnect and some resource options have upstream limitations. docker top requires /bin/ps in the image. A host reboot does not restore stopped containers through the recovery extension.")
                            .font(.caption).foregroundStyle(.secondary)
                    }.padding(8)
                }
                if !service.compatibilityWarning.isEmpty {
                    Text(service.compatibilityWarning).foregroundStyle(.orange).textSelection(.enabled)
                }
                if !service.lastError.isEmpty {
                    Text(service.lastError).foregroundStyle(.red).textSelection(.enabled)
                }
                if !service.diagnosticOutput.isEmpty {
                    Text(service.diagnosticOutput).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                }
            }
            .padding(20)
        }
        .onAppear {
            service.refreshSystemSocket()
            loginEnabled = service.launchAtLogin
        }
        .confirmationDialog("Redirect /var/run/docker.sock to Apple Container?", isPresented: $showSocketConfirmation) {
            Button("Use Apple Container Socket") { Task { await service.configureSystemSocket() } }
        } message: {
            Text("Current target: \(service.systemSocketTarget). The existing symbolic link will be backed up. macOS will request administrator authentication.")
        }
        .sheet(isPresented: $showLog) {
            VStack(alignment: .leading) {
                Text("Socktainer Log").font(.headline)
                ScrollView { Text(logText.isEmpty ? "No log output" : logText).font(.system(.caption, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                HStack {
                    Button("Refresh") { logText = service.readLogTail() }
                    Spacer()
                    Button("Done") { showLog = false }
                }
            }.padding(20).frame(width: 820, height: 480)
        }
    }
}
