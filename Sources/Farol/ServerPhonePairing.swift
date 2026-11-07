import AppKit
import FarolCore
import SwiftUI

/// `farol-host pair` run on a server with no terminal, read line by line: the code it shows, then the phone that scanned it.
final class PhonePairing: ObservableObject {
    enum State: Equatable {
        case starting
        case showing(URL)
        case paired(String)
        /// ssh needed a password it can't ask for here, or pair stopped. The words are for the person looking.
        case failed(String)
    }

    @Published private(set) var state = State.starting
    private let process = Process()
    private var buffer = ""

    init(server: Server) {
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = ServerSetup.pairArguments(ssh: server.ssh)
        process.standardInput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let output = Pipe()
        process.standardOutput = output
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let text = String(decoding: handle.availableData, as: UTF8.self)
            DispatchQueue.main.async { self?.read(text) }
        }
        process.terminationHandler = { [weak self] ended in
            DispatchQueue.main.async {
                guard let self else { return }
                output.fileHandleForReading.readabilityHandler = nil
                switch self.state {
                case .paired, .failed: break
                case .showing: self.state = .failed("The code ran out before a phone scanned it.")
                case .starting:
                    self.state = .failed(ended.terminationStatus == 255
                        ? "Farol couldn't reach \(server.name) without a password. Pair from its terminal instead."
                        : "farol-host on \(server.name) couldn't show a code. Is it running?")
                }
            }
        }
        do { try process.run() } catch { state = .failed("ssh couldn't start.") }
    }

    func stop() {
        if process.isRunning { process.terminate() }
    }

    private func read(_ text: String) {
        buffer += text
        while let end = buffer.firstIndex(of: "\n") {
            let line = String(buffer[..<end])
            buffer = String(buffer[buffer.index(after: end)...])
            switch ServerSetup.pairLine(line) {
            case .code(let link): state = .showing(link)
            case .paired(let name): state = .paired(name)
            case nil: break
            }
        }
    }
}

/// Pair a phone with a server: its code drawn here, so there's no terminal or ssh by hand.
struct PairPhoneSheet: View {
    let server: Server
    @ObservedObject var pairing: PhonePairing
    let palette: Palette
    let openTerminal: () -> Void
    let close: () -> Void

    var body: some View {
        let p = palette
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 16) {
                SheetHeader(title: "Pair a phone with \(server.name)", palette: p) {
                    Text("Your phone then sees \(server.name)'s agents, even with this Mac off.")
                        .fixedSize(horizontal: false, vertical: true)
                }
                content(p)
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: 236)
            }
            .padding(20)
            Rectangle().fill(p.line).frame(height: 1)
            HStack {
                if case .failed = pairing.state {
                    Button("Open Terminal") { close(); openTerminal() }
                        .buttonStyle(SheetButton(palette: p, primary: false))
                }
                Spacer()
                Button(done ? "Done" : "Cancel", action: close)
                    .buttonStyle(SheetButton(palette: p, primary: done))
                    .keyboardShortcut(done ? .defaultAction : .cancelAction)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .font(.system(size: 13))
        .foregroundStyle(p.text)
        .frame(width: 380)
        .sheetBackground(p)
        .ignoresSafeArea()
    }

    private var done: Bool {
        if case .paired = pairing.state { return true }
        return false
    }

    @ViewBuilder private func content(_ p: Palette) -> some View {
        switch pairing.state {
        case .starting:
            VStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("Asking \(server.name) for a code…").foregroundStyle(p.muted)
            }
        case .showing(let link):
            VStack(spacing: 12) {
                if let code = SettingsPage.qrCode(link.absoluteString) {
                    Image(nsImage: code)
                        .interpolation(.none)
                        .resizable()
                        .frame(width: 180, height: 180)
                        .padding(12)
                        .background(Color.white)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                Text("Scan it from Farol on your phone. It works once, for two minutes. Whoever scans it can type into \(server.name)'s sessions.")
                    .font(.system(size: 12))
                    .foregroundStyle(p.muted)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .paired(let phone):
            VStack(spacing: 10) {
                Image(systemName: "checkmark.circle.fill").font(.system(size: 26)).foregroundStyle(p.done)
                Text("\(phone) is paired with \(server.name).").font(.system(size: 13, weight: .medium))
            }
        case .failed(let why):
            Text(why).foregroundStyle(p.muted).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
        }
    }
}
