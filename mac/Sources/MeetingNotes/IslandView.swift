import AppKit
import SwiftUI

/// Token desain pulau (lihat docs/DESIGN.md). Gaya: "neon ocean" — permukaan hitam pekat agar menyatu dengan
/// notch, identitas biru elektrik → cyan → tosca, hijau mint untuk selesai, lime sebagai aksen kontras (Penting),
/// dan merah koral khusus untuk rekam/stop/peringatan.
private enum Palette {
    static let red = Color(red: 1.0, green: 0.30, blue: 0.43)      // #FF4D6D titik rekam, tombol stop
    static let coral = Color(red: 1.0, green: 0.48, blue: 0.54)    // #FF7A8A peringatan, gagal
    static let azure = Color(red: 0.15, green: 0.39, blue: 0.92)   // #2563EB biru tua (tombol)
    static let blue = Color(red: 0.23, green: 0.51, blue: 0.96)    // #3B82F6 biru elektrik
    static let deepCyan = Color(red: 0.03, green: 0.57, blue: 0.70) // #0891B2 cyan gelap (tombol, teks putih)
    static let cyan = Color(red: 0.13, green: 0.83, blue: 0.93)    // #22D3EE cyan neon
    static let teal = Color(red: 0.18, green: 0.83, blue: 0.75)    // #2DD4BF tosca
    static let mint = Color(red: 0.20, green: 0.83, blue: 0.60)    // #34D399 hijau mint: selesai
    static let lime = Color(red: 0.76, green: 0.96, blue: 0.24)    // #C3F53C aksen: momen penting
    static let navy = Color(red: 0.04, green: 0.12, blue: 0.25)    // #0B1E3F ikon di atas gradien terang
    static let chip = Color.white.opacity(0.1)
    /// Garis tepi "kaca": terang di atas, memudar ke bawah. Memberi kesan timbul pada tombol & kartu (statis).
    static let rim = LinearGradient(colors: [Color.white.opacity(0.24), Color.white.opacity(0.04)],
                                    startPoint: .top, endPoint: .bottom)
    /// Latar kartu di dalam pulau (mis. kartu transkrip live).
    static let card = Color.white.opacity(0.055)
    static let secondary = Color.white.opacity(0.72)               // teks transkrip yang sudah final
    static let muted = Color.white.opacity(0.55)                   // ±6:1 di atas hitam

    /// Tombol aksi utama (Mulai, Susun ulang): biru tua → cyan gelap agar teks putih tetap kontras.
    static let action = LinearGradient(colors: [azure, deepCyan], startPoint: .leading, endPoint: .trailing)
    /// Tombol stop: merah koral.
    static let record = LinearGradient(colors: [red, coral], startPoint: .leading, endPoint: .trailing)
    static let process = LinearGradient(colors: [blue, cyan, teal], startPoint: .leading, endPoint: .trailing)
    static let done = LinearGradient(colors: [teal, mint], startPoint: .leading, endPoint: .trailing)
    static let brand = LinearGradient(colors: [blue, cyan, teal], startPoint: .topLeading, endPoint: .bottomTrailing)
    static let partial = LinearGradient(colors: [cyan, mint], startPoint: .leading, endPoint: .trailing)
    /// Warna konfeti saat MoM siap.
    static let confetti: [Color] = [blue, cyan, teal, mint, lime, Color.white]
    /// Warna per jalur suara: cyan = suara kita (mic), mint = peserta online (audio meeting).
    static let micSource = cyan
    static let meetingSource = mint
}

/// Tipografi: SF Pro untuk teks (ringan, mudah dibaca), SF Pro Rounded untuk angka dan judul (ramah, ceria).
/// Bobot dibatasi regular-semibold agar tidak terasa berat.
private enum Typo {
    static let live = Font.system(size: 15, weight: .regular)
    static let title = Font.system(size: 15, weight: .semibold, design: .rounded)
    static let heading = Font.system(size: 17, weight: .semibold, design: .rounded)
    static let label = Font.system(size: 12, weight: .medium)
    static let small = Font.system(size: 11, weight: .medium)
    static func number(_ size: CGFloat) -> Font {
        .system(size: size, weight: .medium, design: .rounded).monospacedDigit()
    }
}

/// Kurva animasi ala Dynamic Island: pegas cepat yang sedikit memantul sehingga bentuknya terasa "cair".
enum Liquid {
    static let morph = Animation.spring(duration: 0.42, bounce: 0.22)
    static let appear = Animation.spring(duration: 0.6, bounce: 0.3)
    static let hover = Animation.spring(duration: 0.3, bounce: 0.25)
    static let press = Animation.spring(duration: 0.22, bounce: 0.35)
    static let pop = Animation.spring(duration: 0.35, bounce: 0.5)
    /// Isi baru muncul sedikit setelah bentuk mulai melebar; isi lama hilang cepat.
    static let contentIn = Animation.spring(duration: 0.32, bounce: 0.15).delay(0.06)
    static let contentOut = Animation.easeIn(duration: 0.08)
}

/// Getaran halus trackpad saat aksi penting (mulai, tandai, selesai).
private func haptic() {
    NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
}

