import CoreFoundation
import Foundation
import QuartzCore

private typealias DeviceList = @convention(c) () -> Unmanaged<CFArray>?
private typealias DeviceID = @convention(c) (UnsafeMutableRawPointer, UnsafeMutablePointer<UInt64>) -> Int32
private typealias IsBuiltIn = @convention(c) (UnsafeMutableRawPointer) -> Bool
private typealias DeviceStart = @convention(c) (UnsafeMutableRawPointer, Int32) -> Int32
private typealias DeviceStop = @convention(c) (UnsafeMutableRawPointer, Int32) -> Int32
private typealias ActuatorCreate = @convention(c) (UInt64) -> Unmanaged<CFTypeRef>?
private typealias ActuatorOpen = @convention(c) (CFTypeRef) -> Int32
private typealias ActuationCreate = @convention(c) (CFDictionary, Int32) -> UnsafeMutableRawPointer?
private typealias ActuationPlay = @convention(c) (UnsafeMutableRawPointer, UnsafeMutableRawPointer, UInt32, Float, Float) -> Int32

final class HapticEngine {
    enum FrequencyMode: String, CaseIterable, Identifiable {
        case standard = "Standard (100–4000 Hz)"
        case extended = "Extended (100–8000 Hz, experimental)"
        var id: String { rawValue }
    }

    struct VoiceState {
        let preset: InstrumentPreset
        let strength: Double
        let startTime: CFTimeInterval
        let duration: Double
        var frequency: Double
    }

    private let queue = DispatchQueue(label: "haptic.engine", qos: .userInteractive)
    private let configurationLock = NSLock()
    private var _frequencyMode: FrequencyMode = .standard
    private var _debugEnabled = false
    var frequencyMode: FrequencyMode {
        get { configurationLock.lock(); defer { configurationLock.unlock() }; return _frequencyMode }
        set { configurationLock.lock(); _frequencyMode = newValue; configurationLock.unlock() }
    }
    var debugEnabled: Bool {
        get { configurationLock.lock(); defer { configurationLock.unlock() }; return _debugEnabled }
        set { configurationLock.lock(); _debugEnabled = newValue; configurationLock.unlock() }
    }

    private var voices: [Int: VoiceState] = [:]
    private var renderTimer: DispatchSourceTimer?
    private let library = dlopen("/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport", RTLD_NOW)
    private var cachedActuator: CFTypeRef?
    private var cachedDevicePtr: UnsafeMutableRawPointer?

    private var currentFrequencyMode: FrequencyMode {
        configurationLock.lock(); defer { configurationLock.unlock() }; return _frequencyMode
    }
    private var currentDebugEnabled: Bool {
        configurationLock.lock(); defer { configurationLock.unlock() }; return _debugEnabled
    }

    private func getSymbol<T>(_ name: String, as type: T.Type) -> T? {
        guard let library, let pointer = dlsym(library, name) else { return nil }
        return unsafeBitCast(pointer, to: type)
    }

    private func getActuator() -> CFTypeRef? {
        if let cachedActuator { return cachedActuator }
        guard let listFn = getSymbol("MTDeviceCreateList", as: DeviceList.self),
              let idFn = getSymbol("MTDeviceGetDeviceID", as: DeviceID.self),
              let builtInFn = getSymbol("MTDeviceIsBuiltIn", as: IsBuiltIn.self),
              let startFn = getSymbol("MTDeviceStart", as: DeviceStart.self),
              let createFn = getSymbol("MTActuatorCreateFromDeviceID", as: ActuatorCreate.self),
              let openFn = getSymbol("MTActuatorOpen", as: ActuatorOpen.self),
              let list = listFn()?.takeRetainedValue() else { return nil }
        for index in 0..<CFArrayGetCount(list) {
            guard let raw = CFArrayGetValueAtIndex(list, index) else { continue }
            let ptr = UnsafeMutableRawPointer(mutating: raw)
            guard builtInFn(ptr) else { continue }
            _ = startFn(ptr, 0)
            var id: UInt64 = 0
            guard idFn(ptr, &id) == 0,
                  let candidate = createFn(id)?.takeRetainedValue(),
                  openFn(candidate) == 0 else { continue }
            cachedDevicePtr = ptr
            cachedActuator = candidate
            return candidate
        }
        return nil
    }

    func close() {
        queue.sync {
            stopRenderer()
            if let ptr = cachedDevicePtr,
               let stopFn = getSymbol("MTDeviceStop", as: DeviceStop.self) {
                _ = stopFn(ptr, 0)
            }
            cachedActuator = nil
            cachedDevicePtr = nil
        }
    }

