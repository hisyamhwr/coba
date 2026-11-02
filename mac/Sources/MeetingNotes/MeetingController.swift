import AppKit
import UserNotifications

/// Mengatur alur: siap → merekam → memproses → selesai/gagal.
@MainActor
final class MeetingController {
    let state: AppState
    let meter: LiveMeter
    private var capture: AudioCapture?
    private var live: LiveTranscriber?
    private var processor: Processor?
    private var worker: LiveWorker?
    private var timer: Timer?
    private var startedAt = Date()
    /// Pengawas: kapan jam audio terakhir bergerak (untuk memulihkan mic yang berhenti diam-diam).
    private var lastAudioProgress = Date()
    private var lastRecordedSeconds: TimeInterval = 0

    init() {
        state = AppState()
        meter = LiveMeter()
    }

    func toggle() {
        switch state.phase {
        case .idle, .done, .failed: start()
        case .recording: stop()
        case .processing: break
        }
    }

    func start() {
        guard !state.starting else { return }
        let started = Date()
        let stamp = Self.stampFormatter.string(from: started)
        let dir = Config.outputDir.appendingPathComponent("rekaman").appendingPathComponent(stamp)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            fail("Tidak bisa membuat folder rekaman: \(error.localizedDescription)", dir: nil)
            return
        }

        // Transkrip live opsional (menu bar) karena pengenal suara memakai CPU selama rapat.
        let live: LiveTranscriber? = state.liveTranscript ? LiveTranscriber(terms: Self.glossaryTerms()) {
            [weak self] caption in
            Task { @MainActor in
                guard let self else { return }
                if self.meter.liveText != caption.committed { self.meter.liveText = caption.committed }
                if self.meter.livePartial != caption.partial { self.meter.livePartial = caption.partial }
            }
        } : nil
        let capture = AudioCapture(output: dir.appendingPathComponent("meeting.wav"))
        live?.onLog = { line in capture.note(line) }
        capture.onSamples = live.map { transcriber in { buffer in transcriber.append(buffer) } }
        capture.onLevel = { [weak self] level in
            Task { @MainActor in self?.meter.level = level }
        }
        capture.onProblem = { [weak self] message in
            Task { @MainActor in self?.state.warning = message }
        }