/// "Pulau" ala Dynamic Island. Gaya mengikuti docs/design-references: kartu hitam dengan cahaya warna sesuai
/// status, satu hal utama per status (timer, transkrip live, judul rapat), dan tombol kapsul. Teks pelengkap
/// (versi, shortcut, nama mic) sengaja tidak ditampilkan; semuanya tetap ada di menu bar.
///
/// Prinsip performa (lihat docs/DESIGN.md):
/// - Jendelanya berukuran tetap; yang beranimasi hanya bentuk hitam di dalamnya. Isi dan cahaya disusun pada
///   ukuran akhir lalu cukup dipotong oleh bentuk yang beranimasi.
/// - Tanpa bayangan, mask, blur, atau gradien yang digambar ulang tiap frame. Yang beranimasi: opacity,
///   transform, dan efek simbol bawaan macOS.
/// - Selama rapat tidak ada animasi yang berjalan terus-menerus kecuali yang mengikuti suara.
/// - Animasi dekoratif mati bila "Reduce motion" aktif di macOS.
struct IslandView: View {
    @ObservedObject var state: AppState
    let meter: LiveMeter
    let controller: MeetingController

    @State private var appeared = false
    @State private var hovering = false
    @State private var pressed = false
    @State private var copied = false

    var body: some View {
        island
            .frame(width: IslandPanel.canvas.width, height: IslandPanel.canvas.height, alignment: .top)
            .onAppear {
                withAnimation(Liquid.appear.delay(0.1)) { appeared = true }
            }
    }

    // MARK: Bentuk pulau

    private var size: CGSize {
        guard appeared else { return CGSize(width: 60, height: 8) }
        let base = state.islandSize
        // Saat kursor di atas pulau ringkas, pulau sedikit "menggembung".
        guard hovering, state.isCompact else { return base }
        return CGSize(width: base.width + 16, height: base.height + 4)
    }

    private var island: some View {
        let shoulder = state.shoulder
        let shape = IslandShape(shoulder: shoulder, topRadius: state.topRadius, bottomRadius: state.bottomRadius)
        let target = state.islandSize
        let isPill = state.style == .pill
        return ZStack(alignment: .top) {
            shape.fill(Color.black)
            // Ukuran akhir (seperti isi): selama bentuk beranimasi, gradien tidak digambar ulang tiap frame.
            glow
                .frame(width: target.width, height: target.height)
            content
                .id(contentKey)
                .transition(.asymmetric(
                    insertion: .opacity.combined(with: .scale(scale: 0.92, anchor: .top))
                        .combined(with: .offset(y: -4))
                        .animation(Liquid.contentIn),
                    removal: .opacity.animation(Liquid.contentOut)
                ))
                .padding(.horizontal, state.isCompact ? 14 : 18)
                .padding(.vertical, state.isCompact ? 0 : 14)
                // Ukuran akhir, bukan ukuran yang sedang beranimasi: isi tidak disusun ulang tiap frame.
                .frame(width: target.width, height: target.height)
                .opacity(appeared ? 1 : 0)
        }
        // Bentuk hitam selebar badan pulau + "bahu" di kiri-kanan; isi tetap di tengah pada lebar badan.
        .frame(width: size.width + shoulder * 2, height: size.height, alignment: .top)
        .clipShape(shape)
        .overlay {
            if state.phase == .processing {
                Aura(shape: shape)
            } else {
                // Pill melayang di atas wallpaper/menu bar: garis tepi tipis agar tetap terlihat rapi.
                shape.stroke(Color.white.opacity(isPill ? 0.14 : (state.isCompact ? 0 : 0.08)), lineWidth: 1)
            }
        }
        .scaleEffect(pressed ? 0.96 : 1, anchor: .top)
        .foregroundStyle(.white)
        .contentShape(shape)
        .onHover { inside in
            withAnimation(Liquid.hover) { hovering = inside }
        }
        .padding(.top, state.topOffset)
        .animation(Liquid.morph, value: target)
        .animation(Liquid.morph, value: state.style)
    }

    /// Cahaya warna di dalam pulau sesuai status; saat merekam ikut berdenyut mengikuti suara.
    @ViewBuilder
    private var glow: some View {
        switch state.phase {
        case .idle:
            Glow(color: Palette.cyan, strength: state.expanded ? 0.3 : (hovering ? 0.22 : 0))
        case .recording:
            if state.expanded {
                LevelGlow(audio: meter.audio)
            } else {
                Glow(color: Palette.blue, strength: 0.3, center: .leading, radius: 130)
            }
        case .processing:
            Glow(color: Palette.cyan, strength: 0.34)
        case .done:
            Glow(color: Palette.mint, strength: 0.36)
        case .failed:
            Glow(color: Palette.coral, strength: 0.32)
        }
    }

    /// Kunci isi pulau; bila berubah, isi lama memudar dan isi baru muncul.
    private var contentKey: String {
        "\(state.phase)-\(state.expanded)"
    }

    @ViewBuilder
    private var content: some View {
        switch state.phase {
        case .idle:
            if state.expanded { idleExpanded } else { idleCompact }
        case .recording:
            if state.expanded { recordingExpanded } else { recordingCompact }
        case .processing:
            processing
        case .done:
            done
        case .failed:
            failed
        }
    }

