import Accelerate
import AVFoundation
import CoreMedia
import ScreenCaptureKit

enum CaptureError: LocalizedError {
    case noMicrophone
    case noDisplay

    var errorDescription: String? {
        switch self {
        case .noMicrophone: return "Mikrofon tidak ditemukan."
        case .noDisplay: return "Layar tidak ditemukan untuk merekam audio sistem."
        }
    }
}

/// Merekam mikrofon + audio sistem (Zoom/Meet/Teams) secara digital, lalu menggabungkannya ke satu WAV 16 kHz mono.
///
/// Mikrofon menjadi "jam" utama: setiap potongan mic dicampur dengan audio sistem sebanyak sampel yang sama.
/// Jika audio sistem tidak tersedia (izin belum diberikan), sisanya diisi hening sehingga rekaman tetap jalan.
final class AudioCapture: NSObject, SCStreamOutput, SCStreamDelegate {
    static let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
    /// Batas antrean audio sistem (2 detik) agar tidak menumpuk jika jam mic dan sistem sedikit berbeda.
    private static let maxSystemBacklog = 32000
    /// Cadangan audio sistem sebelum mulai dipakai. Audio dari rekam layar datang tidak serata mic; tanpa
    /// cadangan, setiap kali datang sedikit terlambat celahnya terisi hening sehingga suara peserta "patah-patah"
    /// dan akurasi transkripsi turun. Core Audio tap jauh lebih rata, jadi cukup cadangan kecil (lebih real time).
    private static let screenPrebuffer = 4000   // 250 ms
    private static let tapPrebuffer = 1600      // 100 ms
    /// Campuran mic + meeting dikecilkan sedikit agar tidak pecah (clipping) saat keduanya keras bersamaan.
    private static let mixGain: Float = 0.8

    /// Musik/video dari aplikasi ini tidak ikut terekam sebagai "suara meeting" (mengacaukan transkripsi).
    private static let excludedApps: Set<String> = [
        "com.apple.Music", "com.spotify.client", "com.apple.podcasts", "com.apple.TV",
    ]

    /// Potongan campuran 16 kHz mono untuk transkrip live, beserta RMS asli (sebelum dikuatkan) untuk deteksi
    /// jeda bicara. Campuran ini dikuatkan otomatis per jalur; file rekaman tetap asli.
    /// Argumen ketiga: posisi akhir potongan ini dalam rekaman (detik), untuk menyelaraskan teks live.
    var onSamples: ((AVAudioPCMBuffer, Float, Double) -> Void)?
    /// Level 0...1 per jalur: mic (suara kita) dan audio meeting (peserta online).
    var onLevels: ((_ mic: Float, _ system: Float) -> Void)?
    /// Masalah yang terdeteksi saat merekam (mis. mic hanya memberi hening total), untuk ditampilkan di pulau.
    var onProblem: ((String) -> Void)?
    private(set) var micName = ""
    private(set) var systemAudioActive = false

