import Foundation
import Network
import os

protocol NodeUI: AnyObject {
    func nodePeers(_ names: [String])
    func nodeBanner(_ text: String, alert: Bool, seconds: Double?)
    func nodeProgress(_ fraction: Double)
    func nodePulse()
    func nodeTrouble(_ text: String?)
}

/// Finds other Black hole apps with Bonjour and copies dropped files to each of them.
/// Both sides dial. When both connections succeed, the one opened by the
/// lexicographically smaller peer id is kept, so either Mac can be the side
/// whose firewall allows an inbound connection.
final class Node {
    let ourID: UUID
    let displayName: String

    weak var ui: NodeUI?

    private let log = Logger(subsystem: "com.tim.blackhole", category: "node")
    private let nodeQueue = DispatchQueue(label: "blackhole.node")
    private let rootBox: RootBox
    private let configLock = NSLock()
    private var code: String
    private var listener: NWListener?
    private var browser: NWBrowser?
    private var links: [UUID: Link] = [:]
    /// In-flight connections. Network.framework keeps the socket after start,
    /// but nothing else retains Link until a hello is registered.
    private var live: [ObjectIdentifier: Link] = [:]
    /// Bonjour instance name to endpoint. Network.framework often delivers no TXT record.
    private var discovered: [String: NWEndpoint] = [:]
    private var linkedNames: [String: UUID] = [:]
    private var dialing: Set<String> = []
    private var backoff: [String: Date] = [:]
    private let advertisedName: String
    private let legacyName: String
    private var pending: [Job] = []
    private var busy = false
    private var life = UUID()
    private var arrivalCount = 0
    private var arrivalName = ""
    private var arrivalToken = 0
    private var started = false

    init(peerID: UUID, name: String, receiveRoot: URL, pairingCode: String) {
        ourID = peerID
        displayName = name
        advertisedName = peerID.uuidString
        legacyName = "BH-\(peerID.uuidString.prefix(8))"
        rootBox = RootBox(receiveRoot)
        code = pairingCode
    }

    func currentCode() -> String {
        configLock.lock()
        defer { configLock.unlock() }
        return code
    }

    func start() {
        nodeQueue.async {
            guard !self.started else { return }
            self.started = true
            self.reboot(quiet: true)
        }
    }

    func stop() {
        let listener: NWListener?
        let browser: NWBrowser?
        configLock.lock()
        listener = self.listener
        browser = self.browser
        configLock.unlock()
        listener?.cancel()
        browser?.cancel()
        nodeQueue.async { [weak self] in
            guard let self else { return }
            self.life = UUID()
            self.started = false
            for link in self.links.values { link.close() }
            self.links.removeAll()
        }
    }

    func setPairingCode(_ raw: String) {
        let normalized = CodeMark.normalize(raw)
        nodeQueue.async {
            guard normalized != self.currentCode() else { return }
            self.configLock.lock()
            self.code = normalized
            self.configLock.unlock()
            self.reboot(quiet: false)
        }
    }

    func setReceiveRoot(_ url: URL) {
        nodeQueue.async {
            guard url.path != self.rootBox.get().path else { return }
            self.rootBox.set(url)
            IncomingSweep.run(root: url)
            for link in self.live.values { link.close() }
        }
    }

    func enqueue(urls: [URL], scopes: [Scope]) {
        nodeQueue.async {
            self.pending.append(Job(urls: urls, scopes: scopes))
            self.pump()
        }
    }

    func noteArrival(_ name: String) {
        nodeQueue.async {
            self.arrivalCount += 1
            self.arrivalName = name
            self.arrivalToken += 1
            let token = self.arrivalToken
            self.nodeQueue.asyncAfter(deadline: .now() + 0.45) { [weak self] in
                guard let self, self.arrivalToken == token else { return }
                let text = self.arrivalCount == 1
                    ? "\(self.arrivalName) arrived"
                    : "\(self.arrivalCount) files arrived"
                self.arrivalCount = 0
                self.ui?.nodeBanner(text, alert: false, seconds: 4)
                self.ui?.nodePulse()
            }
        }
    }

    func noteProblem(_ note: String) {
        let text: String
        switch note {
        case TransferNote.disk: text = "This Mac is out of space"
        case TransferNote.damaged: text = "A file was damaged in transit"
        default: text = "A file was not saved"
        }
        ui?.nodeBanner(text, alert: true, seconds: 5)
    }

