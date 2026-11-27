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
    @Published var keyboardInstrument = InstrumentPreset.piano
    @Published var octave = 4
    @Published var sustainPedal = false
    @Published var visualVoices: [(frequency: Double, amplitude: Double)] = []
    @Published var trackpadAssignment: HapticEngine.TrackpadAssignment = .auto { didSet { haptics.trackpadAssignment = trackpadAssignment } }
    @Published var availableTrackpads: [(id: UInt64, name: String, isBuiltIn: Bool)] = []
    @Published var keyboardTempo = 1.0
    @Published var keyboardVolume = 0.8
    @Published var legato = false
    @Published var portamentoMilliseconds = 40.0
    @Published var frequencyMode: HapticEngine.FrequencyMode = .standard { didSet { haptics.frequencyMode = frequencyMode } }
    @Published var debugRender = false { didSet { haptics.debugEnabled = debugRender } }
    @Published private(set) var flashingNotes = Set<Int>()

    private let haptics = HapticEngine()
    private var process: Process?
    private var outputPipes: [Pipe] = []
    private var midiClient = MIDIClientRef()
    private var midiPort = MIDIPortRef()
    private var activeKeys = Set<Int>()
    private var sustainedKeys = Set<Int>()
    private var lastThereminFrequency: Double?

    init() { haptics.onVoicesChanged = { [weak self] in self?.visualVoices = $0 }; haptics.onTrackpadsChanged = { [weak self] in self?.availableTrackpads = $0 }; loadVoices(); refreshMIDISources(); haptics.discoverDevices() }

    func speak() {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { append("Enter some text to speak.\n"); return }
        var arguments = ["--voice", selectedVoice, value]
        addModes(to: &arguments); launch(arguments)
    }
    func sweep() { var args = ["--sweep"]; addModes(to: &args); launch(args) }
    func demo() { var args: [String] = []; addModes(to: &args); launch(args) }
    func stop() {
        haptics.stopAllTones()
        activeKeys.removeAll()
        lastThereminFrequency = nil
        guard let process, process.isRunning else { return }
        process.terminate()
        append("\nStopping nospeaker…\n")
    }
    func playWelcomeMelody() { haptics.playWelcomeMelody() }

    func playNote(_ midiNote: Int) {
        flashingNotes.insert(midiNote)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) { self.flashingNotes.remove(midiNote) }
        let previous = activeKeys.first
        activeKeys.insert(midiNote)
        if legato, let previous, previous != midiNote {
            haptics.stopNote(midiNote: previous)
        }
        haptics.startNoteSustained(midiNote: midiNote, preset: keyboardInstrument)
    }
    func releaseNote(_ midiNote: Int) {
        if sustainPedal { sustainedKeys.insert(midiNote); return }
        activeKeys.remove(midiNote); haptics.stopNote(midiNote: midiNote)
    }
    func setSustainPedal(_ on: Bool) {
        if !on {
            sustainedKeys.forEach { haptics.stopNote(midiNote: $0); activeKeys.remove($0) }
            sustainedKeys.removeAll()
        }
        sustainPedal = on
    }
    func apply(_ preset: Preset) {
        if let instrument = InstrumentPreset(rawValue: preset.instrument) { keyboardInstrument = instrument }
        octave = preset.octave; keyboardTempo = preset.tempo; keyboardVolume = preset.volume
        portamentoMilliseconds = preset.portamentoMilliseconds; legato = preset.legato
        if let mode = HapticEngine.FrequencyMode(rawValue: preset.frequencyMode) { frequencyMode = mode }
    }
    func rescanTrackpads() { haptics.discoverDevices() }
    func makePreset(name: String) -> Preset { Preset(name: name, instrument: keyboardInstrument.rawValue, tempo: keyboardTempo, volume: keyboardVolume, octave: octave, portamentoMilliseconds: portamentoMilliseconds, legato: legato, frequencyMode: frequencyMode.rawValue) }
    func theremin(_ position: Double) {
        let frequency = 100 + min(1, max(0, position)) * 3900
        if let lastThereminFrequency, abs(frequency - lastThereminFrequency) <= 10 { return }
        lastThereminFrequency = frequency
        haptics.playTone(frequency: frequency, durationSeconds: 0.3, preset: .theremin)
    }
    func endTheremin() { lastThereminFrequency = nil; haptics.stopAllTones() }
    func logMIDI(_ message: String) { append("MIDI: \(message)\n") }

    private func addModes(to arguments: inout [String]) {
        if darkMode { arguments.append("--dark") }
        if plainMode { arguments.append("--plain") }
        if externalTrackpad { arguments.append("--external") }
    }

    private func loadVoices() {
        Task.detached(priority: .userInitiated) { [weak self] in
            let command = Process(); command.executableURL = URL(fileURLWithPath: "/usr/bin/say")
            command.arguments = ["-v", "?"]; let pipe = Pipe(); command.standardOutput = pipe; command.standardError = Pipe()
            do {
                try command.run(); let data = pipe.fileHandleForReading.readDataToEndOfFile(); command.waitUntilExit()
                let parsed = String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline).compactMap { line in
                    line.split(whereSeparator: { $0 == " " || $0 == "\t" }).first.map(String.init)
                }
                await MainActor.run {
                    self?.voices = parsed
                    self?.selectedVoice = parsed.first ?? ""
                    if parsed.isEmpty { self?.append("No installed macOS voices were found.\n") }
                }
            } catch {
                await MainActor.run { self?.append("Could not list macOS voices: \(error.localizedDescription)\n") }
            }
        }
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
                while i < bytes.count {
                    let status = bytes[i]
                    if status == 0xF0 { break }  // SysEx - skip rest
                    let msgLen: Int
                    switch status & 0xF0 {
                    case 0x80, 0x90, 0xA0, 0xB0, 0xE0: msgLen = 3
                    case 0xC0, 0xD0: msgLen = 2
                    default: i += 1; continue
                    }
                    guard i + msgLen <= bytes.count else { break }
                    if msgLen >= 3 {
                        let note = Int(bytes[i + 1]), velocity = bytes[i + 2]
                        if status & 0xF0 == 0x90 && velocity > 0 {
                            Task { @MainActor in self.playNote(note) }
                        } else if status & 0xF0 == 0x80 || (status & 0xF0 == 0x90 && velocity == 0) {
                            Task { @MainActor in self.releaseNote(note) }
                        }
                    }
                    i += msgLen
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
    private func append(_ value: String) { output += value; if output.count > 100_000 { output = "… [older output trimmed] …\n" + output.suffix(80_000) } }
    private static func displayArgument(_ argument: String) -> String { "'" + argument.replacingOccurrences(of: "'", with: "'\\''") + "'" }
}

