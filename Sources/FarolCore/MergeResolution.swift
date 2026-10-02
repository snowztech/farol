import Foundation

/// The decisions taken on a conflicted file and the result they give, piece by piece.
/// A value, so the merge view can keep one per file and snapshot it for undo.
public struct MergeResolution: Equatable {
    public struct Decision: Equatable {
        /// True taken, false left out, nil not decided yet.
        public var mine: Bool?
        public var other: Bool?
        /// Sides taken, in the order you took them. True is yours.
        public var order: [Bool] = []
        /// Typed in by hand, which counts as deciding both sides.
        public var edited = false
        /// Taken when the file opened, because only one side changed it.
        public var auto = false

        public init(mine: Bool? = nil, other: Bool? = nil, order: [Bool] = [], edited: Bool = false, auto: Bool = false) {
            self.mine = mine
            self.other = other
            self.order = order
            self.edited = edited
            self.auto = auto
        }
    }

    public enum Unit: Equatable {
        /// A line all three versions share, by its index in the ancestor.
        case line(Int)
        case chunk(Int)
    }

    public let merge: ThreeWay
    /// The result cut into shared lines and chunks, in file order.
    public let units: [Unit]
    /// What the result holds for each unit, every line ending in a newline. Hand edits included.
    public private(set) var texts: [String]
    public private(set) var decisions: [Decision]
    /// The unit of each chunk.
    private let chunkUnits: [Int]

    /// Starts from what git merged alone: changes only one side made, or both made alike, are taken. Conflicts show the ancestor.
    public init(_ merge: ThreeWay) {
        self.merge = merge
        var units: [Unit] = [], texts: [String] = [], chunkUnits: [Int] = []
        var at = 0
        func addLines(upTo end: Int) {
            while at < end {
                units.append(.line(at))
                texts.append(merge.base[at] + "\n")
                at += 1
            }
        }
        var startLines: [Int: [String]] = [:]
        for case .chunk(let index, let lines) in merge.start() { startLines[index] = lines }
        for (index, chunk) in merge.chunks.enumerated() {
            addLines(upTo: chunk.base.lowerBound)
            chunkUnits.append(units.count)
            units.append(.chunk(index))
            texts.append(Self.text(startLines[index] ?? []))
            at = chunk.base.upperBound
        }
        addLines(upTo: merge.base.count)
        self.units = units
        self.texts = texts
        self.chunkUnits = chunkUnits
        decisions = merge.chunks.map { chunk in
            switch chunk.kind {
            case .mine: Decision(mine: true, order: [true], auto: true)
            case .other: Decision(other: true, order: [false], auto: true)
            case .same: Decision(mine: true, other: true, order: [true], auto: true)
            case .conflict: Decision()
            }
        }
    }

    public func unit(ofChunk index: Int) -> Int { chunkUnits[index] }

    /// The sides that have a decision to make: one for a change only one side made, or made alike, two for a conflict.
    public func sides(_ index: Int) -> (mine: Bool, other: Bool) {
        switch merge.chunks[index].kind {
        case .mine: (true, false)
        case .other: (false, true)
        case .same, .conflict: (true, true)
        }
    }

    public func isDecided(_ index: Int) -> Bool {
        let decision = decisions[index], sides = sides(index)
        return decision.edited || ((!sides.mine || decision.mine != nil) && (!sides.other || decision.other != nil))
    }

    /// Decisions still to make in the file. A change made alike on both sides is one.
    public var openDecisions: Int {
        merge.chunks.indices.reduce(0) { total, index in
            let decision = decisions[index], sides = sides(index)
            if decision.edited { return total }
            if merge.chunks[index].kind == .same { return total + (decision.mine == nil ? 1 : 0) }
            return total + (sides.mine && decision.mine == nil ? 1 : 0) + (sides.other && decision.other == nil ? 1 : 0)
        }
    }

