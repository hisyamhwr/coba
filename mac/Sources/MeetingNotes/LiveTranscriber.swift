import AVFoundation
import Speech

/// Teks live: bagian yang sudah final dan kata-kata yang masih dikenali (bisa berubah).
struct Caption: Equatable {
    var committed: String
    var partial: String = ""
}

/// Transkrip live (perkiraan cepat) dengan pengenal suara bawaan macOS, bahasa Indonesia.
///
/// Hanya untuk ditampilkan selama rapat. Notulen akhir tetap dibuat dari rekaman lengkap oleh Whisper/mesin
/// pilihan yang lebih akurat. Sesi diputar ulang tiap ±50 detik karena pengenal Apple dibatasi ±1 menit.
final class LiveTranscriber {
    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "id-ID"))
    private let onText: (Caption) -> Void
    /// Istilah dari kamus (mis. FE, deploy, flagging) agar pengenal suara lebih tepat menangkap istilah teknis.
    private let terms: [String]
    /// Catatan untuk rekaman.log (izin, error pengenal suara).
    var onLog: ((String) -> Void)?
    private let lock = NSLock()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var generation = 0
    private var committed = ""
    private var partial = ""
    private var running = false
    /// Waktu terakhir teks dikirim ke UI (nanodetik), untuk membatasi update ±7x per detik.
    private var lastEmit: UInt64 = 0
    /// Teks yang tertahan pembatas; dikirim menyusul agar kata terakhir sebelum jeda tidak pernah hilang.
    private var pending: Caption?
    private var flushScheduled = false
    /// Pengenal di perangkat bisa gagal (model bahasa belum terunduh); setelah itu pakai pengenal online Apple.
    private var forceServer = false
    /// Error beruntun tanpa satu hasil pun; berhenti mencoba setelah beberapa kali agar tidak berputar terus.
    private var failures = 0
    private static let minEmitInterval: UInt64 = 150_000_000

    init(terms: [String] = [], onText: @escaping (Caption) -> Void) {
        self.terms = Array(terms.prefix(100))
        self.onText = onText
    }

    func start() {
        SFSpeechRecognizer.requestAuthorization { [weak self] status in
            guard let self else { return }
            guard status == .authorized else {
                self.onLog?("Transkrip live: izin Speech Recognition tidak diberikan (\(status.rawValue))")
                self.onText(Caption(committed: "Transkrip live nonaktif: izinkan Meeting Notes di System Settings → "
                    + "Privacy & Security → Speech Recognition, lalu buka ulang app."))
                return
            }
            self.onLog?("Transkrip live: izin Speech Recognition OK")
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
            onLog?("Transkrip live: pengenal suara id-ID tidak tersedia")
            onText(Caption(committed: "Transkrip live tidak tersedia: nyalakan Dictation di System Settings → "
                + "Keyboard, lalu buka ulang app."))
            return
        }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.addsPunctuation = true
        request.taskHint = .dictation
        request.contextualStrings = terms
        lock.lock()
        let onDevice = recognizer.supportsOnDeviceRecognition && !forceServer
        lock.unlock()
        request.requiresOnDeviceRecognition = onDevice

        lock.lock()
        generation += 1
        let myGeneration = generation
        self.request = request
        lock.unlock()

        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }
            self.lock.lock()
            let isCurrent = myGeneration == self.generation
            if result != nil { self.failures = 0 }
            if let error, result == nil, isCurrent, self.running {
                // Sebelumnya error didiamkan dan sesi tidak dibuka lagi, sehingga pulau hanya menulis
                // "Mendengarkan…" sampai rotasi berikutnya. Sekarang sesi langsung dibuka ulang.
                if !self.partial.isEmpty {
                    self.committed += " " + self.partial
                    self.partial = ""
                }
                // 1110 = tidak ada ucapan (hening sebentar): wajar, tidak dihitung sebagai kegagalan.
                let nsError = error as NSError
                if nsError.code != 1110 { self.failures += 1 }
                let failures = self.failures
                if onDevice { self.forceServer = true }
                self.lock.unlock()
                if nsError.code != 1110 { self.onLog?("Transkrip live error (\(onDevice ? "di perangkat" : "online")): "
                    + "\(nsError.domain) \(nsError.code) \(error.localizedDescription)") }
                if failures <= 3 {
                    self.beginRequest()
                } else {
                    self.onText(Caption(committed: "Transkrip live gagal: \(error.localizedDescription) Pastikan "
                        + "Dictation menyala (System Settings → Keyboard) dan internet tersambung. Rekaman tetap "
                        + "berjalan."))
                }
                return
            }
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
            let caption = Caption(committed: self.committed.trimmingCharacters(in: .whitespaces),
                                  partial: self.partial)
            // Hasil akhir selalu dikirim; hasil sementara dibatasi agar UI tidak digambar ulang tiap kata.
            let now = DispatchTime.now().uptimeNanoseconds
            let isFinal = result?.isFinal ?? true
            let elapsed = now - self.lastEmit
            let shouldEmit = isFinal || elapsed >= Self.minEmitInterval
            var scheduleFlush = false
            if shouldEmit {
                self.lastEmit = now
                self.pending = nil
            } else {
                self.pending = caption
                scheduleFlush = !self.flushScheduled
                self.flushScheduled = true
            }
            self.lock.unlock()
            if shouldEmit { self.onText(caption) }
            if scheduleFlush { self.scheduleFlush(after: Self.minEmitInterval - elapsed) }
        }
    }

    /// Kirim teks yang tertahan pembatas begitu jedanya habis.
    private func scheduleFlush(after nanoseconds: UInt64) {
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + .nanoseconds(Int(nanoseconds))) {
            [weak self] in
            guard let self else { return }
            self.lock.lock()
            let caption = self.pending
            self.pending = nil
            self.flushScheduled = false
            if caption != nil { self.lastEmit = DispatchTime.now().uptimeNanoseconds }
            self.lock.unlock()
            if let caption { self.onText(caption) }
        }
    }
}
