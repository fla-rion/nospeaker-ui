import SwiftUI

struct UpdateSheet: View {
    @ObservedObject var manager: UpdateManager
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let release = manager.latestRelease {
                Text(release.name).font(.title2.weight(.semibold))
                if !release.date.isEmpty { Text("Released \(release.date)").foregroundStyle(.secondary) }
                Text("Current version: v\(UpdateManager.currentVersion)  →  New version: \(release.tag)").font(.callout)
                Text("Release notes").font(.headline)
                ScrollView { Text(release.body.isEmpty ? "No release notes provided." : release.body).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled).padding(10) }
                    .background(Color(nsColor: .textBackgroundColor)).clipShape(RoundedRectangle(cornerRadius: 8)).frame(minHeight: 180)
                if let error = manager.errorMessage { Text(error).foregroundStyle(.red).font(.callout) }
                HStack {
                    if manager.downloadedDMGPath != nil {
                        if manager.isInstalling {
                            ProgressView("Installing…").frame(width: 160)
                        } else if let result = manager.installResult {
                            if result.isEmpty {
                                Label("Installed — restarting…", systemImage: "checkmark.circle.fill").foregroundColor(.green)
                            } else {
                                VStack(alignment: .leading) {
                                    Text("Install failed: \(result)").foregroundColor(.red).font(.caption)
                                    Button("Open DMG manually") { manager.openDMG() }
                                }
                            }
                        } else {
                            Button("Install Update") { Task { await manager.installUpdate() } }.buttonStyle(.borderedProminent)
                            Button("Open DMG") { manager.openDMG() }.foregroundColor(.secondary)
                        }
                    } else if manager.isDownloading {
                        ProgressView(value: manager.downloadProgress) { Text("Downloading…") } currentValueLabel: { Text("\(Int(manager.downloadProgress * 100))%") }.frame(width: 220)
                    } else {
                        Button("Download & Install") { Task { await manager.downloadUpdate() } }.buttonStyle(.borderedProminent)
                    }
                    Spacer()
                    Link("Release Notes", destination: manager.releasesPageURL)
                    Button("Later") { dismiss() }.keyboardShortcut(.cancelAction)
                }
            } else {
                Text("No update information available.")
                Button("Later") { dismiss() }
            }
        }
        .padding(22).frame(width: 520, height: 430)

    }
}
