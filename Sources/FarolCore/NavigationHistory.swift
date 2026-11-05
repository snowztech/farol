import Foundation

/// Where you have been in the open file, so a jump to a definition can be undone and redone like a browser's back and forward.
public struct NavigationHistory: Equatable {
    public struct Place: Equatable {
        public let path: String
        public let line: Int

        public init(path: String, line: Int) {
            self.path = path
            self.line = line
        }
    }

    /// Enough to follow a long chain of definitions, and short enough that an old session doesn't grow it without end.
    static let limit = 100

    private var back: [Place] = []
    private var forward: [Place] = []

    public init() {}

    public var canGoBack: Bool { !back.isEmpty }
    public var canGoForward: Bool { !forward.isEmpty }

    /// Leaving `place` for somewhere else. What had been undone is gone, as in a browser, since this is a new path.
    public mutating func record(leaving place: Place) {
        forward.removeAll()
        // Looking again at where you already were adds nothing to go back to.
        guard back.last != place else { return }
        back.append(place)
        if back.count > Self.limit { back.removeFirst(back.count - Self.limit) }
    }

    /// The place before `current`, which becomes the one to go forward to. Places `isValid` refuses, like a deleted file, are dropped.
    public mutating func goBack(from current: Place, where isValid: (Place) -> Bool = { _ in true }) -> Place? {
        while let place = back.popLast() {
            guard isValid(place) else { continue }
            forward.append(current)
            return place
        }
        return nil
    }

    /// The place after `current`, which becomes the one to go back to.
    public mutating func goForward(from current: Place, where isValid: (Place) -> Bool = { _ in true }) -> Place? {
        while let place = forward.popLast() {
            guard isValid(place) else { continue }
            back.append(current)
            return place
        }
        return nil
    }
}