private struct PianoKey: Identifiable {
    let midi: Int
    let name: String
    var isBlack: Bool { name.contains("#") }
    var id: Int { midi }
}

struct ContentView: View {
    enum ActiveSheet: Identifiable {
        case update, settings
        var id: String { switch self { case .update: return "update"; case .settings: return "settings" } }
    }

    @StateObject private var controller = SpeakerController()
    @StateObject private var updateManager = UpdateManager()
    @StateObject private var midiPlayer = MIDIPlayer()
    @StateObject private var certInstaller = CertificateInstaller()
    @StateObject private var presetManager = PresetManager()
    @Environment(\.colorScheme) private var colorScheme
    @State private var preferredAppearance: ColorScheme? = nil
    @State private var selectedPresetID: UUID? = nil
    @State private var activeSheet: ActiveSheet? = nil
    @State private var selectedTab = 0
    @State private var heldKeys = Set<Int>()
    @State private var mouseHeldKeys = Set<Int>()
    @State private var keyMonitor: Any?
    @State private var thereminPosition = 0.5

    private var keyboardNotes: [PianoKey] { (((controller.octave + 1) * 12)...(((controller.octave + 1) * 12) + 11)).map { midi in
        let names = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
        let pitch = names[midi % 12]
        return PianoKey(midi: midi, name: "\(pitch)\(midi / 12 - 1)")
    } }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("noSpeakerUI").font(.largeTitle.weight(.semibold))
                    Text("Make your trackpad speak.").foregroundColor(.secondary)
                }
                Spacer()
                Toggle("CLI dark mode", isOn: $controller.darkMode).toggleStyle(.switch)
                Toggle("Plain", isOn: $controller.plainMode).toggleStyle(.switch)
                Toggle("External trackpad", isOn: $controller.externalTrackpad).toggleStyle(.switch)
            }

            if certInstaller.needsInstall {
                HStack {
                    Image(systemName: "lock.shield.fill").foregroundColor(.orange)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("noSpeakerUI Root Certificate not installed").font(.headline)
                        Text("Install it once to avoid security warnings when opening the app.")
                            .font(.caption).foregroundColor(.secondary)
                    }
                    Spacer()
                    if certInstaller.isInstalling {
                        ProgressView()
                    } else if let error = certInstaller.installError {
                        Text(error).foregroundColor(.red).font(.caption).lineLimit(2)
                    } else {
                        Button("Install Certificate") {
                            Task { await certInstaller.installCertificate() }
                        }.buttonStyle(.borderedProminent)
                    }
                    if certInstaller.installed {
                        Image(systemName: "checkmark.seal.fill").foregroundColor(.green)
                    }
                }
                .padding(10)
                .background(Color.orange.opacity(0.12))
                .cornerRadius(8)
                .padding(.horizontal)
            }

            TabView(selection: $selectedTab) {
                controls.tabItem { Label("Speak", systemImage: "waveform") }.tag(0)
                keyboard.tabItem { Label("Keyboard", systemImage: "pianokeys") }.tag(1)
                instrument.tabItem { Label("Theremin & MIDI", systemImage: "slider.horizontal.3") }.tag(2)
                midi.tabItem { Label("MIDI Player", systemImage: "music.note.list") }.tag(3)
                BookwormView(voices: controller.voices, selectedVoice: controller.selectedVoice, onVoiceChange: { controller.selectedVoice = $0 }, onLog: { controller.logMIDI($0) })
                    .tabItem { Label("📖 Bookworm", systemImage: "book") }.tag(4)
            }
            .onChange(of: controller.trackpadAssignment) { assignment in midiPlayer.trackpadAssignment = assignment }
            .onChange(of: selectedTab) { tab in
                if tab != 1 { heldKeys.forEach { controller.releaseNote($0) }; heldKeys.removeAll(); mouseHeldKeys.forEach { controller.releaseNote($0) }; mouseHeldKeys.removeAll() }
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
        .preferredColorScheme(preferredAppearance)
        .toolbar { ToolbarItemGroup(placement: .primaryAction) { Menu("Appearance") { Button("☀️ Light") { preferredAppearance = .light }; Button("🌙 Dark") { preferredAppearance = .dark }; Button("Auto") { preferredAppearance = nil } }; Button("Help") { activeSheet = .settings }; Button("Check for Updates…") { Task { await updateManager.checkForUpdates(); if updateManager.latestRelease?.isNewer == true { activeSheet = .update } } }.disabled(updateManager.isChecking) } }
        .onAppear {
            midiPlayer.onLog = { message in controller.logMIDI(message) }
            midiPlayer.trackpadAssignment = controller.trackpadAssignment
            installKeyboardMonitor()
            Task {
                try? await Task.sleep(nanoseconds: 300_000_000)
                controller.playWelcomeMelody()
                certInstaller.checkIfNeeded()
                await updateManager.checkForUpdates()
                if updateManager.latestRelease?.isNewer == true { activeSheet = .update }
            }
        }
        .onDisappear { removeKeyboardMonitor(); if controller.midiEnabled { controller.midiEnabled = false }; controller.stop() }
        .alert("noSpeakerUI is up to date", isPresented: $updateManager.showUpToDateAlert) {
            Button("OK") { updateManager.showUpToDateAlert = false }
        } message: {
            if let err = updateManager.errorMessage {
                Text(err)
            } else {
                Text("Version \(UpdateManager.currentVersion) is the latest release.")
            }
        }
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
            case .update: UpdateSheet(manager: updateManager)
            case .settings: SettingsDocSheet()
            }
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Text to speak").font(.headline)
            GroupBox("Settings / General") {
                VStack(alignment: .leading, spacing: 6) {
                    Picker("Frequency mode", selection: $controller.frequencyMode) { ForEach(HapticEngine.FrequencyMode.allCases) { Text($0.rawValue).tag($0) } }
                    if controller.frequencyMode == .extended { Text("⚠️ Above 4 kHz: quieter and buzzier. May not work on all trackpads.").font(.caption).foregroundColor(.orange) }
                    Text("Render Rate: 10ms / 100 Hz render loop").font(.caption)
                    Toggle("Debug render jitter", isOn: $controller.debugRender)
                    VStack(alignment: .leading) {
                        Text("Trackpads").font(.headline)
                        ForEach(controller.availableTrackpads, id: \.id) { pad in Text("\(pad.name) · \(pad.isBuiltIn ? "Built-in" : "External")") }
                        Picker("Assignment", selection: $controller.trackpadAssignment) { ForEach(HapticEngine.TrackpadAssignment.allCases) { Text($0.rawValue).tag($0) } }
                        Button("Rescan") { controller.rescanTrackpads() }
                        Text(controller.availableTrackpads.isEmpty ? "No trackpads active" : "\(controller.availableTrackpads.count) trackpad\(controller.availableTrackpads.count == 1 ? "" : "s") active").font(.caption).foregroundColor(.secondary)
                    }
                }
            }
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
            HStack { Text("🦶 Sustain").foregroundColor(controller.sustainPedal ? .orange : .secondary); Circle().fill(controller.sustainPedal ? Color.orange : Color.secondary.opacity(0.3)).frame(width: 10, height: 10) }
            Text("Click a key or use A W S E D F T G Y H U J K. Hold to play; release to stop.").foregroundColor(.secondary)
            Picker("Instrument", selection: $controller.keyboardInstrument) { ForEach(InstrumentPreset.allCases) { Text($0.rawValue).tag($0) } }.frame(width: 200)
            HStack { Button("<<") { controller.octave = max(1, controller.octave - 1) }.disabled(controller.octave <= 1); Text("Octave \(controller.octave) (C\(controller.octave)–B\(controller.octave))"); Button(">>") { controller.octave = min(7, controller.octave + 1) }.disabled(controller.octave >= 7); Toggle("Legato", isOn: $controller.legato) }
            HStack { Text("Portamento Time"); Slider(value: $controller.portamentoMilliseconds, in: 0...200); Text("\(Int(controller.portamentoMilliseconds)) ms") }
            HStack {
                Picker("Preset", selection: $selectedPresetID) {
                    Text("Choose preset").tag(UUID?.none)
                    ForEach(presetManager.presets) { Text($0.name).tag(Optional($0.id)) }
                }.frame(width: 220).onChange(of: selectedPresetID) { id in if let id, let preset = presetManager.presets.first(where: { $0.id == id }) { controller.apply(preset) } }
                Button("Save Current") { presetManager.newPresetName = ""; presetManager.showingSaveDialog = true }
                Button("Delete") { if let id = selectedPresetID, let preset = presetManager.presets.first(where: { $0.id == id }) { presetManager.delete(preset); selectedPresetID = nil } }.disabled(selectedPresetID == nil)
            }
            if presetManager.showingSaveDialog {
                HStack { TextField("Preset name", text: $presetManager.newPresetName); Button("Save") { let name = presetManager.newPresetName.trimmingCharacters(in: .whitespacesAndNewlines); if !name.isEmpty { let preset = controller.makePreset(name: name); presetManager.save(preset); selectedPresetID = preset.id }; presetManager.showingSaveDialog = false }; Button("Cancel") { presetManager.showingSaveDialog = false } }
            }
            piano
            FrequencyVisualizer(voices: controller.visualVoices)
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
            pianoButton(key, color: (controller.flashingNotes.contains(key.midi) || midiPlayer.flashingNotes.contains(key.midi)) ? .orange : .white, foreground: .black)
                    }
                }
                ForEach(keyboardNotes.filter(\.isBlack)) { key in
                    let whiteIndex = keyboardNotes.filter { !$0.isBlack && $0.midi < key.midi }.count
                    pianoButton(key, color: (controller.flashingNotes.contains(key.midi) || midiPlayer.flashingNotes.contains(key.midi)) ? .orange : .black, foreground: .white)
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

    private var midi: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Built-in Pieces").font(.headline)
            List(BuiltInPiece.all) { piece in
                HStack {
                    VStack(alignment: .leading) { Text(piece.name); Text("\(piece.composer) · \(piece.difficulty)").font(.caption).foregroundColor(.secondary) }
                    Spacer()
                    if midiPlayer.currentTrackName == piece.name { Image(systemName: "checkmark.circle.fill").foregroundColor(.accentColor) }
                }.contentShape(Rectangle()).onTapGesture { midiPlayer.choose(piece) }
            }.frame(minHeight: 170)
            HStack { Text("Open Your Own MIDI").font(.headline); Spacer(); Button("Open File…", action: midiPlayer.openFile) }
            Divider()
            HStack { Text(midiPlayer.currentTrackName.isEmpty ? "No track selected" : midiPlayer.currentTrackName).lineLimit(1); Spacer(); Text("\(Int(midiPlayer.progress * 100))%") }
            Text(midiPlayer.currentNoteLabel).font(.caption).foregroundColor(.secondary)
            ProgressView(value: midiPlayer.progress)
            FrequencyVisualizer(voices: midiPlayer.visualVoices)
            HStack {
                Button { midiPlayer.isPlaying ? midiPlayer.pause() : midiPlayer.play() } label: { Label(midiPlayer.isPlaying ? "Pause" : "Play", systemImage: midiPlayer.isPlaying ? "pause.fill" : "play.fill") }
                    .disabled(midiPlayer.selectedURL == nil)
                Button(action: midiPlayer.stop) { Label("Stop", systemImage: "stop.fill") }
                Spacer()
                Picker("Instrument", selection: $midiPlayer.currentInstrument) { ForEach(InstrumentPreset.allCases) { Text($0.rawValue).tag($0) } }.frame(width: 170)
            }
            HStack { Text("Tempo"); Slider(value: $midiPlayer.tempo, in: 0.5...2); Text("\(Int(midiPlayer.tempo * 100))%") }
            HStack { Text("Transpose"); Button("−") { midiPlayer.transpose = max(-12, midiPlayer.transpose - 1) }; Text("\(midiPlayer.transpose) st").frame(width: 45); Button("+") { midiPlayer.transpose = min(12, midiPlayer.transpose + 1) }; Spacer(); Toggle("Loop", isOn: $midiPlayer.loop); Toggle("Legato", isOn: $midiPlayer.legato) }
            Picker("Polyphony Limit", selection: $midiPlayer.polyphonyLimit) { ForEach(1...4, id: \.self) { Text("\($0) voices").tag($0) } }
            HStack { Text("Portamento Time"); Slider(value: $midiPlayer.portamentoMilliseconds, in: 0...200); Text("\(Int(midiPlayer.portamentoMilliseconds)) ms") }
            HStack { Text("Strength"); Slider(value: $midiPlayer.volume, in: 0...1); Text("\(Int(midiPlayer.volume * 100))%") }
            Text("Tip: Convert sheet music to MIDI at musescore.com").font(.caption).foregroundColor(.secondary)
        }.padding(.top, 10)
    }

    private func installKeyboardMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { event in
            if event.modifierFlags.contains(.command), event.type == .keyDown, event.keyCode == 126 { controller.octave = min(7, controller.octave + 1); return nil }
            if event.modifierFlags.contains(.command), event.type == .keyDown, event.keyCode == 125 { controller.octave = max(1, controller.octave - 1); return nil }
            guard selectedTab == 1 else { return event }
            if event.charactersIgnoringModifiers == " " {
                if event.type == .keyDown && !event.isARepeat { controller.setSustainPedal(true) }
                if event.type == .keyUp { controller.setSustainPedal(false) }
                return nil
            }
            guard let character = event.charactersIgnoringModifiers?.lowercased().first else { return event }
            let base = (controller.octave + 1) * 12
            let mapping: [Character: Int] = ["a": base, "w": base+1, "s": base+2, "e": base+3, "d": base+4, "f": base+5, "t": base+6, "g": base+7, "y": base+8, "h": base+9, "u": base+10, "j": base+11, "k": base+12]
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

private struct SettingsDocSheet: View {
    @Environment(\.dismiss) private var dismiss
    private let sections: [(String, String)] = [
        ("General", "Voice selects an installed macOS voice. Speak reads the text field. Sweep and Demo run the bundled noSpeaker effects. Stop ends active output. The Output area shows process logs and status. Dark, Plain, and External trackpad select CLI modes."),
        ("Keyboard", "Click piano keys or hold A W S E D F T G Y H U J K. A is the root of the selected octave; the other keys ascend chromatically. << and >> select octaves C1–C7. Command–Up and Command–Down change octave. Legato glides between notes; Portamento Time sets glide duration from 0 to 200 ms."),
        ("MIDI Player", "Choose one of the built-in pieces or open a .mid/.midi file. Play, Pause, and Stop control playback. Instrument selects the timbre; Tempo scales playback speed (50–200%); Strength sets haptic intensity. Transpose shifts notes by semitones (±12). Loop restarts at the end. Legato and Portamento Time control transitions. The current note and instrument appear during playback."),
        ("MIDI Input", "Enable MIDI Input, choose a connected source, and use Refresh to rescan. MIDI note-on starts a haptic note; note-off releases that note. Chords are mixed together."),
        ("Theremin", "Drag the slider across 100–4,000 Hz. Updates are debounced by 10 Hz to avoid excessive actuation calls; release the slider to stop."),
        ("Instruments", "Piano: bright, struck harmonics. Organ: steady, layered harmonics. Guitar: plucked with a strong second partial. Violin: rich sustained harmonics. Flute: soft fundamental. Trumpet: bright odd harmonics. Bass: low fundamental and subharmonic. Xylophone: woody inharmonic partial. Harpsichord: crisp, bright harmonics. Theremin: smooth pure tone."),
        ("Updater", "Check for Updates checks the project's GitHub releases. When a newer release is available, the updater shows its changelog and offers a DMG download with progress. Open the downloaded DMG and move the app into Applications to install it.")]
    var body: some View {
        NavigationView { List { ForEach(sections, id: \.0) { title, detail in Section(header: Text(title)) { Text(detail).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true) } } }.navigationTitle("Settings Help").toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } } }
            .frame(minWidth: 560, minHeight: 560)
    }
}
