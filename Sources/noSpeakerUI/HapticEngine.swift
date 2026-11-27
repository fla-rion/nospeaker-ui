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
    enum FrequencyMode: String, CaseIterable, Identifiable {
        case standard = "Standard (100–4000 Hz)"
        case extended = "Extended (100–8000 Hz, experimental)"
        var id: String { rawValue }
    }
    var frequencyMode: FrequencyMode = .standard
    var debugEnabled = false
    private(set) var minimumFrameMilliseconds = 10.0
    private(set) var maximumFrameMilliseconds = 10.0
    private let library = dlopen("/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport", RTLD_NOW)
    private var actuator: CFTypeRef?
    private var process: Process?
    private struct Voice { let preset: InstrumentPreset; let strength: Double; let started: Date; let duration: Double; var frequency: Double }
    private var activeNotes: [Int: Task<Void, Never>] = [:]
    private var sustainedNotes = Set<Int>()
    private var voices: [Int: Voice] = [:]
    private var renderTimer: DispatchSourceTimer?
    private var eventBuffer = [Int](repeating: 0, count: 64)
    private var eventRead = 0
    private var eventWrite = 0
    private var eventCount = 0
    private let renderQueue = DispatchQueue(label: "haptic.render", qos: .userInteractive)

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
        var notes = [60, 64, 67, 72, 71, 67, 64, 60]
        if frequencyMode == .extended { notes.append(contentsOf: [84, 96, 108]) }
        for note in notes { await playNote(midiNote: note, preset: .piano, durationSeconds: 0.12, strength: 0.85); try? await Task.sleep(nanoseconds: 120_000_000) }
    }
    func playNote(midiNote: Int, preset: InstrumentPreset, durationSeconds: Double, strength: Double = 0.8, sustainUntilStopped: Bool = false) async {
        let task = Task { do { try await Task.sleep(nanoseconds: UInt64(max(0.03, durationSeconds) * 1_000_000_000)) } catch {} }
        activeNotes[midiNote]?.cancel()
        activeNotes[midiNote] = task
        if sustainUntilStopped { sustainedNotes.insert(midiNote) } else { sustainedNotes.remove(midiNote) }
        print("HapticEngine: note \(midiNote), preset=\(preset.rawValue), partials=\(preset.partials.count), duration=\(durationSeconds)s, sustained=\(sustainUntilStopped)")
        enqueue(midiNote)
        let hz = 440 * pow(2, Double(midiNote - 69) / 12)
        voices[midiNote] = Voice(preset: preset, strength: strength, started: Date(), duration: max(0.03, durationSeconds), frequency: min(frequencyMode == .standard ? 3951 : 8000, max(98, hz)))
        startRenderer()
    }
    func stopNote(midiNote: Int) { activeNotes.removeValue(forKey: midiNote)?.cancel(); sustainedNotes.remove(midiNote); voices.removeValue(forKey: midiNote); if activeNotes.isEmpty { stopRenderer() } }
    func stopAllNotes() { activeNotes.values.forEach { $0.cancel() }; activeNotes.removeAll(); sustainedNotes.removeAll(); voices.removeAll(); stopRenderer() }
    func glideToNote(from: Int, to: Int, preset: InstrumentPreset, portamentoMilliseconds: Double = 40, sustainUntilStopped: Bool = false) async {
        let fromHz = 440 * pow(2, Double(from - 69) / 12), toHz = 440 * pow(2, Double(to - 69) / 12)
        activeNotes[from]?.cancel(); activeNotes.removeValue(forKey: from); voices.removeValue(forKey: from)
        await playNote(midiNote: to, preset: preset, durationSeconds: 0.5, sustainUntilStopped: sustainUntilStopped)
        let steps = 4, interval = max(0.01, portamentoMilliseconds / 1000 / Double(steps))
        for step in 1...steps {
            if var voice = voices[to] { voice.frequency = fromHz + (toHz - fromHz) * Double(step) / Double(steps); voices[to] = voice }
            try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
        }
    }
    func playTone(frequency: Double, durationSeconds: Double, strength: Double = 0.8, preset: InstrumentPreset = .flute) async {
        stopAllNotes()
        let task = Task { do { try await Task.sleep(nanoseconds: UInt64(max(0.03, durationSeconds) * 1_000_000_000)) } catch {} }
        activeNotes[-1] = task
        voices[-1] = Voice(preset: preset, strength: strength, started: Date(), duration: max(0.03, durationSeconds), frequency: frequency)
        startRenderer()
    }
    func stopAllTones() { stopAllNotes(); if let process, process.isRunning { process.terminate() }; process = nil }
    private func enqueue(_ note: Int) {
        if eventCount >= eventBuffer.count { eventRead = (eventRead + 1) % eventBuffer.count; eventCount -= 1 }
        eventBuffer[eventWrite] = note; eventWrite = (eventWrite + 1) % eventBuffer.count; eventCount += 1
    }
    private func startRenderer() {
        guard renderTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: renderQueue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(10), leeway: .microseconds(500))
        timer.setEventHandler { [weak self] in
            Task { @MainActor in self?.renderFrame() }
        }
        renderTimer = timer; timer.resume()
    }
    private func stopRenderer() {
        renderTimer?.setEventHandler {}
        renderTimer?.cancel(); renderTimer = nil
    }
    private func renderFrame() {
        guard let actuator = openActuator(), let createFn = symbol("MTActuationCreateFromDictionary", as: ActuationCreate.self), let playFn = symbol("MTActuationActuate", as: ActuationPlay.self) else { return }
        let now = Date()
        for (note, task) in Array(activeNotes) where task.isCancelled || (!sustainedNotes.contains(note) && now.timeIntervalSince(voices[note]?.started ?? now) >= (voices[note]?.duration ?? 0)) { activeNotes.removeValue(forKey: note)?.cancel(); sustainedNotes.remove(note); voices.removeValue(forKey: note) }
        if voices.isEmpty { stopRenderer(); return }
        let sortedVoices = voices.sorted { $0.value.frequency > $1.value.frequency }
        let melodyNote = sortedVoices.first?.key
        let currentVoices = sortedVoices.prefix(4).map(\.value)
        let candidates: [(amplitude: Double, tone: [String: Any])] = currentVoices.flatMap { voice in voice.preset.partials.map { partial in
            let elapsed = now.timeIntervalSince(voice.started)
            let attack = voice.preset.attackTime > 0 ? min(1, elapsed / voice.preset.attackTime) : 1
            let decay = voice.preset.decayTime > 0 ? max(0.25, 1 - elapsed / voice.duration * 0.5) : 1
            let frequency = min(frequencyMode == .standard ? 3951 : 8000, max(98, voice.frequency * partial.multiplier))
            let note = sortedVoices.first(where: { $0.value.started == voice.started })?.key
            let isPolyphonic = currentVoices.count > 1
            let budget = isPolyphonic ? (note == melodyNote ? 0.6 : 0.4) : 1.0
            let amplitude = min(0.95, partial.amplitude * attack * decay * budget)
            return (amplitude, ["Type": "Sine", "Amplitude": amplitude, "DurationMS": 15.0, "DelayMS": 0.0, "FrequencykHz": frequency / 1000])
        }}
        // No global normalization — clamp each amplitude independently above.
        let voiceLimit = max(1, 6 / max(1, currentVoices.count))
        // Take at most 2 partials per active voice (like nospeaker.swift's 2-formant model).
        let tones = candidates.sorted { $0.amplitude > $1.amplitude }.prefix(voiceLimit * 2).map(\.tone)
        let strength = currentVoices.map(\.strength).max() ?? 0.8
        let shape: [String: Any] = ["Tones": tones]
        guard let actuation = createFn(shape as CFDictionary, 0) else { return }
        _ = playFn(actuation, Unmanaged.passUnretained(actuator).toOpaque(), 0, Float(min(1, max(0, strength))), 0)
        Unmanaged<AnyObject>.fromOpaque(actuation).release()
        if debugEnabled { let ms = Date().timeIntervalSince(now) * 1000; minimumFrameMilliseconds = min(minimumFrameMilliseconds, ms); maximumFrameMilliseconds = max(maximumFrameMilliseconds, ms) }
    }
}
