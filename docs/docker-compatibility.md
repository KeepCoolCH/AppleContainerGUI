# Docker API integration

AppleContainerGUI exposes a Docker-compatible API through its bundled Socktainer bridge. Docker clients communicate over a Unix socket; Apple Container runs the containers. No Docker Engine VM or Docker Desktop installation is required.

## Included components

| Component | Version |
| --- | --- |
| Apple Container | 1.6.0 |
| Containerization and vminit | 0.52.1 |
| Socktainer with app extensions | 1.2.1-acgui.15 |
| Docker CLI | 29.9.2 |
| Docker Compose | 5.5.1 |
| Container builder | 0.13.2 |
| Linux kernel | 6.18.35 |

Socktainer is based on upstream revision `cdadd189bf6899cb363a18489e31d36e204fd0dd` with compatibility extensions for this app. Its version is managed with the app bundle.

## Installation

Requires Apple Silicon and macOS 26.2 or newer.

1. Open **AppleContainerGUI.app**.
2. Click **Install Runtime**.
3. Optionally enable the standard Docker socket and approve the macOS administrator prompt.

Setup verifies and installs the included components, starts Apple Container, imports the boot images, installs the kernel and configures Docker CLI, Compose and the API bridge. Homebrew, a separate Apple installer and runtime downloads are not needed. Registry searches, application image pulls and Dockerfile dependencies still require network access.

The app stores its files in the current user's home directory:

| Data | Location |
| --- | --- |
| Runtime binaries | `~/Library/Application Support/AppleContainerGUI/Runtimes/<bundleVersion>` |
| Apple Container data | `~/Library/Application Support/com.apple.container` |
| Docker configuration | `~/Library/Application Support/AppleContainerGUI/docker-config` |
| Shared data volumes | `~/Library/Application Support/AppleContainerGUI/Volumes` |
| Container defaults | `~/Library/Application Support/AppleContainerGUI/container-defaults.json` |
| Private Docker socket | `~/.applecontainergui/docker.sock` |

The app uses its bundled tools rather than searching Homebrew or `/usr/local` for runtime binaries.

**Set Up Again** repairs or upgrades the installation. Setup can stop running containers and the native service while migrating data, then restore the previously running containers. Failed setup displays an error and can be retried.

## Connect Docker clients

The **Docker API** tab provides connection information, API diagnostics, runtime logs and optional Docker context creation. Use the bundled Docker executable path displayed there when running commands from Terminal. The examples below can also be entered in the app's **Command** tab.

External clients can connect using:

```sh
export DOCKER_HOST="unix://$HOME/.applecontainergui/docker.sock"
```

Alternatively, configure `/var/run/docker.sock` in the app. macOS requires administrator authentication for this link. An existing symbolic link is backed up for restoration; regular files and active socket files are not overwritten. Reboots or another Docker application's socket setup can require configuring the link again.

The Docker context created by the app belongs to its separate Docker configuration. Use the connection command shown in the app when working from Terminal.

### Access the API from a container

Create the container through the Docker API and mount the standard socket:

```sh
docker run --rm \
  -v /var/run/docker.sock:/var/run/docker.sock \
  curlimages/curl --unix-socket /var/run/docker.sock http://localhost/_ping
```

Socktainer relays the connection into the Apple Container VM. An existing container without this mount needs recreation to receive it.

The mounted socket grants full API access, including management of other containers and host bind mounts accessible to the app user. Grant this mount only to trusted workloads.

## App and container lifecycle

Closing the window keeps the app available in the menu bar. The menu lists running and stopped application containers and provides **Start**, **Stop** and **Restart** actions. Internal DNS helpers are hidden.

Quitting the app stops its owned Docker API process and removes its socket. Apple Container and its containers remain running. Launch at login and API startup with the app are configurable. Unexpected exits of the owned API process trigger bounded recovery attempts.

Resource lists refresh automatically while the API is available. Failed refreshes retain the previous list, and unchanged data does not replace rows or overwrite command output.

Deleting a running container stops it before removal and retains its data volumes. Confirmed stale resource entries can be removed; connection failures, conflicts and backend errors remain visible.

## Commands and container metadata

Docker commands and supported unprefixed data commands in the **Command** tab use the bundled Docker CLI and API socket. Apple-specific operations, such as snapshots and native system management, still use the Apple CLI.

The command panel is noninteractive and has a five-minute command limit. Use Terminal with the displayed connection configuration for TTY sessions, long builds and following logs.

API-created containers use their effective container name as the default hostname. An explicit `--hostname` takes priority. Existing containers need recreation with their retained volumes to change their creation-time hostname.

The bridge provides container inspection, captured exit codes and `docker top`. Unknown historical exit codes are reported as `-1`. Image metadata distinguishes registry pulls from local builds and includes names, tags, available sizes, history and parent references. Older images without a recorded pull may require another pull through the API before registry-based update checks are available.

## CPU and memory defaults

The **Settings** tab saves CPU and memory defaults for new application containers and DNS helpers. Explicit Docker CPU and memory limits override these defaults independently. Requests without limits, including Compose requests, use the saved defaults.

Recommended defaults are half the available CPU cores rounded up to an even count, capped at the host's core count, and one quarter of physical RAM. Memory has a 256 MiB minimum and reserves the native VM overhead within host limits.

Saving defaults does not recreate or change existing containers, volumes, ports, environment values or networks. Existing DNS helpers retain their resources and IP addresses.

## VirtioFS storage

