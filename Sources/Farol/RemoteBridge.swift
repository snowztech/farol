import AppKit
import FarolRemote
import GhosttyTerminal
import UserNotifications

/// The only code that joins `FarolRemote` to the sessions. It holds nothing and connects to nothing until Remote is turned on.
final class RemoteBridge: ObservableObject {
    static let enabledKey = "remote.enabled"
    private static let relayKey = "remote.relay"
    private static let defaultRelay = "wss://relay.farol.sh"
    /// Farol Remote, the app that scans the code. The site sends this on to TestFlight or the App Store, so moving between them needs no release.
    static let iPhoneApp = "https://farol.sh/iphone"
    private static let devicesKey = "remote.devices"
    private static let pushKey = "remote.push"
    /// Where a phone lands when its own camera scans the code, a page that says to scan from the app. The offer rides after the #, which never reaches that server.
    private static let pairingPage = URL(string: "https://farol.sh/pair")!

    /// The phones this Mac lets in.
    @Published private(set) var devices: [PairedDevice] = []
    /// The code on screen, while one is.
    @Published private(set) var offer: PairingOffer?
    /// The relay answered. False while Remote is off or the network is down.
    @Published private(set) var online = false
    /// Why Remote is on and not working, in words for the settings page.
    @Published private(set) var problem: String?
    /// The paired phones that are connected right now, by their key.
    @Published private(set) var connected: Set<Data> = []
    /// A relay of your own, as you typed it. Nil for Farol's.
    @Published private(set) var ownRelay = UserDefaults.standard.string(forKey: RemoteBridge.relayKey)

    private let store: SessionStore
    private var key: DeviceKey?
    private var connection: RelayConnection?
    private var phones: [UInt32: Phone] = [:]
    /// Kept per device and across its connections, since a phone resends on a new one.
    private var seen: [Data: SeenCommands] = [:]
    private var timer: Timer?
    private var offerEnd: Timer?
    private var wake: NSObjectProtocol?
    /// Held while the Mac is kept awake, and nil the rest of the time.
    private var awake: NSObjectProtocol?
    /// Keeps the Mac from sleeping by itself while an agent works or waits for an answer, so a phone can still reach it.
    var keepAwake = false { didSet { refreshAwake() } }

    /// Where Apple can reach a paired phone with a notification, as that phone said.
    private struct PushTarget: Codable {
        var device: Data
        var token: Data
        var sandbox: Bool
        /// What this phone asked to hear about. Nil is everything, which is what a phone that never said gets.
        var notices: [RemoteNotice]?
        /// Seals which session a notification is about, so only this phone reads it. Nil for a phone that sent none.
        var key: Data?
    }

    private var pushTargets: [PushTarget] = [] {
        didSet { UserDefaults.standard.set(try? JSONEncoder().encode(pushTargets), forKey: Self.pushKey) }
    }

    /// One phone's connection, by the number the relay gave it.
    private struct Phone {
        var link: MacLink
        var device: PairedDevice?
        var watching: UUID?
        /// What it was last sent, so only a change is sent again.
        var sessions: [RemoteSession]?
        var screen: String?
    }

