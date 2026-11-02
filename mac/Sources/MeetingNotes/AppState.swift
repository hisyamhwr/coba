import Foundation

enum Phase: Equatable {
    case idle, recording, processing, done, failed
}

/// Bentuk pulau, dipilih di menu bar.
enum IslandStyle: String {
    /// Menyatu dengan tepi atas layar/notch: sisi atas melebar dengan lengkungan cekung ("bahu").
    case island
    /// Kapsul melayang sedikit di bawah tepi atas, semua sudut membulat.
    case pill
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

    /// Bentuk pulau; diingat antar sesi.
    @Published var style = IslandStyle(rawValue: UserDefaults.standard.string(forKey: "islandStyle") ?? "") ?? .island {
        didSet { UserDefaults.standard.set(style.rawValue, forKey: "islandStyle") }
    }
    /// Tinggi notch kamera layar ini (0 bila tidak ada notch), agar pill tidak tertutup notch.
    @Published var topInset: CGFloat = 0

    var recordingDir: URL?

    /// Lebar lengkungan cekung di kiri-kanan atas (gaya island). Sisi atas pulau melebar sebesar ini di tiap sisi
    /// sehingga bentuknya mengalir keluar dari tepi layar, bukan menempel dengan sudut siku.
    var shoulder: CGFloat {
        style == .pill ? 0 : (isCompact ? 12 : 20)
    }

    /// Radius sudut atas: 0 untuk island (menempel di tepi layar), sama dengan sudut bawah untuk pill.
    var topRadius: CGFloat {
        style == .pill ? bottomRadius : 0
    }

    var bottomRadius: CGFloat {
        switch style {
        case .island: return isCompact ? 14 : 28
        case .pill: return isCompact ? islandSize.height / 2 : 26
        }
    }

    /// Jarak pulau dari tepi atas layar: island menempel, pill melayang di bawah notch (bila ada).
    var topOffset: CGFloat {
        style == .pill ? topInset + 8 : 0
    }

    /// Ukuran pulau per status. Jendelanya berukuran tetap; hanya bentuk pulau di dalamnya yang beranimasi.
    var islandSize: CGSize {
        switch phase {
        case .idle: return expanded ? CGSize(width: 340, height: 106) : CGSize(width: 150, height: 32)
        case .recording:
            // Peringatan (mis. izin audio meeting) menambah satu baris.
            return expanded ? CGSize(width: 460, height: warning == nil ? 198 : 222) : CGSize(width: 240, height: 32)
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
