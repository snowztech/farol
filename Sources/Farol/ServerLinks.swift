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

    private let list: ServerList
    private var links: [UUID: Link] = [:]
    private var watching: [String: Timer] = [:]

    /// The name the servers list this Mac by, as `farol-host devices` prints it.
    static var deviceName: String { Host.current().localizedName ?? "Mac" }

    init(list: ServerList = .default) {
        self.list = list
        servers = list.load()
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

    /// Forgets the server here and, while it is connected, tells it to forget this Mac, as a phone does.
    /// Offline, the server keeps this Mac listed until `farol-host forget` there.
    func remove(_ server: Server) {
        links.removeValue(forKey: server.id)?.forget()
        states[server.id] = nil
        servers.removeAll { $0.id == server.id }
        try? list.save(servers)
    }

    func rename(_ server: Server, to name: String) {
        guard let index = servers.firstIndex(where: { $0.id == server.id }), !name.isEmpty else { return }
        servers[index].name = name
        try? list.save(servers)
    }

    /// Watches the setup terminal for the code farol-host prints, then pairs with it.
    /// ponytail: polls the screen twice a second while setup runs. A screen-changed callback would be lighter.
    func watchSetup(ssh: String, screen: @escaping () -> String?) {
        settingUp.insert(ssh)
        watching[ssh]?.invalidate()
        let started = Date()
        watching[ssh] = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] timer in
            guard let self else { return timer.invalidate() }
            // The code lasts two minutes, after whatever installing took.
            guard let text = screen(), Date().timeIntervalSince(started) < 15 * 60 else { return stopWatching(ssh) }
            if let link = ServerSetup.pairingLink(in: text), let offer = PairingOffer(link: link), offer.expires > Date() {
                stopWatching(ssh)
                pair(ssh: ssh, link: link, offer: offer)
            }
        }
    }

    private func stopWatching(_ ssh: String) {
        watching.removeValue(forKey: ssh)?.invalidate()
        settingUp.remove(ssh)
    }

    private func pair(ssh: String, link: URL, offer: PairingOffer) {
        guard let key = try? Keychain.deviceKey(),
              let request = try? Pairing.request(for: offer, from: key, named: Self.deviceName) else { return }
        // Adding a server again replaces the one before, so it is never listed twice.
        let old = servers.filter { $0.ssh == ssh }
        let server = Server(id: old.first?.id ?? UUID(), name: old.first?.name ?? Server.name(for: ssh), ssh: ssh, link: link)
        old.forEach { links.removeValue(forKey: $0.id)?.stop() }
        servers = servers.filter { $0.ssh != ssh } + [server]
        try? list.save(servers)
        start(server, key: key, offer: offer, pairing: request)
    }

    private func connect(_ server: Server) {
        guard let key = try? Keychain.deviceKey(), let offer = PairingOffer(link: server.link) else {
            states[server.id] = State(connection: .offline)
            return
        }
        start(server, key: key, offer: offer, pairing: nil)
    }

    private func start(_ server: Server, key: DeviceKey, offer: PairingOffer, pairing: PairingRequest?) {
        states[server.id] = State(connection: .connecting, sessions: states[server.id]?.sessions ?? [])
        let link = Link(key: key, offer: offer, pairing: pairing)
        link.onConnection = { [weak self] connection in self?.states[server.id, default: State()].connection = connection }
        link.onSessions = { [weak self] sessions in self?.update(server.id, sessions) }
        links[server.id] = link
        link.start()
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

/// One server's relay connection, opened as the phone opens one.
private final class Link {
    var onConnection: ((ServerLinks.Connection) -> Void)?
    var onSessions: (([RemoteSession]) -> Void)?

    private let key: DeviceKey
    private let offer: PairingOffer
    private var pairing: PairingRequest?
    private var link: PhoneLink
    private let relay: RelayConnection

    init(key: DeviceKey, offer: PairingOffer, pairing: PairingRequest?) {
        self.key = key
        self.offer = offer
        self.pairing = pairing
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
            send(link.start(pairing: pairing))
        case .offline:
            onConnection?(.offline)
        case .data(_, let payload):
            guard let frame = try? JSONDecoder().decode(WireFrame.self, from: payload) else { return }
            for output in link.receive(frame) {
                switch output {
                case .send(let frame): send([frame])
                case .paired: pairing = nil
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