    init(store: SessionStore) {
        self.store = store
        if let saved = UserDefaults.standard.data(forKey: Self.devicesKey) {
            devices = (try? JSONDecoder().decode([PairedDevice].self, from: saved)) ?? []
        }
        if let saved = UserDefaults.standard.data(forKey: Self.pushKey) {
            pushTargets = (try? JSONDecoder().decode([PushTarget].self, from: saved)) ?? []
        }
        // A connection from before a sleep is dead and does not say so. A new one is made at once, so a phone is not left waiting.
        wake = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self, connection != nil else { return }
            stop()
            start()
        }
    }

    func setEnabled(_ enabled: Bool) {
        enabled ? start() : stop()
    }

    private func start() {
        guard connection == nil else { return }
        guard let key = try? Keychain.deviceKey() else {
            problem = "Farol could not read its key from the Keychain. Allow it when macOS asks, then turn Remote off and on."
            return
        }
        problem = nil
        self.key = key
        guard let url = URL(string: "\(relay)/v1/rooms/\(RelayFrame.room(for: key.publicKey))/mac") else { return }
        let connection = RelayConnection(url: url)
        connection.onMessage = { [weak self] in self?.receive($0) }
        connection.onState = { [weak self] up in
            self?.online = up
            // The relay numbers phones again on a new connection, so the old ones mean nothing.
            if !up { self?.forgetPhones() }
        }
        self.connection = connection
        connection.start()
        refreshAwake()
        #if DEBUG
        // Lets a test pair without a camera: the link a QR code would carry, written where the test asks.
        if let path = ProcessInfo.processInfo.environment["FAROL_REMOTE_LINK_FILE"] {
            showOffer()
            try? link?.absoluteString.write(toFile: path, atomically: true, encoding: .utf8)
        }
        #endif
    }

    private func stop() {
        connection?.stop()
        connection = nil
        key = nil
        online = false
        problem = nil
        hideOffer()
        forgetPhones()
        refreshAwake()
    }

    /// The Mac stays awake only while Remote is on and a session needs it. The screen may still sleep, and closing the lid still sleeps the Mac.
    func refreshAwake() {
        let needed = keepAwake && connection != nil && store.sessions.contains { $0.activity == .working || $0.activity == .waiting }
        if needed, awake == nil {
            awake = ProcessInfo.processInfo.beginActivity(options: .idleSystemSleepDisabled, reason: "An agent is working, and a paired phone may answer it.")
        } else if !needed, let held = awake {
            ProcessInfo.processInfo.endActivity(held)
            awake = nil
        }
    }

    /// The relay's address with its scheme. A bare host is taken as secure, since that is what a phone accepts.
    private var relay: String {
        guard let own = ownRelay?.trimmingCharacters(in: .whitespaces), !own.isEmpty else { return Self.defaultRelay }
        if own.hasPrefix("https://") { return "wss://" + own.dropFirst(8) }
        if own.hasPrefix("http://") { return "ws://" + own.dropFirst(7) }
        return own.contains("://") ? own : "wss://" + own
    }

    /// The relay without its scheme, for the settings page.
    var relayHost: String {
        URL(string: relay)?.host ?? relay
    }

    /// Empty goes back to Farol's relay. The connection moves over at once.
    func useRelay(_ address: String) {
        let address = address.trimmingCharacters(in: .whitespaces)
        ownRelay = address.isEmpty ? nil : address
        UserDefaults.standard.set(ownRelay, forKey: Self.relayKey)
        guard connection != nil else { return }
        stop()
        start()
    }

    private func forgetPhones() {
        phones = [:]
        connected = []
        timer?.invalidate()
        timer = nil
    }

    // MARK: Pairing

    /// What the QR code carries.
    var link: URL? { offer?.link(on: Self.pairingPage) }

    func showOffer() {
        guard let key, let relay = URL(string: relay) else { return }
        let offer = PairingOffer(relay: relay, mac: key)
        self.offer = offer
        offerEnd?.invalidate()
        offerEnd = Timer.scheduledTimer(withTimeInterval: offer.expires.timeIntervalSinceNow, repeats: false) { [weak self] _ in
            self?.hideOffer()
        }
    }

    func hideOffer() {
        offerEnd?.invalidate()
        offerEnd = nil
        offer = nil
    }

    /// Cuts the device off at once: its connection is dropped, and the next one is turned away.
    func remove(_ device: PairedDevice) {
        devices.removeAll { $0.key == device.key }
        seen[device.key] = nil
        pushTargets.removeAll { $0.device == device.key }
        phones = phones.filter { $0.value.device?.key != device.key }
        connected.remove(device.key)
        save()
    }

    private func save() {
        UserDefaults.standard.set(try? JSONEncoder().encode(devices), forKey: Self.devicesKey)
    }

    private func paired(_ device: PairedDevice) {
        devices.removeAll { $0.key == device.key }
        devices.append(device)
        save()
        hideOffer()
        // Said out loud every time, so a pairing you did not make does not go unseen.
        let notice = UNMutableNotificationContent()
        notice.title = "A device was paired with Farol"
        notice.body = "\(device.name) can now see and answer your sessions. Remove it in Settings → Remote."
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: notice, trigger: nil))
    }

    // MARK: Messages

    private func receive(_ message: Data) {
        guard let key, let frame = RelayFrame(message, readBy: .mac) else { return }
        switch frame {
        case .joined(let id):
            phones[id] = Phone(link: MacLink(mac: key))
        case .left(let id):
            phones[id] = nil
            if phones.isEmpty { forgetPhones() }
        case .data(let id?, let payload):
            guard let wire = try? JSONDecoder().decode(WireFrame.self, from: payload) else { return }
            var phone = phones[id] ?? Phone(link: MacLink(mac: key))
            let outputs = phone.link.receive(wire, devices: devices, offer: offer)
            phones[id] = phone
            outputs.forEach { handle($0, from: id) }
        case .data(nil, _), .online, .offline:
            break
        }
        let now = Set(phones.values.compactMap { $0.device?.key })
        if now != connected { connected = now }
    }

    private func handle(_ output: MacLink.Output, from id: UInt32) {
        switch output {
        case .send(let frame):
            send(frame, to: id)
        case .paired(let device):
            paired(device)
        case .ready(let device):
            phones[id]?.device = device
            watch()
        case .command(let command):
            run(command, from: id)
        case .close:
            phones[id] = nil
        }
    }

    private func run(_ command: RemoteCommand, from id: UInt32) {
        guard let device = phones[id]?.device else { return }
        switch command.action {
        case .hello(let version):
            tell(.hello(version: RemoteProtocol.version), id)
            if RemoteProtocol.accepts(version) { tick() } else { phones[id] = nil }
        case .watch(let session):
            phones[id]?.watching = session
            phones[id]?.screen = nil
            tick()
        case .notify(let token, let sandbox, let notices, let key):
            pushTargets.removeAll { $0.device == device.key }
            pushTargets.append(PushTarget(device: device.key, token: token, sandbox: sandbox, notices: notices, key: key))
        case .options, .task:
            // Starting a task from the phone, which this version does not do. The phone is told so, and says to update.
            tell(.refused(command: command.id, reason: "This version of Farol cannot start tasks from the phone."), id)
        case .history(let session):
            // Read once, when the phone asks. Reading it on every change would cost the Mac for something rarely looked at.
            guard let pane = store.sessions.first(where: { $0.id == session })?.panes.focused else { return }
            tell(.history(session: session, text: pane.historyText()), id)
        case .send(let session, let text):
            act(command, by: device, on: session, from: id) { $0.pasteText(text) }
        case .type(let session, let text):
            act(command, by: device, on: session, from: id) { $0.type(text) }
        case .key(let session, let key):
            act(command, by: device, on: session, from: id) { pane in
                TerminalView.Key(rawValue: key.rawValue).map { pane.press($0) }
            }
        }
    }

    /// Types into a session once, however many times the command arrives.
    private func act(_ command: RemoteCommand, by device: PairedDevice, on session: UUID, from id: UInt32, _ type: (TerminalView) -> Void) {
        if seen[device.key, default: SeenCommands()].insert(command.id) {
            guard let pane = store.sessions.first(where: { $0.id == session })?.panes.focused else {
                return tell(.refused(command: command.id, reason: "That session is closed."), id)
            }
            type(pane)
        }
        tell(.done(command: command.id), id)
        tick()
    }

    private func tell(_ event: RemoteEvent, _ id: UInt32) {
        guard let frame = phones[id]?.link.seal(event) else { return }
        send(frame, to: id)
    }

    private func send(_ frame: WireFrame, to id: UInt32) {
        guard let payload = try? JSONEncoder().encode(frame) else { return }
        connection?.send(RelayFrame.encode(payload, to: id))
    }

    // MARK: Notifications

    /// Has the relay ask Apple to notify every paired phone when a session starts waiting or finishes.
    /// The relay is told which of the two. Which session it is goes along sealed, for the phone alone.
    func activityChanged(_ session: Session, from before: Session.Activity, to after: Session.Activity) {
        refreshAwake()
        guard let connection, before != after else { return }
        let notice: RemoteNotice? = switch after {
        case .waiting: .waiting
        case .done: .done
        default: nil
        }
        guard let notice else { return }
        for target in pushTargets where target.notices?.contains(notice) ?? true {
            let sealed = target.key.flatMap {
                NoticeBox.seal(RemoteNoticeContent(session: session.id, name: session.displayName, notice: notice), key: $0)
            }
            connection.send(RelayFrame.push(token: target.token, sandbox: target.sandbox, notice: notice, sealed: sealed))
        }
    }

    // MARK: Sessions

    /// Runs only while a phone is connected.
    private func watch() {
        guard timer == nil else { return }
        // ponytail: asks a few times a second while a phone is connected. Observing the store would send sooner and ask less.
        timer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in self?.tick() }
    }

    /// Sends each phone what changed: the list, and the screen of the session it has open. Always in full.
    private func tick() {
        let sessions = store.ordered.map {
            RemoteSession(id: $0.id, name: $0.displayName, branch: $0.branch, status: RemoteStatus(rawValue: "\($0.activity)") ?? .idle)
        }
        for (id, phone) in phones where phone.device != nil {
            if phone.sessions != sessions {
                phones[id]?.sessions = sessions
                tell(.sessions(sessions), id)
            }
            guard let watching = phone.watching,
                  let text = store.sessions.first(where: { $0.id == watching })?.panes.focused.screenText,
                  text != phone.screen else { continue }
            phones[id]?.screen = text
            tell(.screen(session: watching, text: text), id)
        }
    }
}