Named and anonymous Docker volumes are host directories shared through VirtioFS. Bind mounts also use VirtioFS. Multiple containers can write to the same shared directory; explicit `:ro` mounts remain read-only. Empty volumes receive the image directory's initial contents before first start. Volumes referenced by running or stopped containers cannot be deleted.

Setup can migrate existing disk-backed data volumes to VirtioFS without replacing the containers' writable root filesystems. Original disk images and configuration backups are retained. Configuration backups are stored under `~/Library/Application Support/AppleContainerGUI/VolumeMigrationBackups`. Do not use native Apple volume commands to manage those retained backups.

Migration preserves file contents, links, modes and modification dates. Original Linux ownership and hashes are recorded in `linux-metadata.json`. VirtioFS uses macOS ownership mapping and does not emulate exact Linux UID/GID behavior. Applications requiring Linux special files, extended attributes, exact ownership changes or case-sensitive paths may need adaptation. Unsupported special files and filename collisions stop migration rather than silently discarding data. VM root and boot disks remain disk images; `tmpfs` remains memory-backed.

## Networks and DNS

The bridge resolves container names, Compose service names and aliases within shared networks. Identical aliases can exist in separate networks. DNS helpers are hidden from normal container lists and cleaned up when no running or stopped container references their network attachment.

Network connect/disconnect preserves the container ID, writable filesystem, mounts, ports, resources and command configuration. Updating interfaces briefly stops and restarts a running container. Stopped containers remain stopped. Running auto-remove containers are rejected to prevent data loss. Failed updates are rolled back.

Explicit extra-host mappings support IPv4 addresses and `host-gateway`, for example:

```sh
docker run --add-host host.docker.internal:host-gateway alpine:3.22 getent hosts host.docker.internal
```

These mappings use the scoped DNS bridge rather than `/etc/hosts`. They apply only to the requesting container. DNS forwarding uses UDP, supports A records and returns NODATA for local AAAA queries. IPv6 extra-host addresses and host/none network modes are unsupported.

## Compatibility limits

This bridge provides partial Docker API compatibility rather than a complete Docker Engine implementation.

- Swarm, Engine plugins, rename, commit, filesystem diff and pause/unpause are unsupported.
- Compose initial creation, volumes, health dependencies and service DNS are supported. Some recreation flows require the unsupported rename endpoint.
- Static endpoint IP addresses, links and network driver options are rejected. Some resource and security settings have no equivalent in Apple Container.
- Nonempty `SecurityOpt` and positive `PidsLimit` values are rejected because the backend cannot enforce them.
- `docker top` requires `/bin/ps` with `-ef` support in the image. Custom `ps_args` and distroless images without that executable are unsupported.
- API restart recovery resumes monitoring containers that are still running. It does not restore stopped containers after a host reboot, preserve retry counters or provide Docker's complete durable manual-stop semantics. Native CLI actions bypass Docker restart-policy bookkeeping.
- Historical exit codes cannot be recovered after an API restart unless captured again.
- Native network deletion can report an old network reference after a container is disconnected. The bridge reports the error rather than forcing deletion.
- CPU architecture, Linux kernel capabilities, devices and host networking restrictions still apply. A Docker socket does not make Windows images or arbitrary Linux workloads compatible.

## Security

The private Docker socket uses mode `0600` inside a mode-`0700` directory. It is intended for local clients and explicitly authorized containers, not unauthenticated remote access.

The DNS service accepts requests only from known running container addresses and valid shared-network forwarding helpers. Packet-size, concurrency and rate limits restrict request handling. UDP source filtering is not cryptographic authentication, and newly started containers may need a DNS retry while membership updates.

Runtime startup verifies the installed manifest against the bundled copy and checks file hashes. Executable lookup also verifies selected binaries. These checks detect modified installed files but do not protect an already compromised macOS account.

## Build from source

Build requirements are Apple Silicon, macOS 26.2 or newer, Xcode with Swift 6.2 or newer, Python 3 and `zstd` for unpacking the kernel archive. These are developer tools, not dependencies for users downloading the app.

Configure your own Developer ID signing identity and Apple development team in Xcode. The runtime packaging script accepts the signing identity through `APPLE_CONTAINER_GUI_SIGNING_IDENTITY`.

```sh
export APPLE_CONTAINER_GUI_SIGNING_IDENTITY="Developer ID Application: Your Name (TEAMID)"
bash scripts/build-socktainer.sh
python3 scripts/bundle-runtime.py
xcodebuild -project AppleContainerGUI.xcodeproj -scheme AppleContainerGUI \
  -configuration Release \
  CODE_SIGN_IDENTITY="$APPLE_CONTAINER_GUI_SIGNING_IDENTITY" \
  DEVELOPMENT_TEAM=TEAMID build
```

The build scripts fetch the pinned sources, apply the runtime extensions and package the verified Apple, Docker, Compose, kernel and boot-image artifacts. The complete runtime payload must exist before building the app. During the Xcode build, it is packed into a ZIP resource with an archive checksum and the original file manifest. Export signing leaves the archived executables unchanged. Installation checks the archive before extraction and checks every extracted file against the bundled manifest before activation.

Apple binaries retain their original signatures and entitlements. Packaged helper tools use Developer ID signing, Hardened Runtime and secure timestamps. Public distribution also requires notarization and ticket stapling. Included dependency licenses are stored in the payload's `Licenses` directory; source and license obligations also apply to the kernel and OCI images.
