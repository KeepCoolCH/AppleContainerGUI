import Foundation

final class GUIDNSAdmission: @unchecked Sendable {
    private struct Bucket {
        var tokens: Double
        var updated: TimeInterval
        var active: Int = 0
    }
    private let lock = NSLock()
    private var clients: [String: Bucket] = [:]
    private var globalTokens: Double = 1000
    private var updated: TimeInterval = 0
    private var active = 0
    private let maximumConcurrent: Int

    init(maximumConcurrent: Int = 64) {
        self.maximumConcurrent = maximumConcurrent
    }

    func begin(source: String, now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        globalTokens = min(1000, globalTokens + max(0, now - updated) * 500)
        updated = now
        if clients.count > 4096 {
            clients = clients.filter { $0.value.active > 0 || now - $0.value.updated < 60 }
        }
        var bucket = clients[source] ?? Bucket(tokens: 200, updated: now)
        bucket.tokens = min(200, bucket.tokens + max(0, now - bucket.updated) * 100)
        bucket.updated = now
        guard active < maximumConcurrent, bucket.active < 8, globalTokens >= 1, bucket.tokens >= 1 else {
            clients[source] = bucket
            return false
        }
        globalTokens -= 1
        bucket.tokens -= 1
        bucket.active += 1
        clients[source] = bucket
        active += 1
        return true
    }

    func end(source: String) {
        lock.lock()
        defer { lock.unlock() }
        guard var bucket = clients[source], bucket.active > 0 else { return }
        bucket.active -= 1
        clients[source] = bucket
        active -= 1
    }
}