    private let output: URL
    /// Audio meeting lewat Core Audio tap (macOS 14.2+); bila tidak bisa, otomatis lewat rekam layar.
    private let useCoreAudioTap: Bool
    /// Peredam derau mic bawaan macOS (Voice Processing).
    private let noiseReduction: Bool
    /// SystemAudioTap (disimpan sebagai AnyObject karena tipenya hanya ada di macOS 14.2+).
    private var tap: AnyObject?
    private var systemPrebuffer = AudioCapture.screenPrebuffer
    private(set) var systemSourceText = "rekam layar"
    private var systemSilenceReported = false
    private let engine = AVAudioEngine()
    private var micConverter: AVAudioConverter?
    private var systemConverter: AVAudioConverter?
    private var systemFormat: AVAudioFormat?
    private var scStream: SCStream?
    private var file: AVAudioFile?
    /// Jalur terpisah: suara mic dan suara meeting. Ditranskripsi masing-masing agar suara meeting yang digital
    /// tidak tercampur derau ruangan, dan transkrip bisa berlabel "Saya (mic)" / "Peserta online".
    private var micFile: AVAudioFile?
    private var systemFile: AVAudioFile?
    private var systemBuffer: [Float] = []
    /// Audio sistem sedang dipakai (cadangan sudah terisi); kembali false saat antrean habis (meeting hening).
    private var systemFlowing = false
    private var writeFailed = false
    private var lastMicLevel: Float = 0
    private var lastSystemLevel: Float = 0
    /// Penguat otomatis umpan transkrip live, satu per jalur (hanya dipakai di thread audio mic).
    private var micLeveler = Leveler()
    private var systemLeveler = Leveler()
    private var running = false
    private var configObserver: NSObjectProtocol?
    // Diagnostik (ditulis ke rekaman.log): membedakan mic tanpa izin, mic pelan, dan audio sistem yang tidak masuk.
    private var micFormatText = ""
    private var micFrames = 0
    private var micPeak: Float = 0
    private var micRestarts = 0
    private var silenceReported = false
    private var systemFrames = 0
    private var systemPeak: Float = 0
    // Puncak per 10 detik untuk garis waktu di rekaman.log (mis. audio meeting hilang saat headset dipasang).
    private var windowMicPeak: Float = 0
    private var windowSystemPeak: Float = 0
    private var windowSystemFrames = 0
    private var systemRestarts = 0
    private let logQueue = DispatchQueue(label: "meetingnotes.log")
    private let lock = NSLock()
    private let systemQueue = DispatchQueue(label: "meetingnotes.system-audio")
    private let writeQueue = DispatchQueue(label: "meetingnotes.writer")

    init(output: URL, coreAudioTap: Bool = true, noiseReduction: Bool = false) {
        self.output = output
        self.useCoreAudioTap = coreAudioTap
        self.noiseReduction = noiseReduction
    }

