import AppKit
import CoreMIDI
import SwiftUI

@main
struct noSpeakerUIApp: App {
    var body: some Scene {
        WindowGroup { ContentView().frame(minWidth: 760, minHeight: 600) }
            .windowStyle(.titleBar)
    }
}

@MainActor
final class SpeakerController: ObservableObject {
    @Published var text = "Hello from my trackpad."
    @Published var voices: [String] = []
    @Published var selectedVoice = ""
    @Published var darkMode = false
    @Published var plainMode = false
    @Published var externalTrackpad = false
    @Published var output = "Ready. Choose an action to start nospeaker.\n"
    @Published private(set) var isRunning = false
    @Published var midiEnabled = false { didSet { configureMIDI() } }
    @Published var midiSources: [(id: MIDIEndpointRef, name: String)] = []
    @Published var selectedMIDISource: MIDIEndpointRef = 0 { didSet { if midiEnabled { configureMIDI() } } }

    private var process: Process?
    private var outputPipes: [Pipe] = []
    private var midiClient = MIDIClientRef()
    private var midiPort = MIDIPortRef()
    private var activeKey: Int?
    private var lastThereminFrequency: Double?

    init() { loadVoices(); refreshMIDISources() }

    func speak() {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { append("Enter some text to speak.\n"); return }
        var arguments = ["--voice", selectedVoice, value]
        addModes(to: &arguments); launch(arguments)
    }
    func sweep() { var args = ["--sweep"]; addModes(to: &args); launch(args) }
    func demo() { var args: [String] = []; addModes(to: &args); launch(args) }
    func stop() {
        guard let process, process.isRunning else { return }
        process.terminate(); activeKey = nil; lastThereminFrequency = nil
        append("\nStopping nospeaker…\n")
    }

    func playNote(_ midiNote: Int) {
        activeKey = midiNote
        startTone(440 * pow(2, Double(midiNote - 69) / 12))
    }
    func releaseNote(_ midiNote: Int) {
        guard activeKey == midiNote else { return }
        activeKey = nil; stop()
    }
    func theremin(_ position: Double) {
        let frequency = 100 + min(1, max(0, position)) * 3900
        if let lastThereminFrequency, abs(frequency - lastThereminFrequency) <= 10 { return }
        lastThereminFrequency = frequency
        startTone(frequency)
    }
    func endTheremin() { lastThereminFrequency = nil; stop() }

    private func startTone(_ frequency: Double) {
        // A held note replaces the previous tone process; each CLI tone runs until terminated.
        terminateCurrent()
        var args = ["--tone", String(format: "%.2f", frequency)]
        addModes(to: &args); launch(args)
    }
    private func terminateCurrent() {
        guard let process, process.isRunning else { return }
        process.terminate()
    }

    private func addModes(to arguments: inout [String]) {
        if darkMode { arguments.append("--dark") }
        if plainMode { arguments.append("--plain") }
        if externalTrackpad { arguments.append("--external") }
    }