    func noteFailure(_ name: String?) {
        guard let name else { return }
        nodeQueue.async {
            self.backoff[name] = Date().addingTimeInterval(8)
            self.dialing.remove(name)
            self.scheduleRedial(name, after: 8)
        }
    }

    func register(_ link: Link) {
        nodeQueue.async { self.registerNow(link) }
    }

    func linkClosed(_ link: Link) {
        nodeQueue.async {
            self.live.removeValue(forKey: ObjectIdentifier(link))
            if let name = link.dialName {
                self.dialing.remove(name)
            }
            guard let id = link.peerID, self.links[id] === link else {
                if link.peerID == nil, let name = link.dialName {
                    self.scheduleRedial(name, after: 2)
                }
                return
            }
            self.links.removeValue(forKey: id)
            if let name = link.dialName, self.linkedNames[name] == id {
                self.linkedNames.removeValue(forKey: name)
            }
            self.publishPeers()
            if let name = link.dialName {
                self.scheduleRedial(name, after: 2)
            }
        }
    }

    private func reboot(quiet: Bool) {
        life = UUID()
        listener?.cancel()
        browser?.cancel()
        listener = nil
        browser = nil
        for link in links.values { link.close() }
        for link in live.values { link.close() }
        links.removeAll()
        live.removeAll()
        discovered.removeAll()
        linkedNames.removeAll()
        dialing.removeAll()
        backoff.removeAll()
        publishPeers()
        do {
            try boot(token: life)
        } catch {
            log.error("listener failed: \(error.localizedDescription, privacy: .public)")
            if !quiet {
                ui?.nodeTrouble("Couldn't listen on the network")
            } else {
                ui?.nodeTrouble("Couldn't listen on the network")
            }
        }
    }

