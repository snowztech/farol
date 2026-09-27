import AppKit
import GhosttyKit

/// One libghostty surface. Ghostty renders into this view, we forward size, focus and input.
public final class TerminalView: NSView {
    private(set) var surface: ghostty_surface_t?

    // Events from the running program. All called on the main thread.
    public var onTitleChange: ((String) -> Void)?
    public var onWorkingDirectoryChange: ((String) -> Void)?
    public var onNotification: ((_ title: String, _ body: String) -> Void)?
    public var onBell: (() -> Void)?
    /// Asks the user to approve a clipboard access. Without it, such requests are denied.
    public var onClipboardRequest: ((ClipboardRequest, @escaping (Bool) -> Void) -> Void)?
    public var onClose: (() -> Void)?
    /// This terminal became the focused one, by click or keyboard.
    public var onFocus: (() -> Void)?

    /// Search started, from ⌘F or a key binding. The text is pre-filled, for example from ⌘E.
    public var onSearchStart: ((String) -> Void)?
    public var onSearchEnd: (() -> Void)?
    /// The selected match (0 based) and the match count, nil while unknown.
    public var onSearchResults: ((_ selected: Int?, _ total: Int?) -> Void)?
    private var searchSelected: Int?
    private var searchTotal: Int?

    /// The latest title and folder the program reported, kept so a pane regaining focus can show them.
    public private(set) var title = ""
    public private(set) var workingDirectory: String?
    /// A key binding asked for something only the app can do. Called on the next main loop turn.
    public var onRequest: ((TerminalRequest) -> Void)?

    /// True while a program other than the idle shell is running, so closing would kill it.
    public var hasRunningProcess: Bool {
        surface.map { ghostty_surface_needs_confirm_quit($0) } ?? false
    }

    private var cursor = NSCursor.iBeam

    /// Stable for the life of the terminal. The app hands it to the shell so the shell can report back.
    public let id: UUID

