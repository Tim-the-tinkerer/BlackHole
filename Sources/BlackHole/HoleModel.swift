import AppKit
import Foundation

enum Identity {
    private static let peerKey = "blackhole.peerID"
    private static let folderKey = "blackhole.receiveFolder"
    private static let codeKey = "blackhole.pairingCode"

    static func peerID() -> UUID {
        if let saved = UserDefaults.standard.string(forKey: peerKey), let id = UUID(uuidString: saved) {
            return id
        }
        let id = UUID()
        UserDefaults.standard.set(id.uuidString, forKey: peerKey)
        return id
    }

    static func machineName() -> String {
        let raw = Host.current().localizedName ?? ProcessInfo.processInfo.hostName
        return NameList.clean(raw)
    }

    static func receiveFolder() -> URL {
        if let path = UserDefaults.standard.string(forKey: folderKey) {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue {
                return URL(fileURLWithPath: path)
            }
        }
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        return downloads.appendingPathComponent("Black hole", isDirectory: true)
    }

    static func pairingCode() -> String {
        CodeMark.normalize(UserDefaults.standard.string(forKey: codeKey) ?? "")
    }

    static func setReceiveFolder(_ url: URL) {
        UserDefaults.standard.set(url.path, forKey: folderKey)
    }

    static func setPairingCode(_ code: String) {
        UserDefaults.standard.set(CodeMark.normalize(code), forKey: codeKey)
    }

    @discardableResult
    static func ensureReceiveFolder() -> URL {
        let url = receiveFolder()
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

final class HoleModel: ObservableObject, NodeUI {
    @Published var peerNames: [String] = []
    @Published var banner: String?
    @Published var bannerAlert = false
    @Published var progress: Double?
    @Published var pulseToken = 0
    @Published var trouble: String?
    @Published private(set) var receiveFolder: URL
    @Published private(set) var pairingCode: String

    private let node: Node
    private var started = false
    private var bannerToken = 0

    init() {
        let folder = Identity.receiveFolder()
        let code = Identity.pairingCode()
        receiveFolder = folder
        pairingCode = code
        node = Node(
            peerID: Identity.peerID(),
            name: Identity.machineName(),
            receiveRoot: folder,
            pairingCode: code
        )
    }

    func start() {
        guard !started else { return }
        started = true
        node.ui = self
        receiveFolder = Identity.ensureReceiveFolder()
        node.setReceiveRoot(receiveFolder)
        node.start()
    }

    func drop(_ urls: [URL]) {
        let files = urls.filter(\.isFileURL)
        guard !files.isEmpty else { return }
        if peerNames.isEmpty {
            show("No other Black hole", alert: true, seconds: 3)
            return
        }
        node.enqueue(urls: files, scopes: files.map(Scope.init))
    }

    func reveal() {
        let url = Identity.ensureReceiveFolder()
        receiveFolder = url
        NSWorkspace.shared.open(url)
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.message = "Received files land in this folder."
        panel.directoryURL = receiveFolder
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Identity.setReceiveFolder(url)
        receiveFolder = Identity.ensureReceiveFolder()
        node.setReceiveRoot(receiveFolder)
    }

    func promptPairing() {
        let alert = NSAlert()
        alert.messageText = "Pairing code"
        alert.informativeText = "Both Macs must use the same code. Leave it blank to link with every Black hole on this network. The code is not a password, and files are not encrypted."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = pairingCode
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let code = CodeMark.normalize(field.stringValue)
        Identity.setPairingCode(code)
        pairingCode = code
        node.setPairingCode(code)
    }

    func nodePeers(_ names: [String]) {
        DispatchQueue.main.async { self.peerNames = names }
    }

    func nodeBanner(_ text: String, alert: Bool, seconds: Double?) {
        DispatchQueue.main.async {
            self.banner = text
            self.bannerAlert = alert
            if seconds != nil { self.progress = nil }
            self.bannerToken += 1
            let token = self.bannerToken
            guard let seconds else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
                guard self.bannerToken == token else { return }
                self.banner = nil
                self.bannerAlert = false
            }
        }
    }

    func nodeProgress(_ fraction: Double) {
        DispatchQueue.main.async { self.progress = fraction }
    }

    func nodePulse() {
        DispatchQueue.main.async { self.pulseToken += 1 }
    }

    func nodeTrouble(_ text: String?) {
        DispatchQueue.main.async { self.trouble = text }
    }

    private func show(_ text: String, alert: Bool, seconds: Double) {
        banner = text
        bannerAlert = alert
        progress = nil
        bannerToken += 1
        let token = bannerToken
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
            guard self.bannerToken == token else { return }
            self.banner = nil
            self.bannerAlert = false
        }
    }
}
