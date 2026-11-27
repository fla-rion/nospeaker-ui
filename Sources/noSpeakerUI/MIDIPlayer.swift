import AppKit
import Combine
import Foundation

struct BuiltInPiece: Identifiable {
    let name: String; let composer: String; let filename: String; let difficulty: String
    var id: String { filename }
    static let all: [BuiltInPiece] = [
        .init(name:"Für Elise",composer:"Beethoven",filename:"fur_elise.mid",difficulty:"Medium"),
        .init(name:"Mondscheinsonate",composer:"Beethoven",filename:"moonlight_sonata.mid",difficulty:"Advanced"),
        .init(name:"Kanon in D",composer:"Pachelbel",filename:"canon_in_d.mid",difficulty:"Easy"),
        .init(name:"Türkischer Marsch",composer:"Mozart",filename:"turkish_march.mid",difficulty:"Medium"),
        .init(name:"The Entertainer",composer:"Joplin",filename:"the_entertainer.mid",difficulty:"Medium"),
        .init(name:"Gymnopédie Nr. 1",composer:"Satie",filename:"gymnopedie_no1.mid",difficulty:"Easy"),
        .init(name:"Eine Kleine Nachtmusik",composer:"Mozart",filename:"eine_kleine_nachtmusik.mid",difficulty:"Medium"),
        .init(name:"Schwanensee-Thema",composer:"Tschaikowski",filename:"swan_lake.mid",difficulty:"Easy"),
        .init(name:"Ode an die Freude",composer:"Beethoven",filename:"ode_to_joy.mid",difficulty:"Easy"),
        .init(name:"Frühling (Vivaldi)",composer:"Vivaldi",filename:"spring_vivaldi.mid",difficulty:"Advanced")]
}

@MainActor final class MIDIPlayer: ObservableObject {
    // Shared HapticEngine — injected from ContentView to avoid two engines on same hardware
    @Published var isPlaying = false
    @Published var currentTrackName = ""
    @Published var progress = 0.0
    @Published var currentInstrument = InstrumentPreset.piano  // default for channels without GM mapping
    @Published var tempo = 1.0
    @Published var volume = 0.8
    @Published var transpose = 0
    @Published var loop = false
    @Published var legato = false
    @Published var portamentoMilliseconds = 40.0
    @Published var selectedURL: URL?
    @Published var currentNoteLabel = ""
    @Published var polyphonyLimit = 4
    @Published var visualVoices: [(frequency: Double, amplitude: Double)] = []
    @Published var trackpadAssignment: HapticEngine.TrackpadAssignment = .auto {
        didSet { haptics.trackpadAssignment = trackpadAssignment }
    }
    @Published private(set) var flashingNotes = Set<Int>()

    // Multi-track: per-channel preset mapping (auto-detected from GM Program Change events)
    @Published var channelPresets: [Int: InstrumentPreset] = [:]
    @Published var detectedChannels: [Int] = []  // channels found in the loaded file

    var onLog: ((String) -> Void)?
    var haptics: HapticEngine = HapticEngine()  // replaced with shared instance from ContentView

    private struct Event {
        let time: Double
        let note: Int
        let on: Bool
        let velocity: Int
        let channel: Int
    }

    private var events: [Event] = []
    private var index = 0
    private var timer: Task<Void, Never>?
    private var duration = 0.0
    // Voice keys: channel * 128 + note — prevents same-note-on-different-channel conflicts
    private var soundingVoices = Set<Int>()

    func choose(_ piece: BuiltInPiece) {
        guard let url = Bundle.main.url(forResource: piece.filename, withExtension: nil, subdirectory: "midi") else {
            onLog?("Built-in MIDI resource missing: midi/\(piece.filename)"); return
        }
        onLog?("Selected built-in MIDI \(piece.name) at \(url.path)")
        selectedURL = url; currentTrackName = piece.name; stop()
    }

