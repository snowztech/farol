import AppKit
import GhosttyKit

/// Something a key binding asked for that only the app can do, like opening a session.
/// Ghostty's defaults map most of these (⌘N, ⇧⌘W, ⌃⌘F), and users can rebind them in their config.
public enum TerminalRequest {
    case newSession
    case closeSession
    case closeWindow
    case quit
    /// 0 based. Negative values never reach the app: previous and next have their own cases.
    case gotoSession(Int)
    case previousSession
    case nextSession
    case lastSession
    case toggleFullscreen
    case reloadConfig
    case openSettings

    init?(_ action: ghostty_action_s) {
        switch action.tag {
        case GHOSTTY_ACTION_NEW_WINDOW, GHOSTTY_ACTION_NEW_TAB: self = .newSession
        case GHOSTTY_ACTION_CLOSE_TAB: self = .closeSession
        case GHOSTTY_ACTION_CLOSE_WINDOW, GHOSTTY_ACTION_CLOSE_ALL_WINDOWS: self = .closeWindow
        case GHOSTTY_ACTION_QUIT: self = .quit
        case GHOSTTY_ACTION_TOGGLE_FULLSCREEN: self = .toggleFullscreen
        case GHOSTTY_ACTION_RELOAD_CONFIG: self = .reloadConfig
        case GHOSTTY_ACTION_OPEN_CONFIG: self = .openSettings
        case GHOSTTY_ACTION_GOTO_TAB:
            switch action.action.goto_tab {
            case GHOSTTY_GOTO_TAB_PREVIOUS: self = .previousSession
            case GHOSTTY_GOTO_TAB_NEXT: self = .nextSession
            case GHOSTTY_GOTO_TAB_LAST: self = .lastSession
            default: self = .gotoSession(Int(action.action.goto_tab.rawValue) - 1)
            }
        default:
            return nil
        }
    }
}

extension NSCursor {
    /// The closest macOS cursor for a shape a terminal program asked for.
    static func ghostty(_ shape: ghostty_action_mouse_shape_e) -> NSCursor {
        switch shape {
        case GHOSTTY_MOUSE_SHAPE_TEXT: return .iBeam
        case GHOSTTY_MOUSE_SHAPE_VERTICAL_TEXT: return .iBeamCursorForVerticalLayout
        case GHOSTTY_MOUSE_SHAPE_POINTER: return .pointingHand
        case GHOSTTY_MOUSE_SHAPE_CROSSHAIR, GHOSTTY_MOUSE_SHAPE_CELL: return .crosshair
        case GHOSTTY_MOUSE_SHAPE_GRAB: return .openHand
        case GHOSTTY_MOUSE_SHAPE_GRABBING, GHOSTTY_MOUSE_SHAPE_MOVE: return .closedHand
        case GHOSTTY_MOUSE_SHAPE_NOT_ALLOWED, GHOSTTY_MOUSE_SHAPE_NO_DROP: return .operationNotAllowed
        case GHOSTTY_MOUSE_SHAPE_COPY: return .dragCopy
        case GHOSTTY_MOUSE_SHAPE_ALIAS: return .dragLink
        case GHOSTTY_MOUSE_SHAPE_CONTEXT_MENU: return .contextualMenu
        case GHOSTTY_MOUSE_SHAPE_EW_RESIZE, GHOSTTY_MOUSE_SHAPE_COL_RESIZE,
             GHOSTTY_MOUSE_SHAPE_E_RESIZE, GHOSTTY_MOUSE_SHAPE_W_RESIZE: return .resizeLeftRight
        case GHOSTTY_MOUSE_SHAPE_NS_RESIZE, GHOSTTY_MOUSE_SHAPE_ROW_RESIZE,
             GHOSTTY_MOUSE_SHAPE_N_RESIZE, GHOSTTY_MOUSE_SHAPE_S_RESIZE: return .resizeUpDown
        default: return .arrow
        }
    }
}
