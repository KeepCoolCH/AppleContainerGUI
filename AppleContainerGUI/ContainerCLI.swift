import Foundation

struct CLIResult {
    let exitCode: Int32
    let stdout: String
    let stderr: String
}

actor ContainerCLI {
    static let shared = ContainerCLI()

    func run(_ arguments: [String]) async -> CLIResult {
        guard let executable = Self.containerExecutableURL(), let root = ManagedRuntime.shared.installedRoot else {
            return CLIResult(exitCode: -1, stdout: "", stderr: "Install the bundled runtime using Install Runtime in the app.")
        }
        if arguments == ["system", "start"] {
            do {
                try await ManagedRuntime.shared.start(root)
                return CLIResult(exitCode: 0, stdout: "Bundled Apple Container is running", stderr: "")
            } catch { return CLIResult(exitCode: -1, stdout: "", stderr: error.localizedDescription) }
        }
        let result = await LocalCommand.run(executable, arguments, environment: Self.defaultEnvironment(), timeout: 120)
        return CLIResult(exitCode: result.code, stdout: result.output, stderr: result.error)
    }

    static func containerExecutableURL() -> URL? {
        ManagedRuntime.shared.executable("AppleContainer/bin/container")
    }

    static func defaultEnvironment() -> [String: String] {
        ManagedRuntime.shared.environment()
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
