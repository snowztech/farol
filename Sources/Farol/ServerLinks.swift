import AppKit
import FarolCore
import FarolRemote
import Foundation

/// Farol as a device of each server you added, the way the phone is: one relay connection each, carrying what its agents do.
final class ServerLinks: ObservableObject {
    enum Connection: Equatable { case connecting, connected, offline }

    struct State: Equatable {
        var connection = Connection.connecting
        var sessions: [RemoteSession] = []
    }

    @Published private(set) var servers: [Server]
    @Published private(set) var states: [UUID: State] = [:]
    /// Servers being set up, by their ssh name, until the code farol-host shows is used.
    @Published private(set) var settingUp: Set<String> = []
    /// A session of a server changed status, for the notifications and the Dock.
    var onStatusChange: ((Server, RemoteSession, RemoteStatus) -> Void)?
    /// A server finished setting up and trusts this Mac.
    var onSetUp: ((String) -> Void)?

    private let list: ServerList
    private var links: [UUID: Link] = [:]
    private var watching: [String: Timer] = [:]
    /// A server that just dropped away, by id, before it counts as offline.
    private var dropping: [UUID: DispatchWorkItem] = [:]
    /// Long enough for farol-host to restart, as setup and upgrade make it, without the group flashing offline.
    private static let offlineAfter: TimeInterval = 10

    /// The name the servers list this Mac by, as `farol-host devices` prints it.
    static var deviceName: String { Host.current().localizedName ?? "Mac" }

    init(list: ServerList = .default) {
        self.list = list
        servers = list.load()
        try? FileManager.default.createDirectory(at: ServerSetup.connectionFolder, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        servers.forEach(connect)
    }

    func state(of server: Server) -> State { states[server.id] ?? State() }

    /// What a session opened on a server's tmux window keeps, to find it again.
    static func key(_ server: Server, _ window: String) -> String { "\(server.id.uuidString) \(window)" }

    /// Every agent on every server that waits for you, for the Dock count.
    var waiting: Int {
        states.values.reduce(0) { $0 + $1.sessions.filter { $0.status == .waiting || $0.status == .stopped }.count }
    }

    func retry(_ server: Server) {
        links[server.id]?.stop()
        connect(server)
    }

    /// Forgets the server here and tells it to forget this Mac: through the relay as a phone does, and over ssh for when it's offline.
    func remove(_ server: Server) {
        dropping.removeValue(forKey: server.id)?.cancel()
        links.removeValue(forKey: server.id)?.forget()
        let forget = ServerSetup.forgetArguments(ssh: server.ssh, deviceName: Self.deviceName)
        DispatchQueue.global(qos: .utility).async {
            let ssh = Process()
            ssh.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            ssh.arguments = forget
            ssh.standardInput = FileHandle.nullDevice
            ssh.standardOutput = FileHandle.nullDevice
            ssh.standardError = FileHandle.nullDevice
            try? ssh.run()
        }
        states[server.id] = nil
        servers.removeAll { $0.id == server.id }
        try? list.save(servers)
    }

    func rename(_ server: Server, to name: String) {
        guard let index = servers.firstIndex(where: { $0.id == server.id }), !name.isEmpty else { return }
        servers[index].name = name
        try? list.save(servers)
    }

    /// The key servers know this Mac by, for the setup script to hand to `farol-host trust`.
    var publicKey: Data? { (try? Keychain.serverKey())?.publicKey }

    /// Watches the setup terminal's title for the link the script sets there once the server trusts this Mac.
    /// `title` turns nil once the terminal is closed, which ends the wait.
    func watchSetup(ssh: String, title: @escaping () -> String?) {
        settingUp.insert(ssh)
        watching[ssh]?.invalidate()
        watching[ssh] = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] timer in
            guard let self else { return timer.invalidate() }
            guard let text = title() else { return stopWatching(ssh) }
            if let link = ServerSetup.trustedLink(inTitle: text), PairingOffer(link: link) != nil {
                stopWatching(ssh)
                add(ssh: ssh, link: link)
                onSetUp?(ssh)
            }
        }
    }

    private func stopWatching(_ ssh: String) {
        watching.removeValue(forKey: ssh)?.invalidate()
        settingUp.remove(ssh)
    }

    /// Adding a server again replaces the one before, keeping its name, so it is never listed twice.
    private func add(ssh: String, link: URL) {
        let old = servers.first { $0.ssh == ssh }
        if let old { links.removeValue(forKey: old.id)?.stop() }
        let server = Server(id: old?.id ?? UUID(), name: old?.name ?? Server.name(for: ssh), ssh: ssh, link: link)
        servers = servers.filter { $0.ssh != ssh } + [server]
        try? list.save(servers)
        connect(server)
    }

    private func connect(_ server: Server) {
        guard let key = try? Keychain.serverKey(), let offer = PairingOffer(link: server.link) else {
            states[server.id] = State(connection: .offline)
            return
        }
        start(server, key: key, offer: offer)
    }

    private func start(_ server: Server, key: DeviceKey, offer: PairingOffer) {
        states[server.id] = State(connection: .connecting, sessions: states[server.id]?.sessions ?? [])
        let link = Link(key: key, offer: offer)
        link.onConnection = { [weak self] connection in self?.connectionChanged(server.id, to: connection) }
        link.onSessions = { [weak self] sessions in self?.update(server.id, sessions) }
        links[server.id] = link
        link.start()
    }

    private func connectionChanged(_ id: UUID, to connection: Connection) {
        dropping.removeValue(forKey: id)?.cancel()
        guard connection == .offline else {
            states[id, default: State()].connection = connection
            return
        }
        // Breathing as it reconnects, and offline only if it stays away.
        states[id, default: State()].connection = .connecting
        let later = DispatchWorkItem { [weak self] in
            self?.dropping[id] = nil
            self?.states[id, default: State()].connection = .offline
        }
        dropping[id] = later
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.offlineAfter, execute: later)
    }

    private func update(_ id: UUID, _ sessions: [RemoteSession]) {
        let before = Dictionary(states[id]?.sessions.map { ($0.id, $0.status) } ?? [], uniquingKeysWith: { $1 })
        states[id, default: State()].sessions = sessions
        guard let server = servers.first(where: { $0.id == id }) else { return }
        for session in sessions where before[session.id].map({ $0 != session.status }) ?? false {
            onStatusChange?(server, session, before[session.id]!)
        }
    }
}

