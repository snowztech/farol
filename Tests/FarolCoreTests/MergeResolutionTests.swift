import Foundation
import Testing
@testable import FarolCore

// The queue file from the design: every kind of chunk in one place.
private let base = """
import { api } from "./api"

const DELAY = 500

export class Queue {
  push(change) {
    this.pending.push(change)
  }

  async flush() {
    await api.send(change)
    this.pending.shift()
    await sleep(DELAY)
  }

  get size() {
    return this.pending.length
  }

  clear() {
    this.pending = []
  }
}

"""

private let mine = """
import { api } from "./api"
import { log } from "./log"

const RETRY_MS = 500

export class Queue {
  push(change) {
    this.pending.push(change)
    log("queued")
  }

  async flush() {
    await api.post(change)
    this.pending.shift()
    await sleep(RETRY_MS)
  }

  get size() {
    return this.pending.length
  }

  clear() {
    this.pending.length = 0
  }
}

"""

private let other = """
import { api } from "./api"
import { backoff } from "./backoff"

const DELAY = 500

export class Queue {
  push(change) {
    this.pending.push(change)
  }

  async flush() {
    await api.post(change)
    this.pending.shift()
    attempt++
    await sleep(backoff(attempt))
  }

  get size() {
    return this.pending.length
  }
}

"""


@Test func startsWithOneSidedChangesTaken() {
    let merge = ThreeWay(base: base, mine: mine, other: other)
    let resolution = MergeResolution(merge)
    let start = merge.start().flatMap { piece -> [String] in
        switch piece {
        case .stable(let lines), .chunk(_, let lines): lines
        }
    }
    #expect(resolution.result == merge.text(start))
    #expect(resolution.decisions.map(\.auto) == [false, true, true, true, false, false])
    #expect(resolution.decisions[1] == .init(mine: true, order: [true], auto: true))
    #expect(resolution.decisions[3] == .init(mine: true, other: true, order: [true], auto: true))
    #expect(resolution.isDecided(1) && !resolution.isDecided(0))
    // Three conflicts, each with two sides to decide.
    #expect(resolution.openDecisions == 6)
    #expect(resolution.conflictCount == 3)
    #expect(resolution.autoCount == 3)
    #expect(resolution.units.filter { if case .chunk = $0 { true } else { false } }.count == merge.chunks.count)
}

@Test func takesSidesInTheOrderTaken() {
    let merge = ThreeWay(base: base, mine: mine, other: other)
    var resolution = MergeResolution(merge)
    let imports = resolution.unit(ofChunk: 0)
    resolution.decide(0, mine: false, take: true)
    #expect(resolution.texts[imports] == "import { backoff } from \"./backoff\"\n")
    #expect(!resolution.isDecided(0))
    #expect(resolution.openDecisions == 5)
    resolution.decide(0, mine: true, take: true)
    #expect(resolution.texts[imports] == "import { backoff } from \"./backoff\"\nimport { log } from \"./log\"\n")
    #expect(resolution.decisions[0].order == [false, true])
    #expect(resolution.isDecided(0))
    #expect(resolution.openDecisions == 4)
    #expect(resolution.result.contains("import { api } from \"./api\"\nimport { backoff } from \"./backoff\"\nimport { log }"))
}

@Test func leavingBothSidesOutKeepsTheAncestor() {
    let merge = ThreeWay(base: base, mine: mine, other: other)
    var resolution = MergeResolution(merge)
    let flush = resolution.unit(ofChunk: 4)
    resolution.decide(4, mine: true, take: false)
    #expect(resolution.decisions[4].mine == false)
    #expect(!resolution.isDecided(4))
    resolution.decide(4, mine: false, take: false)
    #expect(resolution.isDecided(4))
    #expect(resolution.texts[flush] == merge.baseLines(merge.chunks[4]).map { $0 + "\n" }.joined())
    resolution.decide(4, mine: false, take: true)
    #expect(resolution.texts[flush] == "    attempt++\n    await sleep(backoff(attempt))\n")
}

@Test func decidingTwiceTheSameWayTakesItBack() {
    let merge = ThreeWay(base: base, mine: mine, other: other)
    var resolution = MergeResolution(merge)
    let start = resolution
    resolution.decide(0, mine: true, take: true)
    resolution.decide(0, mine: true, take: true)
    #expect(resolution.decisions[0] == .init())
    #expect(resolution.texts == start.texts)
    // A change taken on its own goes back to waiting for you, as the ancestor.
    resolution.decide(1, mine: true, take: true)
    #expect(resolution.decisions[1] == .init())
    #expect(resolution.texts[resolution.unit(ofChunk: 1)] == "const DELAY = 500\n")
    #expect(resolution.openDecisions == 7)
}

