import CryptoKit
import Foundation

enum WireError: Error {
    case badPreface
    case oversized
    case truncated
    case badType
}

enum Wire {
    static let preface = Data("BH01".utf8)
    static let version: UInt8 = 1
    static let serviceType = "_blackhole._tcp"
    static let chunkSize = 256 * 1024
    /// type byte + uuid + offset + one chunk
    static let maxBody = 1 + 16 + 8 + chunkSize

    static func frame(_ message: Message) throws -> Data {
        let payload = try message.encoded()
        var out = Data(capacity: 4 + payload.count)
        var length = UInt32(payload.count).bigEndian
        withUnsafeBytes(of: &length) { out.append(contentsOf: $0) }
        out.append(payload)
        return out
    }
}

enum Message: Equatable {
    case hello(version: UInt8, id: UUID, name: String, code: String)
    case fileStart(id: UUID, size: UInt64, path: String, directory: Bool, mode: UInt16)
    case fileChunk(id: UUID, offset: UInt64, data: Data)
    case fileEnd(id: UUID, crc: UInt32, size: UInt64)
    case fileResult(id: UUID, ok: Bool, message: String)
    case fileAbort(id: UUID)
    case ping

    private enum Tag: UInt8 {
        case hello = 1
        case fileStart = 2
        case fileChunk = 3
        case fileEnd = 4
        case fileResult = 5
        case fileAbort = 6
        case ping = 7
    }

    func encoded() throws -> Data {
        var w = Writer()
        switch self {
        case let .hello(version, id, name, code):
            w.u8(Tag.hello.rawValue)
            w.u8(version)
            w.uuid(id)
            try w.str(name, max: 256)
            try w.str(code, max: 256)
        case let .fileStart(id, size, path, directory, mode):
            w.u8(Tag.fileStart.rawValue)
            w.uuid(id)
            w.u64(size)
            try w.str(path, max: 1024)
            w.u8(directory ? 1 : 0)
            w.u16(FileMode.bits(mode, directory: directory))
        case let .fileChunk(id, offset, data):
            if data.count > Wire.chunkSize { throw WireError.oversized }
            w.u8(Tag.fileChunk.rawValue)
            w.uuid(id)
            w.u64(offset)
            w.data.append(data)
        case let .fileEnd(id, crc, size):
            w.u8(Tag.fileEnd.rawValue)
            w.uuid(id)
            w.u32(crc)
            w.u64(size)
        case let .fileResult(id, ok, message):
            w.u8(Tag.fileResult.rawValue)
            w.uuid(id)
            w.u8(ok ? 1 : 0)
            try w.str(message, max: 120)
        case let .fileAbort(id):
            w.u8(Tag.fileAbort.rawValue)
            w.uuid(id)
        case .ping:
            w.u8(Tag.ping.rawValue)
        }
        return w.data
    }

    static func decode(_ payload: Data) throws -> Message {
        var r = Reader(payload)
        let tag = try r.u8()
        guard let kind = Tag(rawValue: tag) else { throw WireError.badType }
        let message: Message
        switch kind {
        case .hello:
            let version = try r.u8()
            let id = try r.uuid()
            let name = try r.str(max: 256)
            let code = try r.str(max: 256)
            message = .hello(version: version, id: id, name: name, code: code)
        case .fileStart:
            let id = try r.uuid()
            let size = try r.u64()
            let path = try r.str(max: 1024)
            let flag = try r.u8()
            guard flag == 0 || flag == 1 else { throw WireError.badType }
            let directory = flag == 1
            // Older peers omit the mode. A missing mode uses the usual file or folder bits.
            let mode = r.finished ? FileMode.bits(0, directory: directory) : FileMode.bits(try r.u16(), directory: directory)
            message = .fileStart(id: id, size: size, path: path, directory: directory, mode: mode)
        case .fileChunk:
            let id = try r.uuid()
            let offset = try r.u64()
            let data = r.rest()
            if data.count > Wire.chunkSize { throw WireError.oversized }
            message = .fileChunk(id: id, offset: offset, data: data)
        case .fileEnd:
            let id = try r.uuid()
            let crc = try r.u32()
            let size = try r.u64()
            message = .fileEnd(id: id, crc: crc, size: size)
        case .fileResult:
            let id = try r.uuid()
            let ok = try r.u8()
            guard ok == 0 || ok == 1 else { throw WireError.badType }
            let note = try r.str(max: 120)
            message = .fileResult(id: id, ok: ok == 1, message: note)
        case .fileAbort:
            message = .fileAbort(id: try r.uuid())
        case .ping:
            message = .ping
        }
        if kind != .fileChunk && !r.finished { throw WireError.truncated }
        return message
    }
}

struct Parser {
    private var buffer = Data()
    private var offset = 0
    private var sawPreface = false

    mutating func append(_ data: Data) throws -> [Message] {
        if !data.isEmpty { buffer.append(data) }
        var out: [Message] = []
        if !sawPreface {
            guard available() >= 4 else { return [] }
            guard peek(4) == Wire.preface else { throw WireError.badPreface }
            consume(4)
            sawPreface = true
        }
        while available() >= 4 {
            let n = Int(u32(peek(4)))
            guard n >= 1 && n <= Wire.maxBody else { throw WireError.oversized }
            guard available() >= 4 + n else { break }
            consume(4)
            let payload = peek(n)
            consume(n)
            out.append(try Message.decode(payload))
        }
        compact()
        return out
    }

