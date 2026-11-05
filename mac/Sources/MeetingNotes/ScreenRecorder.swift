import AVFoundation
import ScreenCaptureKit

/// Apa yang direkam sebagai video rapat; dipilih di menu bar.
enum VideoSource: String, CaseIterable {
    case screen, teams, zoom, off

    var menuTitle: String {
        switch self {
        case .screen: return "Video: seluruh layar"
        case .teams: return "Video: jendela Teams saja"
        case .zoom: return "Video: jendela Zoom saja"
        case .off: return "Video: tidak direkam (audio saja)"
        }
    }

    /// Awalan bundle ID aplikasi meeting (Teams baru & lama, Zoom).
    var bundlePrefixes: [String] {
        switch self {
        case .teams: return ["com.microsoft.teams"]
        case .zoom: return ["us.zoom.xos"]
        case .screen, .off: return []
        }
    }
}

/// Rekaman layar seperti OBS: video 720p 30 fps (H.264) + suara peserta + suara mic, ke `layar.mov`.
///
/// Berjalan terpisah dari `AudioCapture` (yang menulis WAV untuk transkripsi), sehingga masalah pada video tidak
/// pernah mengganggu rekaman audio untuk notulen. Video dienkode oleh encoder perangkat keras Apple Silicon, jadi
/// beban CPU kecil. Jendela Meeting Notes sendiri tidak ikut terekam.
final class ScreenRecorder: NSObject, SCStreamOutput, SCStreamDelegate {
    static let maxSize = CGSize(width: 1280, height: 720)
    static let framesPerSecond: Int32 = 30
    /// ±0,9 GB per jam video; ditambah audio AAC.
    static let videoBitRate = 2_000_000
    /// Perkiraan pemakaian disk per menit (video + audio di MOV), untuk info sisa waktu rekam.
    static let bytesPerMinute: Int64 = 17 * 1024 * 1024

    var onLog: ((String) -> Void)?
    /// Video berhenti sendiri (mis. jendela meeting ditutup); rekaman audio tetap berjalan.
    var onStopped: ((String) -> Void)?
    private(set) var targetText = ""

    private let output: URL
    private let source: VideoSource
    private let queue = DispatchQueue(label: "meetingnotes.video")
    private var stream: SCStream?
    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?
    private var micInput: AVAssetWriterInput?
    private var sessionStart: CMTime?
    private var finished = false
    private var frames = 0

    init(output: URL, source: VideoSource) {
        self.output = output
        self.source = source
    }

    func start() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let (filter, size, text) = try Self.makeFilter(content: content, source: source)
        targetText = text