    static func requestMicAccess() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }

    private var logURL: URL { output.deletingLastPathComponent().appendingPathComponent("rekaman.log") }

    /// Tambahkan satu baris bertanda waktu ke rekaman.log, agar langkah yang macet terlihat.
    func note(_ line: String) {
        let stamp = Self.logTime.string(from: Date())
        let data = Data("\(stamp)  \(line)\n".utf8)
        let url = logURL
        logQueue.async {
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(data)
                try? handle.close()
            } else {
                try? data.write(to: url)
            }
        }
    }

    private static let logTime: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    /// Mulai merekam mikrofon. Audio sistem dimulai terpisah lewat `startSystem()` agar menunggu izin
    /// Screen & System Audio Recording tidak menahan rekaman.
    func start() throws {
        let folder = output.deletingLastPathComponent()
        file = try Self.makeWriter(output)
        micFile = try Self.makeWriter(folder.appendingPathComponent("mic.wav"))
        systemFile = try Self.makeWriter(folder.appendingPathComponent("sistem.wav"))
        running = true
        try startMic()
        // Mic berganti (AirPods tersambung, Zoom mengubah format mic): AVAudioEngine berhenti sendiri dan rekaman
        // akan hening sampai selesai. Pasang ulang mic agar rekaman tetap jalan.
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            self?.restartMic()
        }
        note("Mic mulai: \(micName) (\(micFormatText))")
    }

    /// Mulai merekam audio Zoom/Meet/Teams. Mengembalikan peringatan jika tidak bisa.
    func startSystem() async -> String? {
        #if compiler(>=5.9.2)
        if useCoreAudioTap, #available(macOS 14.2, *) {
            do {
                try startTap()
                return nil
            } catch {
                note("Core Audio tap gagal (\(error.localizedDescription)); memakai rekam layar")
            }
        }
        #endif
        do {
            try await startSystemAudio()
            systemAudioActive = true
            systemSourceText = "rekam layar"
            note("Audio sistem mulai (rekam layar)")
            return nil
        } catch {
            note("Audio sistem gagal: \(error.localizedDescription)")
            return "Audio Zoom/Meet/Teams belum terekam. Izinkan Meeting Notes di System Settings → Privacy & "
                + "Security → Screen & System Audio Recording, lalu buka ulang aplikasi."
        }
    }

    #if compiler(>=5.9.2)
    @available(macOS 14.2, *)
    private func startTap() throws {
        let newTap = SystemAudioTap(ioQueue: systemQueue, excludedBundleIDs: Self.excludedApps) { [weak self] buffer in
            self?.handleSystem(buffer)
        }
        newTap.onDeviceChange = { [weak self] in self?.restartTap() }
        try newTap.start()
        // Rekaman bisa saja sudah dihentikan selagi tap disiapkan.
        guard running else {
            newTap.stop()
            return
        }
        lock.lock()
        systemPrebuffer = Self.tapPrebuffer
        lock.unlock()
        tap = newTap
        systemAudioActive = true
        systemSourceText = "Core Audio tap, \(newTap.formatText)"
        note("Audio sistem mulai (\(systemSourceText))")
    }

    /// Perangkat output berganti (headset dipasang/dilepas): pasang ulang tap pada perangkat yang baru.
    @available(macOS 14.2, *)
    private func restartTap() {
        guard running, let old = tap as? SystemAudioTap else { return }
        old.stop()
        tap = nil
        do {
            try startTap()
            systemRestarts += 1
            note("Perangkat output berganti; audio meeting dipasang ulang")
        } catch {
            systemAudioActive = false
            note("Gagal memasang ulang Core Audio tap: \(error.localizedDescription); beralih ke rekam layar")
            Task { [weak self] in
                guard let self, self.running else { return }
                do {
                    try await self.startSystemAudio()
                    self.systemAudioActive = true
                    self.systemSourceText = "rekam layar"
                } catch {
                    self.onProblem?("Audio meeting terputus. Selesaikan lalu mulai rekam lagi.")
                }
            }
        }
    }
    #endif

    private func stopTap() {
        #if compiler(>=5.9.2)
        if #available(macOS 14.2, *) {
            (tap as? SystemAudioTap)?.stop()
        }
        #endif
        tap = nil
    }

    /// Hentikan rekaman dan tutup file WAV.
    func stop() {
        running = false
        stopTap()
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
        configObserver = nil
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        if let active = scStream {
            Task { try? await active.stopCapture() }
        }
        scStream = nil
        writeQueue.sync {
            file = nil
            micFile = nil
            systemFile = nil
        }
        note("Selesai\n" + diagnostics())
        logQueue.sync {}
    }

    /// Durasi yang benar-benar terekam (jam audio), untuk timer dan waktu "Penting". Tidak ikut berjalan saat
    /// Mac tidur atau mic sempat terputus, sehingga waktu tanda selalu cocok dengan rekaman.
    var recordedSeconds: TimeInterval {
        lock.lock()
        defer { lock.unlock() }
        return Double(micFrames) / 16000
    }

    /// Ringkasan kondisi rekaman untuk rekaman.log.
    func diagnostics() -> String {
        lock.lock()
        let sysFrames = systemFrames
        let sysPeak = systemPeak
        let micSeconds = Double(micFrames) / 16000
        lock.unlock()
        let micStatus: String
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: micStatus = "diizinkan"
        case .denied: micStatus = "DITOLAK"
        case .restricted: micStatus = "dibatasi"
        case .notDetermined: micStatus = "belum ditanya"
        @unknown default: micStatus = "tidak diketahui"
        }
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let systemStatus = systemAudioActive ? "aktif (" + systemSourceText + ")" : "TIDAK aktif"
        return """
        Meeting Notes v\(version)
        Mikrofon        : \(micName) (\(micFormatText)), izin \(micStatus)
        Mic diterima    : \(String(format: "%.1f", micSeconds)) detik, puncak \(Self.describe(micPeak))
        Mic dipasang ulang: \(micRestarts)x
        Audio sistem    : \(systemStatus), dipasang ulang \(systemRestarts)x, \
        \(String(format: "%.1f", Double(sysFrames) / 16000)) detik diterima, puncak \(Self.describe(sysPeak))

        """
    }

    private static func describe(_ peak: Float) -> String {
        guard peak > 0 else { return "0 (HENING TOTAL)" }
        return String(format: "%.4f (%.0f dBFS)", peak, 20 * log10(peak))
    }

    // MARK: - Mikrofon (jam utama)

    private func startMic() throws {
        micName = AVCaptureDevice.default(for: .audio)?.localizedName ?? "mikrofon"
        let input = engine.inputNode
        if noiseReduction { enableNoiseReduction(input) }
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else { throw CaptureError.noMicrophone }
        micFormatText = "\(Int(inputFormat.sampleRate)) Hz, \(inputFormat.channelCount) kanal"
        micConverter = Self.makeConverter(from: inputFormat)
        // Potongan ±40 ms (bukan 85 ms): suara sampai ke transkrip live lebih cepat.
        input.installTap(onBus: 0, bufferSize: 2048, format: inputFormat) { [weak self] buffer, _ in
            self?.handleMic(buffer)
        }
        engine.prepare()
        try engine.start()
    }

    /// Peredam derau & penguat otomatis bawaan macOS untuk mic (Voice Processing, sama seperti FaceTime).
    /// Volume aplikasi lain tidak dikecilkan. Gema suara peserta dari speaker tetap ditangani di transkrip
    /// (macOS hanya menghapus gema dari suara yang diputar aplikasi ini sendiri).
    private func enableNoiseReduction(_ input: AVAudioInputNode) {
        guard !input.isVoiceProcessingEnabled else { return }
        do {
            try input.setVoiceProcessingEnabled(true)
            let ducking = AVAudioVoiceProcessingOtherAudioDuckingConfiguration(
                enableAdvancedDucking: false, duckingLevel: .min)
            input.voiceProcessingOtherAudioDuckingConfiguration = ducking
            // Voice Processing butuh jalur output yang tersambung (diisi hening).
            _ = engine.mainMixerNode
            note("Peredam derau mic aktif")
        } catch {
            note("Peredam derau mic gagal: \(error.localizedDescription)")
        }
    }

    /// Satu baris per 10 detik: level mic dan audio meeting, agar terlihat kapan salah satunya hening.
    private func logWindow() {
        lock.lock()
        let sysPeak = windowSystemPeak
        let sysFrames = windowSystemFrames
        windowSystemPeak = 0
        windowSystemFrames = 0
        lock.unlock()
        let micText = Self.describe(windowMicPeak)
        windowMicPeak = 0
        let sysText = sysFrames == 0 ? "TIDAK ADA DATA" : Self.describe(sysPeak)
        note("[\(Int(recordedSeconds)) dtk] mic \(micName): \(micText) | audio meeting: \(sysText)")
    }

    /// Dipanggil pengendali bila jam audio berhenti bergerak beberapa detik (mis. setelah Mac bangun dari tidur,
    /// atau mic berhenti tanpa pemberitahuan): pasang ulang mic agar sisa rapat tetap terekam.
    func recoverIfStalled() {
        guard running else { return }
        note("Mic berhenti mengirim suara (engine \(engine.isRunning ? "jalan" : "berhenti")); dipasang ulang")
        restartMic()
    }

    private func restartMic() {
        guard running else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        micRestarts += 1
        do {
            try startMic()
            note("Perangkat audio berganti; mic dipasang ulang: \(micName) (\(micFormatText))")
        } catch {
            note("Mic gagal dipasang ulang: \(error.localizedDescription)")
            onProblem?("Mic terputus dan gagal disambung ulang. Selesaikan lalu mulai rekam lagi.")
        }
    }

    private func handleMic(_ buffer: AVAudioPCMBuffer) {
        guard let converter = micConverter else { return }
        let mic = Self.convert(buffer, with: converter)
        guard !mic.isEmpty else { return }
        var peak: Float = 0
        vDSP_maxmgv(mic, 1, &peak, vDSP_Length(mic.count))
        micPeak = max(micPeak, peak)
        windowMicPeak = max(windowMicPeak, peak)
        lock.lock()
        let before = micFrames / 160_000
        micFrames += mic.count
        let frames = micFrames
        lock.unlock()
        if frames / 160_000 != before { logWindow() }
        // Sampel nol mutlak selama 3 detik = macOS memberi hening karena izin mic tidak cocok lagi dengan
        // aplikasi (terjadi setelah build ulang). Ruangan sepi pun tetap punya derau, tidak pernah nol mutlak.
        if !silenceReported, frames >= 48000, micPeak == 0 {
            silenceReported = true
            onProblem?("Mic hanya memberi hening (izin macOS tersangkut). Jalankan ./mac/build.sh --reset-izin "
                + "lalu buka ulang app.")
        }

        if !systemSilenceReported, frames >= 16000 * 120 {
            lock.lock()
            let neverHeard = systemPeak == 0
            lock.unlock()
            if neverHeard && systemAudioActive {
                systemSilenceReported = true
                note("Audio meeting hening total selama 2 menit (\(systemSourceText))")
                onProblem?("Suara peserta belum terdengar sama sekali. Bila meeting sedang bersuara, buka menu bar → "
                    + "matikan \"Audio meeting via Core Audio\", lalu mulai rekam lagi.")
            }
        }

        lock.lock()
        if !systemFlowing, systemBuffer.count >= systemPrebuffer { systemFlowing = true }
        let take = systemFlowing ? min(mic.count, systemBuffer.count) : 0
        let system = Array(systemBuffer.prefix(take))
        systemBuffer.removeFirst(take)
        // Antrean habis: meeting sedang hening (ScreenCaptureKit tidak mengirim apa-apa). Isi cadangan lagi
        // sebelum dipakai, agar sambungan berikutnya tidak patah-patah.
        if systemFlowing, systemBuffer.isEmpty { systemFlowing = false }
        lock.unlock()

        var mixed = mic
        for i in 0..<mixed.count {
            let value = (mixed[i] + (i < system.count ? system[i] : 0)) * Self.mixGain
            mixed[i] = max(-1, min(1, value))
        }
        // Jalur meeting diisi hening bila audio sistem belum masuk, agar ketiga file selalu sama panjang.
        var systemTrack = system
        if systemTrack.count < mic.count { systemTrack += [Float](repeating: 0, count: mic.count - systemTrack.count) }
        guard let out = Self.makeBuffer(mixed),
              let micOut = Self.makeBuffer(mic),
              let systemOut = Self.makeBuffer(systemTrack)
        else { return }

        // Umpan transkrip live: tiap jalur dikuatkan ke level yang stabil lalu dicampur, sehingga suara peserta
        // yang pelan dan suara kita yang jauh dari mic sama-sama terdengar jelas oleh pengenal suara.
        var micRMS: Float = 0
        vDSP_rmsqv(mic, 1, &micRMS, vDSP_Length(mic.count))
        var systemRMS: Float = 0
        if !system.isEmpty { vDSP_rmsqv(system, 1, &systemRMS, vDSP_Length(system.count)) }
        // Saat peserta bicara lewat speaker, mic ikut menangkap gemanya: mic tidak dikuatkan banyak agar gema
        // tidak menumpuk di atas suara asli.
        let systemTalking = systemRMS > Leveler.floor
        let liveMic = micLeveler.process(mic, maxGain: systemTalking ? 2 : Leveler.maxGain)
        let liveSystem = systemLeveler.process(systemTrack, maxGain: Leveler.maxGain)
        // Mic jauh lebih pelan dari suara peserta = kemungkinan besar hanya gema dari speaker: diredam di umpan
        // live agar pengenal suara tidak mendengar kalimat yang sama dua kali. Saat kamu bicara, mic lebih keras.
        let micWeight: Float = systemTalking && micRMS < systemRMS * 0.5 ? 0.3 : 1
        var liveMix = liveMic
        for i in 0..<liveMix.count {
            liveMix[i] = Leveler.limit(liveMix[i] * micWeight + liveSystem[i])
        }

        writeQueue.async { [weak self] in
            guard let self else { return }
            do {
                try self.file?.write(from: out)
                try self.micFile?.write(from: micOut)
                try self.systemFile?.write(from: systemOut)
            } catch {
                // Biasanya disk penuh. Laporkan sekali agar pengguna tahu sebelum rapat selesai.
                guard !self.writeFailed else { return }
                self.writeFailed = true
                self.note("Gagal menulis rekaman: \(error.localizedDescription)")
                self.onProblem?("Rekaman gagal disimpan (disk penuh?). Kosongkan ruang disk lalu mulai rekam lagi.")
            }
        }
        if let onSamples, let liveOut = Self.makeBuffer(liveMix) {
            var rms: Float = 0
            vDSP_rmsqv(mixed, 1, &rms, vDSP_Length(mixed.count))
            onSamples(liveOut, rms, Double(frames) / 16000)
        }
        let micLevel = min(micRMS * 8, 1)
        let systemLevel = min(systemRMS * 8, 1)
        // Kirim ke UI hanya bila berubah cukup terlihat, agar tidak menggambar ulang tanpa perlu.
        if abs(micLevel - lastMicLevel) > 0.03 || abs(systemLevel - lastSystemLevel) > 0.03 {
            lastMicLevel = micLevel
            lastSystemLevel = systemLevel
            onLevels?(micLevel, systemLevel)
        }
    }

    // MARK: - Audio sistem lewat ScreenCaptureKit

    private func startSystemAudio() async throws {
        // Semua aplikasi (termasuk yang jendelanya tersembunyi), agar pemutar musik di latar ikut dikecualikan.
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let display = content.displays.first else { throw CaptureError.noDisplay }
        let excluded = content.applications.filter { Self.excludedApps.contains($0.bundleIdentifier) }
        let filter = SCContentFilter(display: display, excludingApplications: excluded, exceptingWindows: [])
        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.sampleRate = 48000
        config.channelCount = 2
        // Video tidak dipakai; dibuat sekecil dan sejarang mungkin.
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)

        let newStream = SCStream(filter: filter, configuration: config, delegate: self)
        try newStream.addStreamOutput(self, type: .audio, sampleHandlerQueue: systemQueue)
        try newStream.addStreamOutput(self, type: .screen, sampleHandlerQueue: systemQueue)
        try await newStream.startCapture()
        // Rekaman bisa saja sudah dihentikan selagi menunggu izin.
        guard running else {
            try? await newStream.stopCapture()
            return
        }
        scStream = newStream
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, sampleBuffer.isValid else { return }
        // Format dibaca apa adanya dari buffer (interleaved atau tidak) agar sampel tidak salah tafsir.
        guard let description = sampleBuffer.formatDescription else { return }
        let format = AVAudioFormat(cmAudioFormatDescription: description)
        try? sampleBuffer.withAudioBufferList { list, _ in
            guard let pcm = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: list.unsafePointer)
            else { return }
            handleSystem(pcm)
        }
    }

    /// Potongan audio meeting (dari Core Audio tap atau rekam layar), selalu di `systemQueue`.
    private func handleSystem(_ pcm: AVAudioPCMBuffer) {
        let format = pcm.format
        if systemConverter == nil || systemFormat != format {
            systemConverter = Self.makeConverter(from: format)
            systemFormat = format
        }
        guard let converter = systemConverter else { return }
        let samples = Self.convert(pcm, with: converter)
        guard !samples.isEmpty else { return }
        var peak: Float = 0
        vDSP_maxmgv(samples, 1, &peak, vDSP_Length(samples.count))
        lock.lock()
        systemFrames += samples.count
        systemPeak = max(systemPeak, peak)
        windowSystemFrames += samples.count
        windowSystemPeak = max(windowSystemPeak, peak)
        systemBuffer.append(contentsOf: samples)
        if systemBuffer.count > Self.maxSystemBacklog {
            systemBuffer.removeFirst(systemBuffer.count - Self.maxSystemBacklog)
        }
        lock.unlock()
    }

    /// macOS bisa menghentikan tangkapan audio (mis. perangkat output berganti ke headset). Sebelumnya audio
    /// meeting lalu hilang diam-diam sampai rapat selesai; sekarang dipasang ulang otomatis.
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        systemAudioActive = false
        note("Audio sistem berhenti: \(error.localizedDescription)")
        Task { [weak self] in
            guard let self else { return }
            for attempt in 1...5 {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard self.running else { return }
                do {
                    try await self.startSystemAudio()
                    self.systemAudioActive = true
                    self.systemRestarts += 1
                    self.note("Audio sistem dipasang ulang (percobaan \(attempt))")
                    return
                } catch {
                    self.note("Gagal memasang ulang audio sistem: \(error.localizedDescription)")
                }
            }
            self.onProblem?("Audio meeting terputus dan gagal disambung ulang. Selesaikan lalu mulai rekam lagi.")
        }
    }

    // MARK: - Konversi format

    private static func makeConverter(from format: AVAudioFormat) -> AVAudioConverter? {
        let converter = AVAudioConverter(from: format, to: Self.format)
        converter?.downmix = true
        // Kualitas tertinggi saat menurunkan 48 kHz ke 16 kHz: konsonan (s, f, t) tetap jelas, tanpa aliasing.
        converter?.sampleRateConverterQuality = AVAudioQuality.max.rawValue
        return converter
    }

    private static func convert(_ buffer: AVAudioPCMBuffer, with converter: AVAudioConverter) -> [Float] {
        let ratio = Self.format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: Self.format, frameCapacity: capacity) else { return [] }
        var consumed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if consumed {
                status.pointee = .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, let data = out.floatChannelData else { return [] }
        return Array(UnsafeBufferPointer(start: data[0], count: Int(out.frameLength)))
    }

    /// WAV 16 kHz mono 16-bit.
    private static func makeWriter(_ url: URL) throws -> AVAudioFile {
        try AVAudioFile(
            forWriting: url,
            settings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 16000,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
            ],
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
    }

    private static func makeBuffer(_ samples: [Float]) -> AVAudioPCMBuffer? {
        guard let buffer = AVAudioPCMBuffer(pcmFormat: Self.format, frameCapacity: AVAudioFrameCount(samples.count)),
              let data = buffer.floatChannelData
        else { return nil }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { data[0].update(from: $0.baseAddress!, count: samples.count) }
        return buffer
    }
}

