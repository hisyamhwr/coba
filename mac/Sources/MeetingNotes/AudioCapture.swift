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

    /// Potongan campuran 16 kHz mono, untuk transkrip live.
    var onSamples: ((AVAudioPCMBuffer) -> Void)?
    var onLevel: ((Float) -> Void)?
    /// Masalah yang terdeteksi saat merekam (mis. mic hanya memberi hening total), untuk ditampilkan di pulau.
    var onProblem: ((String) -> Void)?
    private(set) var micName = ""
    private(set) var systemAudioActive = false

    private let output: URL
    private let engine = AVAudioEngine()
    private var micConverter: AVAudioConverter?
    private var systemConverter: AVAudioConverter?
    private var systemFormat: AVAudioFormat?
    private var scStream: SCStream?
    private var file: AVAudioFile?
    private var systemBuffer: [Float] = []
    private var lastLevel: Float = 0
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
    private let lock = NSLock()
    private let systemQueue = DispatchQueue(label: "meetingnotes.system-audio")
    private let writeQueue = DispatchQueue(label: "meetingnotes.writer")

    init(output: URL) {
        self.output = output
    }

    static func requestMicAccess() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }

    /// Mulai merekam. Mengembalikan peringatan jika audio sistem tidak bisa direkam.
    func start() async throws -> String? {
        file = try AVAudioFile(
            forWriting: output,
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
        running = true
        try startMic()
        // Mic berganti (AirPods tersambung, Zoom mengubah format mic): AVAudioEngine berhenti sendiri dan rekaman
        // akan hening sampai selesai. Pasang ulang mic agar rekaman tetap jalan.
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            self?.restartMic()
        }

        do {
            try await startSystemAudio()
            systemAudioActive = true
            return nil
        } catch {
            return "Audio Zoom/Meet/Teams belum terekam. Izinkan Meeting Notes di System Settings → Privacy & "
                + "Security → Screen & System Audio Recording, lalu buka ulang aplikasi."
        }
    }

    /// Hentikan rekaman dan tutup file WAV.
    func stop() {
        running = false
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
        configObserver = nil
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        if let active = scStream {
            Task { try? await active.stopCapture() }
        }
        scStream = nil
        writeQueue.sync { file = nil }
        let log = output.deletingLastPathComponent().appendingPathComponent("rekaman.log")
        try? diagnostics().write(to: log, atomically: true, encoding: .utf8)
    }

    /// Ringkasan kondisi rekaman untuk rekaman.log.
    func diagnostics() -> String {
        lock.lock()
        let sysFrames = systemFrames
        let sysPeak = systemPeak
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
        return """
        Meeting Notes v\(version)
        Mikrofon        : \(micName) (\(micFormatText)), izin \(micStatus)
        Mic diterima    : \(String(format: "%.1f", Double(micFrames) / 16000)) detik, puncak \(Self.describe(micPeak))
        Mic dipasang ulang: \(micRestarts)x
        Audio sistem    : \(systemAudioActive ? "aktif" : "TIDAK aktif"), \
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
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else { throw CaptureError.noMicrophone }
        micFormatText = "\(Int(inputFormat.sampleRate)) Hz, \(inputFormat.channelCount) kanal"
        micConverter = Self.makeConverter(from: inputFormat)
        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            self?.handleMic(buffer)
        }
        engine.prepare()
        try engine.start()
    }

    private func restartMic() {
        guard running else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        micRestarts += 1
        do {
            try startMic()
        } catch {
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
        micFrames += mic.count
        // Sampel nol mutlak selama 3 detik = macOS memberi hening karena izin mic tidak cocok lagi dengan
        // aplikasi (terjadi setelah build ulang). Ruangan sepi pun tetap punya derau, tidak pernah nol mutlak.
        if !silenceReported, micFrames >= 48000, micPeak == 0 {
            silenceReported = true
            onProblem?("Mic hanya memberi hening (izin macOS tersangkut). Jalankan ./mac/build.sh --reset-izin "
                + "lalu buka ulang app.")
        }

        lock.lock()
        let take = min(mic.count, systemBuffer.count)
        let system = Array(systemBuffer.prefix(take))
        systemBuffer.removeFirst(take)
        lock.unlock()

        var mixed = mic
        for i in 0..<system.count {
            mixed[i] = max(-1, min(1, mixed[i] + system[i]))
        }
        guard let out = Self.makeBuffer(mixed) else { return }

        writeQueue.async { [weak self] in
            try? self?.file?.write(from: out)
        }
        onSamples?(out)
        var rms: Float = 0
        vDSP_rmsqv(mixed, 1, &rms, vDSP_Length(mixed.count))
        let level = min(rms * 8, 1)
        // Kirim ke UI hanya bila berubah cukup terlihat, agar tidak menggambar ulang tanpa perlu.
        if abs(level - lastLevel) > 0.03 {
            lastLevel = level
            onLevel?(level)
        }
    }

    // MARK: - Audio sistem lewat ScreenCaptureKit

    private func startSystemAudio() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first else { throw CaptureError.noDisplay }
        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
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
            systemBuffer.append(contentsOf: samples)
            if systemBuffer.count > Self.maxSystemBacklog {
                systemBuffer.removeFirst(systemBuffer.count - Self.maxSystemBacklog)
            }
            lock.unlock()
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        systemAudioActive = false
    }

    // MARK: - Konversi format

    private static func makeConverter(from format: AVAudioFormat) -> AVAudioConverter? {
        let converter = AVAudioConverter(from: format, to: Self.format)
        converter?.downmix = true
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

    private static func makeBuffer(_ samples: [Float]) -> AVAudioPCMBuffer? {
        guard let buffer = AVAudioPCMBuffer(pcmFormat: Self.format, frameCapacity: AVAudioFrameCount(samples.count)),
              let data = buffer.floatChannelData
        else { return nil }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { data[0].update(from: $0.baseAddress!, count: samples.count) }
        return buffer
    }
}
