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
    /// A host named neither github nor gitlab is one when `hosts` says so, as for a company's own domain.
    public init?(remote: String, hosts: [String: Kind] = Forge.loggedInHosts()) {
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

        let host = authority.lowercased()
        if host.contains("github") {
            kind = .github
        } else if host.contains("gitlab") {
            kind = .gitlab
        } else if let known = hosts[String(host.prefix { $0 != ":" })] {
            kind = known
        } else {
            return nil
        }
        web = "\(scheme)://\(authority)/\(path)"
    }

    /// The hosts gh and glab are logged into, so a GitHub or GitLab on a company's own domain is recognized.
    /// Read from their config files, without running them, since every repo's remote is checked against it.
    public static func loggedInHosts() -> [String: Kind] {
        let environment = ProcessInfo.processInfo.environment
        let config = environment["XDG_CONFIG_HOME"] ?? NSHomeDirectory() + "/.config"
        let read = { (path: String) in (try? String(contentsOfFile: path, encoding: .utf8)) ?? "" }
        var hosts: [String: Kind] = [:]
        let gh = (environment["GH_CONFIG_DIR"] ?? config + "/gh") + "/hosts.yml"
        for host in Self.hosts(inConfig: read(gh), under: nil) { hosts[host] = .github }
        // glab keeps its config under Application Support on macOS, and under the XDG folder when one is set.
        let glab = [environment["GLAB_CONFIG_DIR"] ?? config + "/glab-cli", NSHomeDirectory() + "/Library/Application Support/glab-cli"]
        for folder in glab {
            for host in Self.hosts(inConfig: read(folder + "/config.yml"), under: "hosts") { hosts[host] = .gitlab }
        }
        return hosts
    }

    /// The keys of a YAML config's top level, or of its `section`: the hosts in gh's and glab's files.
    static func hosts(inConfig yaml: String, under section: String?) -> [String] {
        var hosts: [String] = []
        var inside = section == nil
        var level: Int? = section == nil ? 0 : nil
        for line in yaml.split(separator: "\n") {
            let indent = line.prefix { $0 == " " }.count
            let key = line.dropFirst(indent)
            if let section, indent == 0 {
                inside = key == section + ":"
                level = nil
                continue
            }
            // A host is a key with its settings under it, so nothing follows its colon.
            guard inside, key.hasSuffix(":"), !key.contains(" ") else { continue }
            if level == nil { level = indent }
            if indent == level { hosts.append(String(key.dropLast())) }
        }
        return hosts
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

    /// An open pull request, or merge request.
    public struct Request: Equatable {
        public let number: Int
        public let url: URL
        public let title: String
    }

    /// Every open request, by the branch it comes from. Talks to the forge, so call it off the main thread.
    /// Empty when the tool is missing or can't answer, so nothing shows rather than something wrong.
    public func openRequests(in directory: String) -> [String: Request] {
        guard let path = kind.toolPath else { return [:] }
        let arguments = switch kind {
        case .github: ["pr", "list", "--state", "open", "--json", "number,url,title,headRefName,baseRefName", "--limit", "100"]
        case .gitlab: ["mr", "list", "--output", "json", "--per-page", "100"]
        }
        guard let output = try? Git.run(path, arguments, in: directory) else { return [:] }
        return Self.requests(from: output)
    }

    /// Reads either tool's JSON list: gh says headRefName and baseRefName, glab says source_branch and target_branch.
    static func requests(from json: String) -> [String: Request] {
        let list = (try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: Any]]) ?? []
        var requests: [String: Request] = [:]
        for item in list {
            guard let number = (item["number"] ?? item["iid"]) as? Int,
                  let url = ((item["url"] ?? item["web_url"]) as? String).flatMap(URL.init(string:)),
                  let head = (item["headRefName"] ?? item["source_branch"]) as? String else { continue }
            // A fork's main asking to go into main says nothing about our own main.
            guard head != (item["baseRefName"] ?? item["target_branch"]) as? String else { continue }
            requests[head] = requests[head] ?? Request(number: number, url: url, title: item["title"] as? String ?? "")
        }
        return requests
    }

    /// What request `number` changes, as its page shows it. Works for anyone's request, without checking it out.
    /// Talks to the forge, so call it off the main thread.
    public func files(ofRequest number: Int, in directory: String) throws -> [Diff.File] {
        guard let path = kind.toolPath else { throw GitError(description: "\(tool) isn't installed.") }
        let arguments = switch kind {
        case .github: ["pr", "diff", "\(number)", "--color", "never"]
        case .gitlab: ["mr", "diff", "\(number)", "--raw"]
        }
        return Diff.parse(try Git.run(path, arguments, in: directory, trimming: false))
    }

    /// What was said on a request: its description, then every comment, oldest first.
    public struct Discussion: Equatable {
        public struct Comment: Equatable {
            public let author: String
            public let date: Date?
            public let text: String
            /// "approved" or "requested changes", when a review said so.
            public var verdict: String?
            /// Where a comment on a line of the diff was left. Nil for the rest of the conversation.
            public var path: String?
            public var line: Int?
            /// The line is one the request removes, so `line` counts in the old file.
            public var old = false
            /// The code moved since, so `line` is where it was left, not a line of the diff now.
            public var outdated = false
            public var url: URL?
        }

        public let description: Comment
        public let comments: [Comment]
        /// The commit the request's branch is at, which a new comment on a line has to name. GitHub only.
        public var head: String?
    }

    /// Request `number`'s description and comments. Talks to the forge, so call it off the main thread.
    /// Nil when the tool is missing or can't answer.
    public func discussion(ofRequest number: Int, in directory: String) -> Discussion? {
        guard let path = kind.toolPath else { return nil }
        switch kind {
        case .github:
            guard let view = try? Git.run(path, ["pr", "view", "\(number)", "--json", "author,body,createdAt,url,comments,reviews,headRefOid"],
                                          in: directory) else { return nil }
            // Comments on lines of the diff aren't part of the pull request's view, only of the API.
            // The first 100 only, here and on GitLab. Paging through the API would reach the rest of a long review.
            let lines = try? Git.run(path, ["api", "repos/{owner}/{repo}/pulls/\(number)/comments?per_page=100"], in: directory)
            return Self.discussion(github: view, lines: lines ?? "[]")
        case .gitlab:
            guard let request = try? Git.run(path, ["api", "projects/:id/merge_requests/\(number)"], in: directory) else { return nil }
            let notes = try? Git.run(path, ["api", "projects/:id/merge_requests/\(number)/notes?sort=asc&per_page=100"], in: directory)
            return Self.discussion(gitlab: request, notes: notes ?? "[]")
        }
    }

    /// Reads `gh pr view`'s JSON, and the API's list of comments on lines.
    static func discussion(github view: String, lines: String) -> Discussion? {
        guard let request = json(view) as? [String: Any] else { return nil }
        let login = { (item: [String: Any], key: String) in (item[key] as? [String: Any])?["login"] as? String ?? "someone" }
        let url = { (item: [String: Any], key: String) in (item[key] as? String).flatMap(URL.init(string:)) }
        let description = Discussion.Comment(author: login(request, "author"), date: date(request["createdAt"]),
                                             text: request["body"] as? String ?? "", url: url(request, "url"))
        var comments = (request["comments"] as? [[String: Any]] ?? []).map { comment in
            Discussion.Comment(author: login(comment, "author"), date: date(comment["createdAt"]),
                               text: comment["body"] as? String ?? "", url: url(comment, "url"))
        }
        for review in request["reviews"] as? [[String: Any]] ?? [] {
            let verdict: String? = switch review["state"] as? String {
            case "APPROVED": "approved"
            case "CHANGES_REQUESTED": "requested changes"
            default: nil
            }
            let text = review["body"] as? String ?? ""
            // A review with nothing to say holds only its comments on lines, which come from the API.
            guard verdict != nil || !text.isEmpty else { continue }
            comments.append(Discussion.Comment(author: login(review, "author"), date: date(review["submittedAt"]), text: text, verdict: verdict))
        }
        for comment in json(lines) as? [[String: Any]] ?? [] {
            comments.append(Discussion.Comment(author: login(comment, "user"), date: date(comment["created_at"]),
                                               text: comment["body"] as? String ?? "",
                                               path: comment["path"] as? String,
                                               // An outdated comment's line is gone, so it keeps the one it was left on.
                                               line: comment["line"] as? Int ?? comment["original_line"] as? Int,
                                               old: comment["side"] as? String == "LEFT",
                                               outdated: comment["line"] as? Int == nil,
                                               url: url(comment, "html_url")))
        }
        return Discussion(description: description, comments: comments.sorted { ($0.date ?? .distantPast) < ($1.date ?? .distantPast) },
                          head: request["headRefOid"] as? String)
    }

    /// Reads GitLab's merge request and its notes, leaving out the ones GitLab writes itself, like "added 1 commit".
    static func discussion(gitlab request: String, notes: String) -> Discussion? {
        guard let request = json(request) as? [String: Any] else { return nil }
        let username = { (item: [String: Any]) in (item["author"] as? [String: Any])?["username"] as? String ?? "someone" }
        let page = request["web_url"] as? String
        let description = Discussion.Comment(author: username(request), date: date(request["created_at"]),
                                             text: request["description"] as? String ?? "", url: page.flatMap(URL.init(string:)))
        let list: [[String: Any]] = json(notes) as? [[String: Any]] ?? []
        let comments = list.compactMap { note -> Discussion.Comment? in
            guard note["system"] as? Bool != true else { return nil }
            let position = note["position"] as? [String: Any]
            let link = page.flatMap { page in (note["id"] as? Int).flatMap { URL(string: "\(page)#note_\($0)") } }
            // A note on a removed line has only the old line's number.
            let new = position?["new_line"] as? Int
            return Discussion.Comment(author: username(note), date: date(note["created_at"]), text: note["body"] as? String ?? "",
                                      path: position?["new_path"] as? String, line: new ?? position?["old_line"] as? Int,
                                      old: position != nil && new == nil, url: link)
        }
        return Discussion(description: description, comments: comments)
    }

    /// Whether this forge takes new comments on lines from Farol.
    public var takesLineComments: Bool { kind == .github && kind.toolPath != nil }

    /// Leaves `text` on a line of request `number`'s diff, at commit `head`. `old` puts it on a removed line, counted in the old file.
    /// Talks to the forge, so call it off the main thread.
    public func comment(_ text: String, onRequest number: Int, head: String, path: String, line: Int, old: Bool,
                        in directory: String) throws {
        // ponytail: GitHub only. GitLab wants the diff's three commits in a position, to add once it can be tried on a real instance.
        guard kind == .github, let tool = kind.toolPath else { throw GitError(description: "Comments on lines need gh, on GitHub.") }
        // -f sends text as it is, -F turns the line into a number.
        try Git.run(tool, ["api", "repos/{owner}/{repo}/pulls/\(number)/comments", "-f", "body=\(text)", "-f", "commit_id=\(head)",
                           "-f", "path=\(path)", "-F", "line=\(line)", "-f", "side=\(old ? "LEFT" : "RIGHT")"], in: directory)
    }

    private static func json(_ text: String) -> Any? { try? JSONSerialization.jsonObject(with: Data(text.utf8)) }

    /// GitHub writes "2026-10-14T17:26:34Z", GitLab adds milliseconds.
    private static func date(_ value: Any?) -> Date? {
        guard let text = value as? String else { return nil }
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions.insert(.withFractionalSeconds)
        return formatter.date(from: text)
    }

    /// One step of a request's pipeline: a check on GitHub, a job on GitLab.
    public struct Check: Equatable {
        /// In the order they are listed: what needs you comes first.
        public enum State: Int { case failed, running, passed, skipped }
        public let name: String
        public let state: State
        /// The step's own page, with its log.
        public let url: URL?
    }

    /// The steps that ran for `branch`'s open request. Talks to the forge, so call it off the main thread.
    /// Empty when there are none, or when the tool is missing or can't answer.
    public func checks(for branch: String, in directory: String) -> [Check] {
        guard let path = kind.toolPath else { return [] }
        let arguments = switch kind {
        case .github: ["pr", "list", "--head", branch, "--state", "open", "--json", "statusCheckRollup", "--limit", "1"]
        case .gitlab: ["ci", "get", "--branch", branch, "--output", "json"]
        }
        guard let output = try? Git.run(path, arguments, in: directory) else { return [] }
        return Self.checks(from: output)
    }

    /// Reads either tool's JSON: gh lists requests, each with its statusCheckRollup, and glab gives a pipeline with its jobs.
    static func checks(from json: String) -> [Check] {
        let parsed = try? JSONSerialization.jsonObject(with: Data(json.utf8))
        let rollup = (parsed as? [[String: Any]])?.first?["statusCheckRollup"] as? [[String: Any]] ?? []
        let jobs = (parsed as? [String: Any])?["jobs"] as? [[String: Any]] ?? []
        let github = rollup.compactMap { item -> Check? in
            // A check run comes from an action or an app. A status, as an older CI service sets, says context and state.
            guard let name = (item["name"] ?? item["context"]) as? String else { return nil }
            let status = item["status"] as? String ?? "COMPLETED"
            let state: Check.State = switch (item["conclusion"] ?? item["state"]) as? String {
            case _ where status != "COMPLETED": .running
            case "SUCCESS": .passed
            case "NEUTRAL", "SKIPPED": .skipped
            case "PENDING", "EXPECTED": .running
            default: .failed
            }
            return Check(name: name, state: state, url: ((item["detailsUrl"] ?? item["targetUrl"]) as? String).flatMap(URL.init(string:)))
        }
        let gitlab = jobs.compactMap { job -> Check? in
            guard let name = job["name"] as? String else { return nil }
            let state: Check.State = switch job["status"] as? String {
            case "success": .passed
            case "failed", "canceled": .failed
            // A manual job waits for a click that may never come, so it doesn't count as running.
            case "skipped", "manual": .skipped
            default: .running
            }
            return Check(name: name, state: state, url: (job["web_url"] as? String).flatMap(URL.init(string:)))
        }
        return (github + gitlab).sorted { ($0.state.rawValue, $0.name) < ($1.state.rawValue, $1.name) }
    }

    /// Whether this forge's issues can be listed at all, without asking it.
    public var listsIssues: Bool { kind.toolPath != nil }

    /// The repo's open issues, newest first, to start a task from. Talks to the forge, so call it off the main thread.
    public func issues(in directory: String) -> [Ticket] {
        // ponytail: the newest 30. Searching on the forge's side would reach the rest.
        let arguments = switch kind {
        case .github: ["issue", "list", "--state", "open", "--json", "number,title,body,url", "--limit", "30"]
        case .gitlab: ["issue", "list", "--output", "json", "--per-page", "30"]
        }
        guard let path = kind.toolPath, let output = try? Git.run(path, arguments, in: directory) else { return [] }
        return Self.issues(from: output, source: kind == .github ? .github : .gitlab)
    }

    /// Reads either tool's JSON list: gh says number, body and url, glab says iid, description and web_url.
    static func issues(from json: String, source: Ticket.Source) -> [Ticket] {
        let list = (try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: Any]]) ?? []
        return list.compactMap { issue in
            guard let number = (issue["number"] ?? issue["iid"]) as? Int, let title = issue["title"] as? String else { return nil }
            let body = ((issue["body"] ?? issue["description"]) as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let url = ((issue["url"] ?? issue["web_url"]) as? String).flatMap(URL.init(string:))
            return Ticket(source: source, key: "#\(number)", summary: title, description: body, url: url)
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
        (try? Git.run(["remote", "get-url", History.pushRemote(in: directory)], in: directory)).flatMap { Forge(remote: $0) }
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
