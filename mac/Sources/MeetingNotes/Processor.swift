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
        // Aplikasi yang dibuka dari Finder tidak membawa PATH terminal; tambahkan lokasi umum `claude`.
        var env = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        env["PATH"] = ["\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", env["PATH"] ?? "/usr/bin:/bin"]
            .joined(separator: ":")
        env["PYTHONUNBUFFERED"] = "1"
        process.environment = env

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
            self.stderrTail = String((self.stderrTail + text).suffix(600))
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
            } else {
                let detail = self.stderrTail.split(separator: "\n").suffix(3).joined(separator: "\n")
                onFinish(.failure(ProcessorError.failed(detail.isEmpty ? "Pemrosesan gagal." : detail)))
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
