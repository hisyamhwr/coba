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
    /// false bila MoM gagal disusun (transkrip tetap tersimpan). Opsional agar cocok dengan versi Python lama.
    let summarized: Bool?
}

/// Status pulau yang jarang berubah (fase, ukuran, hasil). Hanya diubah dari main actor.
///
/// Data yang berubah berkali-kali per detik (timer, level suara, transkrip live) sengaja dipisah ke
/// `LiveMeter`, supaya perubahan itu hanya menggambar ulang komponen kecilnya, bukan seluruh pulau.
@MainActor
final class AppState: ObservableObject {
    @Published var phase: Phase = .idle
    @Published var expanded = false
    /// Sedang menyiapkan rekaman (menunggu izin mic / mic menyala), sebelum timer berjalan.
    @Published var starting = false
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
        case .idle: return expanded ? CGSize(width: 300, height: 116) : CGSize(width: 150, height: 32)
        case .recording:
            // Peringatan (mis. izin audio meeting) menambah satu baris.
            return expanded ? CGSize(width: 460, height: warning == nil ? 180 : 204) : CGSize(width: 240, height: 32)
        case .processing: return CGSize(width: 360, height: 70)
        case .done: return CGSize(width: 460, height: result?.summarized == false ? 142 : 130)
        case .failed: return CGSize(width: 440, height: 150)
        }
    }

    var isCompact: Bool {
        (phase == .idle || phase == .recording) && !expanded
    }
}

/// Data yang berubah cepat selama rapat, dipecah per jenis. Masing-masing objek hanya diamati komponen kecil
/// yang memakainya: level suara (±10x per detik) tidak lagi ikut menggambar ulang dan menata ulang teks
/// transkrip live tiga baris, dan teks baru tidak menggambar ulang equalizer.
@MainActor
final class LiveMeter {
    let audio = AudioLevels()
    let clock = RecordingClock()
    let caption = LiveCaption()

    /// Level campuran 0...1 (equalizer pulau ringkas, cahaya).
    var level: Float {
        get { audio.level }
        set { if audio.level != newValue { audio.level = newValue } }
    }

    var elapsed: TimeInterval {
        get { clock.elapsed }
        set { if clock.elapsed != newValue { clock.elapsed = newValue } }
    }

    var liveText: String {
        get { caption.committed }
        set { if caption.committed != newValue { caption.committed = newValue } }
    }

    /// Kata-kata yang masih dikenali (belum final), ditampilkan dengan warna aksen.
    var livePartial: String {
        get { caption.partial }
        set { if caption.partial != newValue { caption.partial = newValue } }
    }

    /// Level per jalur: suara kita (mic) dan suara peserta (audio meeting).
    func setLevels(mic: Float, system: Float) {
        if audio.mic != mic { audio.mic = mic }
        if audio.system != system { audio.system = system }
        level = max(mic, system)
    }
}

@MainActor
final class AudioLevels: ObservableObject {
    @Published var level: Float = 0
    @Published var mic: Float = 0
    @Published var system: Float = 0
}

@MainActor
final class RecordingClock: ObservableObject {
    @Published var elapsed: TimeInterval = 0
}

@MainActor
final class LiveCaption: ObservableObject {
    @Published var committed = ""
    @Published var partial = ""
}
