import AppKit
import PDFKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
private final class BookwormReader: ObservableObject {
    @Published var text = ""
    @Published var filename = ""
    @Published var sentences: [(text: String, range: NSRange)] = []
    @Published var currentSentenceIndex: Int? = nil
    @Published var isReading = false
    @Published var isPaused = false
    @Published var speed = 1.0
    @Published var voice = ""
    var onLog: ((String) -> Void)?
    private var task: Task<Void, Never>?
    private var process: Process?
    private var nextIndex = 0
    private var pauseContinuation: CheckedContinuation<Void, Never>?

    func openFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.plainText, .text, .rtf, .pdf, UTType(filenameExtension: "md")].compactMap { $0 }
        panel.allowsOtherFileTypes = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let value: String
            switch url.pathExtension.lowercased() {
            case "pdf":
                guard let pdf = PDFDocument(url: url) else { throw NSError(domain: "Bookworm", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not open PDF."]) }
                value = (0..<pdf.pageCount).compactMap { pdf.page(at: $0)?.string }.joined(separator: "\n")
            case "rtf":
                let data = try Data(contentsOf: url)
                value = try NSAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil).string
            default: value = try String(contentsOf: url, encoding: .utf8)
            }
            stop()
            text = value; filename = url.lastPathComponent; currentSentenceIndex = nil; nextIndex = 0
            sentences = Self.split(value)
            onLog?("Loaded \(filename) (\(value.count) characters).\n")
            if value.count > 10_000 { onLog?("Warning: This is a long text. The trackpad will be very busy.\n") }
        } catch { onLog?("Could not load text file: \(error.localizedDescription)\n") }
    }

    func read() {
        guard !sentences.isEmpty else { onLog?("Open a text file first.\n"); return }
        guard !isReading else { return }
        if nextIndex >= sentences.count { nextIndex = 0 }
        isReading = true; isPaused = false
        let start = nextIndex
        let all = sentences.map(\.text)
        let voice = self.voice
        let speed = self.speed
        let hasEasterEgg = text.localizedCaseInsensitiveContains("nospeaker") && start == 0
        let binaryURL = Bundle.main.url(forResource: "nospeaker", withExtension: nil)
        task = Task.detached { [weak self] in
            if hasEasterEgg, let self {
                await MainActor.run { self.onLog?("♪ Nospeaker found! Playing a tiny bookworm jingle…\n") }
                // A short, playful three note chime from the app's haptic engine is not available here;
                // invoke the bundled CLI's sweep as the easter egg.
                if let binaryURL { await Self.runProcess(url: binaryURL, arguments: ["--sweep", "--plain"], owner: self) }
            }
            for index in start..<all.count {
                if Task.isCancelled { break }
                guard let self else { break }
                await self.waitWhilePaused()
                if Task.isCancelled { break }
                await MainActor.run { self.currentSentenceIndex = index; self.nextIndex = index + 1 }
                guard let binaryURL else { await MainActor.run { self.onLog?("Error: nospeaker is not bundled in this app.\n") }; break }
                await Self.runProcess(url: binaryURL, arguments: ["--voice", voice, "--plain", all[index]], owner: self)
                if Task.isCancelled { break }
                let delay = UInt64(max(0.05, 0.45 / speed) * 1_000_000_000)
                try? await Task.sleep(nanoseconds: delay)
            }
            guard let self else { return }
            await MainActor.run {
                if !Task.isCancelled && self.nextIndex >= all.count { self.onLog?("The End 📚\n"); self.nextIndex = 0 }
                self.isReading = false; self.isPaused = false; self.currentSentenceIndex = nil; self.process = nil
            }
        }
    }

    func togglePause() {
        guard isReading else { return }
        if isPaused { isPaused = false; pauseContinuation?.resume(); pauseContinuation = nil }
        else { isPaused = true; process?.terminate() }
    }

    func stop() {
        task?.cancel(); task = nil; process?.terminate(); process = nil
        pauseContinuation?.resume(); pauseContinuation = nil
        isReading = false; isPaused = false; currentSentenceIndex = nil; nextIndex = 0
    }

    private func waitWhilePaused() async {
        guard isPaused else { return }
        await withCheckedContinuation { pauseContinuation = $0 }
    }

    private static func runProcess(url: URL, arguments: [String], owner: BookwormReader) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            Task { @MainActor in
                if Task.isCancelled { continuation.resume(); return }
                let process = Process(); process.executableURL = url; process.arguments = arguments
                owner.process = process
                process.terminationHandler = { _ in continuation.resume() }
                do { try process.run() } catch { owner.onLog?("Could not start nospeaker: \(error.localizedDescription)\n"); continuation.resume() }
            }
        }
    }

    private static func split(_ text: String) -> [(text: String, range: NSRange)] {
        let ns = text as NSString
        var result: [(String, NSRange)] = [], start = 0
        for index in 0..<ns.length {
            let character = ns.substring(with: NSRange(location: index, length: 1))
            if ".!?\n".contains(character) {
                let range = NSRange(location: start, length: index + 1 - start)
                let sentence = ns.substring(with: range).trimmingCharacters(in: .whitespacesAndNewlines)
                if !sentence.isEmpty, let match = ns.range(of: sentence, options: [], range: range).toOptional { result.append((sentence, match)) }
                start = index + 1
            }
        }
        if start < ns.length {
            let range = NSRange(location: start, length: ns.length - start)
            let sentence = ns.substring(with: range).trimmingCharacters(in: .whitespacesAndNewlines)
            if !sentence.isEmpty, let match = ns.range(of: sentence, options: [], range: range).toOptional { result.append((sentence, match)) }
        }
        return result
    }
}