        state.starting = true
        state.errorMessage = ""
        capture.note("Mulai Catat diklik")
        Task { @MainActor in
            guard await AudioCapture.requestMicAccess() else {
                capture.note("Izin mikrofon ditolak")
                self.state.starting = false
                self.fail("Izin mikrofon ditolak. Buka System Settings → Privacy & Security → Microphone.", dir: dir)
                return
            }
            do {
                try capture.start()
            } catch {
                capture.note("Gagal mulai: \(error.localizedDescription)")
                self.state.starting = false
                self.fail("Gagal mulai merekam: \(error.localizedDescription)", dir: dir)
                return
            }
            self.state.starting = false
            self.capture = capture
            self.live = live
            // Waktu mulai = saat mic benar-benar merekam (bukan saat klik; dialog izin bisa makan waktu).
            self.startedAt = Date()
            self.lastAudioProgress = Date()
            self.lastRecordedSeconds = 0
            self.state.recordingDir = dir
            self.state.micName = capture.micName
            self.state.warning = nil
            self.state.marks = []
            self.meter.elapsed = 0
            self.meter.level = 0
            self.meter.liveText = live == nil ? "Transkrip live dimatikan (hemat baterai)." : ""
            self.meter.livePartial = ""
            self.state.result = nil
            self.state.phase = .recording
            self.state.expanded = true
            live?.start()
            let worker = LiveWorker(folder: dir)
            worker.start()
            self.worker = worker
            let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.tick() }
            }
            // Mode .common: timer tetap berjalan saat menu bar sedang dibuka.
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
            // Audio sistem menyusul tanpa menahan rekaman mic (izinnya bisa membuka dialog macOS).
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 4_000_000_000)
                if self.capture === capture, !capture.systemAudioActive, self.state.warning == nil {
                    self.state.warning = "Menunggu izin Screen & System Audio Recording untuk suara meeting..."
                }
            }
            let warning = await capture.startSystem()
            guard self.capture === capture else { return }
            if let warning {
                self.state.warning = warning
            } else if self.state.warning?.hasPrefix("Menunggu") == true {
                self.state.warning = nil
            }
        }
    }

    /// Istilah dari kamus yang dipelajari (~/MeetingNotes/kamus.txt) lalu kamus dasar, untuk transkrip live.
    private static func glossaryTerms() -> [String] {
        let files = [
            Config.outputDir.appendingPathComponent("kamus.txt"),
            URL(fileURLWithPath: Config.repoPath).appendingPathComponent("meeting_notes/kamus_dasar.txt"),
        ]
        var seen = Set<String>()
        return files.flatMap { url -> [String] in
            let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            return text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty && !$0.hasPrefix("#") }
        }
        .filter { seen.insert($0.lowercased()).inserted }
    }

    func markImportant() {
        guard state.phase == .recording, let capture else { return }
        // Jam audio: tetap cocok dengan rekaman walau Mac sempat tidur atau mic sempat terputus.
        state.marks.append(capture.recordedSeconds)
    }

    func stop() {
        guard state.phase == .recording, let capture, let dir = state.recordingDir else { return }
        timer?.invalidate()
        timer = nil
        live?.stop()
        capture.stop()
        worker?.stop()
        worker = nil
        meter.level = 0
        self.capture = nil
        self.live = nil

        let marksURL = dir.appendingPathComponent("penting.json")
        let marks = (try? JSONEncoder().encode(state.marks.map { ($0 * 10).rounded() / 10 })) ?? Data("[]".utf8)
        try? marks.write(to: marksURL)

        runProcessor(dir: dir)
    }

    /// Proses ulang rekaman terakhir: setelah gagal, atau saat MoM gagal disusun (mis. batas pemakaian Claude).
    /// Transkrip yang sudah jadi dipakai ulang, jadi langsung ke penyusunan MoM.
    func retry() {
        let canRetry = state.phase == .failed || (state.phase == .done && state.result?.summarized == false)
        guard canRetry, let dir = state.recordingDir,
              FileManager.default.fileExists(atPath: dir.appendingPathComponent("meeting.wav").path)
        else { return }
        runProcessor(dir: dir)
    }

    /// Batalkan pemrosesan yang terlalu lama; rekaman tetap aman dan bisa diproses ulang.
    func cancelProcessing() {
        guard state.phase == .processing, let processor else { return }
        processor.cancel()
    }

    /// Dipanggil saat aplikasi ditutup: rekaman yang sedang berjalan ditutup rapi agar file WAV utuh, dan
    /// transkripsi latar belakang dihentikan. Pemrosesan yang sedang berjalan dibiarkan selesai sendiri.
    func shutdown() {
        guard state.phase == .recording, let capture, let dir = state.recordingDir else { return }
        timer?.invalidate()
        live?.stop()
        capture.note("Aplikasi ditutup saat merekam; rekaman disimpan")
        capture.stop()
        worker?.stop()
        let marks = (try? JSONEncoder().encode(state.marks)) ?? Data("[]".utf8)
        try? marks.write(to: dir.appendingPathComponent("penting.json"))
    }

    private func runProcessor(dir: URL) {
        let marksURL = dir.appendingPathComponent("penting.json")
        if !FileManager.default.fileExists(atPath: marksURL.path) {
            try? Data("[]".utf8).write(to: marksURL)
        }
        state.phase = .processing
        state.expanded = false
        state.step = 0
        state.stepDetail = "Mentranskrip..."
        let processor = Processor()
        self.processor = processor
        processor.run(
            audio: dir.appendingPathComponent("meeting.wav"), marks: marksURL, startedAt: startedAt,
            docx: state.exportDocx,
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
        // Buka Word bila dibuat; selain itu file Markdown (terbuka di aplikasi teks default).
        NSWorkspace.shared.open(URL(fileURLWithPath: result.docx ?? result.markdown))
    }

    func copyResult() {
        guard let result = state.result,
              let text = try? String(contentsOfFile: result.markdown, encoding: .utf8) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    // MARK: - Internal

    private func tick() {
        // Durasi terekam (jam audio). Pergantian sesi transkrip live diatur LiveTranscriber sendiri.
        guard let capture else { return }
        let recorded = capture.recordedSeconds
        let seconds = recorded.rounded(.down)
        if meter.elapsed != seconds { meter.elapsed = seconds }
        if recorded > lastRecordedSeconds {
            lastRecordedSeconds = recorded
            lastAudioProgress = Date()
        } else if Date().timeIntervalSince(lastAudioProgress) > 4 {
            // Mic diam total 4 detik (biasanya setelah Mac bangun dari tidur): pasang ulang.
            lastAudioProgress = Date()
            capture.recoverIfStalled()
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
            if result.summarized == false {
                notify(title: "MoM belum tersusun", body: "Transkrip tersimpan. Klik Susun ulang untuk mencoba lagi.")
            } else {
                notify(title: "MoM siap", body: result.title)
            }
        case .failure(let error):
            fail(error.localizedDescription, dir: dir)
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
        UNUserNotificationCenter.current().add(request) { _ in }
    }

    private static let stampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd_HHmmss"
        return formatter
    }()
}
