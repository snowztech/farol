import Foundation

/// Connects an agent that loads plugins from a folder, like OpenCode and Pi, with one file of Farol's there.
/// The plugin calls `farol status` with flags, the way any agent can report, so nothing about it is particular to Farol's socket.
/// Farol owns the file: it rewrites it when its text changes and removes it on Disconnect.
public struct AgentPlugin {
    public let file: URL
    public let text: String

    public static func opencode(in folder: AgentFolder) -> AgentPlugin {
        AgentPlugin(file: folder.directory.appendingPathComponent("plugins/farol.js"), text: opencode)
    }

    public static func pi(in folder: AgentFolder) -> AgentPlugin {
        AgentPlugin(file: folder.directory.appendingPathComponent("extensions/farol.ts"), text: pi)
    }

    public var isInstalled: Bool { FileManager.default.fileExists(atPath: file.path) }

    public var isCurrent: Bool { (try? String(contentsOf: file, encoding: .utf8)) == text }

    public func install() throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: file, atomically: true, encoding: .utf8)
    }

    public func remove() throws {
        guard isInstalled else { return }
        try FileManager.default.removeItem(at: file)
    }

    /// Runs `farol status` one report at a time, so a quick "working" then "done" never lands the other way round.
    /// Handlers don't wait for it, so a report never holds the agent up.
    /// Flags are cut to a length the socket takes, and empty ones are left out.
    private static let report = """
    import { spawn } from "node:child_process"

    const cli = process.env.FAROL_CLI
    let reports = Promise.resolve()

    function farol(event, flags = {}) {
      const args = ["status", event]
      for (const [name, value] of Object.entries(flags)) {
        if (typeof value === "string" && value.trim()) args.push(`--${name}`, value.trim().slice(0, 2000))
      }
      reports = reports.then(() => new Promise((done) => {
        const child = spawn(cli, args, { stdio: "ignore" })
        child.on("exit", done)
        child.on("error", done)
      }))
      return reports
    }
    """

    private static func header(_ agent: String) -> String {
        """
        // Farol's \(agent) plugin, written when you connect \(agent) in Settings → Agents and removed when you disconnect.
        // Farol rewrites it when it changes, so edits here are lost. Your own plugins go beside it.
        // It tells Farol what \(agent) does in this pane, with `farol status`, and does nothing outside Farol.
        """
    }

    static let opencode = header("OpenCode") + "\n" + report + """


    // What a permission asks: the tool, named as Claude Code names its own, and what it would do, like "Bash" and "npm test".
    // An older OpenCode gives a title instead.
    function permission(p) {
      if (typeof p.title === "string" && p.title) return { asking: p.title }
      const kind = p.permission ?? p.type
      const tool = typeof kind === "string" && kind ? kind[0].toUpperCase() + kind.slice(1) : undefined
      const what = [p.patterns ?? p.pattern].flat().filter((part) => typeof part === "string" && part).join(" ")
      return { asking: what || tool, tool: what ? tool : undefined }
    }

    function question(p) {
      const first = p.questions?.[0]
      return first?.question ?? first?.header
    }

    // ponytail: reads the server in this pane's process. A server shared by several terminals can't say which pane asks.
    export const FarolPlugin = async () => {
      if (!cli || !process.env.FAROL_PANE) return {}
      // Sessions a subagent works in. Their questions count for the pane, their own ends don't.
      const children = new Set()
      return {
        // Reports aren't awaited, so a slow one never holds OpenCode up.
        event: async ({ event }) => {
          const p = event?.properties ?? {}
          if (p.info?.id && p.info.parentID) children.add(p.info.id)
          const child = children.has(p.sessionID)
          switch (event?.type) {
            case "session.status": {
              const status = typeof p.status === "string" ? p.status : p.status?.type
              if (!child && (status === "busy" || status === "retry")) farol("working")
              break
            }
            case "session.idle":
            case "session.error":
              if (!child) farol("done")
              break
            case "permission.asked":
            case "permission.updated":
              farol("waiting", permission(p))
              break
            case "question.asked":
              farol("waiting", { asking: question(p) })
              break
            case "permission.replied":
            case "question.replied":
            case "question.rejected":
              farol("working")
              break
          }
        },
      }
    }

    export default { id: "farol", server: FarolPlugin, setup() {} }

    """

    static let pi = header("Pi") + "\n// @ts-nocheck\n" + report + """


    // The conversation's id and log, for the phone to read and the next launch to resume.
    function conversation(ctx) {
      const id = ctx?.sessionManager?.getSessionId?.()
      const log = ctx?.sessionManager?.getSessionFile?.()
      return typeof id === "string" && typeof log === "string" ? { session: id, log } : {}
    }

    export default function (pi) {
      if (!cli || !process.env.FAROL_PANE) return
      // Print, JSON and RPC runs have no terminal to show, so only the TUI reports.
      let tui = false
      pi.on("session_start", (_event, ctx) => {
        tui = ctx?.mode === "tui"
        if (tui) farol("start", conversation(ctx))
      })
      pi.on("input", (event, ctx) => {
        if (tui) farol("working", { prompt: event?.text, ...conversation(ctx) })
        return { action: "continue" }
      })
      pi.on("agent_start", (_event, ctx) => {
        if (tui) farol("working", conversation(ctx))
      })
      // Settled rather than agent_end, which comes before a retry or a queued message starts another run.
      // Stopped with Escape, it is not done with anything you need to look at.
      pi.on("agent_settled", (event, ctx) => {
        if (tui && ctx?.isIdle?.() === true) farol(event?.aborted ? "clear" : "done", conversation(ctx))
      })
      // A new, resumed or forked session starts again right after.
      pi.on("session_shutdown", (event) => {
        if (tui && event?.reason === "quit") farol("clear")
      })
    }

    """
}
