import AppKit
import GhosttyKit

/// One libghostty surface. Ghostty renders into this view, we forward size, focus and input.
public final class TerminalView: NSView {
    private var surface: ghostty_surface_t?

    // Events from the running program. All called on the main thread.
    public var onTitleChange: ((String) -> Void)?
    public var onWorkingDirectoryChange: ((String) -> Void)?
    public var onNotification: ((_ title: String, _ body: String) -> Void)?
    public var onBell: (() -> Void)?
    public var onClose: (() -> Void)?

    /// `command` nil runs the user's login shell.
    public init(runtime: TerminalRuntime, workingDirectory: String? = nil, command: String? = nil) {
        super.init(frame: NSRect(x: 0, y: 0, width: 900, height: 600))

        var cfg = ghostty_surface_config_new()
        cfg.platform_tag = GHOSTTY_PLATFORM_MACOS
        cfg.platform = ghostty_platform_u(
            macos: ghostty_platform_macos_s(nsview: Unmanaged.passUnretained(self).toOpaque()))
        cfg.userdata = Unmanaged.passUnretained(self).toOpaque()
        cfg.scale_factor = Double(NSScreen.main?.backingScaleFactor ?? 2)
        cfg.context = GHOSTTY_SURFACE_CONTEXT_TAB

        surface = workingDirectory.withOptionalCString { wd in
            command.withOptionalCString { cmd in
                cfg.working_directory = wd
                cfg.command = cmd
                return ghostty_surface_new(runtime.app, &cfg)
            }
        }

        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect],
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
            onTitleChange?(String(cString: title))
        case GHOSTTY_ACTION_PWD:
            guard let pwd = action.action.pwd.pwd else { return false }
            onWorkingDirectoryChange?(String(cString: pwd))
        case GHOSTTY_ACTION_DESKTOP_NOTIFICATION:
            let n = action.action.desktop_notification
            onNotification?(n.title.map { String(cString: $0) } ?? "", n.body.map { String(cString: $0) } ?? "")
        case GHOSTTY_ACTION_RING_BELL:
            onBell?()
        default:
            return false
        }
        return true
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
        return true
    }

    public override func resignFirstResponder() -> Bool {
        if let surface { ghostty_surface_set_focus(surface, false) }
        return true
    }

    // MARK: Keyboard
    // TODO: no IME (dead keys, CJK input). Needs NSTextInputClient + ghostty_surface_preedit.

    public override func keyDown(with event: NSEvent) {
        sendKey(event, event.isARepeat ? GHOSTTY_ACTION_REPEAT : GHOSTTY_ACTION_PRESS)
    }

    public override func keyUp(with event: NSEvent) {
        sendKey(event, GHOSTTY_ACTION_RELEASE)
    }

    private func sendKey(_ event: NSEvent, _ action: ghostty_input_action_e) {
        guard let surface else { return }
        var key = ghostty_input_key_s()
        key.action = action
        key.keycode = UInt32(event.keyCode)
        key.mods = ghosttyMods(event.modifierFlags)
        // Ctrl and Cmd never produce text on macOS, everything else might have.
        key.consumed_mods = ghosttyMods(event.modifierFlags.subtracting([.control, .command]))
        if let scalar = event.characters(byApplyingModifiers: [])?.unicodeScalars.first {
            key.unshifted_codepoint = scalar.value
        }

        let text = action == GHOSTTY_ACTION_RELEASE ? nil : keyText(event)
        text.withOptionalCString { ptr in
            key.text = ptr
            _ = ghostty_surface_key(surface, key)
        }
    }

    /// Ghostty encodes control keys itself, so send the plain character and skip function keys.
    private func keyText(_ event: NSEvent) -> String? {
        guard let chars = event.characters else { return nil }
        if chars.count == 1, let scalar = chars.unicodeScalars.first {
            if scalar.value < 0x20 {
                return event.characters(byApplyingModifiers: event.modifierFlags.subtracting(.control))
            }
            if (0xF700...0xF8FF).contains(scalar.value) { return nil }
        }
        return chars
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
