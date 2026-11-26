import Foundation

/// Drives the same sustained tone mode used by the app's existing trackpad controller.
@MainActor
final class HapticEngine {
    private var process: Process?
    private var endTask: Task<Void, Never>?
    private var binaryURL: URL? { Bundle.main.url(forResource: "nospeaker", withExtension: nil) }

    func playTone(frequency: Double, durationSeconds: Double, strength: Double = 1.0) async {
        stopAllTones()
        guard let binaryURL else { return }
        let task = Process(); task.executableURL = binaryURL
        task.arguments = ["--tone", String(format: "%.2f", min(4000, max(100, frequency))), "--strength", String(format: "%.2f", min(1, max(0, strength)))]
        do {
            try task.run(); process = task
            endTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(max(0.03, durationSeconds) * 1_000_000_000))
                guard !Task.isCancelled else { return }
                self?.stopAllTones()
            }
        } catch { process = nil }
    }

    func stopAllTones() {
        endTask?.cancel(); endTask = nil
        if let process, process.isRunning { process.terminate() }
        process = nil
    }
}
