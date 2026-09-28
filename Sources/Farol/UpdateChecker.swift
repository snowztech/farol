import AppKit
import FarolCore

/// Asks GitHub for the latest release at launch and once a day. Nothing is sent, and a failed check just stays quiet.
final class UpdateChecker: ObservableObject {
    /// The newer version, like "0.5.0", or nil when Farol is up to date.
    @Published private(set) var available: String?

    static let download = URL(string: "https://github.com/snowztech/farol/releases/latest/download/Farol.dmg")!
    private static let latest = URL(string: "https://api.github.com/repos/snowztech/farol/releases/latest")!
    private let current = Bundle.main.object(forInfoDictionaryKey: "FarolVersion") as? String ?? "dev"
    private var timer: Timer?

    init() {
        check()
        timer = Timer.scheduledTimer(withTimeInterval: 24 * 60 * 60, repeats: true) { [weak self] _ in self?.check() }
    }

    func install() {
        NSWorkspace.shared.open(Self.download)
    }

    private func check() {
        var request = URLRequest(url: Self.latest)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        URLSession.shared.dataTask(with: request) { [weak self] data, _, _ in
            guard let self, let data,
                  let release = try? JSONDecoder().decode(Release.self, from: data),
                  Version.isNewer(release.tag_name, than: self.current) else { return }
            let version = release.tag_name.hasPrefix("v") ? String(release.tag_name.dropFirst()) : release.tag_name
            DispatchQueue.main.async { self.available = version }
        }.resume()
    }

    private struct Release: Decodable {
        let tag_name: String
    }
}
