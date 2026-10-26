import CryptoKit
import Foundation
import libzstd

enum GUIZstd {
    enum Failure: Error {
        case invalidStream
        case exceedsLimit
    }

    static func digest(_ path: URL, limit: Int) throws -> String {
        guard let stream = ZSTD_createDStream() else { throw Failure.invalidStream }
        defer { ZSTD_freeDStream(stream) }
        guard ZSTD_isError(ZSTD_initDStream(stream)) == 0,
              ZSTD_isError(ZSTD_DCtx_setParameter(stream, ZSTD_d_windowLogMax, 27)) == 0 else { throw Failure.invalidStream }
        let file = try FileHandle(forReadingFrom: path)
        defer { try? file.close() }
        var hash = SHA256()
        var total = 0
        var remaining = 1
        var hasInput = false
        var output = [UInt8](repeating: 0, count: 65536)
        while let data = try file.read(upToCount: 65536), !data.isEmpty {
            hasInput = true
            try data.withUnsafeBytes { bytes in
                var input = ZSTD_inBuffer(src: bytes.baseAddress, size: bytes.count, pos: 0)
                while true {
                    let previous = input.pos
                    let produced = try output.withUnsafeMutableBytes { buffer -> Int in
                        var target = ZSTD_outBuffer(dst: buffer.baseAddress, size: buffer.count, pos: 0)
                        remaining = ZSTD_decompressStream(stream, &target, &input)
                        guard ZSTD_isError(remaining) == 0 else { throw Failure.invalidStream }
                        guard limit >= total, target.pos <= limit - total else { throw Failure.exceedsLimit }
                        total += target.pos
                        hash.update(data: Data(buffer.prefix(target.pos)))
                        return target.pos
                    }
                    if remaining == 0 && input.pos == input.size { break }
                    if input.pos == input.size && produced < output.count { break }
                    guard input.pos > previous || produced > 0 else { throw Failure.invalidStream }
                }
            }
        }
        guard hasInput, remaining == 0 else { throw Failure.invalidStream }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