    /// Klik pada pulau ringkas: langsung melebar (tanpa jeda), dengan sentuhan "tekan" kecil bersamaan.
    private func expand() {
        withAnimation(Liquid.morph) { state.expanded = true }
        withAnimation(Liquid.press) { pressed = true }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 90_000_000)
            withAnimation(Liquid.press) { pressed = false }
        }
    }

    private func collapse() {
        withAnimation(Liquid.morph) { state.expanded = false }
    }

    // MARK: Siap

    private var idleCompact: some View {
        HStack(spacing: 7) {
            if state.starting {
                ProgressView().controlSize(.mini)
            } else {
                BrandMark(size: 18, active: hovering)
            }
            Text(state.starting ? "Menyiapkan" : "Catat rapat")
                .font(Typo.label)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .onTapGesture(perform: expand)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel("Buka Meeting Notes")
    }

    private var idleExpanded: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                BrandMark(size: 34, active: hovering)
                    .entrance(0.02)
                VStack(alignment: .leading, spacing: 2) {
                    Text(Self.greeting())
                        .font(Typo.title)
                    Text(Self.dayFormatter.string(from: Date()))
                        .font(Typo.small)
                        .foregroundStyle(Palette.muted)
                }
                .entrance(0.06)
                Spacer(minLength: 8)
                startButton
                    .entrance(0.1)
            }
            HStack(spacing: 6) {
                toggleChip("Word", icon: "doc.richtext", isOn: $state.exportDocx, help: "Buat juga file Word (.docx)")
                toggleChip("Live", icon: "captions.bubble", isOn: $state.liveTranscript,
                           help: "Transkrip live selama rapat")
                Spacer()
                iconButton("folder", help: "Buka folder notulen") { controller.openFolder() }
                iconButton("xmark", help: "Tutup", action: collapse)
            }
            .entrance(0.14)
        }
    }

    /// Tombol Mulai: kapsul ringkas bergradien merah dengan riak lembut di belakangnya dan kilau sekali lewat.
    private var startButton: some View {
        Button {
            haptic()
            controller.start()
        } label: {
            HStack(spacing: 7) {
                if state.starting {
                    ProgressView().controlSize(.mini).tint(.white)
                } else {
                    RecordGlyph()
                }
                Text(state.starting ? "Menyiapkan" : "Mulai")
                    .font(Typo.label.weight(.semibold))
            }
            .padding(.leading, 10)
            .padding(.trailing, 14)
            .frame(height: 32)
            .background(Capsule().fill(Palette.action))
            .overlay(Sheen().clipShape(Capsule()))
            .overlay(Capsule().strokeBorder(Palette.rim, lineWidth: 1))
            .background(PulseHalo())
            .foregroundStyle(.white)
        }
        .buttonStyle(PressableStyle())
        .hoverLift()
        .disabled(state.starting)
        .help("Mulai merekam & mencatat rapat")
        .accessibilityLabel("Mulai catat rapat")
    }

    private static func greeting(_ date: Date = Date()) -> String {
        let hour = Calendar.current.component(.hour, from: date)
        switch hour {
        case 4..<11: return "Selamat pagi"
        case 11..<15: return "Selamat siang"
        case 15..<18: return "Selamat sore"
        default: return "Selamat malam"
        }
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "id_ID")
        formatter.dateFormat = "EEEE, d MMMM"
        return formatter
    }()

    // MARK: Merekam

    private var recordingCompact: some View {
        HStack(spacing: 8) {
            RecordingDot()
            ElapsedText(clock: meter.clock, size: 13)
            Spacer()
            if !state.marks.isEmpty {
                Label("\(state.marks.count)", systemImage: "star.fill")
                    .font(Typo.small)
                    .foregroundStyle(Palette.lime)
                    .contentTransition(.numericText())
                    .transition(.scale.combined(with: .opacity))
            }
            EqualizerBars(audio: meter.audio, height: 14)
        }
        .animation(Liquid.pop, value: state.marks.count)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .onTapGesture(perform: expand)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel("Sedang merekam. Buka panel rekaman")
    }

    private var recordingExpanded: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                RecordingDot()
                ElapsedText(clock: meter.clock, size: 17)
                Spacer()
                // Dua jalur yang direkam, masing-masing menyala saat ada suara: langsung terlihat bila suara
                // meeting atau mic tidak masuk.
                SourceChip(audio: meter.audio, source: .mic)
                SourceChip(audio: meter.audio, source: .meeting)
                iconButton("chevron.up", help: "Perkecil", action: collapse)
            }
            LiveText(caption: meter.caption)
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(CaptionCard())
            if let warning = state.warning {
                Label(warning, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 10, weight: .regular))
                    .foregroundStyle(Palette.coral)
                    .lineLimit(2)
            }
            HStack(spacing: 8) {
                Button {
                    haptic()
                    withAnimation(Liquid.pop) { controller.markImportant() }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: state.marks.isEmpty ? "star" : "star.fill")
                            .symbolEffect(.bounce, value: state.marks.count)
                            .background(Burst(trigger: state.marks.count, color: Palette.lime))
                        Text("Penting")
                        if !state.marks.isEmpty {
                            Text("\(state.marks.count)")
                                .font(Typo.number(11))
                                .contentTransition(.numericText())
                                .padding(.horizontal, 6)
                                .background(Capsule().fill(Palette.lime.opacity(0.25)))
                                .transition(.scale.combined(with: .opacity))
                        }
                    }
                    .font(Typo.label)
                    .foregroundStyle(Palette.lime)
                    .padding(.horizontal, 12)
                    .frame(height: 30)
                    .background(Capsule().fill(Palette.chip))
                    .overlay(Capsule().strokeBorder(Palette.rim, lineWidth: 0.75))
                }
                .buttonStyle(PressableStyle())
                .hoverLift()
                .help("Tandai momen penting")
                Spacer()
                Button {
                    haptic()
                    controller.stop()
                } label: {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(width: 34, height: 34)
                        .background(Circle().fill(Palette.record))
                        .overlay(Circle().strokeBorder(Palette.rim, lineWidth: 1))
                        .background(Circle().fill(RadialGradient(colors: [Palette.red.opacity(0.45), .clear],
                                                                 center: .center, startRadius: 12, endRadius: 26))
                            .frame(width: 52, height: 52))
                }
                .buttonStyle(PressableStyle())
                .hoverLift()
                .help("Selesai & susun MoM")
                .accessibilityLabel("Selesai dan susun MoM")
            }
        }
    }

    // MARK: Memproses

    private var processing: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: state.step == 0 ? "waveform" : "sparkles")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Palette.process)
                    .contentTransition(.symbolEffect(.replace))
                    .symbolEffect(.variableColor.iterative, options: .repeating)
                Text(state.step == 0 ? "Mentranskrip" : "Menyusun MoM")
                    .font(Typo.title)
                    .contentTransition(.opacity)
                if state.step != 0 {
                    TypingDots()
                }
                Spacer()
                if state.step == 0, let percent = stepPercent {
                    Text("\(percent)%")
                        .font(Typo.number(15))
                        .foregroundStyle(Palette.muted)
                        .contentTransition(.numericText())
                }
                iconButton("xmark", help: "Batalkan (rekaman tetap aman)") { controller.cancelProcessing() }
            }
            ProgressBar(fraction: progressFraction)
        }
        .animation(.snappy, value: state.stepDetail)
    }

    /// Persentase transkripsi dari pesan status Python, mis. "Mentranskrip suara meeting... 42%".
    private var stepPercent: Int? {
        guard let range = state.stepDetail.range(of: #"\d+(?=%)"#, options: .regularExpression) else { return nil }
        return Int(state.stepDetail[range])
    }

    /// Transkripsi mengisi 60% pertama, penyusunan MoM 40% sisanya.
    private var progressFraction: Double {
        switch state.step {
        case 0: return 0.6 * Double(stepPercent ?? 0) / 100
        case 1: return 0.8
        default: return 1
        }
    }

    // MARK: Selesai / gagal

    private var done: some View {
        let summarized = state.result?.summarized != false
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                if summarized {
                    CheckBadge()
                        .background(Confetti())
                    Text("MoM siap").foregroundStyle(Palette.mint)
                } else {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Palette.coral)
                    Text("Transkrip tersimpan, MoM belum tersusun").foregroundStyle(Palette.coral)
                }
                Spacer()
                iconButton("xmark", help: "Tutup") { controller.dismiss() }
            }
            .font(Typo.label)
            if summarized {
                Text(state.result?.title ?? "Rapat")
                    .font(Typo.heading)
                    .lineLimit(1)
            } else {
                Text(state.result?.note ?? "Penyusunan MoM gagal.")
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(Palette.muted)
                    .lineLimit(2)
                    .textSelection(.enabled)
            }
            HStack(spacing: 6) {
                if summarized {
                    stat(state.result?.decisions ?? 0, "keputusan", icon: "checkmark.seal.fill", color: Palette.mint)
                    stat(state.result?.action_items ?? 0, "tugas", icon: "checklist", color: Palette.blue)
                    if !state.marks.isEmpty {
                        stat(state.marks.count, nil, icon: "star.fill", color: Palette.lime)
                    }
                }
                Spacer()
                iconButton(copied ? "checkmark" : "doc.on.doc", help: summarized ? "Salin MoM" : "Salin transkrip") {
                    controller.copyResult()
                    haptic()
                    withAnimation(Liquid.press) { copied = true }
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 1_500_000_000)
                        withAnimation(Liquid.press) { copied = false }
                    }
                }
                iconButton("folder", help: "Buka folder notulen") { controller.openFolder() }
                if summarized {
                    primaryButton("Buka MoM", icon: "doc.text.fill", gradient: Palette.done) { controller.openResult() }
                } else {
                    primaryButton("Susun ulang", icon: "arrow.clockwise", gradient: Palette.action) {
                        controller.retry()
                    }
                }
            }
        }
    }

    private var failed: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .symbolEffect(.bounce, value: state.errorMessage)
                Text("Gagal memproses")
                Spacer()
                iconButton("xmark", help: "Tutup") { controller.dismiss() }
            }
            .font(Typo.label)
            .foregroundStyle(Palette.coral)
            Text(state.errorMessage)
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(Palette.muted)
                .lineLimit(3)
                .textSelection(.enabled)
            HStack(spacing: 8) {
                Spacer()
                iconButton("folder", help: "Buka folder rekaman") { controller.openFolder() }
                if state.recordingDir != nil {
                    primaryButton("Proses ulang", icon: "arrow.clockwise", gradient: Palette.action) {
                        controller.retry()
                    }
                }
            }
        }
    }

    // MARK: Komponen

    private func primaryButton(
        _ title: String, icon: String, gradient: LinearGradient, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(Typo.label)
                .padding(.horizontal, 14)
                .frame(height: 30)
                .background(Capsule().fill(gradient))
                .overlay(Capsule().strokeBorder(Color.white.opacity(0.22), lineWidth: 1))
        }
        .buttonStyle(PressableStyle())
        .hoverLift()
    }

    private func iconButton(_ systemImage: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .semibold))
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 28, height: 28)
                .background(Circle().fill(Palette.chip))
                .overlay(Circle().strokeBorder(Palette.rim, lineWidth: 0.75))
        }
        .buttonStyle(PressableStyle())
        .hoverLift()
        .help(help)
        .accessibilityLabel(help)
    }

    private func toggleChip(_ title: String, icon: String, isOn: Binding<Bool>, help: String) -> some View {
        let on = isOn.wrappedValue
        return Button {
            withAnimation(Liquid.pop) { isOn.wrappedValue.toggle() }
        } label: {
            Label(title, systemImage: on ? "checkmark.circle.fill" : icon)
                .font(Typo.small)
                .foregroundStyle(on ? Palette.cyan : Palette.muted)
                .contentTransition(.symbolEffect(.replace))
                .padding(.horizontal, 10)
                .frame(height: 28)
                .background(Capsule().fill(on ? Palette.cyan.opacity(0.16) : Palette.chip))
                .overlay(Capsule().strokeBorder(Palette.rim, lineWidth: 0.75))
        }
        .buttonStyle(PressableStyle())
        .hoverLift()
        .help(help)
        .accessibilityLabel(help)
        .accessibilityValue(on ? "aktif" : "nonaktif")
    }

    private func stat(_ value: Int, _ label: String?, icon: String, color: Color) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon).foregroundStyle(color)
            Text("\(value)").font(Typo.number(12))
            if let label {
                Text(label).foregroundStyle(Palette.muted)
            }
        }
        .font(Typo.small)
        .padding(.horizontal, 8)
        .frame(height: 24)
        .background(Capsule().fill(Palette.chip))
        .overlay(Capsule().strokeBorder(Palette.rim, lineWidth: 0.75))
    }
}

