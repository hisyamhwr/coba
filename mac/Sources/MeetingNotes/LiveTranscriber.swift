import AVFoundation
import Speech

/// Teks live dalam tiga lapis:
/// - `refined`: hasil Whisper dari worker latar belakang (akurat, memakai kamus istilah), beberapa detik di
///   belakang ucapan;
/// - `committed`: kata dari pengenal suara Apple yang sudah final, untuk bagian yang belum dikoreksi Whisper;
/// - `partial`: kata yang sedang dikenali (bisa berubah), muncul hampir seketika.
struct Caption: Equatable {
    var refined: String = ""
    var committed: String
    var partial: String = ""
}

/// Transkrip live: kata instan dari pengenal suara bawaan macOS (bahasa Indonesia), lalu diganti hasil Whisper
/// begitu worker latar belakang selesai mentranskripsi potongan itu (lihat `applyRefined`).
///
/// Setiap kata Apple diberi waktu (posisi dalam rekaman) saat pertama muncul, sehingga kata yang sudah dicakup
/// Whisper bisa disembunyikan tanpa tampil dua kali. Pengenal Apple dibatasi ±1 menit per sesi, jadi sesi
/// diganti otomatis: setelah 40 detik pada jeda bicara pertama (agar tidak memotong kata), paling lambat 55 detik.
final class LiveTranscriber {
    private struct Word {
        let text: String
        let time: Double
    }

    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "id-ID"))
    private let onText: (Caption) -> Void
    /// Istilah dari kamus (mis. FE, deploy, flagging) agar pengenal suara lebih tepat menangkap istilah teknis.
    private let terms: [String]
    /// Koreksi salah dengar (mis. "legging" → "flagging"), diterapkan sebelum teks ditampilkan.
    private let corrections: LiveCorrections
    /// Catatan untuk rekaman.log (izin, error pengenal suara).
    var onLog: ((String) -> Void)?
    private let lock = NSLock()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var generation = 0
    private var committedWords: [Word] = []
    private var partialWords: [Word] = []
    /// Kata sementara dari sesi lama yang baru diganti; tetap tampil sampai hasil akhir sesi lama datang
    /// (lalu diganti hasil akhir itu, sehingga tidak tercatat dua kali).
    private var carriedWords: [Word] = []
    /// Teks Whisper dan batas waktunya: kata Apple sebelum batas ini tidak ditampilkan lagi.
    private var refined = ""
    private var refinedUntil: Double = 0
    /// Posisi audio terbaru yang sudah dikirim ke pengenal (detik rekaman).
    private var audioTime: Double = 0
    private var running = false
    /// Waktu terakhir teks dikirim ke UI (nanodetik), untuk membatasi update ±10x per detik.
    private var lastEmit: UInt64 = 0
    /// Teks yang tertahan pembatas; dikirim menyusul agar kata terakhir sebelum jeda tidak pernah hilang.
    private var pending: Caption?
    private var flushScheduled = false
    /// Pengenal di perangkat bisa gagal (model bahasa belum terunduh); setelah itu pakai pengenal online Apple.
    private var forceServer = false
    /// Error beruntun tanpa satu hasil pun; berhenti mencoba setelah beberapa kali agar tidak berputar terus.
    private var failures = 0
    private var loggedMode = false
    private static let minEmitInterval: UInt64 = 100_000_000
    private static let rotateAfterPause: UInt64 = 40_000_000_000
    private static let rotateAlways: UInt64 = 55_000_000_000
    /// RMS di bawah ini dianggap jeda bicara.
    private static let pauseLevel: Float = 0.008
    /// Perkiraan jeda pengenal Apple: kata yang muncul sekarang diucapkan ±0,8 detik lalu.
    private static let recognizerLag: Double = 0.8
    private static let maxWords = 160
    private static let maxRefinedCharacters = 600
    private var sessionStart: UInt64 = 0
    private var rotating = false
    private let rotateQueue = DispatchQueue(label: "meetingnotes.live-rotate")

    init(terms: [String] = [], corrections: [(String, String)] = [], onText: @escaping (Caption) -> Void) {
        self.terms = Array(terms.prefix(100))
        self.corrections = LiveCorrections(corrections)
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
        let oldTask = task
        task = nil
        lock.unlock()
        old?.endAudio()
        oldTask?.cancel()
    }

    /// Dipanggil dari thread audio dengan potongan 16 kHz mono yang sudah dikuatkan otomatis. `rms` adalah
    /// level asli sebelum dikuatkan, untuk mendeteksi jeda bicara (derau yang ikut dikuatkan tidak dikira suara).
    /// `time`: posisi akhir potongan dalam rekaman (detik).
    func append(_ buffer: AVAudioPCMBuffer, rms: Float, time: Double) {
        lock.lock()
        audioTime = time
        request?.append(buffer)
        let age = DispatchTime.now().uptimeNanoseconds - sessionStart
        let due = running && request != nil && !rotating
            && (age >= Self.rotateAlways || (age >= Self.rotateAfterPause && rms < Self.pauseLevel))
        if due { rotating = true }
        lock.unlock()
        // Ganti sesi di luar thread audio agar rekaman tidak pernah tertahan.
        if due { rotateQueue.async { [weak self] in self?.rotate() } }
    }

    /// Hasil Whisper untuk audio sampai detik `until`: menggantikan kata-kata Apple pada rentang itu.
    func applyRefined(until: Double, texts: [String]) {
        lock.lock()
        let added = texts.joined(separator: " ").trimmingCharacters(in: .whitespaces)
        if !added.isEmpty {
            refined = refined.isEmpty ? added : refined + " " + added
            if refined.count > Self.maxRefinedCharacters {
                refined = String(refined.suffix(Self.maxRefinedCharacters * 2 / 3))
            }
        }
        refinedUntil = max(refinedUntil, until)
        committedWords.removeAll { $0.time < refinedUntil }
        let caption = makeCaption()
        lock.unlock()
        emit(caption, force: true)
    }

    /// Tutup sesi lama (hasil akhirnya tetap dipakai) dan buka sesi baru.
    func rotate() {
        lock.lock()
        let isRunning = running
        let old = request
        request = nil
        // Kata yang sedang dikenali tetap tampil sampai hasil akhir sesi lama datang.
        if !partialWords.isEmpty {
            carriedWords = partialWords
            partialWords = []
        }
        lock.unlock()
        old?.endAudio()
        if isRunning { beginRequest() }
        lock.lock()
        rotating = false
        lock.unlock()
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
        let logMode = !loggedMode
        loggedMode = true
        lock.unlock()
        request.requiresOnDeviceRecognition = onDevice
        if logMode {
            onLog?("Transkrip live: pengenal \(onDevice ? "di perangkat (cepat)" : "online Apple") "
                + "(dukungan di perangkat untuk id-ID: \(recognizer.supportsOnDeviceRecognition ? "ya" : "tidak"))")
        }

        lock.lock()
        generation += 1
        let myGeneration = generation
        self.request = request
        sessionStart = DispatchTime.now().uptimeNanoseconds
        lock.unlock()

        let newTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            self?.handle(result: result, error: error, generation: myGeneration, onDevice: onDevice)
        }
        lock.lock()
        // Bisa saja sesi yang lebih baru sudah dibuka dari dalam callback (pemulihan error).
        if generation == myGeneration { task = newTask }
        lock.unlock()
    }

    private func handle(result: SFSpeechRecognitionResult?, error: Error?, generation myGeneration: Int,
                        onDevice: Bool) {
        lock.lock()
        let isCurrent = myGeneration == generation
        if result != nil { failures = 0 }
        if let error, result == nil, isCurrent, running {
            // Error: kata yang sedang dikenali disimpan, lalu sesi langsung dibuka ulang.
            committedWords += partialWords
            partialWords = []
            // 1110 = tidak ada ucapan (hening sebentar): wajar, tidak dihitung sebagai kegagalan dan bukan
            // alasan pindah ke pengenal online yang lebih lambat.
            let nsError = error as NSError
            let benign = nsError.code == 1110
            if !benign { failures += 1 }
            let failureCount = failures
            if onDevice && !benign { forceServer = true }
            lock.unlock()
            if !benign {
                onLog?("Transkrip live error (\(onDevice ? "di perangkat" : "online")): "
                    + "\(nsError.domain) \(nsError.code) \(error.localizedDescription)")
            }
            if failureCount <= 3 {
                beginRequest()
            } else {
                onText(Caption(committed: "Transkrip live gagal: \(error.localizedDescription) Pastikan "
                    + "Dictation menyala (System Settings → Keyboard) dan internet tersambung. Rekaman tetap "
                    + "berjalan."))
            }
            return
        }
        var isFinal = true
        if let result {
            let text = result.bestTranscription.formattedString
            isFinal = result.isFinal
            if result.isFinal && isCurrent {
                committedWords += stamp(text, previous: partialWords)
                partialWords = []
            } else if result.isFinal {
                committedWords += stamp(text, previous: carriedWords)
                carriedWords = []
            } else if isCurrent {
                partialWords = stamp(text, previous: partialWords)
            }
        } else if error != nil {
            if isCurrent {
                committedWords += partialWords
                partialWords = []
            } else {
                // Sesi lama berakhir tanpa hasil akhir: simpan kata sementaranya.
                committedWords += carriedWords
                carriedWords = []
            }
        }
        // Simpan secukupnya saja; yang ditampilkan hanya 2-3 baris terakhir.
        if committedWords.count > Self.maxWords {
            committedWords.removeFirst(committedWords.count - Self.maxWords)
        }
        let caption = makeCaption()
        lock.unlock()
        emit(caption, force: isFinal)
    }

    /// Kata-kata dari teks Apple beserta waktunya. Kata pada posisi yang sudah ada mempertahankan waktunya
    /// (walau ejaannya direvisi); kata baru diberi waktu sekarang dikurangi perkiraan jeda pengenal.
    /// Dipanggil dengan lock terkunci.
    private func stamp(_ text: String, previous: [Word]) -> [Word] {
        let now = max(0, audioTime - Self.recognizerLag)
        let tokens = text.split(separator: " ")
        var words: [Word] = []
        words.reserveCapacity(tokens.count)
        for (index, token) in tokens.enumerated() {
            let time = index < previous.count ? previous[index].time : now
            words.append(Word(text: String(token), time: time))
        }
        return words
    }

    /// Dipanggil dengan lock terkunci.
    private func makeCaption() -> Caption {
        let cutoff = refinedUntil
        let committed = committedWords.filter { $0.time >= cutoff }.map(\.text).joined(separator: " ")
        let partial = (carriedWords + partialWords).filter { $0.time >= cutoff }.map(\.text).joined(separator: " ")
        return Caption(
            refined: Self.collapseRepeatedWords(corrections.apply(refined)),
            committed: Self.collapseRepeatedWords(corrections.apply(committed)),
            partial: Self.collapseRepeatedWords(corrections.apply(partial))
        )
    }

    /// Pengaman terakhir di layar: kata yang sama berturut-turut lebih dari dua kali ("Pada Pada Pada ...",
    /// tanda halusinasi pada hening) disisakan dua saja. "ya ya" yang wajar tetap tampil.
    static func collapseRepeatedWords(_ text: String) -> String {
        var kept: [Substring] = []
        var lastKey = ""
        var run = 0
        for token in text.split(separator: " ") {
            let key = token.lowercased().filter { $0.isLetter || $0.isNumber }
            if !key.isEmpty && key == lastKey {
                run += 1
                if run >= 2 { continue }
            } else {
                lastKey = key
                run = 0
            }
            kept.append(token)
        }
        return kept.joined(separator: " ")
    }

    /// Kirim teks ke UI. Hasil final dan koreksi Whisper selalu dikirim; hasil sementara dibatasi ±10x per detik
    /// agar UI tidak digambar ulang tiap kata, dengan kiriman susulan agar kata terakhir tidak tertahan.
    private func emit(_ caption: Caption, force: Bool) {
        lock.lock()
        // Waktu diambil di dalam lock: kiriman susulan bisa memperbarui lastEmit dari thread lain.
        let now = DispatchTime.now().uptimeNanoseconds
        let elapsed = now >= lastEmit ? now - lastEmit : 0
        let shouldEmit = force || elapsed >= Self.minEmitInterval
        var scheduleFlush = false
        if shouldEmit {
            lastEmit = now
            pending = nil
        } else {
            pending = caption
            scheduleFlush = !flushScheduled
            flushScheduled = true
        }
        lock.unlock()
        if shouldEmit { onText(caption) }
        if scheduleFlush { self.scheduleFlush(after: Self.minEmitInterval - elapsed) }
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

/// Koreksi salah dengar untuk transkrip live, dengan aturan yang sama seperti koreksi di notulen (Python):
/// cocok per kata utuh, tidak peduli huruf besar/kecil, kecuali koreksi yang memang hanya mengubah kapitalisasi.
struct LiveCorrections {
    private let rules: [(NSRegularExpression, String)]

    init(_ pairs: [(String, String)]) {
        rules = pairs.prefix(400).compactMap { pair -> (NSRegularExpression, String)? in
            let (wrong, correct) = pair
            guard !wrong.isEmpty, wrong != correct else { return nil }
            var pattern = NSRegularExpression.escapedPattern(for: wrong)
            if wrong.first.map({ $0.isLetter || $0.isNumber }) == true { pattern = "\\b" + pattern }
            if wrong.last.map({ $0.isLetter || $0.isNumber }) == true { pattern += "\\b" }
            let caseOnly = wrong.lowercased() == correct.lowercased()
            guard let regex = try? NSRegularExpression(pattern: pattern, options: caseOnly ? [] : [.caseInsensitive])
            else { return nil }
            return (regex, NSRegularExpression.escapedTemplate(for: correct))
        }
    }

    func apply(_ text: String) -> String {
        guard !rules.isEmpty, !text.isEmpty else { return text }
        var result = text
        for (regex, template) in rules {
            let range = NSRange(result.startIndex..., in: result)
            result = regex.stringByReplacingMatches(in: result, range: range, withTemplate: template)
        }
        return result
    }

    /// Baca file "salah => benar" (koreksi dari MoM sebelumnya dan koreksi bawaan).
    static func load(from urls: [URL]) -> [(String, String)] {
        var seen = Set<String>()
        var pairs: [(String, String)] = []
        for url in urls {
            let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            for line in text.split(separator: "\n") where !line.hasPrefix("#") {
                let parts = line.components(separatedBy: "=>")
                guard parts.count == 2 else { continue }
                let wrong = parts[0].trimmingCharacters(in: .whitespaces)
                let correct = parts[1].trimmingCharacters(in: .whitespaces)
                guard !wrong.isEmpty, !correct.isEmpty, seen.insert(wrong.lowercased()).inserted else { continue }
                pairs.append((wrong, correct))
            }
        }
        return pairs
    }
}
