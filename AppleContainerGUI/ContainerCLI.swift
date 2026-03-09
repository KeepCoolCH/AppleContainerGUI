import Foundation

struct CLIResult {
    let exitCode: Int32
    let stdout: String
    let stderr: String
}

actor ContainerCLI {
    static let shared = ContainerCLI()

    func run(_ arguments: [String]) async -> CLIResult {
        let process = Process()
        let resolved = Self.containerExecutableURL()
        if let resolved {
            process.executableURL = resolved
            process.arguments = arguments
        } else {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["container"] + arguments
        }
        process.environment = Self.mergedEnvironment()

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            return CLIResult(exitCode: -1, stdout: "", stderr: error.localizedDescription)
        }

        return await withCheckedContinuation { continuation in
            process.terminationHandler = { process in
                let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                let stdout = String(data: stdoutData, encoding: .utf8) ?? ""
                let stderr = String(data: stderrData, encoding: .utf8) ?? ""
                continuation.resume(returning: CLIResult(exitCode: process.terminationStatus, stdout: stdout, stderr: stderr))
            }
        }
    }

    private static func resolveContainerExecutable() -> URL? {
        let candidates = [
            "/opt/homebrew/bin/container",
            "/usr/local/bin/container",
            "/usr/bin/container"
        ]
        let fileManager = FileManager.default
        for path in candidates where fileManager.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        return nil
    }

    static func containerExecutableURL() -> URL? {
        resolveContainerExecutable()
    }

    static func defaultEnvironment() -> [String: String] {
        mergedEnvironment()
    }

    private static func mergedEnvironment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let defaultPath = "/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        if let existing = env["PATH"], !existing.isEmpty {
            if !existing.contains("/usr/local/bin") && !existing.contains("/opt/homebrew/bin") {
                env["PATH"] = existing + ":" + defaultPath
            }
        } else {
            env["PATH"] = defaultPath
        }
        return env
    }
}

enum JSONValue: Codable, Hashable {
    case object([String: JSONValue])
    case array([JSONValue])
    case string(String)
    case number(Double)
    case bool(Bool)
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let object = try? container.decode([String: JSONValue].self) {
            self = .object(object)
        } else if let array = try? container.decode([JSONValue].self) {
            self = .array(array)
        } else if let string = try? container.decode(String.self) {
            self = .string(string)
        } else if let number = try? container.decode(Double.self) {
            self = .number(number)
        } else if let bool = try? container.decode(Bool.self) {
            self = .bool(bool)
        } else {
            self = .null
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .object(let object):
            try container.encode(object)
        case .array(let array):
            try container.encode(array)
        case .string(let string):
            try container.encode(string)
        case .number(let number):
            try container.encode(number)
        case .bool(let bool):
            try container.encode(bool)
        case .null:
            try container.encodeNil()
        }
    }

    var stringValue: String? {
        switch self {
        case .string(let string):
            return string
        case .number(let number):
            return String(number)
        case .bool(let bool):
            return bool ? "true" : "false"
        case .null:
            return nil
        case .array, .object:
            return nil
        }
    }
}

extension Dictionary where Key == String, Value == JSONValue {
    func stringValue(for keys: [String]) -> String? {
        for key in keys {
            if let value = self[key]?.stringValue {
                return value
            }
        }
        return nil
    }

    func prettyJSON() -> String {
        if let data = try? JSONEncoder().encode(JSONValue.object(self)),
           let jsonObject = try? JSONSerialization.jsonObject(with: data),
           let prettyData = try? JSONSerialization.data(withJSONObject: jsonObject, options: [.prettyPrinted, .sortedKeys]),
           let pretty = String(data: prettyData, encoding: .utf8) {
            return pretty
        }
        return "{}"
    }
}
