import Darwin
import Foundation

enum TransferError: Error, Equatable {
    case closed
    case timeout
    case refused(String)
    case io(String)
}

protocol MessageOut: AnyObject {
    func send(_ message: Message) throws
    func awaitResult(id: UUID, timeout: TimeInterval) throws
    func failed(_ id: UUID) -> Bool
}

final class Scope {
    let url: URL
    private let active: Bool
    private var done = false
    private let lock = NSLock()

    init(_ url: URL) {
        self.url = url
        active = url.startAccessingSecurityScopedResource()
    }

    func release() {
        lock.lock()
        let should = active && !done
        done = true
        lock.unlock()
        if should { url.stopAccessingSecurityScopedResource() }
    }

    deinit { release() }
}

final class ProgressMeter {
    let total: UInt64
    private var done: UInt64 = 0
    private var last = Date.distantPast
    private let lock = NSLock()
    var onUpdate: ((Double) -> Void)?

    init(total: UInt64) { self.total = total }

    func add(_ count: UInt64) {
        lock.lock()
        done += count
        let fraction = total == 0 ? 1.0 : min(1, Double(done) / Double(total))
        let now = Date()
        let emit = fraction >= 1 || now.timeIntervalSince(last) > 0.08
        if emit { last = now }
        lock.unlock()
        if emit { onUpdate?(fraction) }
    }
}

struct SendItem: Equatable {
    var relativePath: String
    var fileURL: URL?
    var isDirectory: Bool
    var size: UInt64
    /// Permission bits (0o777). Setuid, setgid, and the sticky bit are not sent.
    var mode: UInt16
}

struct DropBatch {
    var items: [SendItem] = []
    var skipped = 0
}

enum DropList {
    static func collect(_ urls: [URL]) -> DropBatch {
        var batch = DropBatch()
        var seen = Set<String>()
        for url in urls {
            let standard = url.standardizedFileURL
            guard standard.path != "/" else {
                batch.skipped += 1
                continue
            }
            guard seen.insert(standard.path).inserted else { continue }
            collectOne(standard, into: &batch)
        }
        return batch
    }

    private static func collectOne(_ url: URL, into batch: inout DropBatch) {
        let values = try? url.resourceValues(forKeys: [
            .isDirectoryKey, .isSymbolicLinkKey, .isRegularFileKey, .fileSizeKey,
        ])
        if values?.isSymbolicLink == true {
            batch.skipped += 1
            return
        }
        let name = url.lastPathComponent
        if Self.isQuiet(name) { return }
        let isDirectory = values?.isDirectory == true
        let isFile = values?.isRegularFile == true
        guard isDirectory || isFile else {
            batch.skipped += 1
            return
        }
        guard let relative = PathGuard.relative(name) else {
            batch.skipped += 1
            return
        }
        let mode = posixMode(url, directory: isDirectory)
        if isDirectory {
            batch.items.append(SendItem(relativePath: relative, fileURL: nil, isDirectory: true, size: 0, mode: mode))
            appendChildren(of: url, into: &batch)
        } else {
            let size = UInt64(max(0, values?.fileSize ?? 0))
            batch.items.append(SendItem(relativePath: relative, fileURL: url, isDirectory: false, size: size, mode: mode))
        }
    }

    /// `.DS_Store` and AppleDouble files are left out without counting as skipped.
    private static func isQuiet(_ name: String) -> Bool {
        name == ".DS_Store" || name.hasPrefix("._")
    }

    private static func posixMode(_ url: URL, directory: Bool) -> UInt16 {
        var info = stat()
        guard lstat(url.path, &info) == 0 else {
            return directory ? FileMode.directory : FileMode.file
        }
        return FileMode.bits(UInt16(info.st_mode & 0o777), directory: directory)
    }