    private func boot(token: UUID) throws {
        IncomingSweep.run(root: rootBox.get())
        let params = Self.tcp()
        let listener = try NWListener(using: params, on: .any)
        var txt = NWTXTRecord()
        txt["id"] = ourID.uuidString
        txt["v"] = "1"
        txt["c"] = CodeMark.mark(currentCode())
        listener.service = NWListener.Service(
            name: advertisedName,
            type: Wire.serviceType,
            txtRecord: txt
        )
        listener.stateUpdateHandler = { [weak self] state in
            self?.listenerState(state)
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.start(queue: nodeQueue)

        let browser = NWBrowser(for: .bonjour(type: Wire.serviceType, domain: nil), using: Self.tcp())
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            self?.apply(results: results)
        }
        browser.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed(let error):
                self?.log.error("browser failed: \(error.localizedDescription, privacy: .public)")
                self?.ui?.nodeTrouble("Couldn't look for other Macs")
            case .waiting(let error):
                self?.log.error("browser waiting: \(error.localizedDescription, privacy: .public)")
            default:
                break
            }
        }
        browser.start(queue: nodeQueue)

        configLock.lock()
        self.listener = listener
        self.browser = browser
        configLock.unlock()
        startPing(token: token)
    }

    private func listenerState(_ state: NWListener.State) {
        switch state {
        case .ready:
            ui?.nodeTrouble(nil)
        case .waiting:
            ui?.nodeTrouble("Waiting for a network")
        case .failed(let error):
            log.error("listener failed: \(error.localizedDescription, privacy: .public)")
            ui?.nodeTrouble("Couldn't listen on the network")
        case .cancelled, .setup:
            break
        @unknown default:
            break
        }
    }

    private func accept(_ connection: NWConnection) {
        if !ConnectionLimit.allows(openConnections: live.count) {
            connection.cancel()
            return
        }
        let link = Link(connection: connection, initiatedByUs: false, dialName: nil, node: self, root: rootBox)
        live[ObjectIdentifier(link)] = link
        link.start()
    }

    private func apply(results: Set<NWBrowser.Result>) {
        let mark = CodeMark.mark(currentCode())
        var seen = Set<String>()
        for result in results {
            guard let name = Discovery.serviceName(result.endpoint) else { continue }
            let version: String?
            let code: String?
            if case .bonjour(let txt) = result.metadata {
                version = txt["v"]
                code = txt["c"]
            } else {
                version = nil
                code = nil
            }
            guard Discovery.shouldDial(
                name: name,
                ownNames: [advertisedName, legacyName],
                version: version,
                code: code,
                mark: mark
            ) else {
                let own = [advertisedName, legacyName].contains {
                    name.compare($0, options: .caseInsensitive) == .orderedSame
                }
                if !own { dropPeer(name) }
                continue
            }
            seen.insert(name)
            discovered[name] = result.endpoint
            dial(name: name, endpoint: result.endpoint)
        }
        for name in discovered.keys where !seen.contains(name) {
            discovered.removeValue(forKey: name)
        }
    }

    private func dropPeer(_ name: String) {
        discovered.removeValue(forKey: name)
        guard let id = linkedNames.removeValue(forKey: name) else { return }
        links[id]?.close()
    }

    private func dial(name: String, endpoint: NWEndpoint) {
        if dialing.contains(name) { return }
        if let id = linkedNames[name], links[id] != nil { return }
        if linkedNames[name] != nil { linkedNames.removeValue(forKey: name) }
        if let until = backoff[name], until > Date() { return }
        if !ConnectionLimit.allows(openConnections: live.count) {
            scheduleRedial(name, after: 2)
            return
        }
        backoff.removeValue(forKey: name)
        dialing.insert(name)
        log.info("dialing \(name, privacy: .public)")
        let link = Link(
            connection: NWConnection(to: endpoint, using: Self.tcp()),
            initiatedByUs: true,
            dialName: name,
            node: self,
            root: rootBox
        )
        live[ObjectIdentifier(link)] = link
        link.start()
    }

    private func scheduleRedial(_ name: String, after seconds: Double) {
        nodeQueue.asyncAfter(deadline: .now() + seconds) { [weak self] in
            guard let self, let endpoint = self.discovered[name] else { return }
            self.dial(name: name, endpoint: endpoint)
        }
    }

    private func registerNow(_ link: Link) {
        guard let id = link.peerID else { return }
        if let name = link.dialName {
            dialing.remove(name)
        }
        if id == ourID {
            link.close()
            return
        }
        if let name = link.dialName {
            linkedNames[name] = id
        }
        if let existing = links[id], existing !== link {
            if link.initiatedBySmaller && !existing.initiatedBySmaller {
                existing.close()
                links[id] = link
            } else {
                link.close()
                return
            }
        } else {
            links[id] = link
        }
        publishPeers()
    }

    private func publishPeers() {
        let pairs = links.values.compactMap { link -> (String, UUID)? in
            guard let id = link.peerID else { return nil }
            return (link.peerName, id)
        }
        var counts: [String: Int] = [:]
        for (name, _) in pairs { counts[name, default: 0] += 1 }
        let names = pairs.map { name, id -> String in
            if counts[name, default: 0] > 1 {
                return "\(name) \(id.uuidString.prefix(4))"
            }
            return name
        }.sorted()
        ui?.nodePeers(names)
    }

    private func startPing(token: UUID) {
        nodeQueue.asyncAfter(deadline: .now() + 25) { [weak self] in
            guard let self, self.life == token else { return }
            for link in self.links.values {
                if let frame = try? Wire.frame(.ping) {
                    link.sendAsync(frame)
                }
            }
            self.startPing(token: token)
        }
    }

    private func pump() {
        guard !busy, !pending.isEmpty else { return }
        busy = true
        let job = pending.removeFirst()
        ui?.nodeBanner("Counting…", alert: false, seconds: nil)
        DispatchQueue.global(qos: .userInitiated).async {
            let batch = DropList.collect(job.urls)
            self.nodeQueue.async {
                self.run(batch, job: job)
            }
        }
    }

    private func run(_ batch: DropBatch, job: Job) {
        guard !batch.items.isEmpty else {
            finishJob(job, banner: StatusLine.nothing(skipped: batch.skipped), alert: true)
            return
        }
        let targets = Array(links.values)
        guard !targets.isEmpty else {
            finishJob(job, banner: "No other Black hole", alert: true)
            return
        }
        let bytes = batch.items.reduce(UInt64(0)) { $0 + $1.size } * UInt64(targets.count)
        let meter = ProgressMeter(total: bytes)
        meter.onUpdate = { [weak self] fraction in
            self?.ui?.nodeProgress(fraction)
        }
        if bytes == 0 { meter.add(0) }
        let report = SendReport()
        let group = DispatchGroup()
        for link in targets {
            group.enter()
            let name = link.peerName
            DispatchQueue.global(qos: .userInitiated).async {
                defer { group.leave() }
                var failure: Error?
                do {
                    try Sender.transmitAll(batch.items, to: link, progress: meter) { item in
                        let label = item.relativePath.split(separator: "/").last.map(String.init) ?? item.relativePath
                        self.ui?.nodeBanner("Sending \(label)", alert: false, seconds: nil)
                    }
                } catch {
                    failure = error
                    link.close()
                }
                report.finish(name: name, error: failure)
            }
        }
        group.notify(queue: nodeQueue) { [weak self] in
            guard let self else { return }
            let (okNames, failed, reason) = report.snapshot()
            let text: String
            let alert: Bool
            let skipped = batch.skipped
            if okNames.isEmpty {
                text = reason.isEmpty ? "Not sent" : reason
                alert = true
            } else if failed == 0 {
                text = StatusLine.sent(to: NameList.join(okNames), skipped: skipped)
                alert = skipped > 0
            } else {
                text = "Sent to \(NameList.join(okNames)). \(reason)" + StatusLine.skipSuffix(skipped)
                alert = true
            }
            job.scopes.forEach { $0.release() }
            self.ui?.nodeBanner(text, alert: alert, seconds: 4)
            self.busy = false
            self.pump()
        }
    }

    private func finishJob(_ job: Job, banner: String, alert: Bool) {
        job.scopes.forEach { $0.release() }
        ui?.nodeBanner(banner, alert: alert, seconds: 3)
        busy = false
        pump()
    }

    static func tcp() -> NWParameters {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.enableKeepalive = true
        return NWParameters(tls: nil, tcp: tcp)
    }

    static func explain(_ error: Error) -> String {
        switch error {
        case let TransferError.refused(note):
            switch note {
            case TransferNote.badPath: return "A file name was rejected"
            case TransferNote.damaged: return "A file was damaged in transit"
            case TransferNote.disk: return "The other Mac is out of space"
            case TransferNote.io: return "The other Mac couldn't save a file"
            default: return "The other Mac refused a file"
            }
        case TransferError.timeout, TransferError.closed:
            return "Lost the other Mac"
        default:
            return "Not sent"
        }
    }
}

