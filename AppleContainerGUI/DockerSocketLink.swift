import Foundation
import Darwin

nonisolated enum DockerSocketLink {
    static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }

    static func removeStaleSocket(at path: String) throws {
        var before = stat()
        guard lstat(path, &before) == 0 else {
            if errno == ENOENT { return }
            throw DockerAPIError(message: "Cannot inspect the Docker socket")
        }
        guard (before.st_mode & S_IFMT) == S_IFSOCK, before.st_uid == getuid(), path.utf8.count < 104 else {
            throw DockerAPIError(message: "The Docker socket path is not an owned Unix socket")
        }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { bytes in
            bytes.copyBytes(from: Array(path.utf8) + [0])
        }
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw DockerAPIError(message: "Cannot probe the Docker socket") }
        defer { close(descriptor) }
        _ = fcntl(descriptor, F_SETFL, O_NONBLOCK)
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        let code = errno
        guard result == -1 && code == ECONNREFUSED else {
            throw DockerAPIError(message: "Another service still owns the Docker socket; stop that service first")
        }
        var after = stat()
        guard lstat(path, &after) == 0, before.st_dev == after.st_dev, before.st_ino == after.st_ino,
              (after.st_mode & S_IFMT) == S_IFSOCK, after.st_uid == getuid() else {
            throw DockerAPIError(message: "The Docker socket changed during cleanup")
        }
        guard unlink(path) == 0 else { throw DockerAPIError(message: "Cannot remove the stale Docker socket") }
    }

    static func command(target: String, restore: Bool, link: String = "/var/run/docker.sock", backup: String = "/var/run/docker.sock.applecontainergui-backup") -> String {
        let target = quote(target)
        let link = quote(link)
        let backup = quote(backup)
        if restore {
            return """
            set -eu
            [ -L \(link) ] && [ "$(/usr/bin/readlink \(link))" = \(target) ] || { echo 'Docker socket is no longer owned by AppleContainerGUI' >&2; exit 1; }
            if [ -e \(backup) ] && [ ! -L \(backup) ]; then echo 'The socket backup is not a symbolic link' >&2; exit 1; fi
            /bin/rm \(link)
            if [ -L \(backup) ]; then /bin/mv \(backup) \(link); fi
            """
        }
        return """
        set -eu
        if [ -L \(link) ] && [ "$(/usr/bin/readlink \(link))" = \(target) ]; then exit 0; fi
        if [ -e \(backup) ] && [ ! -L \(backup) ]; then echo 'The socket backup is not a symbolic link' >&2; exit 1; fi
        if [ -e \(link) ] && [ ! -L \(link) ]; then echo 'Refusing to replace an existing socket or regular file' >&2; exit 1; fi
        if [ -L \(link) ]; then
            if [ -L \(backup) ]; then
                archive=$(/usr/bin/mktemp -d \(backup).XXXXXXXX)
                /bin/mv \(backup) "$archive/docker.sock"
            fi
            /bin/mv \(link) \(backup)
        fi
        if ! /bin/ln -s \(target) \(link); then if [ -L \(backup) ]; then /bin/mv \(backup) \(link); fi; exit 1; fi
        """
    }
}
