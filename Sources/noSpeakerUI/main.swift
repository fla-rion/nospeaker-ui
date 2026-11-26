import AppKit
import SwiftUI

@main
struct noSpeakerUIApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 620, minHeight: 500)
        }
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
    @Published var output = "Ready. Choose an action to start nospeaker.\n"
    @Published private(set) var isRunning = false

    private var process: Process?
    private var outputPipes: [Pipe] = []

    init() {
        loadVoices()
    }

    func speak() {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else {
            append("Enter some text to speak.\n")
            return
        }
        var arguments: [String] = ["--voice", selectedVoice, value]
        addModes(to: &arguments)
        launch(arguments)
    }

    func sweep() {
        var arguments = ["--sweep"]
        addModes(to: &arguments)
        launch(arguments)
    }

    func demo() {
        var arguments: [String] = []
        addModes(to: &arguments)
        launch(arguments)
    }

    func stop() {
        guard let process, process.isRunning else { return }
        process.terminate()
        append("\nStopping nospeaker…\n")
    }

    private func addModes(to arguments: inout [String]) {
        if darkMode { arguments.append("--dark") }
        if plainMode { arguments.append("--plain") }
    }

    private func loadVoices() {
        let command = Process()
        command.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        command.arguments = ["-v", "?"]
        let pipe = Pipe()
        command.standardOutput = pipe
        command.standardError = Pipe()
        do {
            try command.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            command.waitUntilExit()
            let names = String(decoding: data, as: UTF8.self)
                .split(whereSeparator: \.isNewline)
                .compactMap { line -> String? in
                    let columns = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
                    guard let name = columns.first else { return nil }
                    return String(name)
                }
            voices = names
            selectedVoice = names.first ?? ""
            if names.isEmpty { append("No installed macOS voices were found.\n") }
        } catch {
            append("Could not list macOS voices: \(error.localizedDescription)\n")
        }
    }

    private func launch(_ arguments: [String]) {
        guard !isRunning else {
            append("nospeaker is already running. Stop it before starting another action.\n")
            return
        }
        guard let binaryPath = Bundle.main.path(forResource: "nospeaker", ofType: nil) else {
            append("Error: nospeaker is not bundled in this app. Rebuild the app with nospeaker in Contents/Resources.\n")
            return
        }

        let task = Process()
        task.executableURL = URL(fileURLWithPath: binaryPath)
        task.arguments = arguments
        task.environment = ProcessInfo.processInfo.environment.merging(["TERM": "dumb"]) { _, new in new }

        let stdout = Pipe()
        let stderr = Pipe()
        task.standardOutput = stdout
        task.standardError = stderr
        process = task
        outputPipes = [stdout, stderr]
        isRunning = true
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
                if !remaining.isEmpty {
                    let chunk = String(decoding: remaining, as: UTF8.self)
                    Task { @MainActor in self?.append(chunk) }
                }
                try? pipe.fileHandleForReading.close()
            }
            Task { @MainActor in
                self?.append("\nProcess finished with exit code \(finished.terminationStatus).\n")
                self?.isRunning = false
                self?.process = nil
                self?.outputPipes = []
            }
        }

        do {
            try task.run()
        } catch {
            task.terminationHandler = nil
            for pipe in outputPipes { pipe.fileHandleForReading.readabilityHandler = nil }
            outputPipes = []
            process = nil
            isRunning = false
            append("Could not start nospeaker: \(error.localizedDescription)\n")
        }
    }

    private func append(_ value: String) {
        output += value
    }

    private static func displayArgument(_ argument: String) -> String {
        "'" + argument.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

struct ContentView: View {
    @StateObject private var controller = SpeakerController()

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text("noSpeakerUI")
                    .font(.largeTitle.weight(.semibold))
                Text("Make your trackpad speak.")
                    .foregroundColor(.secondary)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Text to speak").font(.headline)
                TextField("Enter text…", text: $controller.text)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(controller.speak)
            }

            HStack(spacing: 12) {
                Picker("Voice", selection: $controller.selectedVoice) {
                    ForEach(controller.voices, id: \.self) { voice in
                        Text(voice).tag(voice)
                    }
                }
                .frame(maxWidth: 260)
                .disabled(controller.voices.isEmpty)

                Toggle("Dark", isOn: $controller.darkMode)
                Toggle("Plain", isOn: $controller.plainMode)
            }

            HStack(spacing: 10) {
                Button(action: controller.speak) {
                    Label("Speak", systemImage: "waveform")
                }
                .keyboardShortcut(.return, modifiers: [.command])
                Button(action: controller.sweep) {
                    Label("Sweep", systemImage: "waveform.path")
                }
                Button(action: controller.demo) {
                    Label("Demo", systemImage: "play.fill")
                }
                Spacer()
                Button(action: controller.stop) {
                    Label("Stop", systemImage: "stop.fill")
                }
                .disabled(!controller.isRunning)
            }

            HStack {
                Text("Output").font(.headline)
                Spacer()
                Circle()
                    .fill(controller.isRunning ? Color.green : Color.secondary.opacity(0.5))
                    .frame(width: 8, height: 8)
                Text(controller.isRunning ? "Running" : "Idle")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            ScrollViewReader { proxy in
                ScrollView {
                    Text(controller.output)
                        .font(.system(.callout, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .padding(12)
                        .id("log-bottom")
                }
                .background(Color(nsColor: .textBackgroundColor))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.2)))
                .onChange(of: controller.output) { _ in
                    proxy.scrollTo("log-bottom", anchor: .bottom)
                }
            }
            .frame(minHeight: 170)
        }
        .padding(24)
    }
}
