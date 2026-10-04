import Darwin
import Foundation
import Network

enum SelfTest {
    static func run() -> String? {
        if let err = versions() { return err }
        if let err = checksum() { return err }
        if let err = codeMark() { return err }
        if let err = handshake() { return err }
        if let err = names() { return err }
        if let err = paths() { return err }
        if let err = localAddresses() { return err }
        if let err = discovery() { return err }
        if let err = frames() { return err }
        if let err = splitParser() { return err }
        if let err = oversized() { return err }
        if let err = copyFile() { return err }
        if let err = keepBothNames() { return err }
        if let err = blockedFolderName() { return err }
        if let err = badPath() { return err }
        if let err = badChecksum() { return err }
        if let err = symlinkStaysInside() { return err }
        if let err = dropList() { return err }
        if let err = permissions() { return err }
        if let err = mergeFolder() { return err }
        if let err = readOnlyDirectory() { return err }
        if let err = interruptedReceive() { return err }
        if let err = incomingSweep() { return err }
        if let err = limits() { return err }
        if let err = socketCopy() { return err }
        return nil
    }

    private static func versions() -> String? {
        if AppInfo.name != "Black hole" { return "name \(AppInfo.name)" }
        if AppInfo.version != "1.0.9" || AppInfo.build != "10" { return "version stamp" }
        let url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("AppInfo.plist")
        guard let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return nil }
        let short = plist["CFBundleShortVersionString"] as? String
        let build = plist["CFBundleVersion"] as? String
        if short != AppInfo.version || build != AppInfo.build {
            return "plist \(short ?? "?") (\(build ?? "?"))"
        }
        if plist["CFBundleName"] as? String != AppInfo.name { return "plist name" }
        return nil
    }

    private static func checksum() -> String? {
        var crc = CRC32()
        crc.update(Data("123456789".utf8))
        if crc.checksum != 0xCBF4_3926 { return String(format: "crc %08x", crc.checksum) }
        let empty = CRC32()
        if empty.checksum != 0 { return "empty crc" }
        var split = CRC32()
        split.update(Data("12345".utf8))
        split.update(Data("6789".utf8))
        if split.checksum != crc.checksum { return "split crc" }
        return nil
    }

    private static func codeMark() -> String? {
        if CodeMark.mark("") != "e3b0c442" { return "empty code mark \(CodeMark.mark(""))" }
        if CodeMark.mark("alpha") != CodeMark.mark("alpha") { return "mark unstable" }
        if CodeMark.normalize("  alpha  ") != "alpha" { return "normalize" }
        if CodeMark.normalize(String(repeating: "a", count: 80)).count != 64 { return "normalize length" }
        return nil
    }

    private static func handshake() -> String? {
        if !Handshake.accept(version: 1, code: "", ours: "") { return "blank code" }
        if Handshake.accept(version: 1, code: "a", ours: "b") { return "mismatched code" }
        if Handshake.accept(version: 2, code: "", ours: "") { return "bad version" }
        return nil
    }

    private static func names() -> String? {
        if NameSlot.numbered("note.txt", 2) != "note 2.txt" { return "note 2" }
        if NameSlot.numbered("archive.tar.gz", 2) != "archive 2.tar.gz" { return "archive 2" }
        if NameSlot.numbered("README", 3) != "README 3" { return "README 3" }
        if NameSlot.numbered(".gitignore", 2) != ".gitignore 2" { return "gitignore" }
        if NameList.join(["Mac mini"]) != "Mac mini" { return "one name" }
        if NameList.join(["Mac mini", "iMac"]) != "Mac mini and iMac" { return "two names" }
        if NameList.join(["A", "B", "C"]) != "A, B, and C" { return "three names" }
        if NameList.clean("  \u{0001}Office  ") != "Office" { return "clean name" }
        return nil
    }

    private static func paths() -> String? {
        let cases: [(String, String?)] = [
            ("a.txt", "a.txt"),
            ("Photos/a.txt", "Photos/a.txt"),
            ("foo//bar", "foo/bar"),
            ("foo/bar/", "foo/bar"),
            ("café.txt", "café.txt"),
            ("", nil),
            ("/etc/passwd", nil),
            ("../x", nil),
            ("a/../../b", nil),
            ("a/../b", nil),
            ("..", nil),
            (".", nil),
            ("foo/..", nil),
            ("foo/.", nil),
            ("a\\..\\b", nil),
            (".blackhole-incoming/x", nil),
            ("ok/.blackhole-incoming", nil),
            ("bad\u{0000}name", nil),
            ("line\nname", nil),
            ("sneaky\u{202E}txt.exe", nil),
        ]
        for (raw, expected) in cases {
            let got = PathGuard.relative(raw)
            if got != expected { return "path \(raw.debugDescription) → \(got ?? "nil")" }
        }
        let long = String(repeating: "a", count: 256)
        if PathGuard.relative(long) != nil { return "long component" }
        return nil
    }

    private static func localAddresses() -> String? {
        let allowed = [
            "127.0.0.1", "10.1.2.3", "192.168.1.20", "172.16.0.1", "172.31.255.255",
            "169.254.4.5", "localhost", "Mac.local", "::1", "fe80::1", "fe80::abcd%en0",
            "[fe80::1%en0]", "fc00::1", "fd12:3456::7", "::ffff:192.168.1.5",
        ]
        let refused = [
            "8.8.8.8", "1.1.1.1", "172.15.0.1", "172.32.0.1", "example.com",
            "2001:4860:4860::8888", "::ffff:8.8.8.8", "",
        ]
        for host in allowed where !LocalNet.allows(host: host) {
            return "should allow \(host)"
        }
        for host in refused where LocalNet.allows(host: host) {
            return "should refuse \(host)"
        }
        guard let loop = IPv6Address("::1") else { return "no ::1" }
        let bytes = LocalNet.octets(loop)
        if bytes.count != 16 || bytes[15] != 1 || bytes.dropLast().contains(where: { $0 != 0 }) {
            return "ipv6 octets \(bytes)"
        }
        guard let v4 = IPv4Address("10.9.8.7"), LocalNet.allows(host: .ipv4(v4)) else {
            return "ipv4 endpoint"
        }
        if !LocalNet.allows(host: .ipv6(loop)) { return "ipv6 endpoint" }
        if LocalNet.allows(host: .ipv4(IPv4Address("8.8.8.8")!)) { return "public ipv4 endpoint" }
        return nil
    }

    private static func discovery() -> String? {
        let ours = "906B8CFC-BF97-4B3D-BE3A-D8BE24D7AE11"
        let own = [ours, "BH-906B8CFC"]
        let mark = CodeMark.mark("")
        if Discovery.shouldDial(name: "BH-4A0D6967", ownNames: own, version: nil, code: nil, mark: mark) == false {
            return "missing txt should dial"
        }
        if Discovery.shouldDial(name: ours, ownNames: own, version: nil, code: nil, mark: mark) {
            return "dialed ourself"
        }
        if Discovery.shouldDial(name: "bh-906b8cfc", ownNames: own, version: nil, code: nil, mark: mark) {
            return "dialed legacy self"
        }
        if Discovery.shouldDial(name: "BH-4A0D6967", ownNames: own, version: "1", code: mark, mark: mark) == false {
            return "matching code should dial"
        }
        if Discovery.shouldDial(name: "BH-4A0D6967", ownNames: own, version: "1", code: "deadbeef", mark: mark) {
            return "wrong code dialed"
        }
        if Discovery.shouldDial(name: "BH-4A0D6967", ownNames: own, version: "2", code: nil, mark: mark) {
            return "wrong version dialed"
        }
        let endpoint = NWEndpoint.service(name: "BH-4A0D6967", type: "_blackhole._tcp", domain: "local.", interface: nil)
        if Discovery.serviceName(endpoint) != "BH-4A0D6967" { return "service name" }
        return nil
    }

    private static func frames() -> String? {
        let id = UUID(uuidString: "00112233-4455-6677-8899-AABBCCDDEEFF")!
        let samples: [Message] = [
            .hello(version: 1, id: id, name: "Office Mac", code: "tide"),
            .fileStart(id: id, size: 5, path: "Notes/a.txt", directory: false, mode: 0o644),
            .fileStart(id: id, size: 0, path: "Empty", directory: true, mode: 0o755),
            .fileChunk(id: id, offset: 0, data: Data([0x00, 0xFF, 0x10, 0x7F])),
            .fileEnd(id: id, crc: 0xCBF4_3926, size: 5),
            .fileResult(id: id, ok: false, message: TransferNote.damaged),
            .fileAbort(id: id),
            .ping,
        ]
        for message in samples {
            do {
                let decoded = try Message.decode(try message.encoded())
                if decoded != message { return "round trip \(message)" }
            } catch {
                return "encode \(error)"
            }
        }
        do {
            var legacy = try Message.fileStart(
                id: id, size: 5, path: "Notes/a.txt", directory: false, mode: 0o755
            ).encoded()
            legacy.removeLast(2)
            let decoded = try Message.decode(legacy)
            guard case .fileStart(_, _, _, false, 0o644) = decoded else { return "legacy mode \(decoded)" }
        } catch {
            return "legacy mode \(error)"
        }
        return nil
    }

    private static func splitParser() -> String? {
        let id = UUID()
        let messages: [Message] = [
            .hello(version: 1, id: id, name: "A", code: ""),
            .fileChunk(id: id, offset: 3, data: Data("hi".utf8)),
            .ping,
        ]
        var blob = Wire.preface
        for message in messages {
            blob.append(try! Wire.frame(message))
        }
        var parser = Parser()
        var got: [Message] = []
        for byte in blob {
            do { got.append(contentsOf: try parser.append(Data([byte]))) }
            catch { return "split \(error)" }
        }
        if got != messages { return "split mismatch \(got.count)" }
        var bad = Parser()
        do {
            _ = try bad.append(Data("NOPE".utf8))
            return "bad preface accepted"
        } catch WireError.badPreface {
            return nil
        } catch {
            return "preface \(error)"
        }
    }

    private static func oversized() -> String? {
        var data = Wire.preface
        var length = UInt32(Wire.maxBody + 1).bigEndian
        withUnsafeBytes(of: &length) { data.append(contentsOf: $0) }
        var parser = Parser()
        do {
            _ = try parser.append(data)
            return "oversized accepted"
        } catch WireError.oversized {
            return nil
        } catch {
            return "oversize \(error)"
        }
    }

    private static func copyFile() -> String? {
        guard let root = try? makeTemp() else { return "temp" }
        defer { remove(root) }
        do {
            let receiver = try Receiver(root: root)
            let payload = Data([0x00, 0x01, 0x02, 0xFF, 0x00])
            try send(payload, name: "Folder/a.bin", to: receiver)
            let url = root.appendingPathComponent("Folder/a.bin")
            let read = try Data(contentsOf: url)
            if read != payload { return "copied bytes \(read as NSData)" }
            var isDir: ObjCBool = false
            if !FileManager.default.fileExists(atPath: root.appendingPathComponent("Folder").path, isDirectory: &isDir) || !isDir.boolValue {
                return "folder missing"
            }
        } catch {
            return "copy \(error)"
        }
        return nil
    }

    private static func keepBothNames() -> String? {
        guard let root = try? makeTemp() else { return "temp" }
        defer { remove(root) }
        do {
            let receiver = try Receiver(root: root)
            try send(Data("one".utf8), name: "note.txt", to: receiver)
            try send(Data("two".utf8), name: "note.txt", to: receiver)
            let first = try String(contentsOf: root.appendingPathComponent("note.txt"), encoding: .utf8)
            let second = try String(contentsOf: root.appendingPathComponent("note 2.txt"), encoding: .utf8)
            if first != "one" || second != "two" { return "names \(first) \(second)" }
        } catch {
            return "names \(error)"
        }
        return nil
    }

    private static func blockedFolderName() -> String? {
        guard let root = try? makeTemp() else { return "temp" }
        defer { remove(root) }
        do {
            try Data("keep".utf8).write(to: root.appendingPathComponent("Box"))
            let receiver = try Receiver(root: root)
            let peer = DirectPeer(receiver: receiver)
            try Sender.transmit(
                SendItem(relativePath: "Box", fileURL: nil, isDirectory: true, size: 0, mode: 0o755),
                to: peer,
                progress: nil
            )
            try send(Data("hi".utf8), name: "Box/hello.txt", to: receiver)
            let blocked = try String(contentsOf: root.appendingPathComponent("Box"), encoding: .utf8)
            let moved = try String(contentsOf: root.appendingPathComponent("Box 2/hello.txt"), encoding: .utf8)
            if blocked != "keep" || moved != "hi" { return "blocked \(blocked) \(moved)" }
        } catch {
            return "blocked folder \(error)"
        }
        return nil
    }

    private static func badPath() -> String? {
        guard let root = try? makeTemp() else { return "temp" }
        defer { remove(root) }
        let outside = root.deletingLastPathComponent().appendingPathComponent("escaped-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: outside) }
        do {
            let receiver = try Receiver(root: root)
            let id = UUID()
            let reply = receiver.handle(.fileStart(id: id, size: 3, path: "../\(outside.lastPathComponent)", directory: false, mode: 0o644))
            guard case .fileResult(_, false, TransferNote.badPath) = reply else { return "bad path reply \(String(describing: reply))" }
            if FileManager.default.fileExists(atPath: outside.path) { return "wrote outside" }
        } catch {
            return "bad path \(error)"
        }
        return nil
    }

    private static func badChecksum() -> String? {
        guard let root = try? makeTemp() else { return "temp" }
        defer { remove(root) }
        do {
            let receiver = try Receiver(root: root)
            let id = UUID()
            _ = receiver.handle(.fileStart(id: id, size: 4, path: "a.txt", directory: false, mode: 0o644))
            _ = receiver.handle(.fileChunk(id: id, offset: 0, data: Data("abcd".utf8)))
            let reply = receiver.handle(.fileEnd(id: id, crc: 1, size: 4))
            guard case .fileResult(_, false, TransferNote.damaged) = reply else { return "crc reply" }
            if FileManager.default.fileExists(atPath: root.appendingPathComponent("a.txt").path) {
                return "damaged file kept"
            }
            let incoming = root.appendingPathComponent(Store.incomingName)
            let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: incoming.path)) ?? []
            if !leftovers.isEmpty { return "temp left \(leftovers)" }
        } catch {
            return "crc \(error)"
        }
        return nil
    }

    private static func symlinkStaysInside() -> String? {
        guard let root = try? makeTemp() else { return "temp" }
        defer { remove(root) }
        let outsideDir = root.deletingLastPathComponent().appendingPathComponent("outside-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: outsideDir) }
        do {
            try FileManager.default.createDirectory(at: outsideDir, withIntermediateDirectories: true)
            if symlink(outsideDir.path, root.appendingPathComponent("jump").path) != 0 {
                return "symlink \(errno)"
            }
            let receiver = try Receiver(root: root)
            try send(Data("owned".utf8), name: "jump/owned.txt", to: receiver)
            if FileManager.default.fileExists(atPath: outsideDir.appendingPathComponent("owned.txt").path) {
                return "followed symlink"
            }
            let saved = root.appendingPathComponent("jump 2/owned.txt")
            let text = try String(contentsOf: saved, encoding: .utf8)
            if text != "owned" { return "symlink save \(text)" }
            let rootReal = root.resolvingSymlinksInPath().path
            guard let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [.isSymbolicLinkKey]
            ) else {
                return "no enumerator"
            }
            while let item = enumerator.nextObject() as? URL {
                if (try? item.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true {
                    continue
                }
                let resolved = item.resolvingSymlinksInPath().path
                if resolved != rootReal && !resolved.hasPrefix(rootReal + "/") {
                    return "escaped \(resolved)"
                }
            }
        } catch {
            return "symlink \(error)"
        }
        return nil
    }

    private static func dropList() -> String? {
        guard let root = try? makeTemp() else { return "temp" }
        defer { remove(root) }
        let box = root.appendingPathComponent("My Files")
        do {
            try FileManager.default.createDirectory(at: box.appendingPathComponent("sub"), withIntermediateDirectories: true)
            try Data("hi".utf8).write(to: box.appendingPathComponent("hello.txt"))
            try Data("x".utf8).write(to: box.appendingPathComponent(".DS_Store"))
            let link = box.appendingPathComponent("link.txt")
            if symlink("/tmp", link.path) != 0 { return "link \(errno)" }
            let batch = DropList.collect([box])
            let paths = Set(batch.items.map(\.relativePath))
            if paths != ["My Files", "My Files/hello.txt", "My Files/sub"] {
                return "drop \(paths)"
            }
            let file = batch.items.first { $0.relativePath == "My Files/hello.txt" }
            if file?.size != 2 || file?.isDirectory != false { return "drop size" }
            if batch.skipped != 1 { return "skipped \(batch.skipped)" }
        } catch {
            return "drop \(error)"
        }
        return nil
    }

    private static func socketCopy() -> String? {
        guard let source = try? makeTemp(), let dest = try? makeTemp() else { return "temp" }
        defer { remove(source); remove(dest) }
        var bytes = [UInt8](repeating: 0, count: 300_000)
        for i in 0..<bytes.count {
            bytes[i] = UInt8(truncatingIfNeeded: i &* 17 &+ 3)
        }
        bytes[0] = 0
        bytes[1000] = 0
        let payload = Data(bytes)
        let file = source.appendingPathComponent("wide.bin")
        do {
            try payload.write(to: file)
            let capture = CaptureOut()
            try Sender.transmit(
                SendItem(relativePath: "wide.bin", fileURL: file, isDirectory: false, size: UInt64(payload.count), mode: 0o644),
                to: capture,
                progress: nil
            )
            let decoded = try pipe(capture.messages)
            let receiver = try Receiver(root: dest)
            for message in decoded {
                _ = receiver.handle(message)
            }
            let read = try Data(contentsOf: dest.appendingPathComponent("wide.bin"))
            if read != payload { return "socket bytes \(read.count)" }
        } catch {
            return "socket \(error)"
        }
        return nil
    }

    private static func permissions() -> String? {
        guard let root = try? makeTemp() else { return "temp" }
        defer { remove(root) }
        do {
            let receiver = try Receiver(root: root)
            try send(Data("#!/bin/sh\n".utf8), name: "tool", to: receiver, mode: 0o755)
            let tool = root.appendingPathComponent("tool")
            if mode(of: tool) != 0o755 { return "file mode \(mode(of: tool))" }
            let peer = DirectPeer(receiver: receiver)
            try Sender.transmit(
                SendItem(relativePath: "Secret", fileURL: nil, isDirectory: true, size: 0, mode: 0o700),
                to: peer,
                progress: nil
            )
            if mode(of: root.appendingPathComponent("Secret")) != 0o700 { return "dir mode" }
        } catch {
            return "mode \(error)"
        }
        return nil
    }

    private static func mergeFolder() -> String? {
        guard let root = try? makeTemp() else { return "temp" }
        defer { remove(root) }
        do {
            let photos = root.appendingPathComponent("Photos")
            try FileManager.default.createDirectory(at: photos, withIntermediateDirectories: true)
            if chmod(photos.path, 0o755) != 0 { return "chmod" }
            try Data("old".utf8).write(to: photos.appendingPathComponent("old.txt"))
            let receiver = try Receiver(root: root)
            let peer = DirectPeer(receiver: receiver)
            try Sender.transmit(
                SendItem(relativePath: "Photos", fileURL: nil, isDirectory: true, size: 0, mode: 0o700),
                to: peer,
                progress: nil
            )
            try send(Data("new".utf8), name: "Photos/new.txt", to: receiver)
            let old = try String(contentsOf: photos.appendingPathComponent("old.txt"), encoding: .utf8)
            let newer = try String(contentsOf: photos.appendingPathComponent("new.txt"), encoding: .utf8)
            if old != "old" || newer != "new" { return "merge \(old) \(newer)" }
            if FileManager.default.fileExists(atPath: root.appendingPathComponent("Photos 2").path) {
                return "renamed folder"
            }
            if mode(of: photos) != 0o755 { return "existing dir mode changed" }
        } catch {
            return "merge \(error)"
        }
        return nil
    }

    private static func readOnlyDirectory() -> String? {
        guard let root = try? makeTemp() else { return "temp" }
        defer { remove(root) }
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("blackhole-\(UUID().uuidString)")
        do {
            try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: scratch) }
            let note = scratch.appendingPathComponent("note")
            let top = scratch.appendingPathComponent("top")
            let plain = scratch.appendingPathComponent("plain")
            try Data("in".utf8).write(to: note)
            try Data("up".utf8).write(to: top)
            try Data("ok".utf8).write(to: plain)
            let receiver = try Receiver(root: root)
            try Sender.transmit(
                SendItem(relativePath: "Empty", fileURL: nil, isDirectory: true, size: 0, mode: 0o555),
                to: DirectPeer(receiver: receiver),
                progress: nil
            )
            if mode(of: root.appendingPathComponent("Empty")) != 0o555 { return "empty mode" }
            try Sender.transmitAll([
                SendItem(relativePath: "Locked", fileURL: nil, isDirectory: true, size: 0, mode: 0o555),
                SendItem(relativePath: "Locked/Sub", fileURL: nil, isDirectory: true, size: 0, mode: 0o555),
                SendItem(relativePath: "Locked/Sub/note.txt", fileURL: note, isDirectory: false, size: 2, mode: 0o644),
                SendItem(relativePath: "Locked/top.txt", fileURL: top, isDirectory: false, size: 2, mode: 0o644),
                SendItem(relativePath: "Plain", fileURL: nil, isDirectory: true, size: 0, mode: 0o755),
                SendItem(relativePath: "Plain/a.txt", fileURL: plain, isDirectory: false, size: 2, mode: 0o644),
            ], to: DirectPeer(receiver: receiver), progress: nil) { _ in }
            if mode(of: root.appendingPathComponent("Locked")) != 0o555 { return "locked mode" }
            if mode(of: root.appendingPathComponent("Locked/Sub")) != 0o555 { return "sub mode" }
            if mode(of: root.appendingPathComponent("Plain")) != 0o755 { return "plain mode" }
            let body = try String(contentsOf: root.appendingPathComponent("Locked/Sub/note.txt"), encoding: .utf8)
            let upper = try String(contentsOf: root.appendingPathComponent("Locked/top.txt"), encoding: .utf8)
            if body != "in" || upper != "up" { return "locked bytes" }
            let early = UUID()
            _ = receiver.handle(.fileStart(id: early, size: 0, path: "Late", directory: true, mode: 0o555))
            let earlyMode = mode(of: root.appendingPathComponent("Late"))
            if earlyMode == 0o555 || !FileMode.ownerCanWrite(earlyMode) { return "sealed early \(earlyMode)" }
            try send(Data("x".utf8), name: "Late/x.txt", to: receiver)
            _ = receiver.handle(.fileEnd(id: early, crc: 0, size: 0))
            if mode(of: root.appendingPathComponent("Late")) != 0o555 { return "late mode" }
            if try String(contentsOf: root.appendingPathComponent("Late/x.txt"), encoding: .utf8) != "x" {
                return "late bytes"
            }
        } catch {
            return "readonly \(error)"
        }
        return nil
    }

    private static func interruptedReceive() -> String? {
        guard let root = try? makeTemp() else { return "temp" }
        defer { remove(root) }
        let before = descriptors()
        do {
            var receiver: Receiver? = try Receiver(root: root)
            let first = UUID()
            let second = UUID()
            _ = receiver?.handle(.fileStart(id: first, size: 4, path: "partial.txt", directory: false, mode: 0o644))
            _ = receiver?.handle(.fileChunk(id: first, offset: 0, data: Data("ab".utf8)))
            _ = receiver?.handle(.fileStart(id: second, size: 2, path: "other.txt", directory: false, mode: 0o644))
            let incoming = root.appendingPathComponent(Store.incomingName)
            let mid = try FileManager.default.contentsOfDirectory(atPath: incoming.path)
            if mid.count != 2 { return "temp count \(mid)" }
            if descriptors().subtracting(before).isEmpty { return "fd not held" }
            receiver?.cancelAll()
            let left = try FileManager.default.contentsOfDirectory(atPath: incoming.path)
            if !left.isEmpty { return "temp remains \(left)" }
            try send(Data("later".utf8), name: "later.txt", to: receiver!)
            let text = try String(contentsOf: root.appendingPathComponent("later.txt"), encoding: .utf8)
            if text != "later" { return "after cancel \(text)" }
            let dir = UUID()
            _ = receiver?.handle(.fileStart(id: dir, size: 0, path: "Locked", directory: true, mode: 0o555))
            receiver?.cancelAll()
            if mode(of: root.appendingPathComponent("Locked")) != 0o555 { return "unsealed dir" }
            receiver = nil
            let leaked = descriptors().subtracting(before).sorted()
            if !leaked.isEmpty { return "fd leak \(leaked)" }
        } catch {
            return "interrupt \(error)"
        }
        return nil
    }

    private static func descriptors() -> Set<Int32> {
        var open = Set<Int32>()
        var fd: Int32 = 0
        while fd < 512 {
            if fcntl(fd, F_GETFD) != -1 { open.insert(fd) }
            fd += 1
        }
        return open
    }

    private static func incomingSweep() -> String? {
        guard let root = try? makeTemp() else { return "temp" }
        defer { remove(root) }
        let incoming = root.appendingPathComponent(Store.incomingName)
        do {
            try FileManager.default.createDirectory(at: incoming, withIntermediateDirectories: true)
            let temp = incoming.appendingPathComponent("stale")
            try Data("temp".utf8).write(to: temp)
            _ = try Receiver(root: root)
            _ = try Receiver(root: root)
            if !FileManager.default.fileExists(atPath: temp.path) { return "second receiver swept" }
            IncomingSweep.run(root: root)
            if FileManager.default.fileExists(atPath: temp.path) { return "sweep left stale" }
        } catch {
            return "sweep \(error)"
        }
        return nil
    }

    private static func limits() -> String? {
        if ConnectionLimit.allows(openConnections: 15) == false { return "cap 15" }
        if ConnectionLimit.allows(openConnections: 16) { return "cap 16" }
        if StatusLine.sent(to: "Mac mini", skipped: 0) != "Sent to Mac mini" { return "sent plain" }
        if StatusLine.sent(to: "Mac mini", skipped: 2) != "Sent to Mac mini — 2 items skipped" {
            return "sent skipped"
        }
        if StatusLine.nothing(skipped: 1) != "1 item skipped" { return "one skip" }
        if Link.handshakeSeconds < 5 || Link.handshakeSeconds > 10 { return "handshake window" }
        return nil
    }

    private static func mode(of url: URL) -> UInt16 {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return 0 }
        return UInt16(info.st_mode & 0o777)
    }

    private static func send(_ data: Data, name: String, to receiver: Receiver, mode: UInt16 = 0o644) throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("payload")
        try data.write(to: file)
        let peer = DirectPeer(receiver: receiver)
        try Sender.transmit(
            SendItem(relativePath: name, fileURL: file, isDirectory: false, size: UInt64(data.count), mode: mode),
            to: peer,
            progress: nil
        )
    }

    private static func pipe(_ messages: [Message]) throws -> [Message] {
        var fds: [Int32] = [0, 0]
        if socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) != 0 { throw TransferError.io("socketpair") }
        var flag: Int32 = 1
        setsockopt(fds[0], SOL_SOCKET, SO_NOSIGPIPE, &flag, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fds[1], SOL_SOCKET, SO_NOSIGPIPE, &flag, socklen_t(MemoryLayout<Int32>.size))
        var blob = Wire.preface
        for message in messages {
            blob.append(try Wire.frame(message))
        }
        let done = DispatchSemaphore(value: 0)
        let box = MessageBox()
        DispatchQueue.global().async {
            var parser = Parser()
            var buffer = [UInt8](repeating: 0, count: 3000)
            while true {
                let n = Darwin.read(fds[0], &buffer, buffer.count)
                if n == 0 { break }
                if n < 0 {
                    if errno == EINTR { continue }
                    box.error = "read"
                    break
                }
                do {
                    box.messages.append(contentsOf: try parser.append(Data(buffer.prefix(n))))
                } catch {
                    box.error = "\(error)"
                    break
                }
            }
            done.signal()
        }
        blob.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var sent = 0
            while sent < raw.count {
                let n = Darwin.write(fds[1], base.advanced(by: sent), raw.count - sent)
                if n < 0 {
                    if errno == EINTR { continue }
                    break
                }
                sent += n
            }
        }
        Darwin.close(fds[1])
        if done.wait(timeout: .now() + 5) == .timedOut {
            Darwin.close(fds[0])
            throw TransferError.timeout
        }
        Darwin.close(fds[0])
        if let error = box.error { throw TransferError.io(error) }
        return box.messages
    }

    private static func makeTemp() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("blackhole-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func remove(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }
}

private final class DirectPeer: MessageOut {
    let receiver: Receiver
    private var results: [UUID: Result<Void, Error>] = [:]

    init(receiver: Receiver) { self.receiver = receiver }

    func send(_ message: Message) throws {
        guard let reply = receiver.handle(message), case let .fileResult(id, ok, note) = reply else { return }
        results[id] = ok ? .success(()) : .failure(TransferError.refused(note))
    }

    func awaitResult(id: UUID, timeout: TimeInterval) throws {
        guard let result = results[id] else { throw TransferError.timeout }
        if case let .failure(error) = result { throw error }
    }

    func failed(_ id: UUID) -> Bool {
        if case .failure = results[id] { return true }
        return false
    }
}

private final class CaptureOut: MessageOut {
    var messages: [Message] = []
    func send(_ message: Message) throws { messages.append(message) }
    func awaitResult(id: UUID, timeout: TimeInterval) throws {}
    func failed(_ id: UUID) -> Bool { false }
}

private final class MessageBox {
    var messages: [Message] = []
    var error: String?
}