        let config = SCStreamConfiguration()
        config.width = Int(size.width)
        config.height = Int(size.height)
        config.minimumFrameInterval = CMTime(value: 1, timescale: Self.framesPerSecond)
        config.queueDepth = 6
        config.showsCursor = true
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.sampleRate = 48000
        config.channelCount = 2
        #if compiler(>=6.0)
        if #available(macOS 15.0, *) {
            config.captureMicrophone = true
        }
        #endif

        try? FileManager.default.removeItem(at: output)
        let writer = try AVAssetWriter(outputURL: output, fileType: .mov)
        let video = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(size.width),
            AVVideoHeightKey: Int(size.height),
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: Self.videoBitRate,
                AVVideoExpectedSourceFrameRateKey: Int(Self.framesPerSecond),
                AVVideoMaxKeyFrameIntervalKey: Int(Self.framesPerSecond) * 2,
            ] as [String: Any],
        ])
        video.expectsMediaDataInRealTime = true
        let audio = AVAssetWriterInput(mediaType: .audio, outputSettings: Self.aacSettings(channels: 2))
        audio.expectsMediaDataInRealTime = true
        let mic = AVAssetWriterInput(mediaType: .audio, outputSettings: Self.aacSettings(channels: 1))
        mic.expectsMediaDataInRealTime = true
        for input in [video, audio, mic] where writer.canAdd(input) {
            writer.add(input)
        }
        guard writer.startWriting() else {
            throw writer.error ?? CaptureError.noDisplay
        }
        self.writer = writer
        videoInput = video
        audioInput = audio
        micInput = mic

        let newStream = SCStream(filter: filter, configuration: config, delegate: self)
        try newStream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try newStream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        #if compiler(>=6.0)
        if #available(macOS 15.0, *) {
            try newStream.addStreamOutput(self, type: .microphone, sampleHandlerQueue: queue)
        }
        #endif
        try await newStream.startCapture()
        stream = newStream
        onLog?("Video mulai: \(text), \(Int(size.width))x\(Int(size.height)) \(Self.framesPerSecond) fps")
    }

    /// Hentikan dan tutup file video dengan rapi (file MOV yang tidak ditutup tidak bisa diputar).
    func stop() async {
        if let stream {
            try? await stream.stopCapture()
        }
        stream = nil
        await finish()
    }

    private func finish() async {
        let (writer, started, count): (AVAssetWriter?, Bool, Int) = queue.sync {
            guard !finished else { return (nil, false, 0) }
            finished = true
            return (self.writer, sessionStart != nil, frames)
        }
        guard let writer else { return }
        guard started, writer.status == .writing else {
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: output)
            onLog?("Video dibatalkan (tidak ada gambar yang terekam)")
            return
        }
        videoInput?.markAsFinished()
        audioInput?.markAsFinished()
        micInput?.markAsFinished()
        await writer.finishWriting()
        if writer.status == .completed {
            onLog?("Video tersimpan: \(output.lastPathComponent), \(count) frame")
        } else {
            onLog?("Video gagal ditutup: \(writer.error?.localizedDescription ?? "status \(writer.status.rawValue)")")
        }
    }

    // MARK: - SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard !finished, sampleBuffer.isValid, let writer, writer.status == .writing else { return }
        switch type {
        case .screen:
            guard Self.isCompleteFrame(sampleBuffer), let videoInput else { return }
            if sessionStart == nil {
                let start = sampleBuffer.presentationTimeStamp
                writer.startSession(atSourceTime: start)
                sessionStart = start
            }
            if videoInput.isReadyForMoreMediaData, videoInput.append(sampleBuffer) {
                frames += 1
            }
        case .audio:
            append(sampleBuffer, to: audioInput)
        default:
            // Mic dari ScreenCaptureKit (macOS 15+).
            append(sampleBuffer, to: micInput)
        }
    }

    private func append(_ sampleBuffer: CMSampleBuffer, to input: AVAssetWriterInput?) {
        guard let input, let start = sessionStart, input.isReadyForMoreMediaData,
              sampleBuffer.presentationTimeStamp >= start
        else { return }
        input.append(sampleBuffer)
    }

    // MARK: - SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        onLog?("Video berhenti: \(error.localizedDescription)")
        Task { [weak self] in
            await self?.finish()
            self?.onStopped?("Rekaman video berhenti (\(error.localizedDescription)). Audio tetap direkam.")
        }
    }

    // MARK: - Bantuan

    private static func aacSettings(channels: Int) -> [String: Any] {
        [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48000,
            AVNumberOfChannelsKey: channels,
            AVEncoderBitRateKey: channels == 1 ? 64000 : 128_000,
        ]
    }

    /// ScreenCaptureKit juga mengirim frame "idle" (layar tidak berubah) tanpa gambar; hanya frame lengkap ditulis.
    private static func isCompleteFrame(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
              let rawStatus = attachments.first?[.status] as? Int,
              let status = SCFrameStatus(rawValue: rawStatus)
        else { return false }
        return status == .complete
    }

    /// Filter isi yang direkam: jendela aplikasi meeting, atau seluruh layar utama tanpa jendela Meeting Notes.
    private static func makeFilter(content: SCShareableContent, source: VideoSource) throws
        -> (SCContentFilter, CGSize, String)
    {
        if !source.bundlePrefixes.isEmpty, let window = meetingWindow(in: content, prefixes: source.bundlePrefixes) {
            let name = window.owningApplication?.applicationName ?? "meeting"
            return (SCContentFilter(desktopIndependentWindow: window), fit(window.frame.size), "jendela \(name)")
        }
        guard let display = content.displays.first else { throw CaptureError.noDisplay }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let own = content.applications.filter { $0.processID == ownPID }
        let filter = SCContentFilter(display: display, excludingApplications: own, exceptingWindows: [])
        let size = fit(CGSize(width: display.width, height: display.height))
        let text = source.bundlePrefixes.isEmpty ? "seluruh layar" : "seluruh layar (jendela meeting tidak ditemukan)"
        return (filter, size, text)
    }

    /// Jendela terbesar milik aplikasi meeting yang sedang tampil di layar.
    private static func meetingWindow(in content: SCShareableContent, prefixes: [String]) -> SCWindow? {
        let candidates = content.windows.filter { window in
            guard window.isOnScreen, window.frame.width >= 320, window.frame.height >= 240,
                  let bundleID = window.owningApplication?.bundleIdentifier
            else { return false }
            return prefixes.contains { bundleID.hasPrefix($0) }
        }
        return candidates.max { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }
    }

    /// Ukuran video: muat di 1280x720 dengan perbandingan sisi asli, bilangan genap (syarat encoder H.264).
    private static func fit(_ size: CGSize) -> CGSize {
        guard size.width > 0, size.height > 0 else { return maxSize }
        let scale = min(maxSize.width / size.width, maxSize.height / size.height, 1)
        let width = max(2, Int(size.width * scale) / 2 * 2)
        let height = max(2, Int(size.height * scale) / 2 * 2)
        return CGSize(width: width, height: height)
    }
}