    public var conflictCount: Int { merge.chunks.filter { $0.kind == .conflict }.count }
    public var autoCount: Int { decisions.filter(\.auto).count }

    /// The file as it will be written.
    public var result: String {
        var text = texts.joined()
        if !merge.trailingNewline, text.hasSuffix("\n") { text.removeLast() }
        return text
    }

    /// What a chunk's decisions put in the result: the sides taken in order, else the ancestor.
    public func decidedText(_ index: Int) -> String {
        let chunk = merge.chunks[index], decision = decisions[index]
        return Self.text(decision.order.isEmpty ? merge.baseLines(chunk) : decision.order.flatMap { merge.lines(chunk, mine: $0) })
    }

    /// Takes or leaves out one side of a chunk. Deciding again the same way takes the decision back.
    /// Hand edits to the chunk are replaced by what the decisions give.
    public mutating func decide(_ index: Int, mine side: Bool, take: Bool) {
        var decision = decisions[index]
        let current = side ? decision.mine : decision.other
        let value: Bool? = current == take ? nil : take
        // Both sides wrote the same lines, so one answer covers both.
        if merge.chunks[index].kind == .same {
            decision.mine = value
            decision.other = value
            decision.order = value == true ? [true] : []
        } else {
            if side { decision.mine = value } else { decision.other = value }
            decision.order.removeAll { $0 == side }
            if value == true { decision.order.append(side) }
        }
        decision.edited = false
        decision.auto = false
        decisions[index] = decision
        texts[chunkUnits[index]] = decidedText(index)
    }

    /// Takes one side's changes everywhere and leaves the other's out, so the result reads as that side's file.
    public mutating func acceptAll(mine side: Bool) {
        for index in merge.chunks.indices {
            let sides = sides(index)
            var decision = Decision()
            if sides.mine { decision.mine = side }
            if sides.other { decision.other = !side }
            if merge.chunks[index].kind == .same { decision.other = side }
            if side ? sides.mine : sides.other { decision.order = [side] }
            decisions[index] = decision
            texts[chunkUnits[index]] = decidedText(index)
        }
    }

    /// Puts typed text in a unit. A chunk counts as edited while its text differs from what its decisions give.
    /// So an undo that brings that text back clears it. Returns whether the chunk's edited mark changed.
    @discardableResult
    public mutating func edit(_ unit: Int, to text: String) -> Bool {
        texts[unit] = text
        guard case .chunk(let index) = units[unit] else { return false }
        let edited = text != decidedText(index)
        guard decisions[index].edited != edited else { return false }
        decisions[index].edited = edited
        return true
    }

    /// The same work on the file read again with whitespace ignored or not, which leaves chunks where they are and may change their kind.
    /// What you decided or typed is kept, and chunks you hadn't touched start as the new reading has them.
    /// Nil when the chunks moved, since nothing then says which decision goes where.
    public func carried(to merge: ThreeWay) -> MergeResolution? {
        let place = { (chunk: ThreeWay.Chunk) in [chunk.base, chunk.mine, chunk.other] }
        guard merge.base == self.merge.base, merge.chunks.map(place) == self.merge.chunks.map(place) else { return nil }
        var next = MergeResolution(merge)
        for (unit, piece) in units.enumerated() {
            guard case .chunk(let index) = piece else {
                next.texts[unit] = texts[unit]
                continue
            }
            let decision = decisions[index]
            if merge.chunks[index].kind == self.merge.chunks[index].kind {
                next.texts[unit] = texts[unit]
                next.decisions[index] = decision
            } else if !decision.auto, decision.edited || decision.mine != nil || decision.other != nil, texts[unit] != next.texts[unit] {
                // The sides to decide changed, so your result for the chunk stays as if typed in.
                next.texts[unit] = texts[unit]
                next.decisions[index] = Decision(edited: true)
            }
        }
        return next
    }

    private static func text(_ lines: [String]) -> String { lines.map { $0 + "\n" }.joined() }
}