    private func midiNoteToHz(_ note: Int) -> Double { 440 * pow(2, Double(note - 69) / 12) }
    private func clampHz(_ hz: Double) -> Double { min(currentFrequencyMode == .standard ? 3951 : 8000, max(98, hz)) }

    func startNote(midiNote: Int, preset: InstrumentPreset, durationSeconds: Double, strength: Double = 0.8) {
        let voice = VoiceState(preset: preset, strength: strength, startTime: CACurrentMediaTime(), duration: durationSeconds, frequency: clampHz(midiNoteToHz(midiNote)))
        queue.async { [weak self] in self?.voices[midiNote] = voice; self?.ensureRenderer() }
    }

    func startNoteSustained(midiNote: Int, preset: InstrumentPreset, strength: Double = 0.8) {
        startNote(midiNote: midiNote, preset: preset, durationSeconds: -1, strength: strength)
    }

    func stopNote(midiNote: Int) {
        queue.async { [weak self] in
            guard let self else { return }
            self.voices.removeValue(forKey: midiNote)
            if self.voices.isEmpty { self.stopRenderer() }
        }
    }

    func stopAllNotes() {
        queue.async { [weak self] in self?.voices.removeAll(); self?.stopRenderer() }
    }

    func stopAllTones() { stopAllNotes() }

    func glideFrequency(midiNote: Int, toHz: Double) {
        queue.async { [weak self] in guard let self else { return }; self.voices[midiNote]?.frequency = self.clampHz(toHz) }
    }

    func playTone(frequency: Double, durationSeconds: Double, strength: Double = 0.8, preset: InstrumentPreset = .theremin) {
        let voice = VoiceState(preset: preset, strength: strength, startTime: CACurrentMediaTime(), duration: durationSeconds, frequency: clampHz(frequency))
        queue.async { [weak self] in self?.voices[-1] = voice; self?.ensureRenderer() }
    }

    func playWelcomeMelody() {
        let notes = [60, 64, 67, 72, 71, 67, 64, 60]
        for (index, note) in notes.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3 + Double(index) * 0.14) { [weak self] in
                self?.startNote(midiNote: note, preset: .piano, durationSeconds: 0.12, strength: 0.9)
            }
        }
    }

    private func ensureRenderer() {
        guard renderTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(10), leeway: .microseconds(500))
        timer.setEventHandler { [weak self] in self?.renderFrame() }
        renderTimer = timer
        timer.resume()
    }

    private func stopRenderer() {
        renderTimer?.setEventHandler {}
        renderTimer?.cancel()
        renderTimer = nil
    }

    private func renderFrame() {
        let now = CACurrentMediaTime()
        for (note, voice) in voices where voice.duration >= 0 && now - voice.startTime >= voice.duration {
            voices.removeValue(forKey: note)
        }
        guard !voices.isEmpty else { stopRenderer(); return }
        guard let actuator = getActuator(),
              let createFn = getSymbol("MTActuationCreateFromDictionary", as: ActuationCreate.self),
              let playFn = getSymbol("MTActuationActuate", as: ActuationPlay.self) else { return }

        let sorted = voices.sorted { $0.value.frequency > $1.value.frequency }
        let melody = sorted.first?.key
        let active = Array(sorted.prefix(4))
        let polyphonic = active.count > 1
        var tones: [[String: Any]] = []
        for (note, voice) in active {
            let elapsed = now - voice.startTime
            let attack = voice.preset.attackTime > 0 ? min(1, elapsed / voice.preset.attackTime) : 1
            let budget = polyphonic ? (note == melody ? 0.6 : 0.4) : 1.0
            for partial in voice.preset.partials.prefix(2) {
                let frequency = clampHz(voice.frequency * partial.multiplier)
                let amplitude = min(0.95, partial.amplitude * attack * budget * voice.strength)
                tones.append(["Type": "Sine", "Amplitude": amplitude, "DurationMS": 12.0, "DelayMS": 0.0, "FrequencykHz": frequency / 1000])
            }
        }
        guard !tones.isEmpty else { return }
        let shape: [String: Any] = ["Tones": Array(tones.prefix(6))]
        let strength = active.map { $0.value.strength }.max() ?? 0.8
        if let actuation = createFn(shape as CFDictionary, 0) {
            _ = playFn(actuation, Unmanaged.passUnretained(actuator).toOpaque(), 0, Float(min(1, max(0, strength))), 0)
            Unmanaged<AnyObject>.fromOpaque(actuation).release()
        }
        if currentDebugEnabled {
            print("HapticEngine: rendered \(active.count) voice(s) in \((CACurrentMediaTime() - now) * 1000) ms")
        }
    }
}
