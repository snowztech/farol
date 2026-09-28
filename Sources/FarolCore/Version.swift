import Foundation

/// Release versions like "0.4.1", compared number by number.
public enum Version {
    /// True when `latest` is a later release than `current`.
    /// A development build like "0.4.1-3-gabc1234" counts as 0.4.1, so it only sees later releases.
    public static func isNewer(_ latest: String, than current: String) -> Bool {
        guard let new = numbers(latest), let old = numbers(current) else { return false }
        return old.lexicographicallyPrecedes(new)
    }

    /// "v0.4.1" or "0.4.1-3-gabc" gives [0, 4, 1]. Anything else gives nil.
    static func numbers(_ version: String) -> [Int]? {
        let core = version.drop { $0 == "v" }.prefix { $0.isNumber || $0 == "." }
        let parts = core.split(separator: ".").map { Int($0) }
        guard parts.count == 3, parts.allSatisfy({ $0 != nil }) else { return nil }
        return parts.compactMap { $0 }
    }
}