/// Penguat otomatis (AGC) sederhana untuk umpan transkrip live. Suara pelan dikuatkan sampai `maxGain` kali,
/// suara keras diturunkan; hening dan derau di bawah `floor` tidak ikut dikuatkan.
struct Leveler {
    static let target: Float = 0.08
    static let maxGain: Float = 8
    static let minGain: Float = 0.5
    static let floor: Float = 0.004

    private(set) var gain: Float = 1

    mutating func process(_ samples: [Float], maxGain: Float) -> [Float] {
        guard !samples.isEmpty else { return samples }
        var rms: Float = 0
        vDSP_rmsqv(samples, 1, &rms, vDSP_Length(samples.count))
        let start = gain
        if rms > Self.floor {
            let desired = min(max(Self.target / rms, Self.minGain), maxGain)
            // Turun cepat agar tidak pecah, naik pelan agar derau tidak "memompa".
            gain += (desired - gain) * (desired < gain ? 0.5 : 0.08)
        } else if gain > maxGain {
            gain = maxGain
        }
        // Gain berubah bertahap di sepanjang potongan agar tidak terdengar klik.
        let step = (gain - start) / Float(samples.count)
        var out = samples
        for i in 0..<out.count {
            out[i] *= start + step * Float(i)
        }
        return out
    }

    /// Pembatas lembut: di bawah 0,9 tidak berubah, di atasnya ditekuk halus menuju 1 (tanpa pecah).
    static func limit(_ x: Float) -> Float {
        let magnitude = abs(x)
        guard magnitude > 0.9 else { return x }
        let bent = 0.9 + 0.1 * tanh((magnitude - 0.9) / 0.1)
        return x < 0 ? -bent : bent
    }
}
