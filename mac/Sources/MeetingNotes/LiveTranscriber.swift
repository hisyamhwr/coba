import AVFoundation
import Speech

/// Transkrip live (perkiraan cepat) dengan pengenal suara bawaan macOS, bahasa Indonesia.
///
/// Hanya untuk ditampilkan selama rapat. Notulen akhir tetap dibuat dari rekaman lengkap oleh Whisper/mesin
/// pilihan yang lebih akurat. Sesi diputar ulang tiap ±50 detik karena pengenal Apple dibatasi ±1 menit.
final class LiveTranscriber {
    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "id-ID"))
    private let onText: (String) -> Void
    private let lock = NSLock()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var generation = 0
    private var committed = ""
    private var partial = ""
    private var running = false

    init(onText: @escaping (String) -> Void) {
        self.onText = onText
    }

    func start() {
        SFSpeechRecognizer.requestAuthorization { [weak self] status in
            guard let self else { return }
            guard status == .authorized else {
                self.onText("Transkrip live nonaktif: izinkan Speech Recognition di System Settings.")
                return
            }
            self.lock.lock()
            self.running = true
            self.lock.unlock()
            self.beginRequest()
        }
    }

    func stop() {
        lock.lock()
        running = false
        let old = request
        request = nil
        lock.unlock()
        old?.endAudio()
        task?.cancel()
    }

    /// Dipanggil dari thread audio dengan potongan 16 kHz mono.
    func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        request?.append(buffer)
        lock.unlock()
    }

    /// Tutup sesi lama (hasil akhirnya tetap dipakai) dan buka sesi baru.
    func rotate() {
        lock.lock()
        let isRunning = running
        let old = request
        request = nil
        partial = ""
        lock.unlock()
        old?.endAudio()
        if isRunning { beginRequest() }
    }

    private func beginRequest() {
        guard let recognizer, recognizer.isAvailable else {
            onText("Transkrip live tidak tersedia untuk bahasa Indonesia di Mac ini.")
            return
        }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.addsPunctuation = true
        if recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }

        lock.lock()
        generation += 1
        let myGeneration = generation
        self.request = request
        lock.unlock()

        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }
            self.lock.lock()
            let isCurrent = myGeneration == self.generation
            if let result {
                let text = result.bestTranscription.formattedString
                if result.isFinal || !isCurrent {
                    if result.isFinal { self.committed += " " + text }
                    if isCurrent { self.partial = "" }
                } else {
                    self.partial = text
                }
            } else if error != nil, isCurrent, !self.partial.isEmpty {
                self.committed += " " + self.partial
                self.partial = ""
            }
            // Simpan secukupnya saja; yang ditampilkan hanya 2-3 baris terakhir.
            if self.committed.count > 600 { self.committed = String(self.committed.suffix(400)) }
            let display = (self.committed + " " + self.partial).trimmingCharacters(in: .whitespaces)
            self.lock.unlock()
            self.onText(String(display.suffix(220)))
        }
    }
}