    private func loadVoices() {
        let command = Process(); command.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        command.arguments = ["-v", "?"]; let pipe = Pipe(); command.standardOutput = pipe; command.standardError = Pipe()
        do {
            try command.run(); let data = pipe.fileHandleForReading.readDataToEndOfFile(); command.waitUntilExit()
            voices = String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline).compactMap { line in
                line.split(whereSeparator: { $0 == " " || $0 == "\t" }).first.map(String.init)
            }
            selectedVoice = voices.first ?? ""
            if voices.isEmpty { append("No installed macOS voices were found.\n") }
        } catch { append("Could not list macOS voices: \(error.localizedDescription)\n") }
    }

    func refreshMIDISources() {
        midiSources = (0..<MIDIGetNumberOfSources()).map { index in
            let endpoint = MIDIGetSource(index)
            var name: Unmanaged<CFString>?
            MIDIObjectGetStringProperty(endpoint, kMIDIPropertyDisplayName, &name)
            return (endpoint, name?.takeRetainedValue() as String? ?? "MIDI Source \(index + 1)")
        }
        if !midiSources.contains(where: { $0.id == selectedMIDISource }) { selectedMIDISource = midiSources.first?.id ?? 0 }
    }

    private func configureMIDI() {
        if midiPort != 0 { MIDIPortDispose(midiPort); midiPort = 0 }
        if midiClient == 0 {
            MIDIClientCreate("noSpeakerUI" as CFString, nil, nil, &midiClient)
        }
        guard midiEnabled, selectedMIDISource != 0, midiClient != 0 else { return }
        let context = Unmanaged.passUnretained(self).toOpaque()
        MIDIInputPortCreateWithBlock(midiClient, "noSpeakerUI Input" as CFString, &midiPort) { [weak self] packetList, _ in
            guard let self else { return }
            var packet = packetList.pointee.packet
            for _ in 0..<packetList.pointee.numPackets {
                let bytes = withUnsafeBytes(of: packet.data) { Array($0.prefix(Int(packet.length))) }
                var i = 0
                while i + 2 < bytes.count {
                    let status = bytes[i], note = Int(bytes[i + 1]), velocity = bytes[i + 2]
                    if status & 0xF0 == 0x90 && velocity > 0 {
                        Task { @MainActor in self.playNote(note) }
                    } else if status & 0xF0 == 0x80 || (status & 0xF0 == 0x90 && velocity == 0) {
                        Task { @MainActor in self.releaseNote(note) }
                    }
                    i += 3
                }
                packet = MIDIPacketNext(&packet).pointee
            }
        }
        MIDIPortConnectSource(midiPort, selectedMIDISource, context)
    }

    private func launch(_ arguments: [String]) {
        guard let binaryPath = Bundle.main.path(forResource: "nospeaker", ofType: nil) else {
            append("Error: nospeaker is not bundled in this app. Rebuild the app with nospeaker in Contents/Resources.\n"); return
        }
        let task = Process(); task.executableURL = URL(fileURLWithPath: binaryPath); task.arguments = arguments
        task.environment = ProcessInfo.processInfo.environment.merging(["TERM": "dumb"]) { _, new in new }
        let stdout = Pipe(), stderr = Pipe(); task.standardOutput = stdout; task.standardError = stderr
        process = task; outputPipes = [stdout, stderr]; isRunning = true
        append("\n$ nospeaker \(arguments.map(Self.displayArgument).joined(separator: " "))\n")
        for pipe in outputPipes {
            pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                guard !data.isEmpty else { return }
                let chunk = String(decoding: data, as: UTF8.self)
                Task { @MainActor in self?.append(chunk) }
            }
        }
        task.terminationHandler = { [weak self] finished in
            for pipe in [stdout, stderr] {
                pipe.fileHandleForReading.readabilityHandler = nil
                let remaining = pipe.fileHandleForReading.readDataToEndOfFile()
                if !remaining.isEmpty { let chunk = String(decoding: remaining, as: UTF8.self); Task { @MainActor in self?.append(chunk) } }
                try? pipe.fileHandleForReading.close()
            }
            Task { @MainActor in
                guard self?.process === finished else { return }
                self?.append("\nProcess finished with exit code \(finished.terminationStatus).\n")
                self?.isRunning = false; self?.process = nil; self?.outputPipes = []
            }
        }
        do { try task.run() }
        catch {
            task.terminationHandler = nil
            for pipe in outputPipes { pipe.fileHandleForReading.readabilityHandler = nil }
            outputPipes = []; process = nil; isRunning = false
            append("Could not start nospeaker: \(error.localizedDescription)\n")
        }
    }
    private func append(_ value: String) { output += value }
    private static func displayArgument(_ argument: String) -> String { "'" + argument.replacingOccurrences(of: "'", with: "'\\''") + "'" }
}

private struct PianoKey: Identifiable {
    let midi: Int
    let name: String
    var isBlack: Bool { name.contains("#") }
    var id: Int { midi }
}

struct ContentView: View {
    @StateObject private var controller = SpeakerController()
    @StateObject private var updateChecker = UpdateChecker()
    @State private var showingUpdateAlert = false
    @State private var selectedTab = 0
    @State private var heldKeys = Set<Int>()
    @State private var mouseHeldKeys = Set<Int>()
    @State private var keyMonitor: Any?
    @State private var thereminPosition = 0.5

