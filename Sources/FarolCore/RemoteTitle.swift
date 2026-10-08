import Foundation

/// Over ssh the remote shell titles the terminal "user@host: ~/dir". It is the only sign the session left this machine.
public struct RemoteTitle: Equatable {
    public let user: String
    public let host: String
    public let path: String

    /// Nil for program titles and for a local shell that titles itself the same way.
    public init?(_ title: String, localHost: String = RemoteTitle.localHost) {
        guard let match = title.wholeMatch(of: #/([^@\s]+)@([^:\s]+):\s*(.*)/#) else { return nil }
        let host = String(match.2)
        // Prompts print the short name, so "mac" and "mac.local" are the same machine.
        let short = { (name: String) in name.split(separator: ".").first.map { $0.lowercased() } }
        guard short(host) != short(localHost) else { return nil }
        self.user = String(match.1)
        self.host = host
        self.path = String(match.3)
    }

    /// A program on the remote, like vim, retitles the terminal, and the host has to outlive that.
    /// It goes when the ssh command ends, which clears the title, or when a local shell titles itself again.
    public static func after(_ title: String, was: RemoteTitle?, localHost: String = RemoteTitle.localHost) -> RemoteTitle? {
        if title.isEmpty { return nil }
        if let remote = RemoteTitle(title, localHost: localHost) { return remote }
        // With no local name to match, any shell title parses. One that does was turned down for being local.
        return RemoteTitle(title, localHost: "") == nil ? was : nil
    }

    /// Read once with gethostname, since ProcessInfo's hostName can wait on a DNS lookup.
    public static let localHost: String = {
        var name = [CChar](repeating: 0, count: 256)
        gethostname(&name, name.count - 1)
        return String(cString: name)
    }()
}
