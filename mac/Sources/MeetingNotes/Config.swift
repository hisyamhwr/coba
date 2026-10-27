import Foundation

/// Pengaturan yang ditanam ke Info.plist oleh build.sh (lokasi Python dan repo meeting_notes).
enum Config {
    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "2.0.0"
    }

    /// Python dari environment conda `meeting`, yang sudah berisi paket meeting_notes 1.x.
    static var pythonPath: String {
        Bundle.main.object(forInfoDictionaryKey: "MNPythonPath") as? String ?? "/usr/bin/python3"
    }

    /// Folder repo (berisi folder meeting_notes dan .env).
    static var repoPath: String {
        Bundle.main.object(forInfoDictionaryKey: "MNRepoPath") as? String ?? FileManager.default.currentDirectoryPath
    }

    static var outputDir: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("MeetingNotes")
    }

    /// Transkrip live diputar ulang tiap 50 detik karena pengenalan suara Apple dibatasi +-1 menit per sesi.
    static let liveRotateSeconds = 50
}
