import AppKit
import UserNotifications

/// Mengatur alur: siap → merekam → memproses → selesai/gagal.
@MainActor
final class MeetingController {
    let state = AppState()
    private var capture: AudioCapture?
    private var live: LiveTranscriber?
    private var processor: Processor?
    private var timer: Timer?
    private var startedAt = Date()

    func toggle() {
        switch state.phase {
        case .idle, .done, .failed: start()
        case .recording: stop()
        case .processing: break
        }
    }

    func start() {
        let started = Date()
        let stamp = Self.stampFormatter.string(from: started)
        let dir = Config.outputDir.appendingPathComponent("rekaman").appendingPathComponent(stamp)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            fail("Tidak bisa membuat folder rekaman: \(error.localizedDescription)", dir: nil)
            return
        }

        let live = LiveTranscriber { [weak self] text in
            Task { @MainActor in self?.state.liveText = text }
        }
        let capture = AudioCapture(output: dir.appendingPathComponent("meeting.wav"))
        capture.onSamples = { [weak live] buffer in live?.append(buffer) }
        capture.onLevel = { [weak self] level in
            Task { @MainActor in self?.state.level = level }
        }

        Task { @MainActor in
            guard await AudioCapture.requestMicAccess() else {
                self.fail("Izin mikrofon ditolak. Buka System Settings → Privacy & Security → Microphone.", dir: dir)
                return
            }
            do {
                let warning = try await capture.start()
                self.capture = capture
                self.live = live
                self.startedAt = started
                self.state.recordingDir = dir
                self.state.micName = capture.micName
                self.state.warning = warning
                self.state.marks = []
                self.state.elapsed = 0
                self.state.liveText = ""
                self.state.result = nil
                self.state.phase = .recording
                self.state.expanded = true
                live.start()
                self.timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                    Task { @MainActor in self?.tick() }
                }
            } catch {
                self.fail("Gagal mulai merekam: \(error.localizedDescription)", dir: dir)
            }
        }
    }

    func markImportant() {
        guard state.phase == .recording else { return }
        state.marks.append(state.elapsed)
    }

    func stop() {
        guard state.phase == .recording, let capture, let dir = state.recordingDir else { return }
        timer?.invalidate()
        timer = nil
        live?.stop()
        capture.stop()
        self.capture = nil
        self.live = nil

        let marksURL = dir.appendingPathComponent("penting.json")
        let marks = (try? JSONEncoder().encode(state.marks.map { ($0 * 10).rounded() / 10 })) ?? Data("[]".utf8)
        try? marks.write(to: marksURL)

        state.phase = .processing
        state.expanded = false
        state.step = 0
        state.stepDetail = "Mentranskrip..."
        let processor = Processor()
        self.processor = processor
        processor.run(
            audio: dir.appendingPathComponent("meeting.wav"), marks: marksURL, startedAt: startedAt,
            onStatus: { [weak self] message in
                Task { @MainActor in self?.updateStep(message) }
            },
            onFinish: { [weak self] outcome in
                Task { @MainActor in self?.finish(outcome, dir: dir) }
            }
        )
    }

    func dismiss() {
        state.phase = .idle
        state.expanded = false
    }

    func openFolder() {
        let dir = state.phase == .failed ? (state.recordingDir ?? Config.outputDir) : Config.outputDir
        NSWorkspace.shared.open(dir)
    }

    func openResult() {
        guard let result = state.result else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: result.docx))
    }

    func copyResult() {
        guard let result = state.result,
              let text = try? String(contentsOfFile: result.markdown, encoding: .utf8) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    // MARK: - Internal

    private func tick() {
        state.elapsed = Date().timeIntervalSince(startedAt)
        if Int(state.elapsed) > 0, Int(state.elapsed) % Config.liveRotateSeconds == 0 {
            live?.rotate()
        }
    }

    private func updateStep(_ message: String) {
        state.stepDetail = message
        if message.hasPrefix("Mentranskrip") {
            state.step = 0
        } else if message.hasPrefix("Mengoreksi") {
            state.step = 1
        } else if message.hasPrefix("Selesai") {
            state.step = 2
        }
    }

    private func finish(_ outcome: Result<NotesResult, Error>, dir: URL) {
        processor = nil
        switch outcome {
        case .success(let result):
            state.result = result
            state.step = 2
            state.phase = .done
            notify(title: "MoM siap", body: result.title)
        case .failure(let error):
            fail("\(error.localizedDescription)\nRekaman aman di folder rekaman.", dir: dir)
            notify(title: "Gagal memproses rapat", body: "Rekaman aman, bisa diproses ulang.")
        }
    }

    private func fail(_ message: String, dir: URL?) {
        timer?.invalidate()
        timer = nil
        state.errorMessage = message
        state.recordingDir = dir
        state.phase = .failed
    }

    private func notify(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    private static let stampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd_HHmmss"
        return formatter
    }()
}