// MARK: - Bentuk

/// Bentuk pulau yang bisa beranimasi antara dua gaya:
/// - island: menempel di tepi atas layar. Sudut atas tidak siku, melainkan melengkung cekung ke luar ("bahu",
///   lebar `shoulder`) sehingga hitamnya mengalir dari tepi layar/notch seperti cairan. Sudut bawah membulat.
/// - pill: kapsul melayang, semua sudut membulat (`topRadius` = `bottomRadius`, tanpa bahu).
/// Badan pulau berada di tengah; lebar total bentuk = lebar badan + 2 × `shoulder`. Semua nilai bisa
/// dianimasikan, jadi perpindahan gaya dan ukuran terlihat sebagai satu gerakan yang mulus.
struct IslandShape: Shape {
    var shoulder: CGFloat
    var topRadius: CGFloat
    var bottomRadius: CGFloat

    var animatableData: AnimatablePair<CGFloat, AnimatablePair<CGFloat, CGFloat>> {
        get { AnimatablePair(shoulder, AnimatablePair(topRadius, bottomRadius)) }
        set {
            shoulder = newValue.first
            topRadius = newValue.second.first
            bottomRadius = newValue.second.second
        }
    }

    func path(in rect: CGRect) -> Path {
        let w = rect.width
        let h = rect.height
        // Batasi agar bentuk tetap sah saat sangat kecil (mis. animasi muncul pertama kali).
        let s = max(0, min(shoulder, h, w / 4))
        let body = w - s * 2
        let rt = max(0, min(topRadius, h / 2, body / 2))
        let rb = max(0, min(bottomRadius, h - s - rt, body / 2))
        // Konstanta Bézier untuk seperempat lingkaran; (1 - k) = jarak titik kendali dari ujung lengkungan.
        let c: CGFloat = 1 - 0.5523
        let x0 = rect.minX + s
        let x1 = rect.maxX - s
        let top = rect.minY
        let bottom = rect.maxY

        var path = Path()
        // Kiri atas: bahu cekung (island) atau sudut membulat (pill); di antaranya bercampur saat beranimasi.
        path.move(to: CGPoint(x: x0 + rt - s, y: top))
        path.addCurve(to: CGPoint(x: x0, y: top + s + rt),
                      control1: CGPoint(x: x0 + (rt - s) * c, y: top),
                      control2: CGPoint(x: x0, y: top + (s + rt) * c))
        // Sisi kiri lalu kiri bawah.
        path.addLine(to: CGPoint(x: x0, y: bottom - rb))
        path.addCurve(to: CGPoint(x: x0 + rb, y: bottom),
                      control1: CGPoint(x: x0, y: bottom - rb * c),
                      control2: CGPoint(x: x0 + rb * c, y: bottom))
        // Bawah lalu kanan bawah.
        path.addLine(to: CGPoint(x: x1 - rb, y: bottom))
        path.addCurve(to: CGPoint(x: x1, y: bottom - rb),
                      control1: CGPoint(x: x1 - rb * c, y: bottom),
                      control2: CGPoint(x: x1, y: bottom - rb * c))
        // Sisi kanan lalu kanan atas (cermin kiri atas).
        path.addLine(to: CGPoint(x: x1, y: top + s + rt))
        path.addCurve(to: CGPoint(x: x1 - rt + s, y: top),
                      control1: CGPoint(x: x1, y: top + (s + rt) * c),
                      control2: CGPoint(x: x1 - (rt - s) * c, y: top))
        path.closeSubpath()
        return path
    }
}

