import CoreFoundation
import Foundation
import QuartzCore

private typealias DeviceList = @convention(c) () -> Unmanaged<CFArray>?
private typealias DeviceID = @convention(c) (UnsafeMutableRawPointer, UnsafeMutablePointer<UInt64>) -> Int32
private typealias IsBuiltIn = @convention(c) (UnsafeMutableRawPointer) -> Bool
private typealias DeviceStart = @convention(c) (UnsafeMutableRawPointer, Int32) -> Void
private typealias DeviceStop = @convention(c) (UnsafeMutableRawPointer) -> Void
private typealias ActuatorCreate = @convention(c) (UInt64) -> Unmanaged<CFTypeRef>?
private typealias ActuatorOpen = @convention(c) (CFTypeRef) -> Int32
private typealias ActuationCreate = @convention(c) (CFDictionary, Int32) -> UnsafeMutableRawPointer?
private typealias ActuationPlay = @convention(c) (UnsafeMutableRawPointer, UnsafeMutableRawPointer, UInt32, Float, Float) -> Int32

final class HapticEngine {
    enum TrackpadAssignment: String, CaseIterable, Identifiable {
        case auto = "Auto (best)"
        case builtIn = "Built-in only"
        case external = "External only"
        case split = "Split: melody=built-in, harmony=external"
        var id: String { rawValue }
    }
    private struct TrackpadDevice {
        let id: UInt64
        let isBuiltIn: Bool
        let actuator: CFTypeRef
        let devicePtr: UnsafeMutableRawPointer
    }
    var onVoicesChanged: ([(frequency: Double, amplitude: Double)]) -> Void = { _ in }
    var onTrackpadsChanged: ([(id: UInt64, name: String, isBuiltIn: Bool)]) -> Void = { _ in }
    var trackpadAssignment: TrackpadAssignment = .auto
    private var devices: [TrackpadDevice] = []

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
    private var cachedDeviceList: CFArray?  // retain to keep device ptrs valid
    private var lastVisualVoices: [(frequency: Double, amplitude: Double)] = []
    private var visualFrameCount = 0

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

    func discoverDevices() {
        queue.async { [weak self] in
            guard let self,
                  let listFn = self.getSymbol("MTDeviceCreateList", as: DeviceList.self),
                  let idFn = self.getSymbol("MTDeviceGetDeviceID", as: DeviceID.self),
                  let startFn = self.getSymbol("MTDeviceStart", as: DeviceStart.self),
                  let createFn = self.getSymbol("MTActuatorCreateFromDeviceID", as: ActuatorCreate.self),
                  let openFn = self.getSymbol("MTActuatorOpen", as: ActuatorOpen.self),
                  let list = listFn()?.takeRetainedValue() else { return }
            // MTDeviceIsBuiltIn is optional — absent on some macOS versions; default to built-in if unavailable
            let builtInFn = self.getSymbol("MTDeviceIsBuiltIn", as: IsBuiltIn.self)
            self.devices.forEach { device in
                if let stopFn = self.getSymbol("MTDeviceStop", as: DeviceStop.self) { stopFn(device.devicePtr) }
            }
            self.devices.removeAll()
            self.cachedDeviceList = list
            for index in 0..<CFArrayGetCount(list) {
                guard let raw = CFArrayGetValueAtIndex(list, index) else { continue }
                let ptr = UnsafeMutableRawPointer(mutating: raw)
                _ = startFn(ptr, 0)
                var id: UInt64 = 0
                guard idFn(ptr, &id) == 0,
                      let actuator = createFn(id)?.takeRetainedValue(), openFn(actuator) == 0 else { continue }
                let isBuiltIn = builtInFn?(ptr) ?? true
                self.devices.append(TrackpadDevice(id: id, isBuiltIn: isBuiltIn, actuator: actuator, devicePtr: ptr))
            }
            let found = self.devices.map { (id: $0.id, name: $0.isBuiltIn ? "Built-in Trackpad" : "Magic Trackpad", isBuiltIn: $0.isBuiltIn) }
            DispatchQueue.main.async { self.onTrackpadsChanged(found) }
        }
    }

    func close() {
        queue.sync {
            stopRenderer()
            if let stopFn = getSymbol("MTDeviceStop", as: DeviceStop.self) { devices.forEach { stopFn($0.devicePtr) } }
            devices.removeAll()
            cachedDeviceList = nil
        }
    }