    private static func appendChildren(of root: URL, into batch: inout DropBatch) {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey, .isRegularFileKey, .fileSizeKey]
        let errors = Count()
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: Array(keys),
            options: [],
            errorHandler: { _, _ in
                errors.value += 1
                return true
            }
        ) else {
            batch.skipped += 1
            return
        }
        let base = root.deletingLastPathComponent().standardizedFileURL.pathComponents
        while let item = enumerator.nextObject() as? URL {
            let values = try? item.resourceValues(forKeys: keys)
            if values?.isSymbolicLink == true {
                enumerator.skipDescendants()
                batch.skipped += 1
                continue
            }
            let leaf = item.lastPathComponent
            if isQuiet(leaf) { continue }
            let parts = item.standardizedFileURL.pathComponents
            guard parts.starts(with: base), parts.count > base.count else {
                batch.skipped += 1
                continue
            }
            let relative = parts.dropFirst(base.count).joined(separator: "/")
            guard let clean = PathGuard.relative(relative) else {
                batch.skipped += 1
                enumerator.skipDescendants()
                continue
            }
            if values?.isDirectory == true {
                batch.items.append(SendItem(
                    relativePath: clean, fileURL: nil, isDirectory: true, size: 0,
                    mode: posixMode(item, directory: true)
                ))
            } else if values?.isRegularFile == true {
                let size = UInt64(max(0, values?.fileSize ?? 0))
                batch.items.append(SendItem(
                    relativePath: clean, fileURL: item, isDirectory: false, size: size,
                    mode: posixMode(item, directory: false)
                ))
            } else {
                batch.skipped += 1
            }
        }
        batch.skipped += errors.value
    }
}

private final class Count {
    var value = 0
}

enum Sender {
    /// Sends a whole drop. A directory is announced first and finished only
    /// after the items inside it, so a read-only mode is not applied too soon.
    static func transmitAll(
        _ items: [SendItem],
        to out: MessageOut,
        progress: ProgressMeter?,
        each: (SendItem) -> Void
    ) throws {
        var stack: [(path: String, id: UUID)] = []
        for item in items {
            try finishDirectories(in: &stack, keeping: item.relativePath, to: out)
            each(item)
            if item.isDirectory {
                let id = UUID()
                try out.send(.fileStart(
                    id: id, size: 0, path: item.relativePath, directory: true, mode: item.mode
                ))
                stack.append((item.relativePath, id))
            } else {
                try transmit(item, to: out, progress: progress)
            }
        }
        try finishDirectories(in: &stack, keeping: nil, to: out)
    }

    private static func finishDirectories(
        in stack: inout [(path: String, id: UUID)],
        keeping path: String?,
        to out: MessageOut
    ) throws {
        while let top = stack.last {
            if let path, path == top.path || path.hasPrefix(top.path + "/") { return }
            stack.removeLast()
            try out.send(.fileEnd(id: top.id, crc: 0, size: 0))
            try out.awaitResult(id: top.id, timeout: 30)
        }
    }

    static func transmit(_ item: SendItem, to out: MessageOut, progress: ProgressMeter?) throws {
        let id = UUID()
        if item.isDirectory {
            try out.send(.fileStart(id: id, size: 0, path: item.relativePath, directory: true, mode: item.mode))
            try out.send(.fileEnd(id: id, crc: 0, size: 0))
            try out.awaitResult(id: id, timeout: 30)
            return
        }
        guard let url = item.fileURL else { throw TransferError.io("Missing file") }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        try out.send(.fileStart(id: id, size: item.size, path: item.relativePath, directory: false, mode: item.mode))
        var crc = CRC32()
        var offset: UInt64 = 0
        while offset < item.size {
            if out.failed(id) {
                try out.send(.fileAbort(id: id))
                try out.awaitResult(id: id, timeout: 30)
                return
            }
            let want = min(Wire.chunkSize, Int(item.size - offset))
            guard let chunk = try handle.read(upToCount: want), !chunk.isEmpty else {
                try out.send(.fileAbort(id: id))
                throw TransferError.io("The file ended early")
            }
            if chunk.count > want {
                try out.send(.fileAbort(id: id))
                throw TransferError.io("The file changed")
            }
            crc.update(chunk)
            try out.send(.fileChunk(id: id, offset: offset, data: chunk))
            offset += UInt64(chunk.count)
            progress?.add(UInt64(chunk.count))
        }
        if offset != item.size {
            try out.send(.fileAbort(id: id))
            throw TransferError.io("The file changed")
        }
        let timeout = max(30, Double(item.size) / Double(512 * 1024))
        try out.send(.fileEnd(id: id, crc: crc.checksum, size: offset))
        try out.awaitResult(id: id, timeout: timeout)
    }
}