// MARK: - Ikon

/// Logo aplikasi: bola bergradien biru-cyan-tosca dengan gelombang suara. Statis (tanpa biaya animasi);
/// saat disorot memantul, sedikit miring, dan gelombangnya "menyala" sekali.
private struct BrandMark: View {
    let size: CGFloat
    let active: Bool

    var body: some View {
        Image(systemName: "waveform")
            .font(.system(size: size * 0.5, weight: .bold))
            .foregroundStyle(Palette.navy)
            .symbolEffect(.bounce, value: active)
            .frame(width: size, height: size)
            .background(Circle().fill(Palette.brand))
            .rotationEffect(.degrees(active ? -12 : 0))
            .scaleEffect(active ? 1.12 : 1)
            .animation(Liquid.pop, value: active)
    }
}

/// Ikon rekam di tombol Mulai: cincin putih dengan inti, seperti tombol rana kamera.
private struct RecordGlyph: View {
    var body: some View {
        ZStack {
            Circle().strokeBorder(Color.white, lineWidth: 1.5)
            Circle().fill(Color.white).padding(3.5)
        }
        .frame(width: 14, height: 14)
        .accessibilityHidden(true)
    }
}

/// Kartu kaca tempat transkrip live: latar sangat tipis dengan tepi terang di atas.
private struct CaptionCard: View {
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        shape
            .fill(Palette.card)
            .overlay(shape.strokeBorder(Palette.rim, lineWidth: 0.75))
    }
}

