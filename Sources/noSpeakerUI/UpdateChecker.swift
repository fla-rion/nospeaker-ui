import AppKit
import Combine
import Foundation

@MainActor
final class UpdateChecker: ObservableObject {
    @Published private(set) var availableVersion: String?

    private let currentVersion = "1.1.0"
    private let latestReleaseURL = URL(string: "https://api.github.com/repos/fla-rion/nospeaker-ui/releases/latest")!
    let releasesPageURL = URL(string: "https://github.com/fla-rion/nospeaker-ui/releases/latest")!

    func checkForUpdates() async {
        var request = URLRequest(url: latestReleaseURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")

        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            let release = try JSONDecoder().decode(Release.self, from: data)
            let version = release.tagName.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
            guard isNewer(version, than: currentVersion) else { return }
            availableVersion = version
        } catch {
            // Update checks are best effort and should not interrupt app launch.
        }
    }

    func openReleasesPage() {
        NSWorkspace.shared.open(releasesPageURL)
    }

    private func isNewer(_ candidate: String, than current: String) -> Bool {
        let candidateParts = candidate.split(separator: ".").compactMap { Int($0) }
        let currentParts = current.split(separator: ".").compactMap { Int($0) }
        guard !candidateParts.isEmpty, candidateParts.count == candidate.split(separator: ".").count,
              currentParts.count == current.split(separator: ".").count else { return false }

        for index in 0..<max(candidateParts.count, currentParts.count) {
            let newPart = index < candidateParts.count ? candidateParts[index] : 0
            let oldPart = index < currentParts.count ? currentParts[index] : 0
            if newPart != oldPart { return newPart > oldPart }
        }
        return false
    }

    private struct Release: Decodable {
        let tagName: String

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
        }
    }
}