final class Receiver {
    private let lock = NSLock()
    private let rootPath: String
    private let root: DirFD
    private let incoming: DirFD
    private var renames: [String: String] = [:]
    private var open: [UUID: Incoming] = [:]
    private var dead: Set<UUID> = []
    /// Directories created without owner write. The mode is applied at fileEnd.
    private var pendingModes: [String: UInt16] = [:]

    init(root url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        guard let resolved = Posix.real(url.path) else {
            throw TransferError.io(TransferNote.io)
        }
        var info = stat()
        if lstat(resolved, &info) != 0 || (info.st_mode & S_IFMT) != S_IFDIR {
            throw TransferError.io(TransferNote.io)
        }
        rootPath = resolved
        root = try DirFD.open(resolved)
        try Receiver.makeIncoming(root)
        let incomingURL = URL(fileURLWithPath: resolved).appendingPathComponent(Store.incomingName)
        if Posix.isSymlink(incomingURL.path) { throw TransferError.io(TransferNote.io) }
        incoming = try root.openDirectory(Store.incomingName)
        // Stale temps are removed once, when the app starts. Doing it here would
        // delete a file another connection is still writing.
    }

    deinit { cleanup() }

    /// Closes every file this receive still has open and removes its temp.
    func cancelAll() {
        lock.lock()
        cleanup()
        lock.unlock()
    }

    func handle(_ message: Message) -> Message? {
        lock.lock()
        defer { lock.unlock() }
        switch message {
        case let .fileStart(id, size, path, directory, mode):
            return start(id: id, size: size, path: path, directory: directory, mode: mode)
        case let .fileChunk(id, offset, data):
            return chunk(id: id, offset: offset, data: data)
        case let .fileEnd(id, crc, size):
            return finish(id: id, crc: crc, size: size)
        case let .fileAbort(id):
            discard(id)
            return nil
        default:
            return nil
        }
    }

    private func start(id: UUID, size: UInt64, path: String, directory: Bool, mode: UInt16) -> Message? {
        discard(id)
        guard let clean = PathGuard.relative(path) else {
            dead.insert(id)
            return .fileResult(id: id, ok: false, message: TransferNote.badPath)
        }
        let bits = FileMode.bits(mode, directory: directory)
        if directory {
            do {
                _ = try claim(original: clean, directory: true, mode: bits)
                open[id] = Incoming(id: id, relative: clean, expected: 0, directory: true)
                return nil
            } catch {
                dead.insert(id)
                return .fileResult(id: id, ok: false, message: note(error))
            }
        }
        let tempName = UUID().uuidString
        let fd = openat(
            incoming.fd,
            tempName,
            O_CREAT | O_EXCL | O_NOFOLLOW | O_WRONLY | O_CLOEXEC,
            mode_t(0o600)
        )
        if fd < 0 {
            dead.insert(id)
            return .fileResult(id: id, ok: false, message: errno == ENOSPC || errno == EDQUOT ? TransferNote.disk : TransferNote.io)
        }
        if fchmod(fd, mode_t(bits)) != 0 {
            Posix.close(fd)
            _ = unlinkat(incoming.fd, tempName, 0)
            dead.insert(id)
            return .fileResult(id: id, ok: false, message: TransferNote.io)
        }
        open[id] = Incoming(
            id: id,
            relative: clean,
            expected: size,
            directory: false,
            fd: fd,
            tempName: tempName
        )
        return nil
    }

    private func chunk(id: UUID, offset: UInt64, data: Data) -> Message? {
        if dead.contains(id) { return nil }
        guard var item = open[id], !item.directory, item.fd >= 0 else {
            dead.insert(id)
            return .fileResult(id: id, ok: false, message: TransferNote.damaged)
        }
        if offset != item.received || item.received + UInt64(data.count) > item.expected {
            discard(id)
            dead.insert(id)
            return .fileResult(id: id, ok: false, message: TransferNote.damaged)
        }
        if !Posix.writeAll(item.fd, data) {
            let full = errno == ENOSPC || errno == EDQUOT
            discard(id)
            dead.insert(id)
            return .fileResult(id: id, ok: false, message: full ? TransferNote.disk : TransferNote.io)
        }
        item.crc.update(data)
        item.received += UInt64(data.count)
        open[id] = item
        return nil
    }

