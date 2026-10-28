import Foundation

enum Phase: Equatable {
    case idle, recording, processing, done, failed
}

/// Hasil dari `python -m meeting_notes proses --json` (baris RESULT).
struct NotesResult: Decodable, Equatable {
    let title: String
    let markdown: String
    /// nil bila Word tidak dicentang.
    let docx: String?
    let decisions: Int
    let action_items: Int
    let note: String?
}

/// Status pulau yang jarang berubah (fase, ukuran, hasil). Hanya diubah dari main actor.
///
/// Data yang berubah berkali-kali per detik (timer, level suara, transkrip live) sengaja dipisah ke
/// `LiveMeter`, supaya perubahan itu hanya menggambar ulang komponen kecilnya, bukan seluruh pulau.
@MainActor
final class AppState: ObservableObject {
    @Published var phase: Phase = .idle
    @Published var expanded = false
    @Published var micName = ""
    @Published var warning: String?
    @Published var marks: [TimeInterval] = []
    /// 0 = mentranskrip, 1 = mengoreksi & menyusun MoM, 2 = selesai.
    @Published var step = 0
    @Published var stepDetail = ""
    @Published var result: NotesResult?
    @Published var errorMessage = ""
    /// Centang "Buat juga Word (.docx)"; diingat antar sesi.
    @Published var exportDocx = UserDefaults.standard.bool(forKey: "exportDocx") {
        didSet { UserDefaults.standard.set(exportDocx, forKey: "exportDocx") }
    }
    /// Transkrip live bisa dimatikan untuk menghemat CPU/baterai; diingat antar sesi.
    @Published var liveTranscript = UserDefaults.standard.object(forKey: "liveTranscript") as? Bool ?? true {
        didSet { UserDefaults.standard.set(liveTranscript, forKey: "liveTranscript") }
    }

    var recordingDir: URL?

    /// Ukuran pulau per status. Jendelanya berukuran tetap; hanya bentuk pulau di dalamnya yang beranimasi.
    var islandSize: CGSize {
        switch phase {
        case .idle: return expanded ? CGSize(width: 320, height: 142) : CGSize(width: 170, height: 32)
        case .recording: return expanded ? CGSize(width: 460, height: 178) : CGSize(width: 250, height: 32)
        case .processing: return CGSize(width: 380, height: 100)
        case .done: return CGSize(width: 440, height: 136)
        case .failed: return CGSize(width: 440, height: 128)
        }
    }

    var isCompact: Bool {
        (phase == .idle || phase == .recording) && !expanded
    }
}

/// Data yang berubah cepat selama rapat.
@MainActor
final class LiveMeter: ObservableObject {
    @Published var level: Float = 0
    @Published var elapsed: TimeInterval = 0
    @Published var liveText = ""
}