    // Synchronous device open — called as fallback from renderFrame() if discoverDevices() hasn't finished.
    // Must call MTDeviceStart before MTActuatorCreateFromDeviceID — required on M1 (Apple Silicon).
    private func openDevicesSynchronously() {
        guard let listFn = getSymbol("MTDeviceCreateList", as: DeviceList.self),
              let idFn = getSymbol("MTDeviceGetDeviceID", as: DeviceID.self),
              let createFn = getSymbol("MTActuatorCreateFromDeviceID", as: ActuatorCreate.self),
              let openFn = getSymbol("MTActuatorOpen", as: ActuatorOpen.self),
              let list = listFn()?.takeRetainedValue() else { return }
        cachedDeviceList = list
        let builtInFn = getSymbol("MTDeviceIsBuiltIn", as: IsBuiltIn.self)
        let startFn = getSymbol("MTDeviceStart", as: DeviceStart.self)
        for index in 0..<CFArrayGetCount(list) {
            guard let raw = CFArrayGetValueAtIndex(list, index) else { continue }
            let ptr = UnsafeMutableRawPointer(mutating: raw)
            _ = startFn?(ptr, 0)  // required on Apple Silicon before creating the actuator
            var id: UInt64 = 0
            guard idFn(ptr, &id) == 0,
                  let actuator = createFn(id)?.takeRetainedValue(),
                  openFn(actuator) == 0 else { continue }
            let isBuiltIn = builtInFn?(ptr) ?? true  // assume built-in if unknown
            devices.append(TrackpadDevice(id: id, isBuiltIn: isBuiltIn, actuator: actuator, devicePtr: ptr))
        }
    }

    private func midiNoteToHz(_ note: Int) -> Double { 440 * pow(2, Double(note - 69) / 12) }
    private func clampHz(_ hz: Double) -> Double { min(currentFrequencyMode == .standard ? 3951 : 8000, max(98, hz)) }

    func startNote(midiNote: Int, preset: InstrumentPreset, durationSeconds: Double, strength: Double = 0.8) {
        startVoice(key: midiNote, midiNote: midiNote, preset: preset, durationSeconds: durationSeconds, strength: strength)
    }

    /// Start a haptic voice using an arbitrary key (e.g. channel*128+note for multi-track MIDI).
    /// `midiNote` determines pitch; `key` is the unique slot in the voice map.
    func startVoice(key: Int, midiNote: Int, preset: InstrumentPreset, durationSeconds: Double, strength: Double = 0.8) {
        let voice = VoiceState(preset: preset, strength: strength, startTime: CACurrentMediaTime(), duration: durationSeconds, frequency: clampHz(midiNoteToHz(midiNote)))
        queue.async { [weak self] in self?.voices[key] = voice; self?.ensureRenderer() }
    }

    func startNoteSustained(midiNote: Int, preset: InstrumentPreset, strength: Double = 0.8) {
        startNote(midiNote: midiNote, preset: preset, durationSeconds: -1, strength: strength)
    }

    func stopNote(midiNote: Int) {
        stopVoice(key: midiNote)
    }