/// The Mac's own remote key, in the login Keychain.
private enum Keychain {
    private static var query: [CFString: Any] {
        [kSecClass: kSecClassGenericPassword, kSecAttrService: "Farol Remote", kSecAttrAccount: Bundle.main.bundleIdentifier ?? "farol"]
    }

    /// Made the first time Remote is turned on, and the same from then on.
    static func deviceKey() throws -> DeviceKey {
        #if DEBUG
        // Each build of Farol Dev is signed anew, and the Keychain treats it as another app that may not read the key.
        // A file only you can read keeps the key, and the phones paired with it, across builds.
        let file = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Farol/\(Bundle.main.bundleIdentifier ?? "farol").remote-key")
        if let stored = try? Data(contentsOf: file) { return try DeviceKey(stored: stored) }
        let key = DeviceKey()
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try key.stored.write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        return key
        #else
        var found: CFTypeRef?
        if SecItemCopyMatching(query.merging([kSecReturnData: true]) { $1 } as CFDictionary, &found) == errSecSuccess,
           let stored = found as? Data {
            return try DeviceKey(stored: stored)
        }
        let key = DeviceKey()
        let status = SecItemAdd(query.merging([kSecValueData: key.stored]) { $1 } as CFDictionary, nil)
        guard status == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
        return key
        #endif
    }
}
