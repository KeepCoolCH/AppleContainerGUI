import ContainerAPIClient
import Foundation
import Vapor

struct ContainerTopResult: Content, Equatable {
    let Titles: [String]
    let Processes: [[String]]
}

protocol ContainerTopProviding: Sendable {
    func top(id: String) async throws -> String
}

struct AppleContainerTopProvider: ContainerTopProviding {
    func top(id: String) async throws -> String {
        let client = ClientContainerService()
        guard let snapshot = try await client.getContainer(id: id) else {
            throw Abort(.notFound, reason: "No such container: \(id)")
        }
        guard snapshot.status == .running else {
            throw Abort(.conflict, reason: "Container \(id) is not running")
        }
        var configuration = snapshot.configuration.initProcess
        configuration.executable = "/bin/ps"
        configuration.arguments = ["-ef"]
        configuration.terminal = false
        configuration.workingDirectory = "/"
        configuration.user = .id(uid: 0, gid: 0)
        guard let pipes = StdioPipes.make([.stdout, .stderr]) else {
            throw Abort(.internalServerError, reason: "Unable to allocate process output")
        }
        let process: ClientProcess
        do {
            process = try await ContainerClient().createProcess(
                containerId: snapshot.id,
                processId: "top-\(UUID().uuidString.lowercased())",
                configuration: configuration,
                stdio: pipes.stdioArray
            )
        } catch {
            pipes.closeAll()
            throw error
        }
        do {
            try await process.start()
        } catch {
            pipes.closeAfterHandoff()
            throw Abort(.internalServerError, reason: "docker top requires /bin/ps with -ef support in the container: \(error)")
        }
        let timeout = Task {
            try await Task.sleep(for: .seconds(10))
            try await process.kill(SIGKILL)
        }
        defer { timeout.cancel() }
        let result = try await pipes.collectOutput { try await process.wait() }
        guard result.exitCode == 0 else {
            throw Abort(.internalServerError, reason: "Container ps failed: \(String(decoding: result.stderr, as: UTF8.self))")
        }
        return String(decoding: result.stdout, as: UTF8.self)
    }
}

struct ContainerTopRoute: RouteCollection {
    let provider: any ContainerTopProviding

    init(provider: any ContainerTopProviding = AppleContainerTopProvider()) {
        self.provider = provider
    }

    func boot(routes: RoutesBuilder) throws {
        let provider = provider
        try routes.registerVersionedRoute(.GET, pattern: "/containers/{id}/top") { req in
            guard let id = req.parameters.get("id") else {
                throw Abort(.badRequest, reason: "Missing container ID")
            }
            let args = try req.query.get(String?.self, at: "ps_args") ?? "-ef"
            guard args == "-ef" else {
                throw Abort(.badRequest, reason: "AppleContainerGUI supports docker top with the default ps_args=-ef only")
            }
            return try Self.parse(await provider.top(id: id))
        }
    }

    static func parse(_ output: String) throws -> ContainerTopResult {
        let lines = output.split(whereSeparator: \.isNewline)
        guard let header = lines.first else {
            throw Abort(.internalServerError, reason: "Container ps returned no header")
        }
        let titles = header.split(whereSeparator: \.isWhitespace).map(String.init)
        guard titles.count >= 2 else {
            throw Abort(.internalServerError, reason: "Invalid container ps header")
        }
        let rows = try lines.dropFirst().map { line in
            let fields = line.split(maxSplits: titles.count - 1, whereSeparator: \.isWhitespace).map(String.init)
            guard fields.count == titles.count else {
                throw Abort(.internalServerError, reason: "Invalid container ps row")
            }
            return fields
        }
        return ContainerTopResult(Titles: titles, Processes: rows)
    }
}