    func openFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.init(filenameExtension: "mid")!, .init(filenameExtension: "midi")!]
        panel.allowsMultipleSelection = false
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in
                self?.selectedURL = url
                self?.currentTrackName = url.deletingPathExtension().lastPathComponent
                self?.stop()
                self?.onLog?("Selected MIDI file: \(url.path)")
            }
        }
    }

    func play() {
        guard !isPlaying else { return }
        guard let selectedURL else { onLog?("No MIDI file selected"); return }
        onLog?("Loading MIDI file: \(selectedURL.path)")
        let data: Data
        do { data = try Data(contentsOf: selectedURL) }
        catch { onLog?("Could not read MIDI file at \(selectedURL.path): \(error.localizedDescription)"); return }
        if index == 0 || progress >= 1 {
            guard let parsed = Self.parse(data) else {
                onLog?("Could not parse MIDI file (invalid header, track, or event data) at \(selectedURL.path)"); return
            }
            events = parsed.events
            duration = parsed.duration
            // Apply GM channel→preset mapping from Program Change events
            var presets: [Int: InstrumentPreset] = [:]
            for (ch, prog) in parsed.channelPrograms {
                presets[ch] = Self.presetForGMProgram(prog, channel: ch)
            }
            channelPresets = presets
            detectedChannels = Array(Set(events.map { $0.channel })).sorted()
            let chInfo = detectedChannels.map { ch in
                let preset = presets[ch]?.rawValue ?? currentInstrument.rawValue
                return "ch\(ch + 1)=\(preset)"
            }.joined(separator: " ")
            onLog?("Parsed \(events.count) note events, duration \(String(format: "%.2f", duration))s, \(detectedChannels.count) channel(s): \(chInfo)")
        }
        guard !events.isEmpty else { onLog?("MIDI file contains no note events at \(selectedURL.path)"); return }
        onLog?("Playing MIDI file: \(selectedURL.path)")
        isPlaying = true
        timer = Task { [weak self] in
            guard let self else { return }
            var elapsed = 0.0
            while !Task.isCancelled {
                if self.index >= self.events.count {
                    if self.loop { self.index = 0; elapsed = 0; self.progress = 0; continue }
                    break
                }
                let event = self.events[self.index]
                let wait = max(0, event.time / self.tempo - elapsed)
                if wait > 0 { try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) }
                if Task.isCancelled { break }
                elapsed += wait

                let note = min(127, max(0, event.note + self.transpose))
                // Voice key encodes both channel and note — no cross-channel conflicts
                let voiceKey = event.channel * 128 + note
                // Instrument: per-channel preset if available, else fallback to currentInstrument
                let preset = self.channelPresets[event.channel] ?? self.currentInstrument

                if event.on {
                    // Polyphony enforcement across all channels
                    if soundingVoices.count >= polyphonyLimit {
                        // Drop the lowest-priority voice (lowest note, not melody)
                        if let drop = soundingVoices.min(by: { ($0 % 128) < ($1 % 128) }),
                           (drop % 128) < note {
                            haptics.stopVoice(key: drop)
                            soundingVoices.remove(drop)
                        }
                    }
                    guard soundingVoices.count < polyphonyLimit || soundingVoices.contains(voiceKey) else {
                        self.index += 1; continue
                    }
                    soundingVoices.insert(voiceKey)
                    self.flashingNotes.insert(note)
                    Task { @MainActor [weak self] in
                        try? await Task.sleep(nanoseconds: 160_000_000)
                        self?.flashingNotes.remove(note)
                    }
                    self.currentNoteLabel = "Ch\(event.channel + 1) \(Self.noteName(note)) (\(preset.rawValue))"

                    // Find matching note-off on same channel
                    let nextOff = self.events[(self.index + 1)...].first(where: {
                        !$0.on && $0.note == event.note && $0.channel == event.channel
                    })
                    let actualEnd = nextOff?.time ?? self.duration
                    let hold = max(0.3, (actualEnd - event.time) / self.tempo * preset.noteDurationMultiplier)
                    let noteLength = max(0, (actualEnd - event.time) / self.tempo)

                    // Legato: glide from previous note on same channel
                    if noteLength >= 0.15, self.legato,
                       let prev = self.events[..<self.index].last(where: { $0.on && $0.channel == event.channel && $0.time < event.time }),
                       let prevOff = self.events[self.index...].first(where: { !$0.on && $0.note == prev.note && $0.channel == event.channel && $0.time > event.time }) {
                        if prevOff.time > event.time {
                            self.haptics.stopVoice(key: prev.channel * 128 + min(127, max(0, prev.note + self.transpose)))
                        }
                    }

                    let isHarmony = soundingVoices.contains(where: { ($0 % 128) > note })
                    self.haptics.startVoice(
                        key: voiceKey,
                        midiNote: note,
                        preset: preset,
                        durationSeconds: hold,
                        strength: self.volume * preset.strength * (isHarmony ? 0.7 : 1)
                    )
                } else {
                    soundingVoices.remove(voiceKey)
                    self.haptics.stopVoice(key: voiceKey)
                }
                self.index += 1
                self.progress = min(1, event.time / max(0.01, self.duration))
            }
            self.haptics.stopAllNotes()
            self.soundingVoices.removeAll()
            self.isPlaying = false
            if self.index >= self.events.count && !self.loop { self.progress = 1; self.index = 0 }
        }
    }

    func pause() { timer?.cancel(); timer = nil; isPlaying = false; haptics.stopAllNotes() }
    func stop() { pause(); index = 0; progress = 0; currentNoteLabel = "" }

    private static func noteName(_ note: Int) -> String {
        ["C","C♯","D","D♯","E","F","F♯","G","G♯","A","A♯","B"][note % 12] + String(note / 12 - 1)
    }

    /// Map a General MIDI program number (0-127) to our haptic presets.
    /// Channel 9 is always drums (xylophone for short percussive hits).
    static func presetForGMProgram(_ program: Int, channel: Int) -> InstrumentPreset {
        if channel == 9 { return .xylophone }
        switch program {
        case 0...7:   return .piano          // Piano family
        case 8...15:  return .xylophone      // Chromatic Percussion
        case 16...23: return .organ          // Organ
        case 24...31: return .guitar         // Guitar
        case 32...39: return .bass           // Bass
        case 40...47: return .violin         // Strings
        case 48...55: return .violin         // Ensemble
        case 56...63: return .trumpet        // Brass
        case 64...71: return .flute          // Reed
        case 72...79: return .flute          // Pipe
        case 80...87: return .organ          // Synth Lead
        case 88...95: return .theremin       // Synth Pad
        default:      return .piano
        }
    }

    // MARK: - MIDI Parser

    private static func parse(_ data: Data) -> (events: [Event], duration: Double, channelPrograms: [Int: Int])? {
        let b = [UInt8](data)
        guard b.count > 14, String(bytes: b[0..<4], encoding: .ascii) == "MThd" else { return nil }
        func u32(_ i: Int) -> Int { Int(b[i])<<24 | Int(b[i+1])<<16 | Int(b[i+2])<<8 | Int(b[i+3]) }
        let format = Int(b[8])<<8 | Int(b[9])
        let tracks = Int(b[10])<<8 | Int(b[11])
        let division = Int(b[12])<<8 | Int(b[13])
        guard format <= 1, division & 0x8000 == 0 else { return nil }

        // Raw event: (tick, order, kind, note, value, channel)
        // kind: 0=NoteOff, 1=NoteOn, 2=Tempo, 3=ProgramChange
        var pos = 14
        var raw: [(tick: Int, order: Int, kind: Int, note: Int, value: Int, channel: Int)] = []
        var maxTick = 0, order = 0

        for _ in 0..<tracks {
            guard pos + 8 <= b.count, String(bytes: b[pos..<pos+4], encoding: .ascii) == "MTrk" else { return nil }
            let size = u32(pos + 4); pos += 8
            let end = min(b.count, pos + size)
            var tick = 0, running: UInt8 = 0

            func vlq(_ p: inout Int) -> Int {
                var n = 0
                while p < end {
                    let x = b[p]; p += 1; n = (n << 7) | Int(x & 0x7f)
                    if x & 0x80 == 0 { break }
                }
                return n
            }

            while pos < end {
                tick += vlq(&pos)
                guard pos < end else { break }
                var status = b[pos]
                if status & 0x80 != 0 { pos += 1; if status < 0xf0 { running = status } } else { status = running }

                // Meta events
                if status == 0xff {
                    guard pos < end else { break }
                    let meta = b[pos]; pos += 1
                    let n = vlq(&pos)
                    if meta == 0x51, n == 3, pos + 3 <= end {
                        let us = Int(b[pos])<<16 | Int(b[pos+1])<<8 | Int(b[pos+2])
                        raw.append((tick, order, 2, 0, us, 0)); order += 1
                    }
                    pos = min(end, pos + n); continue
                }
                if status == 0xf0 || status == 0xf7 { let n = vlq(&pos); pos = min(end, pos + n); continue }

                let kind = status & 0xf0
                let channel = Int(status & 0x0f)
                let msgLen: Int
                switch kind {
                case 0xc0, 0xd0: msgLen = 1
                default:         msgLen = 2
                }
                guard pos + msgLen <= end else { break }

                if kind == 0xc0 {
                    // Program Change — record for GM instrument mapping
                    raw.append((tick, order, 3, Int(b[pos]), 0, channel)); order += 1
                    pos += 1
                } else {
                    let note = Int(b[pos])
                    let velocity = msgLen == 2 ? Int(b[pos + 1]) : 0
                    pos += msgLen
                    if kind == 0x90 && velocity > 0 {
                        raw.append((tick, order, 1, note, velocity, channel)); order += 1
                    } else if kind == 0x80 || (kind == 0x90 && velocity == 0) {
                        raw.append((tick, order, 0, note, velocity, channel)); order += 1
                    }
                    maxTick = max(maxTick, tick)
                }
            }
            pos = end
        }

        var micros = 500_000.0, lastTick = 0, seconds = 0.0
        var events: [Event] = []
        var channelPrograms: [Int: Int] = [:]

        for e in raw.sorted(by: { $0.tick == $1.tick ? $0.order < $1.order : $0.tick < $1.tick }) {
            seconds += Double(e.tick - lastTick) * micros / 1_000_000 / Double(max(1, division))
            lastTick = e.tick
            switch e.kind {
            case 2: micros = Double(e.value)
            case 3: channelPrograms[e.channel] = e.note  // Program Change
            case 0, 1: events.append(Event(time: seconds, note: e.note, on: e.kind == 1, velocity: e.value, channel: e.channel))
            default: break
            }
        }
        seconds += Double(max(0, maxTick - lastTick)) * micros / 1_000_000 / Double(max(1, division))
        return (events: events, duration: seconds, channelPrograms: channelPrograms)
    }
}
