import Foundation

nonisolated enum ContainerSystemStatus {
    static func isRunning(stdout: String, stderr: String = "", exitCode: Int32 = 0) -> Bool {
        guard exitCode == 0 else { return false }
        let text = (stdout + "\n" + stderr)
            .replacingOccurrences(of: "\u{001B}\\[[0-?]*[ -/]*[@-~]", with: "", options: .regularExpression)
            .lowercased()
        let lines = text.split(whereSeparator: \.isNewline)
            .map { $0.split(whereSeparator: \.isWhitespace).map(String.init) }
        for fields in lines where fields.count >= 2 {
            if fields[0] == "status" || fields[0] == "status:" {
                return fields[1] == "running"
            }
        }
        return lines.contains { $0 == ["apiserver", "is", "running"] || $0 == ["apiserver", "is", "running."] }
    }
}
