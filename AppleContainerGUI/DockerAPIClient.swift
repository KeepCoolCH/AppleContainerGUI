import Foundation
import Darwin

nonisolated struct LocalCommandResult: Sendable {
    let code: Int32
    let output: String
    let error: String
}

nonisolated enum LocalCommand {
    static func run(_ executable: URL, _ arguments: [String], environment: [String: String]? = nil, timeout: TimeInterval = 30) async -> LocalCommandResult {
        await Task.detached(priority: .utility) {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                defer { try? FileManager.default.removeItem(at: directory) }
                let outputURL = directory.appendingPathComponent("stdout")
                let errorURL = directory.appendingPathComponent("stderr")
                FileManager.default.createFile(atPath: outputURL.path, contents: nil)
                FileManager.default.createFile(atPath: errorURL.path, contents: nil)
                let output = try FileHandle(forWritingTo: outputURL)
                let error = try FileHandle(forWritingTo: errorURL)
                defer { try? output.close(); try? error.close() }
                let process = Process()
                process.executableURL = executable
                process.arguments = arguments
                process.environment = environment
                process.standardInput = FileHandle.nullDevice
                process.standardOutput = output
                process.standardError = error
                try process.run()
                let deadline = DispatchWorkItem {
                    if process.isRunning { process.terminate() }
                }
                let killDeadline = DispatchWorkItem {
                    if process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) }
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: deadline)
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout + 2, execute: killDeadline)
                process.waitUntilExit()
                deadline.cancel()
                killDeadline.cancel()
                return LocalCommandResult(code: process.terminationStatus,
                                          output: String(decoding: try Data(contentsOf: outputURL), as: UTF8.self),
                                          error: String(decoding: try Data(contentsOf: errorURL), as: UTF8.self))
            } catch {
                return LocalCommandResult(code: -1, output: "", error: error.localizedDescription)
            }
        }.value
    }
}

nonisolated struct DockerAPIResponse: Sendable {
    let status: Int
    let body: Data

    func decode<T: Decodable>(_ type: T.Type) throws -> T {
        try JSONDecoder().decode(type, from: body)
    }
}

nonisolated struct DockerAPIError: LocalizedError {
    let message: String
    var statusCode: Int? = nil
    var errorDescription: String? { message }
}

nonisolated struct DockerVersion: Decodable, Sendable {
    let Version: String
    let ApiVersion: String
    let MinAPIVersion: String?
    let Os: String?
    let Arch: String?
}

nonisolated struct DockerAPIClient: Sendable {
    let socketPath: String

    func request(_ method: String = "GET", path: String, body: Data? = nil, timeout: Int = 5) async throws -> DockerAPIResponse {
        guard path.hasPrefix("/"), !path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw DockerAPIError(message: "Invalid Docker API path")
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        var arguments = ["--silent", "--show-error", "--noproxy", "*", "--proxy", "", "--unix-socket", socketPath,
                         "--max-time", String(timeout), "--request", method, "--write-out", "\n%{http_code}",
                         "--header", "Accept: application/json"]
        if let body {
            let file = directory.appendingPathComponent("request.json")
            try body.write(to: file)
            arguments += ["--header", "Content-Type: application/json", "--data-binary", "@" + file.path]
        }
        arguments.append("http://localhost" + path)
        let result = await LocalCommand.run(URL(fileURLWithPath: "/usr/bin/curl"), arguments, timeout: TimeInterval(timeout + 3))
        guard result.code == 0 else { throw DockerAPIError(message: result.error.isEmpty ? "Docker API request failed" : result.error) }
        guard let separator = result.output.lastIndex(of: "\n"), let status = Int(result.output[result.output.index(after: separator)...]) else {
            throw DockerAPIError(message: "Invalid Docker API response")
        }
        let data = Data(result.output[..<separator].utf8)
        guard (200..<300).contains(status) else {
            let details = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            throw DockerAPIError(message: "HTTP \(status): \(details?["message"] as? String ?? String(decoding: data, as: UTF8.self))", statusCode: status)
        }
        return DockerAPIResponse(status: status, body: data)
    }

    enum Resource: String, Sendable {
        case containers, images, volumes, networks
    }

    func remove(_ resource: Resource, name: String) async throws -> Bool {
        guard !name.isEmpty else { throw DockerAPIError(message: "Missing resource name") }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        guard let encoded = name.addingPercentEncoding(withAllowedCharacters: allowed) else {
            throw DockerAPIError(message: "Invalid resource name")
        }
        let query = resource == .containers ? "?force=true" : ""
        do {
            _ = try await request("DELETE", path: "/" + resource.rawValue + "/" + encoded + query, timeout: 120)
            return true
        } catch let error as DockerAPIError where error.statusCode == 404 {
            return false
        }
    }

    func ping() async throws {
        let response = try await request(path: "/_ping")
        guard String(decoding: response.body, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) == "OK" else {
            throw DockerAPIError(message: "Socket did not return a Docker API ping response")
        }
    }
}
