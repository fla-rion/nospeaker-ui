import SwiftUI

struct UpdateSheet: View {
    @ObservedObject var manager: UpdateManager
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Update-Manager").font(.title2.weight(.semibold))
                    Text("Installed: v\(UpdateManager.currentVersion)")
                        .foregroundStyle(.secondary).font(.subheadline)
                }
                Spacer()
                if manager.isChecking {
                    ProgressView().scaleEffect(0.7)
                }
            }
            .padding([.horizontal, .top], 20)
            .padding(.bottom, 12)

            Divider()

            if manager.allReleases.isEmpty && !manager.isChecking {
                // Not loaded yet
                VStack { Spacer(); Text("No releases loaded. Click Refresh.").foregroundStyle(.secondary); Spacer() }
            } else {
                // Two-column layout: version list + changelog
                HStack(alignment: .top, spacing: 0) {
                    // Left: version list
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Available Versions").font(.headline).padding(.bottom, 2)
                        List(manager.allReleases, id: \.tag, selection: Binding(
                            get: { manager.selectedRelease?.tag },
                            set: { tag in manager.selectedRelease = manager.allReleases.first { $0.tag == tag } }
                        )) { release in
                            VStack(alignment: .leading, spacing: 2) {
                                HStack {
                                    Text(release.tag).font(.system(.body, design: .monospaced))
                                    if release.isNewer {
                                        Text("NEW").font(.caption2).padding(2)
                                            .background(Color.accentColor).foregroundColor(.white).cornerRadius(3)
                                    }
                                    if release.tag == "v\(UpdateManager.currentVersion)" {
                                        Text("installed").font(.caption2).foregroundStyle(.secondary)
                                    }
                                }
                                if !release.date.isEmpty {
                                    Text(release.date).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            .tag(release.tag)
                        }
                        .listStyle(.bordered(alternatesRowBackgrounds: true))
                        .frame(minHeight: 220)
                    }
                    .frame(width: 190)
                    .padding(.leading, 16)
                    .padding(.trailing, 8)
                    .padding(.vertical, 12)

                    Divider()

                    // Right: changelog
                    VStack(alignment: .leading, spacing: 6) {
                        if let rel = manager.selectedRelease {
                            Text(rel.name).font(.headline)
                            if !rel.date.isEmpty { Text(rel.date).foregroundStyle(.secondary).font(.subheadline) }
                            Text("v\(UpdateManager.currentVersion) → \(rel.tag)").font(.caption).foregroundStyle(.secondary)
                        }
                        Text("Release Notes").font(.subheadline.weight(.medium)).padding(.top, 4)
                        ScrollView {
                            Text(manager.selectedRelease?.body.isEmpty == false ? manager.selectedRelease!.body : "No release notes.")
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                                .padding(10)
                        }
                        .background(Color(nsColor: .textBackgroundColor))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.2)))
                        .frame(minHeight: 160)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                }
            }

            Divider()

            // Error
            if let err = manager.errorMessage {
                Text(err).foregroundStyle(.red).font(.caption).padding(.horizontal, 16).padding(.top, 6)
            }

            // Progress bar
            if manager.isDownloading {
                ProgressView(value: manager.downloadProgress) {
                    Text("Downloading… \(Int(manager.downloadProgress * 100))%")
                }
                .padding(.horizontal, 16).padding(.top, 6)
            }

            // Install result
            if let result = manager.installResult {
                if result.isEmpty {
                    Label("Installed — restarting…", systemImage: "checkmark.circle.fill")
                        .foregroundColor(.green).font(.callout).padding(.horizontal, 16).padding(.top, 6)
                } else {
                    Text("Install failed: \(result)").foregroundStyle(.red).font(.caption)
                        .padding(.horizontal, 16).padding(.top, 6)
                }
            }

            // Buttons
            HStack(spacing: 8) {
                Button("Refresh") { Task { await manager.checkForUpdates() } }
                    .disabled(manager.isChecking)
                Spacer()
                Link("All Releases", destination: manager.releasesPageURL)
                if manager.downloadedDMGPath != nil {
                    if manager.isInstalling {
                        ProgressView().scaleEffect(0.7)
                        Text("Installing…").foregroundStyle(.secondary)
                    } else {
                        Button("Install") { Task { await manager.installUpdate() } }.buttonStyle(.borderedProminent)
                        Button("Open DMG") { manager.openDMG() }
                    }
                } else {
                    Button("Download") {
                        Task { await manager.downloadUpdate() }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(manager.selectedRelease == nil || manager.isDownloading || manager.isChecking)
                }
                Button("Close") { dismiss() }
            }
            .padding(16)
        }
        .frame(width: 620, height: 500)
        .onAppear { if manager.allReleases.isEmpty { Task { await manager.checkForUpdates() } } }
    }
}