private extension NSRange {
    var toOptional: NSRange? { location == NSNotFound ? nil : self }
}

struct BookwormView: View {
    let voices: [String]
    let selectedVoice: String
    let onVoiceChange: (String) -> Void
    let onLog: (String) -> Void
    @StateObject private var reader = BookwormReader()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Button("Open Text File…", action: reader.openFile)
                Text(reader.filename.isEmpty ? "No file selected" : reader.filename).lineLimit(1).foregroundColor(.secondary)
                Spacer()
                if !reader.text.isEmpty { Text("\(reader.text.count) characters").font(.caption).foregroundColor(.secondary) }
            }
            if reader.text.count > 10_000 { Label("Warning: This is a long text. The trackpad will be very busy.", systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundColor(.orange) }
            HighlightedTextView(text: reader.text, range: reader.currentSentenceIndex.flatMap { reader.sentences.indices.contains($0) ? reader.sentences[$0].range : nil })
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.25)))
            HStack(spacing: 12) {
                Picker("Voice", selection: Binding(get: { reader.voice }, set: { reader.voice = $0; onVoiceChange($0) })) { ForEach(voices, id: \.self) { Text($0).tag($0) } }.frame(maxWidth: 220)
                Button { reader.isReading ? reader.togglePause() : reader.read() } label: { Label(reader.isPaused ? "Resume" : (reader.isReading ? "Pause" : "Read Aloud"), systemImage: reader.isPaused ? "play.fill" : (reader.isReading ? "pause.fill" : "book.fill")) }.disabled(reader.text.isEmpty)
                Button("Stop", action: reader.stop).disabled(!reader.isReading)
                Spacer()
            }
            HStack { Text("Reading speed"); Slider(value: $reader.speed, in: 0.5...2); Text("\(Int(reader.speed * 100))%").frame(width: 45, alignment: .trailing) }
            if reader.isReading { Text("📖  Reading sentence \(min((reader.currentSentenceIndex ?? 0) + 1, reader.sentences.count)) of \(reader.sentences.count)").font(.caption).foregroundColor(.secondary) }
        }
        .padding(.top, 12)
        .onAppear { reader.voice = selectedVoice; reader.onLog = onLog }
        .onChange(of: selectedVoice) { reader.voice = $0 }
        .onDisappear { reader.stop() }
    }
}

private struct HighlightedTextView: NSViewRepresentable {
    let text: String
    let range: NSRange?
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.borderType = .noBorder
        let view = NSTextView(); view.isEditable = false; view.isSelectable = true; view.font = .systemFont(ofSize: 14); view.textContainerInset = NSSize(width: 10, height: 10); view.autoresizingMask = [.width]
        scroll.documentView = view
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? NSTextView else { return }
        if view.string != text { view.string = text }
        if let range, range.location + range.length <= (text as NSString).length { view.setSelectedRange(range); view.scrollRangeToVisible(range) }
    }
}
