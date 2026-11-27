import AppKit
import Combine
import Foundation

struct BuiltInPiece: Identifiable {
    let name: String; let composer: String; let filename: String; let difficulty: String
    var id: String { filename }
    static let all: [BuiltInPiece] = [
        .init(name:"Für Elise",composer:"Beethoven",filename:"fur_elise.mid",difficulty:"Medium"), .init(name:"Mondscheinsonate",composer:"Beethoven",filename:"moonlight_sonata.mid",difficulty:"Advanced"), .init(name:"Kanon in D",composer:"Pachelbel",filename:"canon_in_d.mid",difficulty:"Easy"), .init(name:"Türkischer Marsch",composer:"Mozart",filename:"turkish_march.mid",difficulty:"Medium"), .init(name:"The Entertainer",composer:"Joplin",filename:"the_entertainer.mid",difficulty:"Medium"), .init(name:"Gymnopédie Nr. 1",composer:"Satie",filename:"gymnopedie_no1.mid",difficulty:"Easy"), .init(name:"Eine Kleine Nachtmusik",composer:"Mozart",filename:"eine_kleine_nachtmusik.mid",difficulty:"Medium"), .init(name:"Schwanensee-Thema",composer:"Tschaikowski",filename:"swan_lake.mid",difficulty:"Easy"), .init(name:"Ode an die Freude",composer:"Beethoven",filename:"ode_to_joy.mid",difficulty:"Easy"), .init(name:"Frühling (Vivaldi)",composer:"Vivaldi",filename:"spring_vivaldi.mid",difficulty:"Advanced")]
}

