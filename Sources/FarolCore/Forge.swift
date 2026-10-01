import Foundation

/// Where a repo is hosted, read from its remote's URL, to link to the page that opens a pull request there.
public struct Forge: Equatable {
    public enum Kind { case github, gitlab }

    public let kind: Kind
    /// The repo's page, like https://github.com/snowztech/farol.
    public let web: String

    /// "GitHub", for labels.
    public var name: String { kind == .github ? "GitHub" : "GitLab" }
    /// What a request to merge is called there.
    public var request: String { kind == .github ? "pull request" : "merge request" }
    public var requestShort: String { kind == .github ? "PR" : "MR" }

    /// Understands the forms git accepts: https://host/path, ssh://git@host:22/path and git@host:path, with or without .git.
    public init?(remote: String) {
        var rest = remote.trimmingCharacters(in: .whitespacesAndNewlines)
        if rest.hasSuffix("/") { rest.removeLast() }
        if rest.hasSuffix(".git") { rest.removeLast(4) }
        var scheme = "https"
        var authority: String
        let path: String
        if let separator = rest.range(of: "://") {
            if rest[..<separator.lowerBound] == "http" { scheme = "http" }
            let web = scheme == "http" || rest[..<separator.lowerBound] == "https"
            rest = String(rest[separator.upperBound...])
            guard let slash = rest.firstIndex(of: "/") else { return nil }
            authority = String(rest[..<slash])
            path = String(rest[rest.index(after: slash)...])
            // An ssh port says nothing about where the web pages are.
            if !web, let colon = authority.lastIndex(of: ":") { authority = String(authority[..<colon]) }
        } else {
            guard let colon = rest.firstIndex(of: ":") else { return nil }
            authority = String(rest[..<colon])
            path = String(rest[rest.index(after: colon)...])
        }
        // Drops "git@", or a token someone put in an https remote.
        if let at = authority.lastIndex(of: "@") { authority = String(authority[authority.index(after: at)...]) }
        guard !authority.isEmpty, !path.isEmpty else { return nil }

        // ponytail: goes by the host's name, so a GitLab at git.company.com isn't recognized. A setting per host would cover it.
        let host = authority.lowercased()
        if host.contains("github") {
            kind = .github
        } else if host.contains("gitlab") {
            kind = .gitlab
        } else {
            return nil
        }
        web = "\(scheme)://\(authority)/\(path)"
    }

    /// The forge the checked out branch pushes to, or nil when its remote isn't GitHub or GitLab.
    public static func detect(in directory: String) -> Forge? {
        (try? Git.run(["remote", "get-url", History.pushRemote(in: directory)], in: directory)).flatMap(Forge.init(remote:))
    }

    /// The page that opens a pull request, or merge request, from `branch` into the default branch.
    /// If one is already open, both forges point to it from there.
    public func newRequest(from branch: String) -> URL? {
        // Slashes stay, as in feat/x. Anything else that means something in a URL is escaped.
        let safe = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~/"))
        guard let name = branch.addingPercentEncoding(withAllowedCharacters: safe) else { return nil }
        switch kind {
        case .github: return URL(string: "\(web)/compare/\(name)?expand=1")
        case .gitlab: return URL(string: "\(web)/-/merge_requests/new?merge_request%5Bsource_branch%5D=\(name)")
        }
    }
}
