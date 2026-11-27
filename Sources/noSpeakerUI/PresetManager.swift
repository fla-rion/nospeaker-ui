import Combine
import Foundation

struct Preset: Codable, Identifiable {
    var id = UUID()
    var name: String
    var instrument: String
    var tempo: Double
    var volume: Double
    var octave: Int
    var portamentoMilliseconds: Double
    var legato: Bool
    var frequencyMode: String
}

@MainActor final class PresetManager: ObservableObject {
    @Published var presets: [Preset] = []
    @Published var showingSaveDialog = false
    @Published var newPresetName = ""
    private let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/nospeakerui/presets.json")

    init() { load() }
    func save(_ preset: Preset) {
        presets.removeAll { $0.name == preset.name }
        presets.append(preset)
        persist()
    }
    func delete(_ preset: Preset) { presets.removeAll { $0.id == preset.id }; persist() }
    private func persist() {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(presets).write(to: url)
    }
    private func load() {
        guard let data = try? Data(contentsOf: url) else { return }
        presets = (try? JSONDecoder().decode([Preset].self, from: data)) ?? []
    }
}