    /// `command` nil runs the user's login shell. `environment` is added to what the shell inherits.
    public init(
        runtime: TerminalRuntime, workingDirectory: String? = nil, command: String? = nil,
        id: UUID = UUID(), environment: [String: String] = [:]
    ) {
        self.id = id
        self.workingDirectory = workingDirectory
        super.init(frame: NSRect(x: 0, y: 0, width: 900, height: 600))

        var cfg = ghostty_surface_config_new()
        cfg.platform_tag = GHOSTTY_PLATFORM_MACOS
        cfg.platform = ghostty_platform_u(
            macos: ghostty_platform_macos_s(nsview: Unmanaged.passUnretained(self).toOpaque()))
        cfg.userdata = Unmanaged.passUnretained(self).toOpaque()
        cfg.scale_factor = Double(NSScreen.main?.backingScaleFactor ?? 2)
        cfg.context = GHOSTTY_SURFACE_CONTEXT_TAB

        // Ghostty copies what it needs during ghostty_surface_new, so these only live for the call.
        let strings = environment.flatMap { [strdup($0.key)!, strdup($0.value)!] }
        defer { strings.forEach { free($0) } }
        var variables = stride(from: 0, to: strings.count, by: 2).map {
            ghostty_env_var_s(key: strings[$0], value: strings[$0 + 1])
        }

        surface = workingDirectory.withOptionalCString { wd in
            command.withOptionalCString { cmd in
                variables.withUnsafeMutableBufferPointer { buffer in
                    cfg.working_directory = wd
                    cfg.command = cmd
                    cfg.env_vars = buffer.baseAddress
                    cfg.env_var_count = buffer.count
                    return ghostty_surface_new(runtime.app, &cfg)
                }
            }
        }

        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .cursorUpdate, .activeInKeyWindow, .inVisibleRect],
            owner: self))
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    deinit {
        if let surface { ghostty_surface_free(surface) }
    }

    static func from(_ userdata: UnsafeMutableRawPointer) -> TerminalView {
        Unmanaged<TerminalView>.fromOpaque(userdata).takeUnretainedValue()
    }

    /// Hidden terminals keep running but stop rendering, so background sessions cost no GPU time.
    public func setVisible(_ visible: Bool) {
        isHidden = !visible
        if let surface { ghostty_surface_set_occlusion(surface, visible) }
    }

    /// Runs on the main thread during ghostty_app_tick. C strings are only valid for this call.
    func handle(_ action: ghostty_action_s) -> Bool {
        switch action.tag {
        case GHOSTTY_ACTION_SET_TITLE:
            guard let title = action.action.set_title.title else { return false }
            self.title = String(cString: title)
            onTitleChange?(self.title)
        case GHOSTTY_ACTION_PWD:
            guard let pwd = action.action.pwd.pwd else { return false }
            workingDirectory = String(cString: pwd)
            onWorkingDirectoryChange?(workingDirectory!)
        case GHOSTTY_ACTION_DESKTOP_NOTIFICATION:
            let n = action.action.desktop_notification
            onNotification?(n.title.map { String(cString: $0) } ?? "", n.body.map { String(cString: $0) } ?? "")
        case GHOSTTY_ACTION_RING_BELL:
            onBell?()
        case GHOSTTY_ACTION_OPEN_URL:
            let link = action.action.open_url
            guard let ptr = link.url else { return false }
            open(String(decoding: Data(bytes: ptr, count: Int(link.len)), as: UTF8.self))
        case GHOSTTY_ACTION_MOUSE_SHAPE:
            cursor = .ghostty(action.action.mouse_shape)
            if let window, bounds.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil)) {
                cursor.set()
            }
        case GHOSTTY_ACTION_START_SEARCH:
            let needle = action.action.start_search.needle.map { String(cString: $0) } ?? ""
            DispatchQueue.main.async { self.onSearchStart?(needle) }
        case GHOSTTY_ACTION_END_SEARCH:
            searchSelected = nil
            searchTotal = nil
            DispatchQueue.main.async { self.onSearchEnd?() }
        case GHOSTTY_ACTION_SEARCH_TOTAL:
            let total = action.action.search_total.total
            searchTotal = total >= 0 ? Int(total) : nil
            onSearchResults?(searchSelected, searchTotal)
        case GHOSTTY_ACTION_SEARCH_SELECTED:
            let selected = action.action.search_selected.selected
            searchSelected = selected >= 0 ? Int(selected) : nil
            onSearchResults?(searchSelected, searchTotal)
        case GHOSTTY_ACTION_MOUSE_VISIBILITY:
            NSCursor.setHiddenUntilMouseMoves(action.action.mouse_visibility == GHOSTTY_MOUSE_HIDDEN)
        default:
            guard let request = TerminalRequest(action), let onRequest else { return false }
            // Requests like closing this session free the surface Ghostty is still calling from.
            DispatchQueue.main.async { onRequest(request) }
        }
        return true
    }

    public override func cursorUpdate(with event: NSEvent) {
        cursor.set()
    }

    /// Opens a clicked link. Anything without a scheme is treated as a file path.
    private func open(_ link: String) {
        let url = URL(string: link).flatMap { $0.scheme == nil ? nil : $0 } ?? URL(fileURLWithPath: link)
        NSWorkspace.shared.open(url)
    }

    // MARK: Edit menu

    @objc public func copy(_ sender: Any?) { perform("copy_to_clipboard") }
    @objc public func paste(_ sender: Any?) { perform("paste_from_clipboard") }
    @objc public override func selectAll(_ sender: Any?) { perform("select_all") }

    // MARK: Search

    public func startSearch() { perform("start_search") }
    public func searchSelection() { perform("search_selection") }
    public func search(_ needle: String) { perform("search:\(needle)") }
    public func searchNext() { perform("navigate_search:next") }
    public func searchPrevious() { perform("navigate_search:previous") }
    public func endSearch() { perform("end_search") }

    private func perform(_ action: String) {
        guard let surface else { return }
        _ = ghostty_surface_binding_action(surface, action, UInt(action.utf8.count))
    }

    // MARK: Size and focus

    public override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        guard let surface else { return }
        let px = convertToBacking(newSize)
        ghostty_surface_set_size(surface, UInt32(px.width), UInt32(px.height))
    }

    public override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        guard let surface, let window else { return }
        let scale = window.backingScaleFactor
        ghostty_surface_set_content_scale(surface, scale, scale)
        setFrameSize(frame.size)
    }

    public override var acceptsFirstResponder: Bool { true }

    public override func becomeFirstResponder() -> Bool {
        if let surface { ghostty_surface_set_focus(surface, true) }
        onFocus?()
        return true
    }

    public override func resignFirstResponder() -> Bool {
        if let surface { ghostty_surface_set_focus(surface, false) }
        return true
    }

    // MARK: Keyboard

    /// Text an input method is still composing, like a dead key waiting for its letter.
    var markedText = ""
    /// Collects text inserted while a key press is interpreted, so it goes out with that key.
    var keyTextAccumulator: [String]?

    public override func keyDown(with event: NSEvent) {
        guard let surface else { return }
        let action = event.isARepeat ? GHOSTTY_ACTION_REPEAT : GHOSTTY_ACTION_PRESS
        let translated = translationEvent(for: event, surface: surface)

        let wasComposing = !markedText.isEmpty
        keyTextAccumulator = []
        defer { keyTextAccumulator = nil }
        interpretKeyEvents([translated])
        syncPreedit(clearIfNeeded: wasComposing)

        let inserted = keyTextAccumulator ?? []
        if wasComposing && !inserted.isEmpty {
            // A composition just finished (´ then e gives é). Send the result, not this key.
            inserted.forEach(sendText)
        } else if !inserted.isEmpty {
            inserted.forEach { sendKey(event, translated, action, text: plainText($0, translated)) }
        } else {
            sendKey(event, translated, action, text: keyText(translated), composing: wasComposing || !markedText.isEmpty)
        }
    }

    public override func keyUp(with event: NSEvent) {
        sendKey(event, event, GHOSTTY_ACTION_RELEASE, text: nil)
    }

    /// Without this, keys the input system doesn't handle (arrows, ctrl+key) would beep.
    public override func doCommand(by selector: Selector) {}

    /// Applies Ghostty's modifier rules, such as `macos-option-as-alt`, before macOS turns the key into text.
    private func translationEvent(for event: NSEvent, surface: ghostty_surface_t) -> NSEvent {
        let allowed = ghostty_surface_key_translation_mods(surface, ghosttyMods(event.modifierFlags))
        var flags = event.modifierFlags
        for (flag, mod) in [(NSEvent.ModifierFlags.shift, GHOSTTY_MODS_SHIFT), (.control, GHOSTTY_MODS_CTRL),
                            (.option, GHOSTTY_MODS_ALT), (.command, GHOSTTY_MODS_SUPER)] {
            if allowed.rawValue & mod.rawValue != 0 { flags.insert(flag) } else { flags.remove(flag) }
        }
        guard flags != event.modifierFlags else { return event }
        return NSEvent.keyEvent(
            with: event.type, location: event.locationInWindow, modifierFlags: flags,
            timestamp: event.timestamp, windowNumber: event.windowNumber, context: nil,
            characters: event.characters(byApplyingModifiers: flags) ?? "",
            charactersIgnoringModifiers: event.charactersIgnoringModifiers ?? "",
            isARepeat: event.isARepeat, keyCode: event.keyCode) ?? event
    }

    private func sendKey(
        _ event: NSEvent, _ translated: NSEvent, _ action: ghostty_input_action_e,
        text: String?, composing: Bool = false
    ) {
        guard let surface else { return }
        var key = ghostty_input_key_s()
        key.action = action
        key.keycode = UInt32(event.keyCode)
        key.mods = ghosttyMods(event.modifierFlags)
        // Ctrl and Cmd never produce text on macOS, everything else might have.
        key.consumed_mods = ghosttyMods(translated.modifierFlags.subtracting([.control, .command]))
        key.composing = composing
        if let scalar = event.characters(byApplyingModifiers: [])?.unicodeScalars.first {
            key.unshifted_codepoint = scalar.value
        }
        text.withOptionalCString { ptr in
            key.text = ptr
            _ = ghostty_surface_key(surface, key)
        }
    }

    /// Text that isn't tied to a key: a finished composition, the emoji picker, dictation.
    func sendText(_ text: String) {
        guard let surface, !text.isEmpty else { return }
        var key = ghostty_input_key_s()
        key.action = GHOSTTY_ACTION_PRESS
        text.withCString { ptr in
            key.text = ptr
            _ = ghostty_surface_key(surface, key)
        }
    }

    /// Ghostty encodes control keys itself, so send the plain character and skip function keys.
    private func keyText(_ event: NSEvent) -> String? {
        guard let chars = event.characters else { return nil }
        return plainText(chars, event)
    }

    private func plainText(_ chars: String, _ event: NSEvent) -> String? {
        guard chars.count == 1, let scalar = chars.unicodeScalars.first else { return chars }
        if scalar.value < 0x20 {
            return event.characters(byApplyingModifiers: event.modifierFlags.subtracting(.control))
        }
        if (0xF700...0xF8FF).contains(scalar.value) { return nil }
        return chars
    }

    /// Shows the text being composed at the cursor, or clears it.
    func syncPreedit(clearIfNeeded: Bool = true) {
        guard let surface else { return }
        if !markedText.isEmpty {
            markedText.withCString { ghostty_surface_preedit(surface, $0, UInt(markedText.utf8.count)) }
        } else if clearIfNeeded {
            ghostty_surface_preedit(surface, nil, 0)
        }
    }

    // MARK: Mouse

    public override func mouseDown(with event: NSEvent) { mouseButton(event, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_LEFT) }
    public override func mouseUp(with event: NSEvent) { mouseButton(event, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_LEFT) }
    public override func rightMouseDown(with event: NSEvent) { mouseButton(event, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_RIGHT) }
    public override func rightMouseUp(with event: NSEvent) { mouseButton(event, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_RIGHT) }
    public override func mouseMoved(with event: NSEvent) { mousePos(event) }
    public override func mouseDragged(with event: NSEvent) { mousePos(event) }

    public override func scrollWheel(with event: NSEvent) {
        guard let surface else { return }
        var x = event.scrollingDeltaX
        var y = event.scrollingDeltaY
        // Bit 0 of scroll mods is "precision" (trackpad). Ghostty scales line vs pixel deltas.
        var mods: ghostty_input_scroll_mods_t = 0
        if event.hasPreciseScrollingDeltas {
            mods |= 1
            x *= 2
            y *= 2
        }
        ghostty_surface_mouse_scroll(surface, x, y, mods)
    }

    private func mouseButton(_ event: NSEvent, _ state: ghostty_input_mouse_state_e, _ button: ghostty_input_mouse_button_e) {
        guard let surface else { return }
        if state == GHOSTTY_MOUSE_PRESS { window?.makeFirstResponder(self) }
        mousePos(event)
        _ = ghostty_surface_mouse_button(surface, state, button, ghosttyMods(event.modifierFlags))
    }

    private func mousePos(_ event: NSEvent) {
        guard let surface else { return }
        let p = convert(event.locationInWindow, from: nil)
        // Ghostty's origin is top-left, AppKit's is bottom-left.
        ghostty_surface_mouse_pos(surface, p.x, frame.height - p.y, ghosttyMods(event.modifierFlags))
    }
}

private func ghosttyMods(_ flags: NSEvent.ModifierFlags) -> ghostty_input_mods_e {
    var m: UInt32 = GHOSTTY_MODS_NONE.rawValue
    if flags.contains(.shift) { m |= GHOSTTY_MODS_SHIFT.rawValue }
    if flags.contains(.control) { m |= GHOSTTY_MODS_CTRL.rawValue }
    if flags.contains(.option) { m |= GHOSTTY_MODS_ALT.rawValue }
    if flags.contains(.command) { m |= GHOSTTY_MODS_SUPER.rawValue }
    if flags.contains(.capsLock) { m |= GHOSTTY_MODS_CAPS.rawValue }
    return ghostty_input_mods_e(m)
}

private extension Optional where Wrapped == String {
    func withOptionalCString<R>(_ body: (UnsafePointer<CChar>?) -> R) -> R {
        switch self {
        case .some(let s): return s.withCString(body)
        case .none: return body(nil)
        }
    }
}
