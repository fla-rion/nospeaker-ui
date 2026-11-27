import CoreFoundation
import Foundation

private typealias DeviceList = @convention(c) () -> Unmanaged<CFArray>?
private typealias DeviceID = @convention(c) (UnsafeMutableRawPointer, UnsafeMutablePointer<UInt64>) -> Int32
private typealias ActuatorCreate = @convention(c) (UInt64) -> Unmanaged<CFTypeRef>?
private typealias ActuatorOpen = @convention(c) (CFTypeRef) -> Int32
private typealias ActuationCreate = @convention(c) (CFDictionary, Int32) -> UnsafeMutableRawPointer?
private typealias ActuationPlay = @convention(c) (UnsafeMutableRawPointer, UnsafeMutableRawPointer, UInt32, Float, Float) -> Int32

@MainActor
final class HapticEngine {
    private let library = dlopen("/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport", RTLD_NOW)
    private var actuator: CFTypeRef?
    private var playingTask: Task<Void, Never>?
    private var process: Process?
    private var endTask: Task<Void, Never>?

    private func symbol<T>(_ name: String, as type: T.Type) -> T? {
        guard let library, let pointer = dlsym(library, name) else { return nil }
        return unsafeBitCast(pointer, to: type)
    }

    private func openActuator() -> CFTypeRef? {
        if let actuator { return actuator }
        guard let listFn = symbol("MTDeviceCreateList", as: DeviceList.self),
              let idFn = symbol("MTDeviceGetDeviceID", as: DeviceID.self),
              let createFn = symbol("MTActuatorCreateFromDeviceID", as: ActuatorCreate.self),
              let openFn = symbol("MTActuatorOpen", as: ActuatorOpen.self),
              let list = listFn()?.takeRetainedValue() else { return nil }
        for index in 0..<CFArrayGetCount(list) {
            guard let raw = CFArrayGetValueAtIndex(list, index) else { continue }
            var id: UInt64 = 0
            if idFn(UnsafeMutableRawPointer(mutating: raw), &id) == 0,
               let candidate = createFn(id)?.takeRetainedValue(), openFn(candidate) == 0 {
                actuator = candidate
                return candidate
            }
        }
        return nil
    }

    func playWelcomeMelody() async {
        for note in [60, 64, 67, 72, 71, 67, 64, 60] {
            await playNote(midiNote: note, preset: .piano, durationSeconds: 0.12, strength: 0.85)
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    func playNote(midiNote: Int, preset: InstrumentPreset, durationSeconds: Double, strength: Double = 0.8) async {
        let hz = 440 * pow(2, Double(midiNote - 69) / 12)
        await playTone(frequency: hz, durationSeconds: durationSeconds, strength: strength, preset: preset)
    }

    func playTone(frequency: Double, durationSeconds: Double, strength: Double = 0.8, preset: InstrumentPreset = .flute) async {
        stopAllTones()
        guard let actuator = openActuator(),
              let createFn = symbol("MTActuationCreateFromDictionary", as: ActuationCreate.self),
              let playFn = symbol("MTActuationActuate", as: ActuationPlay.self) else { return }
        let tones = preset.partials.map { partial in
            ["Type": "Sine", "Amplitude": partial.amplitude, "DurationMS": max(30, durationSeconds * 1000), "DelayMS": 0.0, "FrequencykHz": frequency * partial.multiplier / 1000] as [String: Any]
        }
        let shape: [String: Any] = ["BaseWaveform": ["Type": "Gaussian", "Amplitude": 0.0, "DurationMS": max(30, durationSeconds * 1000)], "Tones": tones]
        guard let actuation = createFn(shape as CFDictionary, 0) else { return }
        _ = playFn(actuation, Unmanaged.passUnretained(actuator).toOpaque(), 0, Float(min(1, max(0, strength))), 0)
        Unmanaged<AnyObject>.fromOpaque(actuation).release()
        endTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(0.03, durationSeconds) * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.stopAllTones()
        }
    }

    func stopAllTones() {
        endTask?.cancel(); endTask = nil
        playingTask?.cancel(); playingTask = nil
        if let process, process.isRunning { process.terminate() }
        process = nil
    }
}
