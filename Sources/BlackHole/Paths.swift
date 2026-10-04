import Foundation

enum Store {
    static let incomingName = ".blackhole-incoming"
}

enum PathGuard {
    static func relative(_ raw: String) -> String? {
        if raw.utf8.contains(0) { return nil }
        let nfc = raw.precomposedStringWithCanonicalMapping
        if nfc.unicodeScalars.contains(where: isForbidden) { return nil }
        let unified = nfc.replacingOccurrences(of: "\\", with: "/")
        if unified.hasPrefix("/") { return nil }
        let parts = unified.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        if parts.isEmpty || parts.count > 40 { return nil }
        for part in parts {
            if part == "." || part == ".." || part == Store.incomingName { return nil }
            if part.utf8.count > 255 { return nil }
        }
        let joined = parts.joined(separator: "/")
        if joined.utf8.count > 1024 { return nil }
        return joined
    }

    private static func isForbidden(_ scalar: Unicode.Scalar) -> Bool {
        if scalar.value < 32 || scalar.value == 127 { return true }
        switch scalar.value {
        case 0x200E, 0x200F, 0x202A, 0x202B, 0x202C, 0x202D, 0x202E,
             0x2066, 0x2067, 0x2068, 0x2069, 0xFEFF:
            return true
        default:
            return false
        }
    }
}

enum NameSlot {
    /// "archive.tar.gz" + 2 → "archive 2.tar.gz". ".gitignore" + 2 → ".gitignore 2".
    static func numbered(_ name: String, _ n: Int) -> String {
        if n <= 1 { return name }
        if let dot = name.firstIndex(of: "."), dot != name.startIndex {
            let stem = name[..<dot]
            let ext = name[dot...]
            return "\(stem) \(n)\(ext)"
        }
        return "\(name) \(n)"
    }
}

enum NameList {
    static func join(_ names: [String]) -> String {
        switch names.count {
        case 0: return ""
        case 1: return names[0]
        case 2: return "\(names[0]) and \(names[1])"
        default:
            let head = names.dropLast().joined(separator: ", ")
            return "\(head), and \(names[names.count - 1])"
        }
    }

    static func clean(_ raw: String) -> String {
        let scalars = raw.unicodeScalars.filter { $0.value >= 32 && $0.value != 127 }
        var name = String(String.UnicodeScalarView(scalars))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty { name = "Mac" }
        if name.count > 80 { name = String(name.prefix(80)) }
        return name
    }
}
