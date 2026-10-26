import SwiftUI

struct RuntimeSetupView: View {
    @State private var installer = RuntimeInstaller.shared

    var body: some View {
        GroupBox("Included Runtime") {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(installer.versions).font(.headline)
                        Text(installer.status).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if installer.isInstalling { ProgressView().controlSize(.small) }
                    Button(installer.isInstalled ? "Set Up Again" : "Install Runtime", systemImage: "shippingbox") {
                        Task { await installer.install() }
                    }
                    .disabled(installer.isInstalling)
                }
                if !installer.isInstalled {
                    Toggle("Set up /var/run/docker.sock for Docker clients", isOn: $installer.configureStandardSocket)
                        .disabled(installer.isInstalling)
                    Text("No Homebrew or runtime downloads required. macOS requests administrator authentication only for the standard socket. New container images may require registry access.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text("Existing disk volumes are migrated to shared VirtioFS folders. Running containers are stopped during setup and restarted afterwards; original disk images are retained.")
                    .font(.caption).foregroundStyle(.secondary)
                if !installer.error.isEmpty { Text(installer.error).foregroundStyle(.red).textSelection(.enabled) }
            }.padding(6)
        }
    }
}