    /// Stop a voice by its arbitrary key (matches startVoice(key:)).
    func stopVoice(key: Int) {
        queue.async { [weak self] in
            guard let self else { return }
            self.voices.removeValue(forKey: key)
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
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5 + Double(index) * 0.14) { [weak self] in
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

    // Compute DurationMS aligned to a whole number of cycles of `hz`.
    // Target ~11ms so each frame is clean without click artefacts at the boundary.
    private func wholeCycleDurationMs(hz: Double) -> Double {
        let periodMs = 1000.0 / hz
        let n = max(1, Int((11.0 / periodMs).rounded()))
        return Double(n) * periodMs
    }

    private func renderFrame() {
        let now = CACurrentMediaTime()
        for (note, voice) in voices where voice.duration >= 0 && now - voice.startTime >= voice.duration {
            voices.removeValue(forKey: note)
        }
        guard !voices.isEmpty else { DispatchQueue.main.async { [weak self] in self?.onVoicesChanged([]) }; stopRenderer(); return }
        // Lazy device open: if discoverDevices() hasn't finished yet, open synchronously now
        if devices.isEmpty { openDevicesSynchronously() }
        guard !devices.isEmpty,
              let createFn = getSymbol("MTActuationCreateFromDictionary", as: ActuationCreate.self),
              let playFn = getSymbol("MTActuationActuate", as: ActuationPlay.self) else { return }

        let sorted = voices.sorted { $0.value.frequency > $1.value.frequency }
        let melody = sorted.first?.key
        let active = Array(sorted.prefix(4))
        let visual = active.map { ($0.value.frequency, min(1, max(0, $0.value.strength))) }
        visualFrameCount += 1
        if visualFrameCount >= 3 {
            visualFrameCount = 0
            DispatchQueue.main.async { [weak self] in self?.onVoicesChanged(visual) }
        }
        let polyphonic = active.count > 1
        var tones: [[String: Any]] = []
        var melodyTones: [[String: Any]] = []
        var harmonyTones: [[String: Any]] = []
        for (note, voice) in active {
            let elapsed = now - voice.startTime
            // Attack envelope
            let attack = voice.preset.attackTime > 0 ? min(1, elapsed / voice.preset.attackTime) : 1.0
            // Decay envelope: fade out the last decayTime seconds of a finite note
            let decay: Double
            if voice.preset.decayTime > 0, voice.duration > 0 {
                let remaining = (voice.startTime + voice.duration) - now
                decay = remaining < voice.preset.decayTime ? max(0.05, remaining / voice.preset.decayTime) : 1.0
            } else { decay = 1.0 }
            let budget = polyphonic ? (note == melody ? 0.55 : 0.45) : 1.0
            // Whole-cycle duration aligned to the fundamental of this voice
            let durationMs = wholeCycleDurationMs(hz: voice.frequency)
            for partial in voice.preset.partials.prefix(2) {
                let frequency = clampHz(voice.frequency * partial.multiplier)
                // Raw amplitude before normalization — will be normalized per-actuation below
                let amplitude = partial.amplitude * attack * decay * budget * voice.strength
                let tone: [String: Any] = ["Type": "Sine", "Amplitude": amplitude, "DurationMS": durationMs, "DelayMS": 0.0, "FrequencykHz": frequency / 1000]
                tones.append(tone)
                if note == melody { melodyTones.append(tone) } else { harmonyTones.append(tone) }
            }
        }
        guard !tones.isEmpty else { return }
        let strength = active.map { $0.value.strength }.max() ?? 0.8

        // Normalize amplitudes to sum ≤ 1.0 — matches original nospeaker.swift and prevents motor distortion
        func normalize(_ tones: [[String: Any]]) -> [[String: Any]] {
            let sum = tones.compactMap { $0["Amplitude"] as? Double }.reduce(0, +)
            guard sum > 0.0001 else { return tones }
            return tones.map { var t = $0; t["Amplitude"] = ((t["Amplitude"] as? Double) ?? 0) / sum; return t }
        }

        func play(_ rawTones: [[String: Any]], on device: TrackpadDevice) {
            guard !rawTones.isEmpty else { return }
            let normalized = normalize(rawTones)
            let maxDurationMs = normalized.compactMap { $0["DurationMS"] as? Double }.max() ?? 11.0
            let shape: [String: Any] = [
                "BaseWaveform": ["Type": "Gaussian", "Amplitude": 0.0, "DurationMS": maxDurationMs],
                "Tones": Array(normalized.prefix(6))
            ]
            guard let actuation = createFn(shape as CFDictionary, 0) else { return }
            _ = playFn(actuation, Unmanaged.passUnretained(device.actuator).toOpaque(), 0, Float(min(1, max(0, strength))), 0)
            Unmanaged<AnyObject>.fromOpaque(actuation).release()
        }
        if trackpadAssignment == .split {
            let builtIn = devices.first(where: \.isBuiltIn)
            let external = devices.first(where: { !$0.isBuiltIn })
            if let builtIn { play(melodyTones, on: builtIn) }
            if let external { play(harmonyTones, on: external) }
        } else {
            let target: TrackpadDevice? = trackpadAssignment == .builtIn ? devices.first(where: \.isBuiltIn) : trackpadAssignment == .external ? devices.first(where: { !$0.isBuiltIn }) : devices.first(where: \.isBuiltIn) ?? devices.first
            if let target { play(tones, on: target) }
        }
        if currentDebugEnabled {
            print("HapticEngine: rendered \(active.count) voice(s) in \((CACurrentMediaTime() - now) * 1000) ms")
        }
    }
}
