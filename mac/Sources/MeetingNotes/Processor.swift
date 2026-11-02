import Foundation

enum ProcessorError: LocalizedError {
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .failed(let message): return message
        }
    }
}

/// Menjalankan "otak" Python 1.x: `python -m meeting_notes proses <wav> --json`.
///
/// Python mencetak `STATUS\t<pesan>` untuk progres dan satu baris `RESULT\t<json>` di akhir.
final class Processor {
    private let process = Process()
    private var stdoutBuffer = Data()
    private var stderrTail = ""
    private var result: NotesResult?
    private var cancelled = false

    /// Hentikan pemrosesan (tombol batal di pulau).
    func cancel() {
        cancelled = true
        if process.isRunning { process.terminate() }
    }

    /// Environment untuk Python, seperti setelah `conda activate`.
    static func pythonEnvironment() -> [String: String] {
        // Aplikasi yang dibuka dari Finder tidak membawa PATH terminal; tambahkan lokasi umum `claude`.
        var env = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        // Tiru "conda activate": folder bin environment di depan PATH dan CONDA_PREFIX terisi.
        let envBin = URL(fileURLWithPath: Config.pythonPath).deletingLastPathComponent()
        env["CONDA_PREFIX"] = envBin.deletingLastPathComponent().path
        env["PATH"] = [envBin.path, "\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin",
                       env["PATH"] ?? "/usr/bin:/bin"].joined(separator: ":")
        env["PYTHONUNBUFFERED"] = "1"
        return env
    }

    func run(
        audio: URL, marks: URL, startedAt: Date, docx: Bool,
        onStatus: @escaping (String) -> Void,
        onFinish: @escaping (Result<NotesResult, Error>) -> Void
    ) {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"

        process.executableURL = URL(fileURLWithPath: Config.pythonPath)
        process.arguments = [
            "-m", "meeting_notes", "proses", audio.path, "--json",
            "--penting", marks.path, "--mulai", formatter.string(from: startedAt),
        ] + (docx ? ["--docx"] : [])
        process.currentDirectoryURL = URL(fileURLWithPath: Config.repoPath)
        process.environment = Self.pythonEnvironment()
        // Whisper & Claude memakai CPU berat; prioritas di bawah tampilan agar animasi pulau tetap mulus.
        process.qualityOfService = .utility

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let self, !data.isEmpty else { return }
            self.stdoutBuffer.append(data)
            while let newline = self.stdoutBuffer.firstIndex(of: 0x0A) {
                let lineData = self.stdoutBuffer.subdata(in: self.stdoutBuffer.startIndex..<newline)
                self.stdoutBuffer.removeSubrange(self.stdoutBuffer.startIndex...newline)
                guard let line = String(data: lineData, encoding: .utf8) else { continue }
                if line.hasPrefix("STATUS\t") {
                    onStatus(String(line.dropFirst("STATUS\t".count)))
                } else if line.hasPrefix("RESULT\t"),
                          let json = line.dropFirst("RESULT\t".count).data(using: .utf8) {
                    self.result = try? JSONDecoder().decode(NotesResult.self, from: json)
                }
            }
        }
        stderr.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let self, !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            self.stderrTail = String((self.stderrTail + text).suffix(20_000))
        }

        process.terminationHandler = { [weak self] proc in
            guard let self else { return }
            stdout.fileHandleForReading.readabilityHandler = nil
            stderr.fileHandleForReading.readabilityHandler = nil
            // Sisa keluaran yang belum terbaca.
            let rest = stdout.fileHandleForReading.readDataToEndOfFile()
            if let text = String(data: rest, encoding: .utf8),
               let line = text.split(separator: "\n").last(where: { $0.hasPrefix("RESULT\t") }),
               let json = line.dropFirst("RESULT\t".count).data(using: .utf8) {
                self.result = try? JSONDecoder().decode(NotesResult.self, from: json)
            }
            if let result = self.result, proc.terminationStatus == 0 {
                onFinish(.success(result))
            } else if self.cancelled {
                onFinish(.failure(ProcessorError.failed("Pemrosesan dibatalkan. Rekaman aman; klik Proses ulang.")))
            } else {
                // Simpan log lengkap di folder rekaman; tampilkan inti error (baris terakhir traceback).
                let log = audio.deletingLastPathComponent().appendingPathComponent("proses.log")
                try? self.stderrTail.write(to: log, atomically: true, encoding: .utf8)
                let lastLine = self.stderrTail.split(separator: "\n").last { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                let detail = lastLine.map { String($0).trimmingCharacters(in: .whitespaces) } ?? "Pemrosesan gagal."
                onFinish(.failure(ProcessorError.failed("\(detail)\nLog lengkap: proses.log di folder rekaman.")))
            }
        }

        do {
            try process.run()
        } catch {
            onFinish(.failure(ProcessorError.failed(
                "Python tidak ditemukan di \(Config.pythonPath). Jalankan ulang mac/build.sh dari environment conda.")))
        }
    }
}

/// Transkripsi di latar belakang selama rapat: `python -m meeting_notes ikuti <folder>`.
///
/// Saat rapat selesai, `proses` hanya perlu mentranskripsi beberapa menit terakhir. Prosesnya berprioritas
/// rendah agar Zoom/Teams tetap lancar, dan boleh dihentikan kapan saja (hasil disimpan per potongan).
final class LiveWorker {
    private struct LiveUpdate: Decodable {
        let until: Double
        let text: [String]
    }

    private let process = Process()
    private let output = Pipe()
    /// Sisa baris stdout yang belum lengkap.
    private var lineBuffer = Data()
    /// Hasil Whisper untuk transkrip live: (sampai detik ke-, kalimat-kalimat baru). Dipanggil di thread latar.
    var onRefined: ((Double, [String]) -> Void)?

    init(folder: URL) {
        process.executableURL = URL(fileURLWithPath: Config.pythonPath)
        process.arguments = ["-m", "meeting_notes", "ikuti", folder.path]
        process.currentDirectoryURL = URL(fileURLWithPath: Config.repoPath)
        process.environment = Processor.pythonEnvironment()
        // Prioritas sedang: koreksi live tidak tertinggal, Zoom/Teams tetap didahulukan.
        process.qualityOfService = .default
        let log = folder.appendingPathComponent("ikuti.log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        if let handle = try? FileHandle(forWritingTo: log) {
            process.standardError = handle
        }
        // stdout: baris "LIVE\t{json}" berisi hasil Whisper terbaru.
        process.standardOutput = output
    }

    func start() {
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            self?.consume(handle.availableData)
        }
        try? process.run()
    }

    private func consume(_ data: Data) {
        guard !data.isEmpty else { return }
        lineBuffer.append(data)
        while let newline = lineBuffer.firstIndex(of: 0x0A) {
            let line = lineBuffer.subdata(in: lineBuffer.startIndex..<newline)
            lineBuffer.removeSubrange(lineBuffer.startIndex...newline)
            guard let text = String(data: line, encoding: .utf8), text.hasPrefix("LIVE\t"),
                  let json = text.dropFirst(5).data(using: .utf8),
                  let update = try? JSONDecoder().decode(LiveUpdate.self, from: json)
            else { continue }
            onRefined?(update.until, update.text)
        }
    }

    /// Hentikan dan tunggu sampai benar-benar keluar, agar model Whisper tidak dimuat dua kali bersamaan.
    func stop() {
        output.fileHandleForReading.readabilityHandler = nil
        guard process.isRunning else { return }
        process.terminate()
        process.waitUntilExit()
    }
}