@MainActor final class MIDIPlayer: ObservableObject {
    @Published var isPlaying = false; @Published var currentTrackName = ""; @Published var progress = 0.0
    @Published var currentInstrument = InstrumentPreset.piano; @Published var tempo = 1.0; @Published var volume = 0.8
    @Published var transpose = 0; @Published var loop = false; @Published var legato = false; @Published var portamentoMilliseconds = 40.0
    @Published var selectedURL: URL?; @Published var currentNoteLabel = ""
    @Published var polyphonyLimit = 3
    @Published var visualVoices: [(frequency: Double, amplitude: Double)] = []
    @Published var trackpadAssignment: HapticEngine.TrackpadAssignment = .auto { didSet { haptics.trackpadAssignment = trackpadAssignment } }
    @Published private(set) var flashingNotes = Set<Int>()
    var onLog: ((String) -> Void)?
    private let haptics = HapticEngine(); private var events: [Event] = []; private var index = 0; private var timer: Task<Void, Never>?; private var duration = 0.0
    init() { haptics.onVoicesChanged = { [weak self] in self?.visualVoices = $0 }; haptics.discoverDevices() }
    private struct Event { let time: Double; let note: Int; let on: Bool; let velocity: Int }
    private var soundingNotes = Set<Int>()
    func choose(_ piece: BuiltInPiece) {
        guard let url = Bundle.main.url(forResource: piece.filename, withExtension: nil, subdirectory: "midi") else { onLog?("Built-in MIDI resource missing: midi/\(piece.filename)"); return }
        onLog?("Selected built-in MIDI \(piece.name) at \(url.path)")
        selectedURL = url; currentTrackName = piece.name; stop()
    }
    func openFile() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.init(filenameExtension: "mid")!, .init(filenameExtension: "midi")!]; panel.allowsMultipleSelection = false
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in self?.selectedURL = url; self?.currentTrackName = url.deletingPathExtension().lastPathComponent; self?.stop(); self?.onLog?("Selected MIDI file: \(url.path)") }
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
            guard let parsed = Self.parse(data) else { onLog?("Could not parse MIDI file (invalid header, track, or event data) at \(selectedURL.path)"); return }
            events = parsed.events; duration = parsed.duration
            onLog?("Parsed \(events.count) note events, duration \(String(format: "%.2f", duration))s from \(selectedURL.path)")
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
                let event = self.events[self.index]; let wait = max(0, event.time / self.tempo - elapsed)
                if wait > 0 { try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) }; if Task.isCancelled { break }; elapsed += wait
                let note = min(127, max(0, event.note + self.transpose))
                if event.on {
                    if soundingNotes.count >= polyphonyLimit, let quietestHarmony = soundingNotes.min(), quietestHarmony < note {
                        haptics.stopNote(midiNote: quietestHarmony); soundingNotes.remove(quietestHarmony)
                    }
                    guard soundingNotes.count < polyphonyLimit || soundingNotes.contains(note) else { self.index += 1; continue }
                    soundingNotes.insert(note)
                    self.flashingNotes.insert(note)
                    Task { @MainActor [weak self] in
                        try? await Task.sleep(nanoseconds: 160_000_000)
                        self?.flashingNotes.remove(note)
                    }
                    self.currentNoteLabel = "Playing: \(Self.noteName(note)) (\(self.currentInstrument.rawValue))"
                    let nextOff = self.events[(self.index + 1)...].first(where: { !$0.on && $0.note == event.note })
                    let actualEnd = nextOff?.time ?? self.duration
                    let hold = max(0.3, (actualEnd - event.time) / self.tempo * self.currentInstrument.noteDurationMultiplier)
                    let noteLength = max(0, (actualEnd - event.time) / self.tempo)
                    if noteLength >= 0.15, self.legato, let prev = self.events[..<self.index].last(where: { $0.on && $0.time < event.time }), let prevOff = self.events[self.index...].first(where: { !$0.on && $0.note == prev.note && $0.time > event.time }) {
                        if prevOff.time > event.time { self.haptics.stopNote(midiNote: prev.note + self.transpose) }
                    }
                    let isHarmony = soundingNotes.contains(where: { $0 > note })
                    self.haptics.startNote(midiNote: note, preset: self.currentInstrument, durationSeconds: hold, strength: self.volume * self.currentInstrument.strength * (isHarmony ? 0.7 : 1))
                } else { soundingNotes.remove(note); self.haptics.stopNote(midiNote: note) }
                self.index += 1; self.progress = min(1, event.time / max(0.01, self.duration))
            }
            self.haptics.stopAllNotes(); self.soundingNotes.removeAll(); self.isPlaying = false
            if self.index >= self.events.count && !self.loop { self.progress = 1; self.index = 0 }
        }
    }
    func pause() { timer?.cancel(); timer = nil; isPlaying = false; haptics.stopAllNotes() }
    func stop() { pause(); index = 0; progress = 0; currentNoteLabel = "" }
    private static func noteName(_ note: Int) -> String { ["C","C♯","D","D♯","E","F","F♯","G","G♯","A","A♯","B"][note % 12] + String(note / 12 - 1) }

    private static func parse(_ data: Data) -> (events: [Event], duration: Double)? {
        let b = [UInt8](data); guard b.count > 14, String(bytes:b[0..<4],encoding:.ascii) == "MThd" else { return nil }
        func u32(_ i:Int)->Int { Int(b[i])<<24 | Int(b[i+1])<<16 | Int(b[i+2])<<8 | Int(b[i+3]) }
        let format = Int(b[8])<<8 | Int(b[9]), tracks = Int(b[10])<<8 | Int(b[11]), division = Int(b[12])<<8 | Int(b[13]); guard format <= 1, division & 0x8000 == 0 else { return nil }
        var pos=14; var raw: [(tick:Int, order:Int, kind:Int, note:Int, value:Int)] = []; var maxTick=0; var order=0
        for _ in 0..<tracks {
            guard pos+8<=b.count, String(bytes:b[pos..<pos+4],encoding:.ascii)=="MTrk" else { return nil }
            let size=u32(pos+4); pos += 8; let end=min(b.count,pos+size); var tick=0, running:UInt8=0
            func vlq(_ p: inout Int)->Int { var n=0; while p<end { let x=b[p]; p+=1; n=(n<<7)|Int(x&0x7f); if x&0x80==0 { break } }; return n }
            while pos<end { tick += vlq(&pos); guard pos<end else { break }; var status=b[pos]
                if status & 0x80 != 0 { pos+=1; if status<0xf0 { running=status } } else { status=running }
                if status==0xff { guard pos<end else { break }; let meta=b[pos]; pos+=1; let n=vlq(&pos); if meta==0x51, n==3, pos+3<=end { let us=Int(b[pos])<<16|Int(b[pos+1])<<8|Int(b[pos+2]); raw.append((tick,order,2,0,us)); order+=1 }; pos=min(end,pos+n); continue }
                if status==0xf0 || status==0xf7 { let n=vlq(&pos); pos=min(end,pos+n); continue }
                let kind=status&0xf0, n=(kind==0xc0 || kind==0xd0) ? 1 : 2; guard pos+n<=end else { break }
                let note=Int(b[pos]), velocity=n==2 ? Int(b[pos+1]):0; pos+=n
                if kind==0x90 && velocity>0 { raw.append((tick,order,1,note,velocity)); order+=1 } else if kind==0x80 || (kind==0x90 && velocity==0) { raw.append((tick,order,0,note,velocity)); order+=1 }
                maxTick=max(maxTick,tick)
            }; pos=end
        }
        var micros=500_000.0, lastTick=0, seconds=0.0; var events:[Event]=[]
        for e in raw.sorted(by: { $0.tick == $1.tick ? $0.order < $1.order : $0.tick < $1.tick }) {
            seconds += Double(e.tick-lastTick)*micros/1_000_000/Double(max(1,division)); lastTick=e.tick
            if e.kind==2 { micros=Double(e.value) } else { events.append(Event(time:seconds,note:e.note,on:e.kind==1,velocity:e.value)) }
        }
        seconds += Double(max(0,maxTick-lastTick))*micros/1_000_000/Double(max(1,division))
        return (events,seconds)
    }
}