/// Riak lembut yang terus memancar dari belakang tombol Mulai (hanya selama panel Siap terbuka).
/// Yang beranimasi hanya skala dan opacity.
private struct PulseHalo: View {
    @State private var on = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Capsule()
            .fill(Palette.blue.opacity(0.5))
            .scaleEffect(x: on ? 1.22 : 1, y: on ? 1.5 : 1)
            .opacity(on ? 0 : 0.7)
            .allowsHitTesting(false)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeOut(duration: 1.8).repeatForever(autoreverses: false)) { on = true }
            }
    }
}

/// Kilau putih yang menyapu tombol sekali saat muncul.
private struct Sheen: View {
    @State private var swept = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        LinearGradient(colors: [.clear, Color.white.opacity(0.5), .clear], startPoint: .leading, endPoint: .trailing)
            .frame(width: 34)
            .rotationEffect(.degrees(18))
            .offset(x: swept ? 90 : -90)
            .allowsHitTesting(false)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 0.9).delay(0.45)) { swept = true }
            }
    }
}

/// Lencana centang yang "tergambar" lalu memancarkan satu riak saat MoM siap (animasi sekali jalan).
private struct CheckBadge: View {
    @State private var drawn = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Circle()
                .stroke(Palette.mint, lineWidth: 2)
                .scaleEffect(drawn ? 2.2 : 1)
                .opacity(drawn ? 0 : 0.8)
            Circle().fill(Palette.done)
                .scaleEffect(drawn ? 1 : 0.4)
            CheckShape()
                .trim(from: 0, to: drawn ? 1 : 0)
                .stroke(Color.black, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                .padding(4)
        }
        .frame(width: 16, height: 16)
        .onAppear {
            if reduceMotion {
                drawn = true
            } else {
                withAnimation(.spring(duration: 0.6, bounce: 0.45).delay(0.12)) { drawn = true }
            }
        }
    }
}

private struct CheckShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.38, y: rect.maxY - rect.height * 0.1))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + rect.height * 0.1))
        return path
    }
}

/// Konfeti kecil berwarna yang menyembur sekali dari lencana saat MoM siap (±1 detik, lalu diam).
private struct Confetti: View {
    @State private var burst = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private struct Piece: Identifiable {
        let id: Int
        let angle: Double
        let distance: Double
        let spin: Double
    }

    private static let pieces: [Piece] = (0..<14).map(makePiece)

    /// Dipecah per langkah bertipe jelas: dalam satu ekspresi, pemeriksa tipe Swift kehabisan waktu.
    private static func makePiece(_ i: Int) -> Piece {
        let index = Double(i)
        let angle: Double = index / 14 * 360 + Double(i % 3) * 9
        let distance: Double = Double(26 + (i * 7) % 22)
        let spin: Double = Double((i * 53) % 270) - 135
        return Piece(id: i, angle: angle, distance: distance, spin: spin)
    }

    var body: some View {
        ZStack {
            ForEach(Self.pieces) { piece in
                let i = piece.id
                let radians = piece.angle * .pi / 180
                RoundedRectangle(cornerRadius: 1)
                    .fill(Palette.confetti[i % Palette.confetti.count])
                    .frame(width: i % 2 == 0 ? 3 : 5, height: i % 2 == 0 ? 6 : 3)
                    .rotationEffect(.degrees(burst ? piece.spin : 0))
                    .offset(x: burst ? CGFloat(cos(radians) * piece.distance) : 0,
                            y: burst ? CGFloat(sin(radians) * piece.distance * 0.6 + 6) : 0)
                    .opacity(burst ? 0 : 1)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeOut(duration: 1.0).delay(0.2)) { burst = true }
        }
    }
}

/// Riak sekali jalan setiap kali `trigger` berubah (mis. tombol Penting ditekan).
private struct Burst: View {
    let trigger: Int
    let color: Color

    var body: some View {
        Circle()
            .stroke(color, lineWidth: 1.5)
            .frame(width: 18, height: 18)
            .phaseAnimator([0, 1, 2], trigger: trigger) { ring, phase in
                ring
                    .scaleEffect(phase == 2 ? 2.4 : 0.6)
                    .opacity(phase == 1 ? 1 : 0)
            } animation: { phase in
                switch phase {
                case 1: return .easeOut(duration: 0.06)
                case 2: return .easeOut(duration: 0.45)
                default: return .linear(duration: 0)
                }
            }
            .allowsHitTesting(false)
    }
}

/// Tiga titik "sedang menulis" saat Claude menyusun MoM. Kecil dan hanya selama memproses.
private struct TypingDots: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<3, id: \.self) { i in
                Circle()
                    .fill(Palette.muted)
                    .frame(width: 4, height: 4)
                    .phaseAnimator([false, true]) { dot, up in
                        dot.offset(y: up && !reduceMotion ? -3 : 0)
                    } animation: { _ in
                        .easeInOut(duration: 0.4).delay(Double(i) * 0.13)
                    }
            }
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Cahaya dan progres