    private func available() -> Int { buffer.count - offset }

    private func peek(_ count: Int) -> Data {
        let start = buffer.startIndex + offset
        return buffer.subdata(in: start..<(start + count))
    }

    private mutating func consume(_ count: Int) { offset += count }

    private mutating func compact() {
        if offset > 64 * 1024 && offset * 2 > buffer.count {
            buffer.removeFirst(offset)
            offset = 0
        }
    }

    private func u32(_ data: Data) -> UInt32 {
        data.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    }
}

struct CRC32 {
    private static let table: [UInt32] = {
        (0..<256).map { index -> UInt32 in
            var c = UInt32(index)
            for _ in 0..<8 {
                c = (c & 1) == 1 ? (0xEDB8_8320 ^ (c >> 1)) : (c >> 1)
            }
            return c
        }
    }()

    private var value: UInt32 = 0xFFFF_FFFF

    mutating func update(_ data: Data) {
        var c = value
        for byte in data {
            let index = Int((c ^ UInt32(byte)) & 0xFF)
            c = Self.table[index] ^ (c >> 8)
        }
        value = c
    }

    var checksum: UInt32 { value ^ 0xFFFF_FFFF }
}

enum CodeMark {
    static func normalize(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let scalars = trimmed.unicodeScalars.filter { $0.value >= 32 && $0.value != 127 }
        let cleaned = String(String.UnicodeScalarView(scalars))
        if cleaned.count > 64 { return String(cleaned.prefix(64)) }
        return cleaned
    }

    static func mark(_ code: String) -> String {
        let digest = SHA256.hash(data: Data(code.utf8))
        return digest.prefix(4).map { String(format: "%02x", $0) }.joined()
    }
}

enum FileMode {
    static let file: UInt16 = 0o644
    static let directory: UInt16 = 0o755

    /// Permission bits only. Setuid, setgid, and the sticky bit are not copied.
    static func bits(_ raw: UInt16, directory: Bool) -> UInt16 {
        let masked = raw & 0o777
        if masked == 0 { return directory ? Self.directory : Self.file }
        return masked
    }

    /// Owner write. A directory without it cannot accept the files that follow.
    static func ownerCanWrite(_ mode: UInt16) -> Bool {
        mode & 0o200 != 0
    }
}

enum Handshake {
    static func accept(version: UInt8, code: String, ours: String) -> Bool {
        version == Wire.version && code == ours
    }
}

enum TransferNote {
    static let saved = "Saved"
    static let badPath = "Bad path"
    static let damaged = "Damaged"
    static let disk = "Disk full"
    static let io = "Couldn't save"
}

private struct Writer {
    var data = Data()

    mutating func u8(_ value: UInt8) { data.append(value) }

    mutating func u16(_ value: UInt16) {
        data.append(UInt8(value >> 8))
        data.append(UInt8(value & 0xFF))
    }

    mutating func u32(_ value: UInt32) {
        u16(UInt16(value >> 16))
        u16(UInt16(value & 0xFFFF))
    }

    mutating func u64(_ value: UInt64) {
        u32(UInt32(value >> 32))
        u32(UInt32(value & 0xFFFF_FFFF))
    }

    mutating func uuid(_ id: UUID) {
        withUnsafeBytes(of: id.uuid) { data.append(contentsOf: $0) }
    }

    mutating func str(_ string: String, max: Int) throws {
        let bytes = Data(string.utf8)
        if bytes.count > max || bytes.count > Int(UInt16.max) { throw WireError.truncated }
        u16(UInt16(bytes.count))
        data.append(bytes)
    }
}

private struct Reader {
    let data: Data
    var i = 0

    init(_ data: Data) { self.data = data }

    var finished: Bool { i == data.count }

    mutating func u8() throws -> UInt8 {
        try need(1)
        defer { i += 1 }
        return data[data.startIndex + i]
    }

    mutating func u16() throws -> UInt16 {
        let hi = UInt16(try u8())
        let lo = UInt16(try u8())
        return (hi << 8) | lo
    }

    mutating func u32() throws -> UInt32 {
        let hi = UInt32(try u16())
        let lo = UInt32(try u16())
        return (hi << 16) | lo
    }

    mutating func u64() throws -> UInt64 {
        let hi = UInt64(try u32())
        let lo = UInt64(try u32())
        return (hi << 32) | lo
    }

    mutating func uuid() throws -> UUID {
        let bytes = try bytes(16)
        let raw: uuid_t = bytes.withUnsafeBytes { $0.loadUnaligned(as: uuid_t.self) }
        return UUID(uuid: raw)
    }

    mutating func str(max: Int) throws -> String {
        let n = Int(try u16())
        if n > max { throw WireError.truncated }
        let bytes = try self.bytes(n)
        guard let string = String(data: bytes, encoding: .utf8) else { throw WireError.truncated }
        return string
    }

    func rest() -> Data {
        data.subdata(in: (data.startIndex + i)..<data.endIndex)
    }

    private mutating func bytes(_ count: Int) throws -> Data {
        try need(count)
        let start = data.startIndex + i
        i += count
        return data.subdata(in: start..<(start + count))
    }

    private func need(_ count: Int) throws {
        if i + count > data.count { throw WireError.truncated }
    }
}
