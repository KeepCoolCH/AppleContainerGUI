import SwiftUI

struct ContainerSettingsView: View {
  @State private var cpus = ContainerDefaults.standard.cpus
  @State private var memoryMiB = ContainerDefaults.standard.memoryMiB
  @State private var saved = ContainerDefaults.standard
  @State private var status = ""
  @State private var error = ""

  private var settingsURL: URL {
    ManagedRuntime.shared.storage.appendingPathComponent("container-defaults.json")
  }
  private var hostCPUs: Int { ContainerDefaults.maximumCPUs }
  private var hostMemoryMiB: Int { Int(ProcessInfo.processInfo.physicalMemory / (1024 * 1024)) }
  private var maximumMemoryMiB: Int { ContainerDefaults.maximumMemoryMiB }
  private var current: ContainerDefaults { ContainerDefaults(cpus: cpus, memoryMiB: memoryMiB) }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        GroupBox("New container defaults") {
          VStack(alignment: .leading, spacing: 16) {
            Text(
              "Used by the app, Docker commands, Compose and Dockamp whenever a container is created without its own CPU or memory limit. New DNS helper containers also use these defaults."
            )
            .foregroundStyle(.secondary)
            VStack(alignment: .leading) {
              Text("Virtual CPUs: \(cpus)")
              Slider(
                value: Binding(get: { Double(cpus) }, set: { cpus = Int($0.rounded()) }),
                in: 1...Double(max(2, hostCPUs)), step: 1
              )
              .disabled(hostCPUs == 1)
              .accessibilityLabel("Virtual CPUs")
              .accessibilityValue("\(cpus)")
              HStack {
                Text("1")
                Spacer()
                Text("\(hostCPUs)")
              }.font(.caption).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading) {
              Text("Memory: \(Double(memoryMiB) / 1024, specifier: "%.2f") GiB (\(memoryMiB) MiB)")
              memorySlider
              HStack {
                Label("Minimum: 256 MiB", systemImage: "circle.fill").foregroundStyle(.orange)
                Spacer()
                Label("VM overhead: 128 MiB", systemImage: "circle.fill").foregroundStyle(.purple)
              }.font(.caption).foregroundStyle(.secondary)
            }
            Text(
              "This Mac: \(hostCPUs) CPU cores · \(hostMemoryMiB / 1024) GiB memory. These values apply per container."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
          }
          .padding(8)
          .frame(maxWidth: .infinity, alignment: .leading)
        }
        GroupBox {
          VStack(alignment: .leading, spacing: 12) {
            Text(
              "Apple adds 1 virtual CPU and 128 MiB of memory per VM. The memory slider reserves this overhead."
            )
            .font(.caption).foregroundStyle(.secondary)
            Text(
              "Explicit container limits take priority. Existing containers keep their current resources. Changes apply immediately to newly created containers after saving."
            )
            .foregroundStyle(.secondary)
            HStack {
              Button("Save Defaults") { save() }
                .disabled(memoryMiB < 256 || memoryMiB > maximumMemoryMiB)
              Button("Use Recommended Defaults") {
                cpus = ContainerDefaults.standard.cpus
                memoryMiB = ContainerDefaults.standard.memoryMiB
                status = "Save to apply these values."
              }
              Button("Reload") { load() }
            }
            if current != saved {
              Text("Unsaved changes").font(.caption).foregroundStyle(.secondary)
            }
            if memoryMiB < 256 || memoryMiB > maximumMemoryMiB {
              Text("Enter between 256 and \(maximumMemoryMiB) MiB.").foregroundStyle(.red)
            }
            if !status.isEmpty { Text(status).foregroundStyle(.secondary) }
            if !error.isEmpty { Text(error).foregroundStyle(.red).textSelection(.enabled) }
          }
          .padding(8)
          .frame(maxWidth: .infinity, alignment: .leading)
        }
      }
      .padding(16)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .task { load() }
  }

  private var memorySlider: some View {
    VStack(spacing: 2) {
      Slider(
        value: Binding(
          get: { Double(memoryMiB) },
          set: { memoryMiB = min(maximumMemoryMiB, max(256, Int($0.rounded()))) }
        ), in: 0...Double(max(257, hostMemoryMiB))
      )
      .overlay {
        GeometryReader { geometry in
          let width = max(0, geometry.size.width - 16)
          let minimumWidth = max(3, width * 256 / Double(hostMemoryMiB))
          let overheadWidth = max(
            3, width * Double(hostMemoryMiB - maximumMemoryMiB) / Double(hostMemoryMiB))
          HStack(spacing: 0) {
            Capsule().fill(.orange.opacity(0.8)).frame(width: minimumWidth)
            Spacer(minLength: 0)
            Capsule().fill(.purple.opacity(0.8)).frame(width: overheadWidth)
          }
          .frame(height: 6)
          .padding(.horizontal, 8)
          .frame(height: geometry.size.height)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
      }
      .accessibilityLabel("Memory")
      .accessibilityValue("\(memoryMiB) MiB")
      .accessibilityHint(
        "Minimum 256 MiB. Maximum \(maximumMemoryMiB) MiB. 128 MiB reserved for the virtual machine."
      )
      Canvas { context, size in
        for index in 0...16 {
          let x = 8 + (size.width - 16) * Double(index) / 16
          let height: CGFloat = index.isMultiple(of: 4) ? 7 : 4
          let tick = CGRect(x: x - 0.5, y: 0, width: 1, height: height)
          context.fill(
            Path(roundedRect: tick, cornerRadius: 0.5), with: .color(.secondary.opacity(0.45)))
        }
      }
      .frame(height: 8)
      .accessibilityHidden(true)
    }
  }

  private func load() {
    do {
      let value = try ContainerDefaults.load(from: settingsURL) ?? .standard
      cpus = min(hostCPUs, value.cpus)
      memoryMiB = min(maximumMemoryMiB, value.memoryMiB)
      saved = value
      error = ""
      status =
        current == value
        ? "" : "Saved values exceed this Mac’s limits. Save to apply the adjusted values."
    } catch { self.error = error.localizedDescription }
  }

  private func save() {
    do {
      try current.save(to: settingsURL)
      saved = current
      error = ""
      status = "Saved. New containers use \(cpus) CPUs and \(memoryMiB) MiB unless overridden."
    } catch { self.error = error.localizedDescription }
  }
}
