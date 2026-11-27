import AppKit
import Combine
import Foundation

@MainActor
final class UpdateManager: ObservableObject {
    static var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
    }
    @Published var latestRelease: ReleaseInfo? = nil
    @Published var isChecking = false
    @Published var downloadProgress: Double = 0.0
    @Published var isDownloading = false
    @Published var downloadedDMGPath: String? = nil
    @Published var errorMessage: String? = nil
    @Published var upToDate: Bool = false
    @Published var showUpToDateAlert: Bool = false

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
            if newer {
                latestRelease = info
                upToDate = false
            } else {
                latestRelease = nil
                upToDate = true
                showUpToDateAlert = true
            }
        } catch {
            errorMessage = "Update check failed: \(error.localizedDescription)"
            showUpToDateAlert = true
        }
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
            // Remove macOS quarantine attribute so Gatekeeper doesn't block the DMG
            let xattr = Process()
            xattr.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
            xattr.arguments = ["-d", "com.apple.quarantine", destination.path]
            try? xattr.run(); xattr.waitUntilExit()
            downloadedDMGPath = destination.path
            downloadProgress = 1
        } catch { errorMessage = "Download failed: \(error.localizedDescription)" }
    }

    @Published var isInstalling = false
    @Published var installResult: String? = nil  // nil = no result yet, "" = success, "error msg" = failure

    func installUpdate() async {
        guard let dmgPath = downloadedDMGPath else { return }
        isInstalling = true; installResult = nil
        defer { isInstalling = false }

        do {
            // 1. Mount DMG
            let mountOutput = try await runCommand("/usr/bin/hdiutil",
                args: ["attach", "-nobrowse", "-quiet", dmgPath])

            // Find mount point (last /Volumes/... line from hdiutil)
            let mountPoint = mountOutput.split(separator: "\n")
                .compactMap { line -> String? in
                    let parts = line.split(separator: "\t")
                    guard parts.count >= 3 else { return nil }
                    let mp = parts.last.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
                    return mp.hasPrefix("/Volumes/") ? mp : nil
                }.last

            guard let mountPoint else { throw UpdateError.mountFailed }

            // 2. Find .app in mounted volume
            let fm = FileManager.default
            let appFiles = try fm.contentsOfDirectory(atPath: mountPoint)
                .filter { $0.hasSuffix(".app") }
            guard let appName = appFiles.first else { throw UpdateError.noAppFound }

            let sourceApp = "\(mountPoint)/\(appName)"
            let destApp = "/Applications/\(appName)"
            let destAppUser = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Applications/\(appName)").path

            // 3. Copy app — try /Applications first, fall back to ~/Applications
            let destination: String
            if fm.fileExists(atPath: destApp) || fm.isWritableFile(atPath: "/Applications/") {
                if fm.fileExists(atPath: destApp) {
                    try fm.removeItem(atPath: destApp)
                }
                try fm.copyItem(atPath: sourceApp, toPath: destApp)
                destination = destApp
            } else {
                try fm.createDirectory(atPath: FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent("Applications").path,
                    withIntermediateDirectories: true)
                if fm.fileExists(atPath: destAppUser) {
                    try fm.removeItem(atPath: destAppUser)
                }
                try fm.copyItem(atPath: sourceApp, toPath: destAppUser)
                destination = destAppUser
            }

            // 4. Unmount DMG
            _ = try? await runCommand("/usr/bin/hdiutil", args: ["detach", mountPoint, "-quiet"])

            // 5. Launch new version and quit current
            installResult = ""
            try? fm.removeItem(atPath: dmgPath)  // cleanup
            NSWorkspace.shared.open(URL(fileURLWithPath: destination))
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                NSApplication.shared.terminate(nil)
            }
        } catch {
            installResult = error.localizedDescription
        }
    }

    // Legacy: just open the DMG if auto-install fails
    func openDMG() {
        guard let downloadedDMGPath else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: downloadedDMGPath))
    }

    private enum UpdateError: LocalizedError {
        case mountFailed, noAppFound
        var errorDescription: String? {
            switch self {
            case .mountFailed: return "Could not mount the downloaded DMG."
            case .noAppFound: return "No .app found in the downloaded DMG."
            }
        }
    }

    private func runCommand(_ path: String, args: [String]) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: path)
            proc.arguments = args
            let pipe = Pipe()
            proc.standardOutput = pipe
            proc.terminationHandler = { p in
                let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                if p.terminationStatus == 0 {
                    continuation.resume(returning: output)
                } else {
                    continuation.resume(throwing: NSError(domain: "UpdateError", code: Int(p.terminationStatus),
                        userInfo: [NSLocalizedDescriptionKey: "Command failed: \(path) \(args.joined(separator: " "))\n\(output)"]))
                }
            }
            do { try proc.run() } catch { continuation.resume(throwing: error) }
        }
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