/// Cahaya lembut dari tepi atas pulau. Gradien statis; kekuatan diatur lewat opacity lapisan (murah).
private struct Glow: View {
    let color: Color
    let strength: Double
    var center: UnitPoint = .top
    var radius: CGFloat = 240

    var body: some View {
        RadialGradient(colors: [color, .clear], center: center, startRadius: 0, endRadius: radius)
            .opacity(strength)
            .animation(.easeOut(duration: 0.4), value: strength)
            .allowsHitTesting(false)
    }
}

/// Cahaya biru-cyan yang menguat saat ada suara (lewat opacity, tanpa menggambar ulang gradien).
private struct LevelGlow: View {
    @ObservedObject var audio: AudioLevels

    var body: some View {
        RadialGradient(colors: [Palette.blue, Palette.cyan.opacity(0.25), .clear],
                       center: .top, startRadius: 0, endRadius: 260)
            .opacity(0.22 + Double(audio.level) * 0.45)
            .animation(.easeOut(duration: 0.18), value: audio.level)
            .allowsHitTesting(false)
    }
}

/// Garis tepi bergradien biru-cyan-tosca-mint saat Claude memproses ("AI sedang bekerja"). Gradiennya statis;
/// yang beranimasi hanya opacity lapisannya, sehingga GPU tidak perlu menggambar ulang gradien tiap frame.
private struct Aura: View {
    let shape: IslandShape
    @State private var bright = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        shape
            .stroke(LinearGradient(colors: [Palette.blue, Palette.cyan, Palette.teal, Palette.mint],
                                   startPoint: .leading, endPoint: .trailing), lineWidth: 1.5)
            .opacity(bright ? 1 : 0.45)
            .allowsHitTesting(false)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) { bright = true }
            }
    }
}

/// Garis progres tipis bergradien dengan "kepala" bercahaya yang mengisi dengan pegas lembut.
private struct ProgressBar: View {
    let fraction: Double

    var body: some View {
        GeometryReader { geo in
            let width = max(8, geo.size.width * fraction)
            ZStack(alignment: .leading) {
                Capsule().fill(Palette.chip)
                Capsule()
                    .fill(Palette.process)
                    .frame(width: width)
                Circle()
                    .fill(Color.white)
                    .frame(width: 6, height: 6)
                    .offset(x: width - 6)
            }
        }
        .frame(height: 6)
        .animation(.spring(duration: 0.6, bounce: 0.15), value: fraction)
        .accessibilityElement()
        .accessibilityLabel("Progres")
        .accessibilityValue("\(Int(fraction * 100)) persen")
    }
}

// MARK: - Komponen kecil yang mengamati data cepat
// Masing-masing hanya mengamati satu objek (jam, level suara, atau teks live), sehingga hanya komponen itu yang
// digambar ulang saat datanya berubah.

private func timeString(_ seconds: TimeInterval) -> String {
    let total = Int(seconds)
    let (h, m, s) = (total / 3600, total % 3600 / 60, total % 60)
    return h > 0 ? String(format: "%02d:%02d:%02d", h, m, s) : String(format: "%02d:%02d", m, s)
}

private struct ElapsedText: View {
    @ObservedObject var clock: RecordingClock
    let size: CGFloat

    var body: some View {
        Text(timeString(clock.elapsed))
            .font(Typo.number(size))
            .contentTransition(.numericText())
            .animation(.snappy(duration: 0.25), value: Int(clock.elapsed))
    }
}

/// Transkrip live. Selalu menampilkan kata-kata TERBARU: teks lama dipotong di depan (bukan di belakang),
/// sehingga ucapan terakhir tidak pernah terpotong di kanan. Kata yang masih dikenali (bisa berubah) tampil
/// dengan gradien cyan-mint, lalu berubah putih begitu final.
private struct LiveText: View {
    @ObservedObject var caption: LiveCaption

    /// Kira-kira muat 3 baris pada lebar pulau dengan huruf 15 pt.
    private static let maxCharacters = 150

    var body: some View {
        Group {
            if caption.committed.isEmpty && caption.partial.isEmpty {
                Text("Mendengarkan…").foregroundStyle(Palette.muted)
            } else {
                let partial = caption.partial
                let committed = Self.tail(caption.committed, max(0, Self.maxCharacters - partial.count))
                let gap = committed.isEmpty || partial.isEmpty ? "" : " "
                let head: Text = Text(committed).foregroundStyle(Palette.secondary)
                let newest: Text = Text(Self.tail(partial, Self.maxCharacters)).foregroundStyle(Palette.partial)
                head + Text(gap) + newest
            }
        }
        .font(Typo.live)
        .lineSpacing(2)
        .lineLimit(3)
        .truncationMode(.head)
        .frame(maxWidth: .infinity, alignment: .bottomLeading)
        .frame(height: 62, alignment: .bottomLeading)
        .animation(.easeOut(duration: 0.12), value: caption.partial)
    }

    /// Bagian akhir teks (maksimal `limit` karakter), dipotong di batas kata dan diawali "…".
    static func tail(_ text: String, _ limit: Int) -> String {
        guard text.count > limit else { return text }
        let suffix = text.suffix(limit)
        let start = suffix.firstIndex(of: " ").map { suffix.index(after: $0) } ?? suffix.startIndex
        return "…" + suffix[start...]
    }
}