    private let keyboardNotes: [PianoKey] = (48...72).map { midi in
        let names = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
        let pitch = names[midi % 12]
        return PianoKey(midi: midi, name: "\(pitch)\(midi / 12 - 1)")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("noSpeakerUI").font(.largeTitle.weight(.semibold))
                    Text("Make your trackpad speak.").foregroundColor(.secondary)
                }
                Spacer()
                Toggle("Dark", isOn: $controller.darkMode).toggleStyle(.switch)
                Toggle("Plain", isOn: $controller.plainMode).toggleStyle(.switch)
                Toggle("External trackpad", isOn: $controller.externalTrackpad).toggleStyle(.switch)
            }

            TabView(selection: $selectedTab) {
                controls.tabItem { Label("Speak", systemImage: "waveform") }.tag(0)
                keyboard.tabItem { Label("Keyboard", systemImage: "pianokeys") }.tag(1)
                instrument.tabItem { Label("Theremin & MIDI", systemImage: "slider.horizontal.3") }.tag(2)
            }

            HStack {
                Text("Output").font(.headline); Spacer()
                Circle().fill(controller.isRunning ? Color.green : Color.secondary.opacity(0.5)).frame(width: 8, height: 8)
                Text(controller.isRunning ? "Running" : "Idle").font(.caption).foregroundColor(.secondary)
                Button(action: controller.stop) { Label("Stop", systemImage: "stop.fill") }.disabled(!controller.isRunning)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    Text(controller.output).font(.system(.callout, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled).padding(12).id("log-bottom")
                }
                .background(Color(nsColor: .textBackgroundColor))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.2)))
                .onChange(of: controller.output) { _ in proxy.scrollTo("log-bottom", anchor: .bottom) }
            }.frame(minHeight: 125)
        }
        .padding(20)
        .onAppear { installKeyboardMonitor(); Task { await updateChecker.checkForUpdates(); showingUpdateAlert = updateChecker.availableVersion != nil } }
        .onDisappear { removeKeyboardMonitor(); if controller.midiEnabled { controller.midiEnabled = false }; controller.stop() }
        .alert("Update available: v\(updateChecker.availableVersion ?? "")", isPresented: $showingUpdateAlert) {
            Button("Open Releases") { updateChecker.openReleasesPage() }; Button("Later", role: .cancel) {}
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Text to speak").font(.headline)
            TextField("Enter text…", text: $controller.text).textFieldStyle(.roundedBorder).onSubmit(controller.speak)
            HStack {
                Picker("Voice", selection: $controller.selectedVoice) {
                    ForEach(controller.voices, id: \.self) { Text($0).tag($0) }
                }.frame(maxWidth: 260).disabled(controller.voices.isEmpty)
                Button(action: controller.speak) { Label("Speak", systemImage: "waveform") }.keyboardShortcut(.return, modifiers: [.command])
                Button(action: controller.sweep) { Label("Sweep", systemImage: "waveform.path") }
                Button(action: controller.demo) { Label("Demo", systemImage: "play.fill") }
            }
            Spacer()
        }.padding(.top, 12)
    }

    private var keyboard: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Keyboard synthesizer").font(.headline)
            Text("Click a key or use A W S E D F T G Y H U J K. Hold to play; release to stop.").foregroundColor(.secondary)
            piano
            Spacer()
        }.padding(.top, 12)
    }

    private var piano: some View {
        GeometryReader { geometry in
            let whites = keyboardNotes.filter { !$0.isBlack }
            let whiteWidth = geometry.size.width / CGFloat(whites.count)
            ZStack(alignment: .topLeading) {
                HStack(spacing: 1) {
                    ForEach(whites) { key in
                        pianoButton(key, color: .white, foreground: .black)
                    }
                }
                ForEach(keyboardNotes.filter(\.isBlack)) { key in
                    let whiteIndex = keyboardNotes.filter { !$0.isBlack && $0.midi < key.midi }.count
                    pianoButton(key, color: .black, foreground: .white)
                        .frame(width: whiteWidth * 0.62, height: geometry.size.height * 0.62)
                        .offset(x: CGFloat(whiteIndex) * whiteWidth - whiteWidth * 0.31)
                }
            }
        }.frame(height: 180).padding(.horizontal, 4)
    }

    private func pianoButton(_ key: PianoKey, color: Color, foreground: Color) -> some View {
        Button {} label: {
            VStack { Spacer(); Text(key.name).font(.caption2); Text(String(format: "%.0f", 440 * pow(2, Double(key.midi - 69) / 12))).font(.system(size: 8)); Spacer().frame(height: 6) }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(color).foregroundColor(foreground)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.gray.opacity(0.6)))
        }.buttonStyle(.plain)
            .simultaneousGesture(DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    if !mouseHeldKeys.contains(key.midi) {
                        mouseHeldKeys.insert(key.midi)
                        controller.playNote(key.midi)
                    }
                }
                .onEnded { _ in
                    mouseHeldKeys.remove(key.midi)
                    controller.releaseNote(key.midi)
                })
    }

    private var instrument: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Theremin").font(.headline)
            Text("Drag from 100 Hz to 4,000 Hz. Tone updates in 10 Hz steps.").foregroundColor(.secondary)
            Slider(value: $thereminPosition, in: 0...1, onEditingChanged: { editing in
                if editing { controller.theremin(thereminPosition) } else { controller.endTheremin() }
            }).onChange(of: thereminPosition) { controller.theremin($0) }
            HStack { Text("100 Hz"); Spacer(); Text("4,000 Hz") }
            Divider()
            Toggle("MIDI Input", isOn: $controller.midiEnabled)
            HStack {
                Picker("MIDI source", selection: $controller.selectedMIDISource) {
                    ForEach(controller.midiSources, id: \.id) { source in Text(source.name).tag(source.id) }
                }.disabled(!controller.midiEnabled || controller.midiSources.isEmpty)
                Button("Refresh") { controller.refreshMIDISources() }
            }
            if controller.midiEnabled && controller.midiSources.isEmpty { Text("No MIDI input sources found.").foregroundColor(.secondary) }
            Spacer()
        }.padding(.top, 12)
    }

    private func installKeyboardMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { event in
            guard selectedTab == 1, let character = event.charactersIgnoringModifiers?.lowercased().first else { return event }
            let mapping: [Character: Int] = ["a": 60, "w": 61, "s": 62, "e": 63, "d": 64, "f": 65, "t": 66, "g": 67, "y": 68, "h": 69, "u": 70, "j": 71, "k": 72]
            guard let note = mapping[character] else { return event }
            if event.type == .keyDown {
                if !event.isARepeat { heldKeys.insert(note); controller.playNote(note) }
            } else { heldKeys.remove(note); controller.releaseNote(note) }
            return nil
        }
    }
    private func removeKeyboardMonitor() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor); self.keyMonitor = nil }
    }
}
