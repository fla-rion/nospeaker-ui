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
    private var process: Process?
    private struct Voice { var task: Task<Void, Never>; let preset: InstrumentPreset; let strength: Double; let started: Date; let duration: Double; var frequency: Double }
    private var activeNotes: [Int: Voice] = [:]
    private var renderTask: Task<Void, Never>?

    private func symbol<T>(_ name: String, as type: T.Type) -> T? {
        guard let library, let pointer = dlsym(library, name) else { return nil }
        return unsafeBitCast(pointer, to: type)
    }
    private func openActuator() -> CFTypeRef? {
        if let actuator { return actuator }
        guard let listFn = symbol("MTDeviceCreateList", as: DeviceList.self), let idFn = symbol("MTDeviceGetDeviceID", as: DeviceID.self), let createFn = symbol("MTActuatorCreateFromDeviceID", as: ActuatorCreate.self), let openFn = symbol("MTActuatorOpen", as: ActuatorOpen.self), let list = listFn()?.takeRetainedValue() else { return nil }
        for index in 0..<CFArrayGetCount(list) {
            guard let raw = CFArrayGetValueAtIndex(list, index) else { continue }
            var id: UInt64 = 0
            if idFn(UnsafeMutableRawPointer(mutating: raw), &id) == 0, let candidate = createFn(id)?.takeRetainedValue(), openFn(candidate) == 0 { actuator = candidate; return candidate }
        }
        return nil
    }
    func playWelcomeMelody() async {
        for note in [60, 64, 67, 72, 71, 67, 64, 60] { await playNote(midiNote: note, preset: .piano, durationSeconds: 0.12, strength: 0.85); try? await Task.sleep(nanoseconds: 120_000_000) }
    }
    func playNote(midiNote: Int, preset: InstrumentPreset, durationSeconds: Double, strength: Double = 0.8) async {
        let task = Task { do { try await Task.sleep(nanoseconds: UInt64(max(0.03, durationSeconds) * 1_000_000_000)) } catch {} }
        activeNotes[midiNote]?.task.cancel()
        activeNotes[midiNote] = Voice(task: task, preset: preset, strength: strength, started: Date(), duration: max(0.03, durationSeconds), frequency: 440 * pow(2, Double(midiNote - 69) / 12))
        startRenderer()
    }
    func stopNote(midiNote: Int) { activeNotes.removeValue(forKey: midiNote)?.task.cancel(); if activeNotes.isEmpty { renderTask?.cancel(); renderTask = nil } }
    func stopAllNotes() { activeNotes.values.forEach { $0.task.cancel() }; activeNotes.removeAll(); renderTask?.cancel(); renderTask = nil }
    func glideToNote(from: Int, to: Int, preset: InstrumentPreset, portamentoMilliseconds: Double = 40) async {
        let fromHz = 440 * pow(2, Double(from - 69) / 12), toHz = 440 * pow(2, Double(to - 69) / 12)
        activeNotes[from]?.task.cancel(); activeNotes.removeValue(forKey: from)
        await playNote(midiNote: to, preset: preset, durationSeconds: 0.5)
        let steps = 4, interval = max(0.01, portamentoMilliseconds / 1000 / Double(steps))
        for step in 1...steps {
            if var voice = activeNotes[to] { voice.frequency = fromHz + (toHz - fromHz) * Double(step) / Double(steps); activeNotes[to] = voice }
            try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
        }
    }
    func playTone(frequency: Double, durationSeconds: Double, strength: Double = 0.8, preset: InstrumentPreset = .flute) async {
        stopAllNotes()
        let task = Task { do { try await Task.sleep(nanoseconds: UInt64(max(0.03, durationSeconds) * 1_000_000_000)) } catch {} }
        activeNotes[-1] = Voice(task: task, preset: preset, strength: strength, started: Date(), duration: max(0.03, durationSeconds), frequency: frequency)
        startRenderer()
    }
    func stopAllTones() { stopAllNotes(); if let process, process.isRunning { process.terminate() }; process = nil }
    private func startRenderer() {
        guard renderTask == nil else { return }
        renderTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.renderFrame()
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
        }
    }
    private func renderFrame() {
        guard let actuator = openActuator(), let createFn = symbol("MTActuationCreateFromDictionary", as: ActuationCreate.self), let playFn = symbol("MTActuationActuate", as: ActuationPlay.self) else { return }
        let now = Date()
        activeNotes = activeNotes.filter { !$0.value.task.isCancelled && now.timeIntervalSince($0.value.started) < $0.value.duration }
        if activeNotes.isEmpty { renderTask?.cancel(); renderTask = nil; return }
        let voices = Array(activeNotes.values.prefix(4))
        let tones: [[String: Any]] = voices.flatMap { voice in voice.preset.partials.map { partial in
            let elapsed = now.timeIntervalSince(voice.started)
            let attack = voice.preset.attackTime > 0 ? min(1, elapsed / voice.preset.attackTime) : 1
            let decay = voice.preset.decayTime > 0 ? max(0.25, 1 - elapsed / voice.duration * 0.5) : 1
            return ["Type": "Sine", "Amplitude": partial.amplitude * attack * decay, "DurationMS": 35.0, "DelayMS": 0.0, "FrequencykHz": voice.frequency * partial.multiplier / 1000]
        }}
        let strength = voices.map(\.strength).max() ?? 0.8
        let shape: [String: Any] = ["BaseWaveform": ["Type": "Gaussian", "Amplitude": 0.0, "DurationMS": 35.0], "Tones": tones]
        guard let actuation = createFn(shape as CFDictionary, 0) else { return }
        _ = playFn(actuation, Unmanaged.passUnretained(actuator).toOpaque(), 0, Float(min(1, max(0, strength))), 0)
        Unmanaged<AnyObject>.fromOpaque(actuation).release()
    }
}
