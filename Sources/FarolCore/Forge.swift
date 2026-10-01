import Foundation

/// Where a repo is hosted, read from its remote's URL, to link to the page that opens a pull request there.
public struct Forge: Equatable {
    public enum Kind: CaseIterable {
        case github, gitlab

        /// "GitHub", for labels.
        public var name: String { self == .github ? "GitHub" : "GitLab" }
        /// What a request to merge is called there.
        public var request: String { self == .github ? "pull request" : "merge request" }
        public var requestShort: String { self == .github ? "PR" : "MR" }
        /// The forge's own command line tool, which Farol asks about requests and creates them with.
        public var tool: String { self == .github ? "gh" : "glab" }
        /// Where the tool's own documentation is, for installing it and logging in.
        public var docs: String { self == .github ? "https://cli.github.com" : "https://docs.gitlab.com/cli/" }

        var toolPath: String? {
            // ponytail: looks where Homebrew and the official installers put them. Other setups, like nix, read as not installed.
            let folders = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", NSHomeDirectory() + "/.local/bin"]
            return folders.map { "\($0)/\(tool)" }.first(where: FileManager.default.isExecutableFile(atPath:))
        }

        /// Whether the tool is there and logged in, for Settings. Runs the tool, so call it off the main thread.
        public func toolState() -> ToolState {
            guard let path = toolPath else { return .missing }
            // glab reports on stderr, and so did gh before it moved to stdout.
            guard let status = try? Git.run(path, ["auth", "status"], in: NSHomeDirectory(), mergingErrors: true) else {
                return .loggedOut
            }
            return .connected(account: Self.account(from: status))
        }

        /// "Logged in to github.com account ana (keyring)" from gh, "Logged in to gitlab.com as ana" from glab and older gh.
        static func account(from status: String) -> String? {
            guard let match = status.firstMatch(of: #/Logged in to \S+ (?:account|as) (\S+)/#) else { return nil }
            return String(match.1)
        }

        /// Where the account's picture is. GitLab has to be asked, so call it off the main thread.
        public func avatar(of account: String) -> URL? {
            switch self {
            case .github:
                // ponytail: github.com only. An account on GitHub Enterprise keeps the placeholder until the host is read too.
                return URL(string: "https://github.com/\(account).png?size=64")
            case .gitlab:
                guard let path = toolPath, let user = try? Git.run(path, ["api", "user"], in: NSHomeDirectory()) else { return nil }
                return Self.avatar(fromUser: user)
            }
        }

        /// Reads `avatar_url` from GitLab's answer about the logged in user.
        static func avatar(fromUser json: String) -> URL? {
            let user = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
            return (user?["avatar_url"] as? String).flatMap(URL.init(string:))
        }

        /// Typed into a terminal to get from `state` to connected. Logging in asks questions, so it can't run in the background.
        public func setupCommand(from state: ToolState) -> String {
            (state == .missing ? "brew install \(tool) && " : "") + "\(tool) auth login"
        }
    }

    public enum ToolState: Equatable {
        case missing
        /// Installed, but it has no account to act for.
        case loggedOut
        case connected(account: String?)
    }

    public let kind: Kind
    /// The repo's page, like https://github.com/snowztech/farol.
    public let web: String

    public var name: String { kind.name }
    public var request: String { kind.request }
    public var requestShort: String { kind.requestShort }
    public var tool: String { kind.tool }

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

    /// What is known about a branch's request. Asking needs the forge's own command line tool, gh or glab, installed and logged in.
    public enum RequestState: Equatable {
        /// The tool is missing or couldn't answer, so there may or may not be one.
        case unknown
        case none
        case open(number: Int, url: URL)
    }

    /// Whether `branch` has an open pull request, or merge request. Talks to the forge, so call it off the main thread.
    public func request(for branch: String, in directory: String) -> RequestState {
        guard let path = kind.toolPath else { return .unknown }
        let arguments = switch kind {
        case .github: ["pr", "list", "--head", branch, "--state", "open", "--json", "number,url", "--limit", "1"]
        case .gitlab: ["mr", "list", "--source-branch", branch, "--output", "json"]
        }
        // Not logged in, offline, or a repo the tool can't place all end here.
        guard let output = try? Git.run(path, arguments, in: directory) else { return .unknown }
        return Self.request(from: output)
    }

    /// Whether this forge's issues can be listed at all, without asking it.
    public var listsIssues: Bool { kind == .github && kind.toolPath != nil }

    /// The repo's open issues, newest first, to start a task from. Talks to the forge, so call it off the main thread.
    public func issues(in directory: String) -> [Ticket] {
        // ponytail: GitHub only, and the newest 30. glab lists issues too, for when GitLab needs them.
        let arguments = ["issue", "list", "--state", "open", "--json", "number,title,body", "--limit", "30"]
        guard kind == .github, let path = kind.toolPath,
              let output = try? Git.run(path, arguments, in: directory) else { return [] }
        return Self.issues(from: output)
    }

    static func issues(from json: String) -> [Ticket] {
        let list = (try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: Any]]) ?? []
        return list.compactMap { issue in
            guard let number = issue["number"] as? Int, let title = issue["title"] as? String else { return nil }
            let body = (issue["body"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return Ticket(source: .github, key: "#\(number)", summary: title, description: body)
        }
    }

    /// Creates the request for `branch`, titled and described from its commits. The branch has to be pushed first.
    public func createRequest(for branch: String, in directory: String) throws {
        guard let path = kind.toolPath else { throw GitError(description: "\(tool) isn't installed.") }
        // Both flags keep the tools from stopping to ask, which they can't here.
        let arguments = switch kind {
        case .github: ["pr", "create", "--fill", "--head", branch]
        case .gitlab: ["mr", "create", "--fill", "--yes", "--source-branch", branch]
        }
        try Git.run(path, arguments, in: directory)
    }

    /// Reads either tool's JSON list: gh says number and url, glab says iid and web_url.
    static func request(from json: String) -> RequestState {
        guard let list = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: Any]] else { return .unknown }
        guard let first = list.first else { return .none }
        guard let number = (first["number"] ?? first["iid"]) as? Int,
              let url = ((first["url"] ?? first["web_url"]) as? String).flatMap(URL.init(string:)) else { return .unknown }
        return .open(number: number, url: url)
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
