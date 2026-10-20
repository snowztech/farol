import Foundation

/// Keeps a newly sent command visible while the shell is still starting it.
public struct RunCommandState {
    private let startedAt: Date
    private var sawProgram = false

    public init(startedAt: Date) { self.startedAt = startedAt }

    /// False once the program has ended, or a command never reached the foreground.
    public mutating func observe(runsProgram: Bool, at now: Date) -> Bool {
        if runsProgram {
            sawProgram = true
            return true
        }
        return !sawProgram && now.timeIntervalSince(startedAt) < 6
    }
}