/// Decides which Bonjour names to dial. A missing TXT record still dials:
/// the hello message carries the version and pairing code.
enum ConnectionLimit {
    static let maximum = 16

    static func allows(openConnections: Int) -> Bool {
        openConnections < maximum
    }
}

enum Discovery {
    static func shouldDial(
        name: String,
        ownNames: [String],
        version: String?,
        code: String?,
        mark: String
    ) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if ownNames.contains(where: { trimmed.compare($0, options: .caseInsensitive) == .orderedSame }) {
            return false
        }
        if let version, version != "1" { return false }
        if let code, code != mark { return false }
        return true
    }

    static func serviceName(_ endpoint: NWEndpoint) -> String? {
        guard case .service(let name, _, _, _) = endpoint else { return nil }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

private struct Job {
    var urls: [URL]
    var scopes: [Scope]
}

private final class SendReport {
    private let lock = NSLock()
    private var okNames: [String] = []
    private var failed = 0
    private var reason = ""

    func finish(name: String, error: Error?) {
        lock.lock()
        defer { lock.unlock() }
        if let error {
            failed += 1
            if reason.isEmpty { reason = Node.explain(error) }
        } else {
            okNames.append(name)
        }
    }

    func snapshot() -> ([String], Int, String) {
        lock.lock()
        defer { lock.unlock() }
        return (okNames.sorted(), failed, reason)
    }
}

final class RootBox {
    private let lock = NSLock()
    private var url: URL
    init(_ url: URL) { self.url = url }
    func get() -> URL {
        lock.lock()
        defer { lock.unlock() }
        return url
    }
    func set(_ url: URL) {
        lock.lock()
        self.url = url
        lock.unlock()
    }
}

final class Link: MessageOut {
    static let handshakeSeconds: Double = 8

    let initiatedByUs: Bool
    let dialName: String?
    private let connection: NWConnection
    private let readQueue: DispatchQueue
    private let writeQueue: DispatchQueue
    private weak var node: Node?
    private let root: RootBox
    private var receiver: Receiver?
    private let receiverLock = NSLock()
    private var parser = Parser()
    private var peerIDValue: UUID?
    private var peerNameValue = "Mac"
    private var didReady = false
    private var didClose = false
    private let closeLock = NSLock()
    private let waitLock = NSLock()
    private var waiters: [UUID: (Result<Void, Error>) -> Void] = [:]
    private var early: [UUID: Result<Void, Error>] = [:]
    private var inboundNames: [UUID: String] = [:]

    init(connection: NWConnection, initiatedByUs: Bool, dialName: String?, node: Node, root: RootBox) {
        self.connection = connection
        self.initiatedByUs = initiatedByUs
        self.dialName = dialName
        self.node = node
        self.root = root
        let token = UUID().uuidString
        readQueue = DispatchQueue(label: "blackhole.read.\(token)")
        writeQueue = DispatchQueue(label: "blackhole.write.\(token)")
    }

    var peerID: UUID? { peerIDValue }
    var peerName: String { peerNameValue }

    var initiatedBySmaller: Bool {
        guard let peerIDValue, let node else { return false }
        let weAreSmaller = node.ourID.uuidString < peerIDValue.uuidString
        return initiatedByUs == weAreSmaller
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            self?.onState(state)
        }
        connection.start(queue: readQueue)
    }

    deinit {
        connection.cancel()
    }

    func close() {
        closeLock.lock()
        if didClose {
            closeLock.unlock()
            return
        }
        didClose = true
        closeLock.unlock()
        failWaiters()
        retireReceiver()
        connection.cancel()
        node?.linkClosed(self)
    }

    func send(_ message: Message) throws {
        try sendSync(try Wire.frame(message))
    }

    func sendAsync(_ data: Data) {
        writeQueue.async { [weak self] in
            guard let self, !self.isClosed else { return }
            self.connection.send(content: data, completion: .contentProcessed { [weak self] error in
                if error != nil { self?.close() }
            })
        }
    }

    func awaitResult(id: UUID, timeout: TimeInterval) throws {
        let box = ResultBox()
        let sem = DispatchSemaphore(value: 0)
        waitLock.lock()
        if let existing = early.removeValue(forKey: id) {
            waitLock.unlock()
            switch existing {
            case .success: return
            case let .failure(error): throw error
            }
        }
        waiters[id] = { result in
            box.result = result
            sem.signal()
        }
        waitLock.unlock()
        let wait = sem.wait(timeout: .now() + timeout)
        waitLock.lock()
        waiters.removeValue(forKey: id)
        waitLock.unlock()
        if wait == .timedOut { throw TransferError.timeout }
        switch box.result {
        case .success: return
        case let .failure(error): throw error
        case nil: throw TransferError.closed
        }
    }

    func failed(_ id: UUID) -> Bool {
        waitLock.lock()
        defer { waitLock.unlock() }
        if case .failure = early[id] { return true }
        return false
    }

    private var isClosed: Bool {
        closeLock.lock()
        defer { closeLock.unlock() }
        return didClose
    }

    private func onState(_ state: NWConnection.State) {
        switch state {
        case .ready:
            guard !didReady else { return }
            didReady = true
            guard remoteIsLocal() else {
                node?.noteFailure(dialName)
                close()
                return
            }
            sendHello()
            readLoop()
            armHandshakeTimer()
        case .failed, .cancelled:
            close()
        case .setup, .waiting, .preparing:
            break
        @unknown default:
            break
        }
    }

    private func remoteIsLocal() -> Bool {
        guard let endpoint = connection.currentPath?.remoteEndpoint else { return false }
        return LocalNet.allows(endpoint: endpoint)
    }

    private func armHandshakeTimer() {
        readQueue.asyncAfter(deadline: .now() + Link.handshakeSeconds) { [weak self] in
            guard let self, !self.isClosed, self.peerIDValue == nil else { return }
            self.node?.noteFailure(self.dialName)
            self.close()
        }
    }

    private func sendHello() {
        guard let node else { return }
        var data = Wire.preface
        if let frame = try? Wire.frame(.hello(
            version: Wire.version,
            id: node.ourID,
            name: node.displayName,
            code: node.currentCode()
        )) {
            data.append(frame)
        }
        sendAsync(data)
    }

    private func readLoop() {
        if isClosed { return }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self, !self.isClosed else { return }
            if let data, !data.isEmpty {
                do {
                    let messages = try self.parser.append(data)
                    for message in messages { self.handle(message) }
                } catch {
                    self.close()
                    return
                }
            }
            if isComplete || error != nil {
                self.close()
                return
            }
            if !self.isClosed { self.readLoop() }
        }
    }

    private func handle(_ message: Message) {
        switch message {
        case let .hello(version, id, name, code):
            guard peerIDValue == nil else { return }
            guard Handshake.accept(version: version, code: code, ours: node?.currentCode() ?? "") else {
                node?.noteFailure(dialName)
                close()
                return
            }
            peerIDValue = id
            peerNameValue = NameList.clean(name)
            do {
                try installReceiver()
            } catch {
                node?.ui?.nodeTrouble("Can't create the receive folder")
                node?.noteFailure(dialName)
                close()
                return
            }
            node?.register(self)
        case let .fileStart(id, _, path, directory, _):
            guard let current = borrowReceiver() else {
                close()
                return
            }
            if !directory, let clean = PathGuard.relative(path) {
                inboundNames[id] = (clean as NSString).lastPathComponent
            }
            reply(current.handle(message))
        case let .fileEnd(id, _, _):
            guard let current = borrowReceiver() else {
                close()
                return
            }
            let leaf = inboundNames.removeValue(forKey: id)
            guard let result = current.handle(message) else { return }
            reply(result)
            if case let .fileResult(_, ok, note) = result {
                if ok, let leaf { node?.noteArrival(leaf) }
                if !ok { node?.noteProblem(note) }
            }
        case .fileChunk, .fileAbort:
            guard let current = borrowReceiver() else {
                close()
                return
            }
            reply(current.handle(message))
        case let .fileResult(id, ok, note):
            if ok {
                deliver(id, .success(()))
            } else {
                deliver(id, .failure(TransferError.refused(note)))
            }
        case .ping:
            break
        }
    }

    private func installReceiver() throws {
        receiverLock.lock()
        defer { receiverLock.unlock() }
        if receiver == nil {
            receiver = try Receiver(root: root.get())
        }
    }

    private func borrowReceiver() -> Receiver? {
        receiverLock.lock()
        defer { receiverLock.unlock() }
        return receiver
    }

    /// Drops the receiver so an interrupted copy closes its files now.
    private func retireReceiver() {
        receiverLock.lock()
        let current = receiver
        receiver = nil
        receiverLock.unlock()
        current?.cancelAll()
    }

    private func reply(_ message: Message?) {
        guard let message, let data = try? Wire.frame(message) else { return }
        sendAsync(data)
    }

    private func sendSync(_ data: Data) throws {
        if isClosed { throw TransferError.closed }
        let outcome = ErrorSlot()
        let sent = DispatchSemaphore(value: 0)
        // Submit on the write queue, but wait on the caller so a file result
        // can be queued between chunks instead of sitting behind the whole file.
        writeQueue.async { [weak self] in
            guard let self, !self.isClosed else {
                outcome.error = TransferError.closed
                sent.signal()
                return
            }
            self.connection.send(content: data, completion: .contentProcessed { error in
                if let error { outcome.network = error }
                sent.signal()
            })
        }
        if sent.wait(timeout: .now() + 120) == .timedOut {
            close()
            throw TransferError.timeout
        }
        if let error = outcome.error { throw error }
        if outcome.network != nil { throw TransferError.closed }
    }

    private func deliver(_ id: UUID, _ result: Result<Void, Error>) {
        waitLock.lock()
        let waiter = waiters.removeValue(forKey: id)
        if waiter == nil { early[id] = result }
        waitLock.unlock()
        waiter?(result)
    }

    private func failWaiters() {
        waitLock.lock()
        let pending = waiters
        waiters.removeAll()
        early.removeAll()
        waitLock.unlock()
        for (_, waiter) in pending {
            waiter(.failure(TransferError.closed))
        }
    }
}

private final class ResultBox {
    var result: Result<Void, Error>?
}

private final class ErrorSlot {
    var error: Error?
    var network: NWError?
}
