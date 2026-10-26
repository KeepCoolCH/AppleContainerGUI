import ContainerAPIClient
import Foundation
import Vapor

struct ContainerStatsRoute: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        try routes.registerVersionedRoute(
            .GET, pattern: "/containers/{id}/stats", use: ContainerStatsRoute.handler)
    }

    static func handler(_ req: Request) async throws -> Response {
        guard let reference = req.parameters.get("id") else {
            throw Abort(.badRequest, reason: "Missing container ID")
        }
        guard let container = try await ClientContainerService().getContainer(id: reference) else {
            throw Abort(.notFound, reason: "No such container: \(reference)")
        }
        guard container.status == .running else {
            throw Abort(.conflict, reason: "Container is not running: \(reference)")
        }
        let stream = MobyBool.queryValue(req.query["stream"] as String?, defaultingTo: true)
        let client = ContainerClient()
        let nativeID = container.id
        let dockerID = DockerContainerID.hexId(for: container)
        let firstSample = try await client.stats(id: nativeID)
        let firstRead = Date()
        var headers = HTTPHeaders()
        headers.add(name: "Content-Type", value: "application/json")

        if !stream {
            try await Task.sleep(for: .seconds(1))
            let current = try await client.stats(id: nativeID)
            let stats = RESTContainerStats.build(
                id: dockerID, prev: firstSample, curr: current,
                prevRead: firstRead, currRead: Date())
            return Response(status: .ok, headers: headers, body: .init(data: try JSONEncoder().encode(stats)))
        }

        let body = Response.Body { writer in
            Task {
                do {
                    var previous = firstSample
                    var previousRead = firstRead
                    while !Task.isCancelled {
                        try await Task.sleep(for: .seconds(1))
                        let current = try await client.stats(id: nativeID)
                        let read = Date()
                        let stats = RESTContainerStats.build(
                            id: dockerID, prev: previous, curr: current,
                            prevRead: previousRead, currRead: read)
                        let data = try JSONEncoder().encode(stats)
                        var buffer = sharedAllocator.buffer(capacity: data.count + 1)
                        buffer.writeBytes(data)
                        buffer.writeString("\n")
                        try await writer.write(.buffer(buffer)).get()
                        previous = current
                        previousRead = read
                    }
                    _ = writer.write(.end)
                } catch {
                    req.logger.debug("Container stats stream ended for \(nativeID): \(error)")
                    _ = writer.write(.error(error))
                }
            }
        }
        return Response(status: .ok, headers: headers, body: body)
    }
}
