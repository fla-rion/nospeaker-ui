import Combine
import CoreMIDI
import Foundation

@MainActor
final class VirtualMIDIPort: ObservableObject {
    @Published var isActive = false
    @Published var lastMessage = ""

    private var client = MIDIClientRef()
    private var destination = MIDIEndpointRef()

    var onNoteOn: ((Int, Int, Int) -> Void)?
    var onNoteOff: ((Int, Int) -> Void)?
    var onProgramChange: ((Int, Int) -> Void)?
    var onControlChange: ((Int, Int, Int) -> Void)?
    var onClockPulse: (() -> Void)?
    var onClockStart: (() -> Void)?
    var onClockStop: (() -> Void)?

    func start() {
        guard !isActive else { return }
        guard MIDIClientCreate("noSpeakerUI" as CFString, nil, nil, &client) == noErr else { return }
        let status = MIDIDestinationCreateWithBlock(client, "noSpeakerUI Haptic Synth" as CFString, &destination) { [weak self] packetList, _ in
            guard let self else { return }
            self.handlePacketList(packetList)
        }
        isActive = status == noErr
        if status != noErr, client != 0 { MIDIClientDispose(client); client = 0 }
    }

    func stop() {
        if destination != 0 { MIDIEndpointDispose(destination); destination = 0 }
        if client != 0 { MIDIClientDispose(client); client = 0 }
        isActive = false
    }

    nonisolated private func handlePacketList(_ packetList: UnsafePointer<MIDIPacketList>) {
        var packet = packetList.pointee.packet
        for _ in 0..<packetList.pointee.numPackets {
            let bytes = withUnsafeBytes(of: packet.data) { Array($0.prefix(Int(packet.length))) }
            parsePacket(bytes)
            packet = MIDIPacketNext(&packet).pointee
        }
    }

    nonisolated private func parsePacket(_ bytes: [UInt8]) {
        var i = 0
        while i < bytes.count {
            let status = bytes[i]
            if status == 0xF8 { Task { @MainActor in self.onClockPulse?() }; i += 1; continue }
            if status == 0xFA { Task { @MainActor in self.onClockStart?() }; i += 1; continue }
            if status == 0xFC { Task { @MainActor in self.onClockStop?() }; i += 1; continue }
            if status == 0xF0 { break }

            let kind = status & 0xF0
            let length: Int
            switch kind {
            case 0x80, 0x90, 0xA0, 0xB0, 0xE0: length = 3
            case 0xC0, 0xD0: length = 2
            default: i += 1; continue
            }
            guard i + length <= bytes.count else { break }
            let channel = Int(status & 0x0F)
            switch kind {
            case 0x90:
                let note = Int(bytes[i + 1]), velocity = Int(bytes[i + 2])
                if velocity > 0 {
                    Task { @MainActor in
                        self.lastMessage = "Note On: \(Self.noteName(note)) vel \(velocity) ch \(channel + 1)"
                        self.onNoteOn?(note, velocity, channel)
                    }
                } else { Task { @MainActor in self.onNoteOff?(note, channel) } }
            case 0x80:
                let note = Int(bytes[i + 1]); Task { @MainActor in self.onNoteOff?(note, channel) }
            case 0xC0:
                let program = Int(bytes[i + 1])
                Task { @MainActor in
                    self.lastMessage = "Program Change: \(program) ch \(channel + 1)"
                    self.onProgramChange?(program, channel)
                }
            case 0xB0:
                let cc = Int(bytes[i + 1]), value = Int(bytes[i + 2])
                Task { @MainActor in
                    self.lastMessage = "Control Change: CC \(cc) = \(value) ch \(channel + 1)"
                    self.onControlChange?(cc, value, channel)
                }
            default: break
            }
            i += length
        }
    }

    nonisolated private static func noteName(_ note: Int) -> String {
        ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"][note % 12] + String(note / 12 - 1)
    }

    deinit {
        if destination != 0 { MIDIEndpointDispose(destination) }
        if client != 0 { MIDIClientDispose(client) }
    }
}