@Test func aChangeMadeAlikeIsOneDecision() {
    let merge = ThreeWay(base: base, mine: mine, other: other)
    var resolution = MergeResolution(merge)
    let post = resolution.unit(ofChunk: 3)
    resolution.decide(3, mine: false, take: false)
    #expect(resolution.decisions[3] == .init(mine: false, other: false))
    #expect(resolution.texts[post] == "    await api.send(change)\n")
    #expect(resolution.isDecided(3))
    resolution.decide(3, mine: true, take: false)
    #expect(resolution.decisions[3] == .init())
    #expect(resolution.openDecisions == 7)
    resolution.decide(3, mine: false, take: true)
    #expect(resolution.decisions[3] == .init(mine: true, other: true, order: [true]))
    #expect(resolution.texts[post] == "    await api.post(change)\n")
    #expect(resolution.openDecisions == 6)
}

@Test func acceptingOneSideGivesThatFile() {
    let merge = ThreeWay(base: base, mine: mine, other: other)
    var resolution = MergeResolution(merge)
    resolution.acceptAll(mine: true)
    #expect(resolution.result == mine)
    #expect(resolution.openDecisions == 0)
    #expect(resolution.autoCount == 0)
    resolution.acceptAll(mine: false)
    #expect(resolution.result == other)
    #expect(resolution.openDecisions == 0)

    var bare = MergeResolution(ThreeWay(base: "a\nb\nc", mine: "A\nb\nc", other: "a\nb\nC"))
    bare.acceptAll(mine: true)
    #expect(bare.result == "A\nb\nc")
}

/// Mutating calls can't go inside #expect.
private func edit(_ resolution: inout MergeResolution, _ unit: Int, to text: String) -> Bool { resolution.edit(unit, to: text) }

@Test func handEditsCountAsDecided() {
    let merge = ThreeWay(base: base, mine: mine, other: other)
    var resolution = MergeResolution(merge)
    let imports = resolution.unit(ofChunk: 0)
    resolution.decide(0, mine: true, take: true)
    #expect(edit(&resolution, imports, to: "import { log, warn } from \"./log\"\n") == true)
    #expect(resolution.decisions[0].edited)
    #expect(resolution.isDecided(0))
    #expect(resolution.openDecisions == 4)
    #expect(resolution.result.contains("log, warn"))
    // Typing the same again changes nothing, and an undo back to the decided text clears it.
    #expect(edit(&resolution, imports, to: "import { log, warn } from \"./log\"\n") == false)
    #expect(edit(&resolution, imports, to: "import { log } from \"./log\"\n") == true)
    #expect(!resolution.decisions[0].edited)
    #expect(resolution.openDecisions == 5)
    // Deciding again replaces what was typed.
    resolution.edit(imports, to: "// mine\n")
    resolution.decide(0, mine: false, take: true)
    #expect(!resolution.decisions[0].edited)
    #expect(resolution.texts[imports] == "import { log } from \"./log\"\nimport { backoff } from \"./backoff\"\n")
    // Shared lines take typing too, without any decision.
    #expect(edit(&resolution, 0, to: "import { api } from \"./api2\"\n") == false)
    #expect(resolution.result.hasPrefix("import { api } from \"./api2\"\n"))
}

@Test func keepsDecisionsWhenWhitespaceIsIgnored() throws {
    let base = "a\n  b\nc\nd\ne\nf\ng\nh\nx\ni\n"
    let mine = "a\nb\nc\nd\ne\nf\ng\nh\nmine\ni\n"
    let other = "a\n  B\nc\nd\ne\nf\ng\nh\nother\ni\n"
    let strict = ThreeWay(base: base, mine: mine, other: other)
    let relaxed = ThreeWay(base: base, mine: mine, other: other, ignoringWhitespace: true)
    #expect(strict.chunks.map(\.kind) == [.conflict, .conflict])
    #expect(relaxed.chunks.map(\.kind) == [.other, .conflict])

    var resolution = MergeResolution(strict)
    resolution.decide(1, mine: true, take: true)
    resolution.decide(1, mine: false, take: false)
    let carried = try #require(resolution.carried(to: relaxed))
    #expect(carried.decisions[1] == resolution.decisions[1])
    #expect(carried.decisions[0].auto)
    #expect(carried.openDecisions == 0)
    #expect(carried.result == "a\n  B\nc\nd\ne\nf\ng\nh\nmine\ni\n")

    // Back to reading every space: the chunk taken on its own is a conflict to decide again, yours stays.
    let back = try #require(carried.carried(to: strict))
    #expect(back.decisions[1] == resolution.decisions[1])
    #expect(back.openDecisions == 2)

    // A chunk you settled by hand keeps your result when its kind changes.
    var typed = MergeResolution(strict)
    typed.decide(0, mine: true, take: true)
    typed.decide(0, mine: false, take: true)
    let kept = try #require(typed.carried(to: relaxed))
    #expect(kept.decisions[0].edited)
    #expect(kept.texts[kept.unit(ofChunk: 0)] == "b\n  B\n")
}
