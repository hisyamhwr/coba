import Foundation

enum Phase: Equatable {
    case idle, recording, processing, done, failed
}

/// Hasil dari `python -m meeting_notes proses --json` (baris RESULT).
struct NotesResult: Decodable, Equatable {
    let title: String
    let markdown: String
    let docx: String
    let decisions: Int
    let action_items: Int
    let note: String?
}

/// Semua yang ditampilkan di "pulau" notch. Hanya diubah dari main actor.
@MainActor
final class AppState: ObservableObject {
    @Published var phase: Phase = .idle
    @Published var expanded = false
    @Published var elapsed: TimeInterval = 0
    @Published var level: Float = 0
    @Published var liveText = ""
    @Published var micName = ""
    @Published var warning: String?
    @Published var marks: [TimeInterval] = []
    /// 0 = mentranskrip, 1 = mengoreksi & menyusun MoM, 2 = selesai.
    @Published var step = 0
    @Published var stepDetail = ""
    @Published var result: NotesResult?
    @Published var errorMessage = ""

    var recordingDir: URL?

    /// Ukuran panel per status; panel mengikuti ukuran ini.
    var panelSize: CGSize {
        switch phase {
        case .idle: return expanded ? CGSize(width: 320, height: 118) : CGSize(width: 170, height: 32)
        case .recording: return expanded ? CGSize(width: 460, height: 178) : CGSize(width: 250, height: 32)
        case .processing: return CGSize(width: 380, height: 100)
        case .done: return CGSize(width: 440, height: 136)
        case .failed: return CGSize(width: 440, height: 128)
        }
    }
}