    private func finish(id: UUID, crc: UInt32, size: UInt64) -> Message? {
        if dead.contains(id) {
            dead.remove(id)
            return nil
        }
        guard let item = open.removeValue(forKey: id) else {
            return .fileResult(id: id, ok: false, message: TransferNote.damaged)
        }
        if item.directory {
            if !sealMode(apply(item.relative)) {
                return .fileResult(id: id, ok: false, message: TransferNote.io)
            }
            return .fileResult(id: id, ok: true, message: TransferNote.saved)
        }
        defer { Posix.close(item.fd) }
        if item.received != item.expected || item.received != size || item.crc.checksum != crc {
            unlinkTemp(item.tempName)
            return .fileResult(id: id, ok: false, message: TransferNote.damaged)
        }
        if Darwin.fsync(item.fd) != 0 {
            unlinkTemp(item.tempName)
            return .fileResult(id: id, ok: false, message: TransferNote.io)
        }
        guard let tempName = item.tempName else {
            return .fileResult(id: id, ok: false, message: TransferNote.io)
        }
        do {
            try commitFile(original: item.relative, tempName: tempName)
            return .fileResult(id: id, ok: true, message: TransferNote.saved)
        } catch {
            unlinkTemp(item.tempName)
            return .fileResult(id: id, ok: false, message: note(error))
        }
    }

    private func discard(_ id: UUID) {
        guard let item = open.removeValue(forKey: id) else { return }
        if item.fd >= 0 { Posix.close(item.fd) }
        unlinkTemp(item.tempName)
    }

    /// Caller holds `lock`, except `deinit`, which runs with no other user.
    private func cleanup() {
        for id in Array(open.keys) { discard(id) }
        let pending = pendingModes
        pendingModes.removeAll()
        for relative in pending.keys.sorted(by: { $0.count > $1.count }) {
            _ = setMode(relative, pending[relative] ?? FileMode.directory)
        }
    }

    @discardableResult
    private func sealMode(_ relative: String) -> Bool {
        guard let mode = pendingModes[relative] else { return true }
        guard setMode(relative, mode) else { return false }
        pendingModes.removeValue(forKey: relative)
        return true
    }

    private func setMode(_ relative: String, _ mode: UInt16) -> Bool {
        let parts = relative.split(separator: "/").map(String.init)
        guard let leaf = parts.last, !leaf.isEmpty else { return false }
        var current = root
        for part in parts.dropLast() {
            guard let next = try? current.openDirectory(part) else { return false }
            current = next
        }
        return fchmodat(current.fd, leaf, mode_t(mode), AT_SYMLINK_NOFOLLOW) == 0
    }

    private func unlinkTemp(_ name: String?) {
        guard let name else { return }
        _ = unlinkat(incoming.fd, name, 0)
    }

    private func commitFile(original: String, tempName: String) throws {
        let parts = try components(original)
        let parentParts = Array(parts.dropLast())
        let parent = try openChain(parentParts, originalPrefixes: prefixes(parentParts), leafMode: FileMode.directory)
        let leafOriginal = parts[parts.count - 1]
        var n = 1
        var candidate = leafOriginal
        while n < 5000 {
            if linkat(incoming.fd, tempName, parent.fd, candidate, 0) == 0 {
                _ = unlinkat(incoming.fd, tempName, 0)
                _ = Darwin.fsync(parent.fd)
                let parentOriginal = parentParts.joined(separator: "/")
                let parentActual = parentOriginal.isEmpty ? "" : apply(parentOriginal)
                let relative = parentActual.isEmpty ? candidate : parentActual + "/" + candidate
                if relative != original { renames[original] = relative }
                return
            }
            if errno != EEXIST { throw TransferError.io(note(errno)) }
            n += 1
            candidate = NameSlot.numbered(leafOriginal, n)
        }
        throw TransferError.io(TransferNote.io)
    }

