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
    @Published var isPlaying = false
    @Published var currentTrackName = ""
    @Published var progress = 0.0
    @Published var currentInstrument = InstrumentPreset.piano
    @Published var tempo = 1.0
    @Published var volume = 0.8
    @Published var selectedURL: URL?
    private let haptics = HapticEngine()
    private var events: [Event] = []; private var index = 0
    private var timer: Task<Void, Never>?
    private var duration: Double = 0
    private struct Event { let time: Double; let note: Int; let length: Double }

    func choose(_ piece: BuiltInPiece) {
        guard let url = Bundle.main.resourceURL?.appendingPathComponent("midi").appendingPathComponent(piece.filename) else { return }
        selectedURL = url; currentTrackName = piece.name
    }
    func openFile() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.init(filenameExtension: "mid")!, .init(filenameExtension: "midi")!]
        panel.allowsMultipleSelection = false; panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in self?.selectedURL = url; self?.currentTrackName = url.deletingPathExtension().lastPathComponent }
        }
    }
    func play() {
        if isPlaying { return }
        guard let selectedURL, let data = try? Data(contentsOf: selectedURL), let parsed = Self.parse(data) else { return }
        if index == 0 || progress >= 1 { events = parsed.events; duration = parsed.duration }
        isPlaying = true
        timer = Task { [weak self] in
            guard let self else { return }
            var elapsed = 0.0
            while !Task.isCancelled && self.index < self.events.count {
                let event = self.events[self.index]
                let wait = max(0, (event.time / self.tempo) - elapsed)
                if wait > 0 { try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) }
                if Task.isCancelled { break }
                elapsed += wait
                let hz = 440 * pow(2, Double(event.note - 69) / 12)
                let hold = max(0.04, event.length / self.tempo * self.currentInstrument.noteDurationMultiplier)
                await self.haptics.playTone(frequency: hz, durationSeconds: hold, strength: self.volume * self.currentInstrument.strength)
                self.index += 1; self.progress = min(1, event.time / max(0.01, self.duration))
            }
            self.isPlaying = false; self.progress = 1; self.index = 0
        }
    }
    func pause() { timer?.cancel(); timer = nil; isPlaying = false; haptics.stopAllTones() }
    func stop() { pause(); index = 0; progress = 0 }

    private static func parse(_ data: Data) -> (events: [Event], duration: Double)? {
        let b = [UInt8](data); guard b.count > 14, String(bytes:b[0..<4],encoding:.ascii) == "MThd" else { return nil }
        func u32(_ i:Int)->Int { Int(b[i])<<24 | Int(b[i+1])<<16 | Int(b[i+2])<<8 | Int(b[i+3]) }
        let tracks = Int(b[10])<<8 | Int(b[11]), division = max(1,Int(b[12])<<8 | Int(b[13])); var pos=14
        var gathered: [(Int,Int,Int,Int)] = []; var maxTick=0; let ppq = division & 0x7fff
        for _ in 0..<tracks {
            guard pos+8<=b.count, String(bytes:b[pos..<pos+4],encoding:.ascii)=="MTrk" else { return nil }
            let size=u32(pos+4); pos += 8; let end=min(b.count,pos+size); var tick=0, running:UInt8=0
            func vlq(_ p: inout Int)->Int { var n=0; while p<end { let x=b[p]; p+=1; n=(n<<7)|Int(x&0x7f); if x&0x80==0 { break } }; return n }
            while pos<end { tick += vlq(&pos); guard pos<end else { break }; var status=b[pos]
                if status & 0x80 != 0 { pos+=1; if status<0xf0 { running=status } } else { status=running }
                if status==0xff { guard pos<end else { break }; pos+=1; let n=vlq(&pos); if pos+n<=end { pos+=n }; continue }
                if status==0xf0 || status==0xf7 { let n=vlq(&pos); pos=min(end,pos+n); continue }
                let kind=status&0xf0; let n=(kind==0xc0 || kind==0xd0) ? 1 : 2; guard pos+n<=end else { break }
                let a=Int(b[pos]), v=n==2 ? Int(b[pos+1]):0; pos+=n
                if kind==0x90 && v>0 { gathered.append((tick,a,1,v)) } else if kind==0x80 || (kind==0x90 && v==0) { gathered.append((tick,a,0,0)) }
                maxTick=max(maxTick,tick)
            }; pos=end
        }
        let tempo=500_000.0; var active:[Int:(Int,Int)]=[:]; var out:[Event]=[]
        for e in gathered.sorted(by:{$0.0<$1.0}) { let time=Double(e.0)*tempo/1_000_000/Double(ppq)
            if e.2==1 { active[e.1]=(e.0,0) } else if let start=active.removeValue(forKey:e.1) { let begin=Double(start.0)*tempo/1_000_000/Double(ppq); out.append(Event(time:begin,note:e.1,length:max(0.07,time-begin))) }
        }
        return (out.sorted{$0.time<$1.time}, Double(maxTick)*tempo/1_000_000/Double(ppq))
    }
}