/// Equalizer 5 batang warna-warni yang mengikuti level suara. Hanya bergerak saat level berubah (bukan animasi
/// per frame), dengan pegas sehingga gerakannya tetap mulus. Saat hening, batang turun dan meredup.
private struct EqualizerBars: View {
    @ObservedObject var audio: AudioLevels
    let height: CGFloat

    private static let bars: [LevelBars.Bar] = [
        .init(id: 0, weight: 0.55, color: Palette.blue),
        .init(id: 1, weight: 0.9, color: Palette.cyan),
        .init(id: 2, weight: 1.0, color: Palette.teal),
        .init(id: 3, weight: 0.8, color: Palette.mint),
        .init(id: 4, weight: 0.6, color: Palette.cyan),
    ]

    var body: some View {
        LevelBars(level: Double(audio.level), bars: Self.bars, height: height, width: 3)
    }
}

/// Batang-batang level suara. Hanya bergerak saat level berubah (bukan animasi per frame), dengan pegas
/// sehingga gerakannya tetap mulus. Saat hening, batang turun dan meredup. Hanya menerima nilai (bukan objek),
/// jadi ikut digambar ulang hanya bila levelnya berubah.
private struct LevelBars: View {
    struct Bar: Identifiable {
        let id: Int
        let weight: Double
        let color: Color
    }

    let level: Double
    let bars: [Bar]
    let height: CGFloat
    let width: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let clamped = min(max(level, 0), 1)
        // Variasi per batang diturunkan dari level itu sendiri, jadi setiap update terlihat "hidup" tanpa timer.
        let seed = clamped * 41
        HStack(alignment: .center, spacing: width * 0.8) {
            ForEach(bars) { bar in
                let wobble = 0.65 + 0.35 * abs(sin(seed + Double(bar.id) * 1.7))
                let fraction = clamped < 0.04 ? 0.18 : min(1, 0.25 + clamped * 1.4 * bar.weight * wobble)
                Capsule()
                    .fill(bar.color)
                    .frame(width: width, height: max(width, height * fraction))
            }
        }
        .frame(height: height)
        .opacity(clamped < 0.04 ? 0.5 : 1)
        .animation(reduceMotion ? nil : .spring(duration: 0.25, bounce: 0.35), value: clamped)
        .accessibilityHidden(true)
    }
}

/// Chip satu jalur suara (mic atau audio meeting): ikon + batang level. Menyala dengan warnanya saat ada
/// suara, redup saat hening.
private struct SourceChip: View {
    enum Source {
        case mic, meeting

        var icon: String { self == .mic ? "mic.fill" : "person.2.fill" }
        var color: Color { self == .mic ? Palette.micSource : Palette.meetingSource }
        var help: String {
            self == .mic ? "Suaramu (mikrofon)" : "Suara peserta online (Zoom/Meet/Teams)"
        }
    }

    @ObservedObject var audio: AudioLevels
    let source: Source

    var body: some View {
        let level = Double(source == .mic ? audio.mic : audio.system)
        let active = level >= 0.04
        let color = source.color
        HStack(spacing: 4) {
            Image(systemName: source.icon)
                .font(.system(size: 9, weight: .semibold))
            LevelBars(level: level, bars: [
                .init(id: 0, weight: 0.7, color: color),
                .init(id: 1, weight: 1.0, color: color),
                .init(id: 2, weight: 0.8, color: color),
            ], height: 10, width: 2)
        }
        .foregroundStyle(active ? color : Palette.muted)
        .padding(.horizontal, 8)
        .frame(height: 22)
        .background(Capsule().fill(color.opacity(active ? 0.2 : 0.07)))
        .animation(.easeOut(duration: 0.2), value: active)
        .help(source.help)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(source.help)
        .accessibilityValue(active ? "ada suara" : "hening")
    }
}

/// Titik merah yang berdenyut pelan selama merekam (efek simbol sistem, tanpa animasi per frame).
private struct RecordingDot: View {
    var body: some View {
        Image(systemName: "circle.fill")
            .font(.system(size: 8))
            .foregroundStyle(Palette.red)
            .symbolEffect(.pulse, options: .repeating)
            .accessibilityHidden(true)
    }
}

/// Tombol yang sedikit mengecil saat ditekan, lalu memantul kembali.
private struct PressableStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.92 : 1)
            .brightness(configuration.isPressed ? -0.06 : 0)
            .animation(Liquid.press, value: configuration.isPressed)
    }
}

/// Tombol sedikit "terangkat" dan lebih terang saat kursor di atasnya (transform + brightness, murah).
private struct HoverLift: ViewModifier {
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .scaleEffect(hovering ? 1.05 : 1)
            .brightness(hovering ? 0.06 : 0)
            .animation(Liquid.hover, value: hovering)
            .onHover { hovering = $0 }
    }
}

/// Elemen muncul bertahap (sedikit naik + memudar masuk) dengan jeda berbeda, sehingga isi pulau terasa
/// "tersusun" alih-alih muncul sekaligus. Sekali jalan setiap isi pulau berganti.
private struct Entrance: ViewModifier {
    let delay: Double
    @State private var shown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .offset(y: shown ? 0 : 6)
            .onAppear {
                if reduceMotion {
                    shown = true
                } else {
                    withAnimation(.spring(duration: 0.45, bounce: 0.25).delay(delay)) { shown = true }
                }
            }
    }
}

private extension View {
    func hoverLift() -> some View { modifier(HoverLift()) }
    func entrance(_ delay: Double) -> some View { modifier(Entrance(delay: delay)) }
}
