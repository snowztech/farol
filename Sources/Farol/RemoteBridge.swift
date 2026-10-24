import AppKit
import FarolCore
import FarolRemote
import GhosttyTerminal
import SystemConfiguration
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
    private static let activityKey = "remote.activity"
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
    private var phones: [UInt32: Phone] = [:] {
        didSet {
            followLogs()
            retime()
        }
    }
    /// Kept per device and across its connections, since a phone resends on a new one.
    private var seen: [Data: SeenCommands] = [:]
    /// A reconnect repeats the same decision ID. Return the same result, including a refusal.
    private var askResponses: [Data: [UUID: RemoteEvent]] = [:]
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
        /// Where Apple can start a Live Activity on this phone with the app closed. Nil before iOS 17.2.
        var starts: Data?
    }

    /// Phones sent a start and not yet the started activity's address. Another start would only stack a second one.
    private var starting: Set<Data> = []

    private var pushTargets: [PushTarget] = [] {
        didSet { UserDefaults.standard.set(try? JSONEncoder().encode(pushTargets), forKey: Self.pushKey) }
    }

    /// Where Apple can reach the Live Activity a phone started, and the sessions it last showed, so only a change is sent.
    private struct ActivityTarget: Codable {
        var device: Data
        var token: Data
        var sandbox: Bool
        var shown: [RemoteSession] = []
    }

    private var activityTargets: [ActivityTarget] = [] {
        didSet { UserDefaults.standard.set(try? JSONEncoder().encode(activityTargets), forKey: Self.activityKey) }
    }

    /// One phone's connection, by the number the relay gave it.
    private struct Phone {
        var link: MacLink
        var device: PairedDevice?
        var watching: UUID?
        /// What it was last sent, so only a change is sent again.
        var sessions: [RemoteSession]?
        var screen: String?
        /// The session whose terminal it shows, which then gets its screen often. Nil while it shows a conversation.
        var terminal: UUID?
        /// It said when it shows a terminal, so its screen goes only then. An older phone never says, and always gets it.
        var saysTerminal = false
        /// The session it was told is an empty conversation, an agent started there with no log yet, so it is told once.
        var toldEmpty: UUID?
        /// What it was told the watched session waits on. Nil until told, so the first tick always says, even that it waits on nothing.
        var request: RemoteRequest??
        /// A phone opts in on `watch`, so an older phone never receives an event it cannot decode.
        var asks = false
        var ask: RemoteAsk??
        /// The conversation it reads, and the last message it has, so only what follows is sent.
        var conversation: (session: UUID, log: String, last: String?)?
    }

    /// The agents' logs, read where they were left. Only on `reading`, since the first read of a long log takes a second.
    private var transcripts: [String: Transcript] = [:]
    private let reading = DispatchQueue(label: "sh.farol.remote.transcripts", qos: .utility)
    /// The logs phones read, watched so a change is read when the agent writes and nothing is done while it does not.
    private var logWatches: [String: DispatchSourceFileSystemObject] = [:]

    init(store: SessionStore) {
        self.store = store
        if let saved = UserDefaults.standard.data(forKey: Self.devicesKey) {
            devices = (try? JSONDecoder().decode([PairedDevice].self, from: saved)) ?? []
        }
        if let saved = UserDefaults.standard.data(forKey: Self.pushKey) {
            pushTargets = (try? JSONDecoder().decode([PushTarget].self, from: saved)) ?? []
        }
        if let saved = UserDefaults.standard.data(forKey: Self.activityKey) {
            activityTargets = (try? JSONDecoder().decode([ActivityTarget].self, from: saved)) ?? []
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

    /// What a phone calls this Mac: its name in System Settings, like "Lucas's MacBook Pro". Read without asking the network, unlike `Host`.
    private static var computerName: String? {
        SCDynamicStoreCopyComputerName(nil, nil) as String?
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

    /// How often phones are sent what changed: often while one shows a terminal, so typing there feels live, and less the rest of the time.
    private var interval: TimeInterval { phones.values.contains { $0.terminal != nil } ? 0.12 : 0.4 }

    private func retime() {
        guard let timer, timer.timeInterval != interval else { return }
        timer.invalidate()
        self.timer = nil
        watch()
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
        activityTargets.removeAll { $0.device == device.key }
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
            tell(.hello(version: RemoteProtocol.version, features: RemoteFeature.allCases.map(\.rawValue), name: Self.computerName), id)
            if RemoteProtocol.accepts(version) { tick() } else { phones[id] = nil }
        case .watch(let session, let asks):
            phones[id]?.watching = session
            phones[id]?.asks = asks == true
            phones[id]?.screen = nil
            phones[id]?.request = nil
            phones[id]?.ask = nil
            phones[id]?.toldEmpty = nil
            phones[id]?.conversation = nil
            tick()
        case .notify(let token, let sandbox, let notices, let key, let starts):
            pushTargets.removeAll { $0.device == device.key }
            pushTargets.append(PushTarget(device: device.key, token: token, sandbox: sandbox, notices: notices, key: key, starts: starts))
        case .activity(let token, let sandbox):
            starting.remove(device.key)
            activityTargets.removeAll { $0.device == device.key }
            activityTargets.append(ActivityTarget(device: device.key, token: token, sandbox: sandbox))
            updateActivities()
        case .options:
            let agents = AgentFolder.find()
            tell(.options(projects: projects.map { RemoteChoice(id: $0, name: $0 == NSHomeDirectory() ? "Home" : URL(fileURLWithPath: $0).lastPathComponent) },
                          agents: agents.map { RemoteChoice(id: $0.id, name: $0.label) }, agent: agents.first?.id), id)
        case .open(let project, let agent):
            open(command, by: device, in: project, with: agent, from: id)
        case .close(let session):
            close(command, by: device, session: session, from: id)
        case .conversation(let session, let before):
            conversation(command, of: session, before: before, from: id)
        case .answer(let session, let request, let choice):
            answer(command, by: device, session: session, request: request, choice: choice, from: id)
        case .respondAsk(let session, let ask, let decision):
            respondAsk(command, by: device, session: session, ask: ask, decision: decision, from: id)
        case .terminal(let session, let open):
            phones[id]?.saysTerminal = true
            if open { phones[id]?.terminal = session } else if phones[id]?.terminal == session { phones[id]?.terminal = nil }
            phones[id]?.screen = nil
            retime()
            tick()
        case .commands(let session):
            commands(command, of: session, from: id)
        case .attach(let session, let attachment, let part, let parts, let data):
            attach(command, session: session, attachment: attachment, part: part, of: parts, data: data, from: id)
        case .forget:
            tell(.done(command: command.id), id)
            remove(device)
        case .control(let session, let key):
            guard key.count == 1, let letter = key.first, ("a"..."z").contains(letter) else {
                return tell(.refused(command: command.id, reason: "Only Control with a letter can be sent."), id)
            }
            act(command, by: device, on: session, from: id) { $0.pressControl(letter) }
        case .changes(let session):
            changes(command, in: session, from: id)
        case .diff(let session, let path):
            diff(command, of: path, in: session, from: id)
        case .task:
            // Starting a task in a new worktree from the phone, which this version does not do. The phone is told so, and says to update.
            tell(.refused(command: command.id, reason: "This version of Farol cannot start tasks from the phone."), id)
        case .history(let session):
            // Read once, when the phone asks. Reading it on every change would cost the Mac for something rarely looked at.
            guard let terminal = pane(session)?.terminal else { return }
            tell(.history(session: session, text: terminal.historyText()), id)
        case .send(let session, let text):
            act(command, by: device, on: session, from: id) { pane in
                // While Farol holds a question, the agent shows nothing to type into, so a typed reply is the answer, as Other is on the Mac.
                let answer = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if let target = self.pane(session)?.session, let ask = target.ask, ask.pane == pane.id,
                   ask.questions.count == 1, let question = ask.questions.first, !answer.isEmpty {
                    return store.answer(target, with: [question.text: answer])
                }
                pane.pasteText(text)
                pasted[ObjectIdentifier(pane)] = (.now, text)
            }
        case .type(let session, let text):
            act(command, by: device, on: session, from: id) { $0.type(text) }
        case .key(let session, let key):
            act(command, by: device, on: session, from: id) { [weak self] pane in
                guard let key = TerminalView.Key(rawValue: key.rawValue) else { return }
                // Return right after a paste waits for the agent to take the paste in, or it is lost and the reply stays unsent.
                guard key == .enter, let paste = self?.pasted.removeValue(forKey: ObjectIdentifier(pane)) else { return pane.press(key) }
                let wait = RemoteTyping.returnDelay(afterPasteOf: paste.text, elapsed: Date.now.timeIntervalSince(paste.at))
                DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak pane] in pane?.press(.enter) }
            }
        }
    }

    /// The last paste from a phone into each pane, until the Return that sends it.
    private var pasted: [ObjectIdentifier: (at: Date, text: String)] = [:]

    /// Types into a session once, however many times the command arrives.
    private func act(_ command: RemoteCommand, by device: PairedDevice, on session: UUID, from id: UInt32, _ type: (TerminalView) -> Void) {
        if seen[device.key, default: SeenCommands()].insert(command.id) {
            guard let terminal = pane(session)?.terminal else {
                return tell(.refused(command: command.id, reason: "That session is closed."), id)
            }
            type(terminal)
        }
        tell(.done(command: command.id), id)
        tick()
    }

    /// Types the answer's number into the pane that asked, once, and only while it still asks the same thing.
    /// A tap that arrives after the question was answered on the Mac, or replaced by another, is refused rather than typed into it.
    private func answer(_ command: RemoteCommand, by device: PairedDevice, session id: UUID, request: String, choice: Int, from phone: UInt32) {
        guard seen[device.key, default: SeenCommands()].insert(command.id) else { return tell(.done(command: command.id), phone) }
        guard let (session, terminal) = pane(id), let (asking, asked) = session.request, asking == terminal.id, asked.id == request,
              session.agents[asking]?.status == .waiting else {
            return tell(.refused(command: command.id, reason: "That was already answered."), phone)
        }
        // Gone at once, so a second tap is refused rather than typed into whatever the agent asks next.
        session.request = nil
        // While Farol holds a question through its hook, the agent shows nothing to type into, so the answer goes back through the hook.
        if let ask = session.ask, ask.pane == asking, let question = ask.questions.first, ask.questions.count == 1,
           question.options.indices.contains(choice - 1) {
            store.answer(session, with: [question.text: question.options[choice - 1].label])
        } else {
            terminal.type(String(choice))
        }
        tell(.done(command: command.id), phone)
        tick()
    }

    private func respondAsk(_ command: RemoteCommand, by device: PairedDevice, session id: UUID, ask: UUID,
                            decision: RemoteAsk.Decision, from phone: UInt32) {
        if let previous = askResponses[device.key]?[command.id] { return tell(previous, phone) }
        guard let (session, terminal) = pane(id), let held = session.ask, held.id == ask, held.pane == terminal.id,
              session.agentIsWaiting else {
            return finishAsk(.refused(command: command.id, reason: "That question is no longer waiting."), command: command, device: device, phone: phone)
        }
        switch decision {
        case .submit(let answers):
            guard let values = Self.answers(answers, to: held.questions) else {
                return finishAsk(.refused(command: command.id, reason: "Choose an answer for every question."), command: command, device: device, phone: phone)
            }
            store.answer(session, with: values)
        case .discuss:
            store.chat(session)
        case .inTerminal:
            store.answer(session, with: nil)
        }
        finishAsk(.done(command: command.id), command: command, device: device, phone: phone)
        tick()
    }

    private func finishAsk(_ event: RemoteEvent, command: RemoteCommand, device: PairedDevice, phone: UInt32) {
        var replies = askResponses[device.key] ?? [:]
        if replies.count >= 100 { replies.removeValue(forKey: replies.keys.first!) }
        replies[command.id] = event
        askResponses[device.key] = replies
        tell(event, phone)
    }

    private static func answers(_ submitted: [RemoteAsk.Answer], to questions: [AgentQuestion]) -> [String: String]? {
        guard submitted.count == questions.count, Set(questions.map(\.text)).count == questions.count,
              Set(submitted.map(\.question)).count == submitted.count else { return nil }
        var values: [String: String] = [:]
        for answer in submitted {
            guard questions.indices.contains(answer.question) else { return nil }
            let question = questions[answer.question]
            guard Set(answer.choices).count == answer.choices.count,
                  answer.choices.allSatisfy({ question.options.indices.contains($0) }),
                  question.multiSelect || answer.choices.count <= 1 else { return nil }
            let words = answer.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard question.multiSelect || words.isEmpty || answer.choices.isEmpty else { return nil }
            let labels = answer.choices.map { question.options[$0].label }
            let parts = labels + (words.isEmpty ? [] : [words])
            guard !parts.isEmpty else { return nil }
            values[question.text] = AskHook.join(parts)
        }
        return values
    }

    private func tell(_ event: RemoteEvent, _ id: UInt32) {
        guard let frame = phones[id]?.link.seal(event) else { return }
        send(frame, to: id)
    }

    private func send(_ frame: WireFrame, to id: UInt32) {
        guard let payload = try? JSONEncoder().encode(frame) else { return }
        connection?.send(RelayFrame.encode(payload, to: id))
    }

    // MARK: New sessions

    /// The folders a session is open in, its repository's when it has one, then the home folder, where a new tab opens anyway.
    /// Home is there so a phone can open the first session when none is. A phone opens a session in one of these, never any folder on the Mac.
    private var projects: [String] {
        var seen = Set<String>()
        return (store.ordered.map { $0.repoRoot ?? $0.directory } + [NSHomeDirectory()]).filter { seen.insert($0).inserted }
    }

    /// The session each `open` made, so one a phone sends again after a dropped connection is answered and not opened twice.
    private var opened: [UUID: UUID] = [:]

    /// A new session in a project, like a new tab: the agent running in it, or a plain shell.
    private func open(_ command: RemoteCommand, by device: PairedDevice, in project: String, with agent: String?, from id: UInt32) {
        if let session = opened[command.id] { return tell(.opened(command: command.id, session: session), id) }
        let folder = agent.flatMap { agent in AgentFolder.find().first { $0.id == agent } }
        guard projects.contains(project), agent == nil || folder != nil else {
            return tell(.refused(command: command.id, reason: "The Mac could not open that session. Pick the project again and retry."), id)
        }
        let pane = store.create(directory: project, run: folder?.command()).panes.focused.id
        opened[command.id] = pane
        tell(.opened(command: command.id, session: pane), id)
        tick()
    }

    /// Closes a split pane, or a session as its tab's close button would, but never the last one: closing that quits Farol, and the phone with it.
    /// A worktree session keeps its worktree. Removing that asks questions only the Mac's own close button answers.
    private func close(_ command: RemoteCommand, by device: PairedDevice, session id: UUID, from phone: UInt32) {
        guard seen[device.key, default: SeenCommands()].insert(command.id) else { return tell(.done(command: command.id), phone) }
        guard let (session, terminal) = pane(id) else { return tell(.done(command: command.id), phone) }
        if session.panes.remove(terminal) {
            tell(.done(command: command.id), phone)
            return tick()
        }
        guard store.sessions.count > 1 else {
            return tell(.refused(command: command.id, reason: "Farol keeps its last session open. Open another one first."), phone)
        }
        store.close(session)
        tell(.done(command: command.id), phone)
        tick()
    }

    // MARK: Conversation

    /// Reads a log off the main thread, then hands its messages back on it.
    private func read(_ log: String, then use: @escaping ([Transcript.Message]) -> Void) {
        reading.async { [weak self] in
            guard let self else { return }
            let transcript = transcripts[log] ?? Transcript(url: URL(fileURLWithPath: log))
            transcripts[log] = transcript
            let changed = transcript.refresh()
            let messages = transcript.messages, revised = transcript.revised
            DispatchQueue.main.async {
                // What the agent wrote since goes to the phones following the log too, since its watch now finds nothing new.
                if changed { self.logChanged(log, messages, revised: revised) }
                use(messages)
            }
        }
    }

    /// The latest page of a session's conversation, then what follows while it is watched, or a page further back.
    private func conversation(_ command: RemoteCommand, of session: UUID, before: String?, from id: UInt32) {
        let asked = pane(session)
        guard let log = asked.flatMap({ $0.session.logs[$0.terminal.id] })?.log else {
            // An agent that has not said anything yet has no log, and its conversation is empty rather than missing.
            if let asked, asked.session.agentRuns(in: asked.terminal.id), before == nil {
                phones[id]?.toldEmpty = session
                return tell(.conversation(session: session, messages: [], place: .latest, more: false), id)
            }
            return tell(.refused(command: command.id, reason: "This session has no agent conversation to show."), id)
        }
        guard let before else { return openConversation(of: session, log: log, for: id) }
        read(log) { [weak self] messages in
            guard let self, phones[id] != nil else { return }
            guard let end = messages.firstIndex(where: { $0.id == before }) else {
                return tell(.refused(command: command.id, reason: "That part of the conversation was rewound."), id)
            }
            let start = Self.pageStart(messages, end: end)
            tell(.conversation(session: session, messages: messages[start..<end].map(Self.remote), place: .before(before), more: start > 0), id)
        }
    }

    private func openConversation(of session: UUID, log: String, for id: UInt32) {
        phones[id]?.conversation = (session, log, nil)
        read(log) { [weak self] messages in
            guard let self, phones[id]?.conversation?.log == log else { return }
            sendLatest(messages, of: session, to: id)
        }
    }

    private func sendLatest(_ messages: [Transcript.Message], of session: UUID, to id: UInt32) {
        let start = Self.pageStart(messages, end: messages.count)
        phones[id]?.conversation?.last = messages.last?.id
        tell(.conversation(session: session, messages: messages[start...].map(Self.remote), place: .latest, more: start > 0), id)
    }

    /// Sends the phones reading a log what the agent just wrote, and the messages they have that changed, like a tool you said no to.
    /// After a rewind, or more than a page, they get the latest page instead, as does one whose page was empty.
    private func logChanged(_ log: String, _ messages: [Transcript.Message], revised: Set<String>) {
        for (id, phone) in phones {
            guard let (session, current, last) = phone.conversation, current == log, phone.watching == session else { continue }
            if let last, let index = messages.lastIndex(where: { $0.id == last }), Self.pageStart(messages, end: messages.count) <= index + 1 {
                let changed = messages[...index].filter { revised.contains($0.id) }
                if !changed.isEmpty { tell(.conversation(session: session, messages: changed.map(Self.remote), place: .changed, more: false), id) }
                guard index + 1 < messages.count else { continue }
                phones[id]?.conversation?.last = messages.last?.id
                tell(.conversation(session: session, messages: messages[(index + 1)...].map(Self.remote), place: .after(last), more: false), id)
            } else {
                sendLatest(messages, of: session, to: id)
            }
        }
    }

    /// Watches the logs phones read, and only those. A few logs read last stay in memory, so opening a session again is quick.
    private func followLogs() {
        let read = Set(phones.values.compactMap { phone in phone.conversation.flatMap { phone.watching == $0.session ? $0.log : nil } })
        for (log, watch) in logWatches where !read.contains(log) {
            watch.cancel()
            logWatches[log] = nil
            reading.async { [weak self] in
                if let self, transcripts.count > 8 { transcripts[log] = nil }
            }
        }
        for log in read where logWatches[log] == nil {
            // Claude Code names its log before writing it. Until the file is there, this is tried again at every tick.
            let file = Darwin.open(log, O_EVTONLY)
            guard file >= 0 else { continue }
            let watch = DispatchSource.makeFileSystemObjectSource(fileDescriptor: file, eventMask: [.extend, .write], queue: reading)
            watch.setEventHandler { [weak self] in
                guard let self, let transcript = transcripts[log], transcript.refresh() else { return }
                let messages = transcript.messages, revised = transcript.revised
                DispatchQueue.main.async { self.logChanged(log, messages, revised: revised) }
            }
            watch.setCancelHandler { Darwin.close(file) }
            watch.resume()
            logWatches[log] = watch
            // What was written before the watch began.
            reading.async { [weak self] in
                guard let self else { return }
                let transcript = transcripts[log] ?? Transcript(url: URL(fileURLWithPath: log))
                transcripts[log] = transcript
                guard transcript.refresh() else { return }
                let messages = transcript.messages, revised = transcript.revised
                DispatchQueue.main.async { self.logChanged(log, messages, revised: revised) }
            }
        }
    }

    /// Where a page ending at `end` starts: up to 60 messages, and well under the relay's 256 KB a message.
    private static func pageStart(_ messages: [Transcript.Message], end: Int) -> Int {
        var start = end, bytes = 0
        while start > 0, end - start < 60 {
            let message = messages[start - 1]
            bytes += message.text.utf8.count + (message.detail?.utf8.count ?? 0) + 100
            if bytes > 150_000, start < end { break }
            start -= 1
        }
        return start
    }

    private static func remote(_ request: AgentRequest) -> RemoteRequest {
        RemoteRequest(id: request.id, tool: request.tool, title: request.title, detail: request.detail,
                      choices: request.choices.map { RemoteRequest.Choice(label: $0.label, detail: $0.detail) })
    }

    private static func remote(_ ask: PendingAsk) -> RemoteAsk {
        RemoteAsk(id: ask.id, questions: ask.questions.map { question in
            RemoteAsk.Question(text: question.text, header: question.header,
                               options: question.options.map { .init(label: $0.label, detail: $0.detail.isEmpty ? nil : $0.detail) },
                               multiSelect: question.multiSelect)
        })
    }

    private static func remote(_ message: Transcript.Message) -> RemoteMessage {
        let role: RemoteMessage.Role = switch message.role {
        case .you: .you
        case .agent: .agent
        case .tool: .tool
        }
        let outcome: RemoteMessage.Outcome? = switch message.outcome {
        case .stopped: .stopped
        case .failed: .failed
        case nil: nil
        }
        return RemoteMessage(id: message.id, role: role, text: message.text, tool: message.tool, detail: message.detail, outcome: outcome)
    }

    // MARK: Commands

    /// What the agent in a session takes after a slash, read off the main thread since it reads a few dozen small files.
    private func commands(_ command: RemoteCommand, of id: UUID, from phone: UInt32) {
        guard let (session, terminal) = pane(id) else {
            return tell(.refused(command: command.id, reason: "That session is closed."), phone)
        }
        let log = session.logs[terminal.id]?.log, project = session.repoRoot ?? session.directory
        DispatchQueue.global(qos: .userInitiated).async {
            let commands = AgentCommands.list(log: log, project: project).map { RemoteAgentCommand(name: $0.name, detail: $0.detail, menu: $0.menu, mention: $0.mention) }
            DispatchQueue.main.async { [weak self] in self?.tell(.commands(session: id, commands: commands), phone) }
        }
    }

    // MARK: Pictures

    /// Pictures from phones, in the caches folder, where macOS may also clear them.
    private lazy var inbox: AttachmentInbox = {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let inbox = AttachmentInbox(folder: caches.appendingPathComponent("Farol/Attachments"), maxSize: RemoteAttachment.maxSize)
        inbox.sweep()
        return inbox
    }()

    /// One part of a picture. Each is answered, so the phone sends the next, and the last with where the picture is.
    private func attach(_ command: RemoteCommand, session: UUID, attachment: UUID, part: Int, of parts: Int, data: Data, from id: UInt32) {
        guard pane(session) != nil else {
            return tell(.refused(command: command.id, reason: "That session is closed."), id)
        }
        do {
            if let file = try inbox.take(attachment, part: part, of: parts, data: data) {
                tell(.attached(command: command.id, attachment: attachment, path: file.path), id)
            } else {
                tell(.done(command: command.id), id)
            }
        } catch AttachmentInbox.Problem.notAnImage {
            tell(.refused(command: command.id, reason: "Only a photo or a screenshot can be attached."), id)
        } catch AttachmentInbox.Problem.tooLarge {
            tell(.refused(command: command.id, reason: "That picture is too large to attach."), id)
        } catch {
            tell(.refused(command: command.id, reason: "The Mac could not keep that picture. Attach it again."), id)
        }
    }

    // MARK: Changes

    /// The repository a session works in, and what the review panel compares it with. Nil outside git.
    private func repository(of session: UUID) -> (directory: String, scope: Diff.Scope)? {
        guard let session = pane(session)?.session else { return nil }
        let directory = session.repoRoot ?? session.directory
        return (directory, Diff.defaultScope(in: directory))
    }

    /// The changed files, as the review panel lists them. Git runs off the main thread, as it does for the panel.
    private func changes(_ command: RemoteCommand, in session: UUID, from id: UInt32) {
        guard let (directory, scope) = repository(of: session) else {
            return tell(.refused(command: command.id, reason: "That session is closed."), id)
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let files = try? Diff.files(in: directory, scope)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                guard let files else {
                    return tell(.refused(command: command.id, reason: "This session is not in a git repository."), id)
                }
                tell(.changes(session: session, scope: Self.label(scope), files: files.map(Self.change)), id)
            }
        }
    }

    /// One file as a unified diff, cut short so a message stays under the relay's limit.
    private func diff(_ command: RemoteCommand, of path: String, in session: UUID, from id: UInt32) {
        guard let (directory, scope) = repository(of: session) else {
            return tell(.refused(command: command.id, reason: "That session is closed."), id)
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let file = (try? Diff.files(in: directory, scope))?.first { $0.path == path }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                guard let file else { return tell(.refused(command: command.id, reason: "That file has no changes any more."), id) }
                tell(.diff(session: session, path: path, text: Self.unified(file)), id)
            }
        }
    }

    private static func label(_ scope: Diff.Scope) -> String {
        switch scope {
        case .uncommitted: "Uncommitted"
        case .branch(let base): "Since \(base)"
        case .commit(let hash): "Commit \(hash.prefix(7))"
        case .request(let number): "Pull request #\(number)"
        }
    }

    private static func change(_ file: Diff.File) -> RemoteChange {
        let status: RemoteChange.Status = switch file.status {
        case .modified: .modified
        case .added: .added
        case .deleted: .deleted
        case .renamed: .renamed
        }
        return RemoteChange(path: file.path, oldPath: file.oldPath, status: status, added: file.added, removed: file.removed, binary: file.isBinary)
    }

    private static func unified(_ file: Diff.File, limit: Int = 120_000) -> String {
        if file.isBinary { return "Binary file" }
        var text = ""
        for hunk in file.hunks {
            text += "@@ -\(hunk.oldStart) +\(hunk.newStart) @@\n"
            for line in hunk.lines {
                let sign = switch line.kind { case .added: "+"; case .removed: "-"; case .context: " " }
                text += sign + line.text + "\n"
                if text.utf8.count > limit { return text + "… cut short, open it on the Mac for the rest" }
            }
        }
        return text
    }

    // MARK: Notifications

    /// Has the relay ask Apple to notify every paired phone when a session starts waiting or finishes.
    /// The relay is told which of the two. Which session it is goes along sealed, for the phone alone.
    func activityChanged(_ session: Session, from before: Session.Activity, to after: Session.Activity) {
        refreshAwake()
        guard let connection, before != after else { return }
        updateActivities()
        let notice: RemoteNotice? = switch after {
        case .waiting: .waiting
        case .done: .done
        default: nil
        }
        guard let notice else { return }
        // The pane that asks or is done, which is the session a phone opens.
        let panes = session.panes.terminals
        let pane = panes.count == 1 ? panes[0] : panes.first { session.activity(of: $0.id) == after } ?? session.panes.focused
        let name = session.label(of: pane)
        for target in pushTargets where target.notices?.contains(notice) ?? true {
            let sealed = target.key.flatMap {
                NoticeBox.seal(RemoteNoticeContent(session: pane.id, name: name, notice: notice), key: $0)
            }
            connection.send(RelayFrame.push(token: target.token, sandbox: target.sandbox, notice: notice, sealed: sealed))
        }
    }

    /// Has the relay update the Live Activity on each phone that has one, when what it shows changed.
    /// Once nothing waits or works it is ended.
    /// When something gets busy again, it is started on each phone that is not open, and an open one starts its own.
    private func updateActivities() {
        guard let connection else { return }
        let sessions = remoteSessions
        let busy = sessions.filter { $0.status == .waiting || $0.status == .stopped || $0.status == .working }
        for (place, target) in activityTargets.enumerated().reversed() where target.shown != busy {
            let key = pushTargets.first { $0.device == target.device }?.key
            let state = RemoteActivityState(sessions, key: key)
            // Urgent only when one more agent waits for you. Apple caps urgent pushes, and the rest can wait for the phone's next wake.
            let urgent = state.waiting > target.shown.filter { $0.status == .waiting || $0.status == .stopped }.count
            connection.send(RelayFrame.activity(token: target.token, sandbox: target.sandbox, event: state.isQuiet ? .end : .update, urgent: urgent, state: state))
            if state.isQuiet { activityTargets.remove(at: place) } else { activityTargets[place].shown = busy }
        }
        if busy.isEmpty { return starting.removeAll() }
        for target in pushTargets {
            guard let starts = target.starts, !connected.contains(target.device), !starting.contains(target.device),
                  !activityTargets.contains(where: { $0.device == target.device }) else { continue }
            starting.insert(target.device)
            let state = RemoteActivityState(sessions, key: target.key)
            connection.send(RelayFrame.activity(token: starts, sandbox: target.sandbox, event: .start, urgent: true, state: state))
        }
    }

    // MARK: Sessions

    /// Each pane is a session to a phone, so an agent in a split pane is listed, read and answered on its own.
    /// A tab of one pane is listed as the sidebar shows it, and its pane's id is the one a phone knows it by.
    private var remoteSessions: [RemoteSession] {
        store.ordered.flatMap { session in
            let panes = session.panes.terminals
            return panes.map { pane in
                RemoteSession(id: pane.id, name: session.label(of: pane), branch: session.branch,
                              status: RemoteStatus(rawValue: "\(session.status(of: pane))") ?? .idle,
                              agent: session.agent(in: pane), asking: session.asking(in: pane))
            }
        }
    }

    /// The pane a phone means by a session's id, and the session it is in.
    private func pane(_ id: UUID) -> (session: Session, terminal: TerminalView)? {
        for session in store.sessions {
            if let terminal = session.panes.terminals.first(where: { $0.id == id }) { return (session, terminal) }
        }
        return nil
    }

    /// Runs only while a phone is connected.
    private func watch() {
        guard timer == nil else { return }
        // ponytail: asks a few times a second while a phone is connected. Observing the store would send sooner and ask less.
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in self?.tick() }
    }

    /// Sends each phone what changed: the list, and the screen of the session it has open. Always in full.
    private func tick() {
        // A log named before it was written gets its watch once it is.
        followLogs()
        let sessions = remoteSessions
        for (id, phone) in phones where phone.device != nil {
            // Claude Code starts a new log after /clear, and its next hook says so.
            if let (session, log, _) = phone.conversation, phone.watching == session,
               let now = pane(session).flatMap({ $0.session.logs[$0.terminal.id] })?.log, now != log {
                openConversation(of: session, log: now, for: id)
            }
            // The log is known only once a hook names it: Codex names it after its first turn, and Claude Code after its first prompt.
            // The phone shows the terminal until then, so it is sent the conversation as soon as there is one rather than waiting to ask.
            if phone.conversation == nil, let watching = phone.watching, let (session, _) = pane(watching) {
                if let log = session.logs[watching]?.log {
                    openConversation(of: watching, log: log, for: id)
                } else if session.agentRuns(in: watching), phone.toldEmpty != watching {
                    // An agent just started, with nothing said: the phone leaves the terminal for its empty conversation.
                    phones[id]?.toldEmpty = watching
                    tell(.conversation(session: watching, messages: [], place: .latest, more: false), id)
                }
            }
            if phone.sessions != sessions {
                phones[id]?.sessions = sessions
                tell(.sessions(sessions), id)
            }
            if let watching = phone.watching, let (session, _) = pane(watching) {
                let request = session.request.flatMap { $0.pane == watching ? Self.remote($0.asked) : nil }
                if phone.request != .some(request) {
                    phones[id]?.request = .some(request)
                    tell(.request(session: watching, request: request), id)
                }
                if phone.asks {
                    let ask = session.ask.flatMap { $0.pane == watching ? Self.remote($0) : nil }
                    if phone.ask != .some(ask) {
                        phones[id]?.ask = .some(ask)
                        tell(.ask(session: watching, ask: ask), id)
                    }
                }
            }
            // Codex can keep a question on screen while its title says working. Keep that screen live so the phone can offer the terminal.
            guard let watching = phone.watching, let (session, terminal) = pane(watching),
                  case let activity = session.activity(of: watching),
                  !phone.saysTerminal || phone.terminal == watching || activity == .waiting ||
                  (activity == .working && terminal.foregroundProgram?.name == "codex"),
                  case let text = terminal.screenText, text != phone.screen else { continue }
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