    @discardableResult
    private func claim(original: String, directory: Bool, mode: UInt16) throws -> String {
        let parts = try components(original)
        if directory {
            _ = try openChain(parts, originalPrefixes: prefixes(parts), leafMode: mode)
            return apply(original)
        }
        return original
    }

    private func components(_ original: String) throws -> [String] {
        guard let clean = PathGuard.relative(original) else { throw TransferError.io(TransferNote.badPath) }
        return clean.split(separator: "/").map(String.init)
    }

    private func prefixes(_ parts: [String]) -> [String] {
        var list: [String] = []
        var built = ""
        for part in parts {
            built = built.isEmpty ? part : built + "/" + part
            list.append(built)
        }
        return list
    }

    /// Returns a private fd for the directory. Never hands out `root`, whose fd stays open.
    private func openChain(_ parts: [String], originalPrefixes: [String], leafMode: UInt16) throws -> DirFD {
        var current = root
        var actual = ""
        for (index, part) in parts.enumerated() {
            let originalPrefix = originalPrefixes[index]
            if let mapped = renames[originalPrefix] {
                current = try reopen(mapped)
                actual = mapped
                continue
            }
            let mode = index == parts.count - 1 ? leafMode : FileMode.directory
            let (chosen, created) = try claimDirectory(part, in: current, mode: mode)
            actual = actual.isEmpty ? chosen : actual + "/" + chosen
            if actual != originalPrefix {
                renames[originalPrefix] = actual
            }
            if created && !FileMode.ownerCanWrite(mode) {
                pendingModes[actual] = mode
            }
            current = try current.openDirectory(chosen)
        }
        let copy = Darwin.dup(current.fd)
        if copy < 0 { throw TransferError.io(TransferNote.io) }
        return DirFD(fd: copy)
    }

    private func reopen(_ relative: String) throws -> DirFD {
        var current = root
        for part in relative.split(separator: "/").map(String.init) {
            current = try current.openDirectory(part)
        }
        return current
    }

    /// An existing directory is reused, so dropping Photos twice merges into the
    /// Photos folder already there. Files inside still keep both names.
    /// Permission bits are applied only to a directory this call creates.
    /// A mode without owner write stays writable until that directory's fileEnd,
    /// so the files inside it can still be placed.
    private func claimDirectory(_ name: String, in parent: DirFD, mode: UInt16) throws -> (String, Bool) {
        var n = 1
        var candidate = name
        var spins = 0
        while n < 5000 && spins < 5000 {
            spins += 1
            switch parent.kind(candidate) {
            case .absent:
                if mkdirat(parent.fd, candidate, mode_t(0o700)) == 0 {
                    if FileMode.ownerCanWrite(mode),
                       fchmodat(parent.fd, candidate, mode_t(mode), AT_SYMLINK_NOFOLLOW) != 0 {
                        _ = unlinkat(parent.fd, candidate, AT_REMOVEDIR)
                        throw TransferError.io(TransferNote.io)
                    }
                    return (candidate, true)
                }
                if errno != EEXIST { throw TransferError.io(note(errno)) }
            case .dir:
                return (candidate, false)
            case .blocked:
                n += 1
                candidate = NameSlot.numbered(name, n)
            }
        }
        throw TransferError.io(TransferNote.io)
    }

    private func apply(_ original: String) -> String {
        var best: (String, String)?
        for (from, to) in renames {
            if original == from || original.hasPrefix(from + "/") {
                if best == nil || from.count > best!.0.count { best = (from, to) }
            }
        }
        guard let best else { return original }
        return best.1 + original.dropFirst(best.0.count)
    }

    private func note(_ error: Error) -> String {
        if let transfer = error as? TransferError, case let .io(text) = transfer { return text }
        return TransferNote.io
    }

    private func note(_ code: Int32) -> String {
        if code == ENOSPC || code == EDQUOT { return TransferNote.disk }
        return TransferNote.io
    }

    private static func makeIncoming(_ root: DirFD) throws {
        if mkdirat(root.fd, Store.incomingName, mode_t(0o755)) != 0 && errno != EEXIST {
            throw TransferError.io(TransferNote.io)
        }
    }
}

