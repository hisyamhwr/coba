import AppKit
import UserNotifications

/// Mengatur alur: siap → merekam (audio + video layar) → memproses (transkrip → MoM) → selesai/gagal.
///
/// Sejak 4.0.0 tidak ada transkripsi selama rapat: Mac tetap ringan (penting untuk RAM 8 GB) dan bagian yang
/// bisa bermasalah lebih sedikit. Transkripsi dan MoM dikerjakan setelah rapat selesai.
@MainActor
final class MeetingController {
    let state: AppState
    let meter: LiveMeter
    private var capture: AudioCapture?
    private var recorder: ScreenRecorder?
    private var processor: Processor?
    private var timer: Timer?
    private var ticks = 0
    /// Disk hampir habis: video dihentikan agar audio untuk notulen tetap bisa direkam sampai akhir.
    private static let stopVideoBelowMinutes = 10
    private static let warnBelowMinutes = 30
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

        let capture = AudioCapture(output: dir.appendingPathComponent("meeting.wav"),
                                   coreAudioTap: state.coreAudioTap, noiseReduction: state.micNoiseReduction)
        capture.onLevels = { [weak self] mic, system in
            Task { @MainActor in self?.meter.setLevels(mic: mic, system: system) }
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
                self.fail("Izin mikrofon ditolak. Buka System Settings → Privacy & Security → Microphone.", dir: dir,
                          startFailure: true)
                return
            }
            do {
                try capture.start()
            } catch {
                capture.note("Gagal mulai: \(error.localizedDescription)")
                self.state.starting = false
                self.fail("Mic gagal menyala: \(error.localizedDescription) Tutup aplikasi lain yang memakai mic "
                    + "secara eksklusif, cek System Settings → Sound → Input, lalu klik Coba lagi.", dir: dir,
                          startFailure: true)
                return
            }
            self.state.starting = false
            self.capture = capture
            // Waktu mulai = saat mic benar-benar merekam (bukan saat klik; dialog izin bisa makan waktu).
            self.startedAt = Date()
            self.lastAudioProgress = Date()
            self.lastRecordedSeconds = 0
            self.state.recordingDir = dir
            self.state.micName = capture.micName
            self.state.warning = nil
            self.state.marks = []
            self.meter.elapsed = 0
            self.meter.setLevels(mic: 0, system: 0)
            self.state.result = nil
            self.state.videoText = ""
            self.ticks = 0
            self.updateDiskSpace()
            self.state.phase = .recording
            self.state.expanded = true
            let timer = Timer(timeInterval: 0.5, repeats: true) { [weak controller = self] _ in
                Task { @MainActor in controller?.tick() }
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
            await self.startVideo(dir: dir, capture: capture)
        }
    }

    /// Video layar menyusul setelah audio jalan. Gagal merekam video tidak pernah menghentikan rekaman audio.
    private func startVideo(dir: URL, capture: AudioCapture) async {
        let source = state.videoSource
        guard source != .off else {
            state.videoText = "Video tidak direkam"
            return
        }
        let recorder = ScreenRecorder(output: dir.appendingPathComponent("layar.mov"), source: source)
        recorder.onLog = { line in capture.note(line) }
        recorder.onStopped = { [weak self, weak recorder] message in
            Task { @MainActor in
                guard let self, let recorder, self.recorder === recorder else { return }
                self.recorder = nil
                self.state.videoText = "Video berhenti"
                self.state.warning = message
            }
        }
        do {
            try await recorder.start()
            guard self.capture === capture else {
                await recorder.stop()
                return
            }
            self.recorder = recorder
            state.videoText = "Merekam \(recorder.targetText) · 720p"
        } catch {
            capture.note("Video gagal mulai: \(error.localizedDescription)")
            state.videoText = "Video tidak terekam"
            if state.warning == nil {
                state.warning = "Video layar gagal direkam (\(error.localizedDescription)). Audio tetap direkam."
            }
        }
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
        capture.stop()
        meter.setLevels(mic: 0, system: 0)
        self.capture = nil
        if let recorder {
            // Video ditutup di latar; transkripsi tidak perlu menunggu (memakai file WAV).
            self.recorder = nil
            Task { await recorder.stop() }
        }

        let marksURL = dir.appendingPathComponent("penting.json")
        let marks = (try? JSONEncoder().encode(state.marks.map { ($0 * 10).rounded() / 10 })) ?? Data("[]".utf8)
        try? marks.write(to: marksURL)

        runProcessor(dir: dir)
    }

    /// Proses ulang rekaman terakhir: setelah gagal, atau saat MoM gagal disusun (mis. batas pemakaian Claude).
    /// Transkrip yang sudah jadi dipakai ulang, jadi langsung ke penyusunan MoM.
    func retry() {
        let canRetry = (state.phase == .failed && !state.failedToStart)
            || (state.phase == .done && state.result?.summarized == false)
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

    /// Dipanggil saat aplikasi ditutup: rekaman yang sedang berjalan ditutup rapi agar file WAV dan video utuh.
    /// Pemrosesan yang sedang berjalan dibiarkan selesai sendiri.
    func shutdown() {
        guard state.phase == .recording, let capture, let dir = state.recordingDir else { return }
        timer?.invalidate()
        capture.note("Aplikasi ditutup saat merekam; rekaman disimpan")
        capture.stop()
        if let recorder {
            // Tunggu video ditutup (paling lama 5 detik) agar file MOV bisa diputar.
            let done = DispatchSemaphore(value: 0)
            Task.detached {
                await recorder.stop()
                done.signal()
            }
            _ = done.wait(timeout: .now() + 5)
        }
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

    /// Video rapat terakhir (bila direkam).
    var videoURL: URL? {
        guard let dir = state.recordingDir else { return nil }
        let url = dir.appendingPathComponent("layar.mov")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    func openVideo() {
        guard let videoURL else { return }
        NSWorkspace.shared.open(videoURL)
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
        // Durasi terekam (jam audio).
        guard let capture else { return }
        ticks += 1
        if ticks % 20 == 0 { updateDiskSpace() }
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

    /// Sisa disk dalam menit rekaman (audio + video). Peringatan bila < 30 menit; bila < 10 menit video dihentikan
    /// agar audio untuk notulen tetap terekam sampai rapat selesai.
    private func updateDiskSpace() {
        let dir = state.recordingDir ?? Config.outputDir
        guard let values = try? dir.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
              let free = values.volumeAvailableCapacityForImportantUsage
        else { return }
        let perMinute: Int64 = (recorder != nil ? ScreenRecorder.bytesPerMinute : 0) + 6 * 1024 * 1024
        let minutes = Int(free / perMinute)
        // Dibulatkan agar tampilan tidak berubah tiap 10 detik.
        let shown = minutes > 120 ? minutes / 30 * 30 : minutes
        if state.diskMinutesLeft != shown { state.diskMinutesLeft = shown }
        guard state.phase == .recording else { return }
        if minutes < Self.stopVideoBelowMinutes, let recorder {
            self.recorder = nil
            Task { await recorder.stop() }
            state.videoText = "Video dihentikan (disk hampir penuh)"
            state.warning = "Disk hampir penuh: video dihentikan, audio tetap direkam. Sisa ±\(minutes) menit."
        } else if minutes < Self.warnBelowMinutes, state.warning == nil {
            state.warning = "Disk hampir penuh: sisa ±\(minutes) menit rekaman. Kosongkan ruang disk."
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

    /// startFailure: rekaman belum sempat dimulai (izin/mic gagal), jadi tombolnya "Coba lagi", bukan "Proses ulang".
    private func fail(_ message: String, dir: URL?, startFailure: Bool = false) {
        timer?.invalidate()
        timer = nil
        state.errorMessage = message
        state.recordingDir = dir
        state.failedToStart = startFailure
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
