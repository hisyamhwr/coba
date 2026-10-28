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
        micName = AVCaptureDevice.default(for: .audio)?.localizedName ?? "mikrofon"

        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else { throw CaptureError.noMicrophone }
        micConverter = Self.makeConverter(from: inputFormat)
        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            self?.handleMic(buffer)
        }
        engine.prepare()
        try engine.start()

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
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        if let active = scStream {
            Task { try? await active.stopCapture() }
        }
        scStream = nil
        writeQueue.sync { file = nil }
    }

    // MARK: - Mikrofon (jam utama)

    private func handleMic(_ buffer: AVAudioPCMBuffer) {
        guard let converter = micConverter else { return }
        let mic = Self.convert(buffer, with: converter)
        guard !mic.isEmpty else { return }

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
        try? sampleBuffer.withAudioBufferList { list, _ in
            guard let asbd = sampleBuffer.formatDescription?.audioStreamBasicDescription,
                  let format = AVAudioFormat(standardFormatWithSampleRate: asbd.mSampleRate,
                                             channels: asbd.mChannelsPerFrame),
                  let pcm = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: list.unsafePointer)
            else { return }
            if systemConverter == nil || systemFormat != format {
                systemConverter = Self.makeConverter(from: format)
                systemFormat = format
            }
            guard let converter = systemConverter else { return }
            let samples = Self.convert(pcm, with: converter)
            lock.lock()
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
