import AppKit
import Combine
import Foundation

@MainActor
final class UpdateManager: ObservableObject {
    static let currentVersion = "1.5.0"
    @Published var latestRelease: ReleaseInfo? = nil
    @Published var isChecking = false
    @Published var downloadProgress: Double = 0.0
    @Published var isDownloading = false
    @Published var downloadedDMGPath: String? = nil
    @Published var errorMessage: String? = nil

    struct ReleaseInfo {
        let tag: String
        let name: String
        let body: String
        let dmgURL: URL
        let dmgSize: Int
        let date: String
        var isNewer: Bool
    }

    private let releasesURL = URL(string: "https://api.github.com/repos/fla-rion/nospeaker-ui/releases")!
    let releasesPageURL = URL(string: "https://github.com/fla-rion/nospeaker-ui/releases")!

    func checkForUpdates() async {
        isChecking = true; errorMessage = nil
        defer { isChecking = false }
        do {
            var request = URLRequest(url: releasesURL)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
            let releases = try JSONDecoder().decode([GitHubRelease].self, from: data)
            guard let release = releases.first(where: { !$0.draft && !$0.prerelease }),
                  let asset = release.assets.first(where: { $0.name.lowercased().hasSuffix(".dmg") }),
                  let url = URL(string: asset.browserDownloadURL) else { latestRelease = nil; return }
            let newer = Self.isVersion(release.tagName, newerThan: Self.currentVersion)
            let formatter = ISO8601DateFormatter()
            let date = release.publishedAt.flatMap { formatter.date(from: $0) }.map { DateFormatter.localizedString(from: $0, dateStyle: .medium, timeStyle: .none) } ?? ""
            let info = ReleaseInfo(tag: release.tagName, name: release.name.isEmpty ? "noSpeakerUI \(release.tagName)" : release.name, body: release.body, dmgURL: url, dmgSize: asset.size, date: date, isNewer: newer)
            latestRelease = newer ? info : nil
        } catch { errorMessage = "Could not check for updates: \(error.localizedDescription)" }
    }

    func downloadUpdate() async {
        guard let release = latestRelease else { return }
        isDownloading = true; downloadProgress = 0; errorMessage = nil
        defer { isDownloading = false }
        do {
            let downloader = DMGDownloader(url: release.dmgURL) { [weak self] value in
                Task { @MainActor in self?.downloadProgress = value }
            }
            let data = try await downloader.download()
            let destination = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads/noSpeakerUI-\(release.tag).dmg")
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: destination, options: .atomic)
            downloadedDMGPath = destination.path
            downloadProgress = 1
        } catch { errorMessage = "Download failed: \(error.localizedDescription)" }
    }

    func openDMG() {
        guard let downloadedDMGPath else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: downloadedDMGPath))
    }

    func openReleasesPage() { NSWorkspace.shared.open(releasesPageURL) }

    private static func isVersion(_ candidate: String, newerThan current: String) -> Bool {
        func parts(_ version: String) -> [Int]? {
            let pieces = version.trimmingCharacters(in: CharacterSet(charactersIn: "vV")).split(separator: ".")
            let values = pieces.compactMap { Int($0) }
            return !pieces.isEmpty && values.count == pieces.count ? values : nil
        }
        guard let lhs = parts(candidate), let rhs = parts(current) else { return false }
        for i in 0..<max(lhs.count, rhs.count) {
            let a = i < lhs.count ? lhs[i] : 0, b = i < rhs.count ? rhs[i] : 0
            if a != b { return a > b }
        }
        return false
    }

    private struct GitHubRelease: Decodable {
        let tagName: String; let name: String; let body: String; let publishedAt: String?
        let draft: Bool; let prerelease: Bool; let assets: [Asset]
        enum CodingKeys: String, CodingKey { case tagName = "tag_name", name, body, publishedAt = "published_at", draft, prerelease, assets }
    }
    private struct Asset: Decodable {
        let name: String; let size: Int; let browserDownloadURL: String
        enum CodingKeys: String, CodingKey { case name, size, browserDownloadURL = "browser_download_url" }
    }
}

private final class DMGDownloader: NSObject, URLSessionDownloadDelegate {
    private let url: URL
    private let progress: (Double) -> Void
    private var continuation: CheckedContinuation<Data, Error>?
    init(url: URL, progress: @escaping (Double) -> Void) { self.url = url; self.progress = progress }
    func download() async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            URLSession(configuration: .default, delegate: self, delegateQueue: nil).downloadTask(with: url).resume()
        }
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        progress(min(1, Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)))
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        do { let data = try Data(contentsOf: location); continuation?.resume(returning: data) }
        catch { continuation?.resume(throwing: error) }
        continuation = nil; session.finishTasksAndInvalidate()
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error, let continuation { continuation.resume(throwing: error); self.continuation = nil }
    }
}