/// Removes leftover temps once per launch, not once per connection.
enum IncomingSweep {
    static func run(root url: URL) {
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        guard let resolved = Posix.real(url.path) else { return }
        guard let root = try? DirFD.open(resolved) else { return }
        guard root.kind(Store.incomingName) == .dir else { return }
        guard let incoming = try? root.openDirectory(Store.incomingName) else { return }
        for name in incoming.childNames() {
            if unlinkat(incoming.fd, name, 0) == 0 { continue }
            if errno == EISDIR || errno == EPERM {
                _ = unlinkat(incoming.fd, name, AT_REMOVEDIR)
            }
        }
    }
}

enum StatusLine {
    static func sent(to names: String, skipped: Int) -> String {
        "Sent to \(names)" + skipSuffix(skipped)
    }

    static func nothing(skipped: Int) -> String {
        guard skipped > 0 else { return "Nothing to send" }
        return skipPhrase(skipped)
    }

    static func skipSuffix(_ count: Int) -> String {
        guard count > 0 else { return "" }
        return " — \(skipPhrase(count))"
    }

    private static func skipPhrase(_ count: Int) -> String {
        let noun = count == 1 ? "item" : "items"
        return "\(count) \(noun) skipped"
    }
}

private struct Incoming {
    var id: UUID
    var relative: String
    var expected: UInt64
    var directory: Bool
    var fd: Int32 = -1
    var tempName: String?
    var received: UInt64 = 0
    var crc = CRC32()
}

private enum EntryKind {
    case absent
    case dir
    case blocked
}

private final class DirFD {
    let fd: Int32

    init(fd: Int32) { self.fd = fd }

    deinit { if fd >= 0 { Darwin.close(fd) } }

    static func open(_ path: String) throws -> DirFD {
        let fd = Darwin.open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        if fd < 0 { throw TransferError.io(TransferNote.io) }
        return DirFD(fd: fd)
    }

    func openDirectory(_ name: String) throws -> DirFD {
        let fd = openat(self.fd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        if fd < 0 { throw TransferError.io(TransferNote.io) }
        return DirFD(fd: fd)
    }

    func childNames() -> [String] {
        let copy = Darwin.dup(fd)
        if copy < 0 { return [] }
        guard let dir = fdopendir(copy) else {
            Darwin.close(copy)
            return []
        }
        defer { closedir(dir) }
        var names: [String] = []
        while let entry = readdir(dir) {
            let name = Self.entryName(entry)
            if name.isEmpty || name == "." || name == ".." { continue }
            names.append(name)
        }
        return names
    }

    private static func entryName(_ entry: UnsafeMutablePointer<dirent>) -> String {
        withUnsafePointer(to: entry.pointee.d_name) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) {
                String(cString: $0)
            }
        }
    }

    func kind(_ name: String) -> EntryKind {
        var info = stat()
        if fstatat(fd, name, &info, AT_SYMLINK_NOFOLLOW) != 0 {
            return errno == ENOENT ? .absent : .blocked
        }
        if (info.st_mode & S_IFMT) == S_IFDIR { return .dir }
        return .blocked
    }
}

private enum Posix {
    static func real(_ path: String) -> String? {
        guard let pointer = realpath(path, nil) else { return nil }
        defer { free(pointer) }
        return String(cString: pointer)
    }

    static func isSymlink(_ path: String) -> Bool {
        var info = stat()
        if lstat(path, &info) != 0 { return false }
        return (info.st_mode & S_IFMT) == S_IFLNK
    }

    static func writeAll(_ fd: Int32, _ data: Data) -> Bool {
        var remaining = data
        while !remaining.isEmpty {
            let wrote = remaining.withUnsafeBytes { buffer -> Int in
                guard let base = buffer.baseAddress else { return -1 }
                return Darwin.write(fd, base, buffer.count)
            }
            if wrote < 0 {
                if errno == EINTR { continue }
                return false
            }
            if wrote == 0 { return false }
            remaining.removeFirst(wrote)
        }
        return true
    }

    static func close(_ fd: Int32) {
        if fd >= 0 { Darwin.close(fd) }
    }
}