/// One server's relay connection, opened as the phone opens one. The server already trusts this Mac's key, so it never pairs.
private final class Link {
    var onConnection: ((ServerLinks.Connection) -> Void)?
    var onSessions: (([RemoteSession]) -> Void)?

    private let key: DeviceKey
    private let offer: PairingOffer
    private var link: PhoneLink
    private let relay: RelayConnection

    init(key: DeviceKey, offer: PairingOffer) {
        self.key = key
        self.offer = offer
        link = PhoneLink(phone: key, mac: offer.mac)
        relay = RelayConnection(url: offer.relay.appendingPathComponent("v1/rooms/\(RelayFrame.room(for: offer.mac))/phone"))
    }

    func start() {
        relay.onState = { [weak self] reached in if !reached { self?.onConnection?(.offline) } }
        relay.onMessage = { [weak self] in self?.receive($0) }
        relay.start()
    }

    func stop() {
        relay.stop()
    }

    func forget() {
        if let frame = link.seal(RemoteCommand(.forget)) { send([frame]) }
        // The message needs a moment on the socket before it closes.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [relay] in relay.stop() }
    }

    private func send(_ frames: [WireFrame]) {
        for frame in frames {
            guard let payload = try? JSONEncoder().encode(frame) else { continue }
            relay.send(RelayFrame.encode(payload))
        }
    }

    private func receive(_ message: Data) {
        switch RelayFrame(message, readBy: .phone) {
        case .online:
            link = PhoneLink(phone: key, mac: offer.mac)
            send(link.start())
        case .offline:
            onConnection?(.offline)
        case .data(_, let payload):
            guard let frame = try? JSONDecoder().decode(WireFrame.self, from: payload) else { return }
            for output in link.receive(frame) {
                switch output {
                case .send(let frame): send([frame])
                case .ready:
                    onConnection?(.connected)
                    if let hello = link.seal(RemoteCommand(.hello(version: RemoteProtocol.version))) { send([hello]) }
                case .event(.sessions(let list)): onSessions?(list)
                case .refused, .close: onConnection?(.offline)
                default: break
                }
            }
        default:
            break
        }
    }
}
