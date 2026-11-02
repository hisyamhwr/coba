import AppKit
import SwiftUI

/// Token desain pulau. Gaya: "AI-native dark" ala Dynamic Island. Permukaan hitam pekat agar menyatu dengan
/// notch, satu warna aksen per status supaya status terbaca sekilas, dan teks putih/abu dengan kontras >= 4.5:1.
private enum Palette {
    static let red = Color(red: 1.0, green: 0.27, blue: 0.23)      // #FF453A merekam
    static let orange = Color(red: 1.0, green: 0.62, blue: 0.04)   // #FF9F0A penting, peringatan
    static let green = Color(red: 0.19, green: 0.82, blue: 0.35)   // #30D158 selesai
    static let mint = Color(red: 0.4, green: 0.83, blue: 0.81)     // #66D4CF
    static let blue = Color(red: 0.04, green: 0.52, blue: 1.0)     // #0A84FF memproses
    static let purple = Color(red: 0.75, green: 0.35, blue: 0.95)  // #BF5AF2 memproses (AI)
    static let pink = Color(red: 1.0, green: 0.22, blue: 0.56)     // #FF375F
    static let chip = Color.white.opacity(0.12)
    static let muted = Color.white.opacity(0.55)                   // ±6:1 di atas hitam

    static let record = LinearGradient(colors: [red, orange], startPoint: .leading, endPoint: .trailing)
    static let process = LinearGradient(colors: [blue, purple], startPoint: .leading, endPoint: .trailing)
    static let done = LinearGradient(colors: [green, mint], startPoint: .leading, endPoint: .trailing)
    static let brand = LinearGradient(colors: [pink, red, orange], startPoint: .topLeading, endPoint: .bottomTrailing)
}

/// Kurva animasi ala Dynamic Island: pegas cepat yang sedikit memantul sehingga bentuknya terasa "cair".
enum Liquid {
    static let morph = Animation.spring(duration: 0.42, bounce: 0.22)
    static let appear = Animation.spring(duration: 0.6, bounce: 0.3)
    static let hover = Animation.spring(duration: 0.3, bounce: 0.2)
    static let press = Animation.spring(duration: 0.22, bounce: 0.35)
    /// Isi baru muncul sedikit setelah bentuk mulai melebar; isi lama hilang cepat.
    static let contentIn = Animation.spring(duration: 0.32, bounce: 0.15).delay(0.06)
    static let contentOut = Animation.easeIn(duration: 0.08)
}

/// Getaran halus trackpad saat aksi penting (mulai, tandai, selesai).
private func haptic() {
    NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
}

/// "Pulau" ala Dynamic Island. Gaya mengikuti docs/design-references: kartu hitam dengan cahaya warna sesuai
/// status, satu hal utama yang besar (timer, transkrip live, judul rapat), dan tombol kapsul. Teks pelengkap
/// (versi, shortcut, nama mic) sengaja tidak ditampilkan; semuanya tetap ada di menu bar.
///
/// Prinsip performa:
/// - Jendelanya berukuran tetap (IslandPanel.canvas); yang beranimasi hanya bentuk hitam di dalamnya. Isi pulau
///   disusun sekali pada ukuran akhirnya lalu cukup dipotong oleh bentuk yang beranimasi.
/// - Selama rapat (bisa berjam-jam) tidak ada animasi yang berjalan terus-menerus: gelombang suara dan cahaya
///   hanya bergerak saat level suara berubah. Animasi kontinu (garis cahaya berputar) hanya saat memproses,
///   yang berlangsung singkat, dan dirender lewat GPU.
/// - Semua animasi dekoratif dimatikan bila "Reduce motion" aktif di macOS.
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

    private var radius: CGFloat {
        state.isCompact ? size.height / 2 : 30
    }

    private var island: some View {
        let shape = UnevenRoundedRectangle(
            topLeadingRadius: 0, bottomLeadingRadius: radius,
            bottomTrailingRadius: radius, topTrailingRadius: 0, style: .continuous
        )
        let target = state.islandSize
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
        .frame(width: size.width, height: size.height, alignment: .top)
        .clipShape(shape)
        .overlay {
            if state.phase == .processing {
                Aura(shape: shape)
            } else {
                shape.stroke(Color.white.opacity(state.isCompact ? 0 : 0.08), lineWidth: 1)
            }
        }
        .scaleEffect(pressed ? 0.96 : 1, anchor: .top)
        .foregroundStyle(.white)
        .contentShape(shape)
        .onHover { inside in
            withAnimation(Liquid.hover) { hovering = inside }
        }
        .animation(Liquid.morph, value: target)
    }

    /// Cahaya warna di dalam pulau sesuai status; saat merekam ikut berdenyut mengikuti suara.
    @ViewBuilder
    private var glow: some View {
        switch state.phase {
        case .idle:
            Glow(color: Palette.pink, strength: state.expanded ? 0.35 : (hovering ? 0.22 : 0))
        case .recording:
            if state.expanded {
                LevelGlow(meter: meter)
            } else {
                Glow(color: Palette.red, strength: 0.2, center: .leading, radius: 130)
            }
        case .processing:
            Glow(color: Palette.purple, strength: 0.4)
        case .done:
            Glow(color: Palette.green, strength: 0.4)
        case .failed:
            Glow(color: Palette.orange, strength: 0.35)
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
                BrandMark(size: 18, bounce: hovering)
            }
            Text(state.starting ? "Menyiapkan" : "Catat rapat")
                .font(.system(size: 12, weight: .semibold, design: .rounded))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .onTapGesture(perform: expand)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel("Buka Meeting Notes")
    }

    private var idleExpanded: some View {
        VStack(spacing: 12) {
            Button {
                haptic()
                controller.start()
            } label: {
                HStack(spacing: 10) {
                    if state.starting {
                        ProgressView().controlSize(.small).tint(.white)
                    } else {
                        RecordGlyph()
                    }
                    Text(state.starting ? "Menyiapkan…" : "Mulai catat")
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                }
                .frame(maxWidth: .infinity)
                .frame(height: 46)
                .background(Capsule().fill(Palette.brand))
                .overlay(Capsule().strokeBorder(Color.white.opacity(0.25), lineWidth: 1))
            }
            .buttonStyle(PressableStyle())
            .disabled(state.starting)
            HStack(spacing: 8) {
                toggleChip("Word", icon: "doc.richtext", isOn: $state.exportDocx)
                Spacer()
                iconButton("folder", help: "Buka folder notulen") { controller.openFolder() }
                iconButton("xmark", help: "Tutup", action: collapse)
            }
        }
    }

    // MARK: Merekam

    private var recordingCompact: some View {
        HStack(spacing: 8) {
            RecordingDot()
            ElapsedText(meter: meter, size: 13)
            Spacer()
            if !state.marks.isEmpty {
                Label("\(state.marks.count)", systemImage: "star.fill")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(Palette.orange)
                    .contentTransition(.numericText())
            }
            EqualizerBars(meter: meter, height: 14)
        }
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
                ElapsedText(meter: meter, size: 15)
                Spacer()
                EqualizerBars(meter: meter, height: 18)
                iconButton("chevron.up", help: "Perkecil", action: collapse)
            }
            LiveText(meter: meter)
            if let warning = state.warning {
                Label(warning, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Palette.orange)
                    .lineLimit(2)
            }
            HStack(spacing: 8) {
                Button {
                    haptic()
                    withAnimation(Liquid.press) { controller.markImportant() }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: state.marks.isEmpty ? "star" : "star.fill")
                            .symbolEffect(.bounce, value: state.marks.count)
                            .background(Burst(trigger: state.marks.count, color: Palette.orange))
                        Text("Penting")
                        if !state.marks.isEmpty {
                            Text("\(state.marks.count)")
                                .font(.system(size: 11, weight: .bold, design: .rounded))
                                .contentTransition(.numericText())
                                .padding(.horizontal, 6)
                                .background(Capsule().fill(Palette.orange.opacity(0.3)))
                        }
                    }
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Palette.orange)
                    .padding(.horizontal, 12)
                    .frame(height: 30)
                    .background(Capsule().fill(Palette.chip))
                }
                .buttonStyle(PressableStyle())
                .help("Tandai momen penting")
                Spacer()
                Button {
                    haptic()
                    controller.stop()
                } label: {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 14, weight: .bold))
                        .frame(width: 38, height: 38)
                        .background(Circle().fill(Palette.record))
                        .overlay(Circle().strokeBorder(Color.white.opacity(0.25), lineWidth: 1))
                        .background(Circle().fill(RadialGradient(colors: [Palette.red.opacity(0.5), .clear],
                                                                 center: .center, startRadius: 14, endRadius: 30))
                            .frame(width: 60, height: 60))
                }
                .buttonStyle(PressableStyle())
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
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(Palette.process)
                    .contentTransition(.symbolEffect(.replace))
                    .symbolEffect(.variableColor.iterative, options: .repeating)
                Text(state.step == 0 ? "Mentranskrip" : "Menyusun MoM")
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                    .contentTransition(.opacity)
                Spacer()
                if state.step == 0, let percent = stepPercent {
                    Text("\(percent)%")
                        .font(.system(size: 15, weight: .bold, design: .rounded).monospacedDigit())
                        .foregroundStyle(Palette.muted)
                        .contentTransition(.numericText())
                }
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
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                CheckBadge()
                Text("MoM siap").foregroundStyle(Palette.green)
                Spacer()
                iconButton("xmark", help: "Tutup") { controller.dismiss() }
            }
            .font(.system(size: 12, weight: .bold))
            Text(state.result?.title ?? "Rapat")
                .font(.system(size: 18, weight: .bold, design: .rounded))
                .lineLimit(1)
            HStack(spacing: 6) {
                stat(state.result?.decisions ?? 0, "keputusan", icon: "checkmark.seal.fill", color: Palette.green)
                stat(state.result?.action_items ?? 0, "tugas", icon: "checklist", color: Palette.blue)
                if !state.marks.isEmpty {
                    stat(state.marks.count, nil, icon: "star.fill", color: Palette.orange)
                }
                Spacer()
                iconButton(copied ? "checkmark" : "doc.on.doc", help: "Salin MoM") {
                    controller.copyResult()
                    haptic()
                    withAnimation(Liquid.press) { copied = true }
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 1_500_000_000)
                        withAnimation(Liquid.press) { copied = false }
                    }
                }
                iconButton("folder", help: "Buka folder notulen") { controller.openFolder() }
                primaryButton("Buka MoM", icon: "doc.text.fill", gradient: Palette.done) { controller.openResult() }
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
            .font(.system(size: 12, weight: .bold))
            .foregroundStyle(Palette.orange)
            Text(state.errorMessage)
                .font(.system(size: 12))
                .foregroundStyle(Palette.muted)
                .lineLimit(3)
                .textSelection(.enabled)
            HStack(spacing: 8) {
                Spacer()
                iconButton("folder", help: "Buka folder rekaman") { controller.openFolder() }
                if state.recordingDir != nil {
                    primaryButton("Proses ulang", icon: "arrow.clockwise", gradient: Palette.record) {
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
                .font(.system(size: 12, weight: .bold))
                .padding(.horizontal, 14)
                .frame(height: 30)
                .background(Capsule().fill(gradient))
                .overlay(Capsule().strokeBorder(Color.white.opacity(0.22), lineWidth: 1))
        }
        .buttonStyle(PressableStyle())
    }

    private func iconButton(_ systemImage: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .bold))
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 28, height: 28)
                .background(Circle().fill(Palette.chip))
        }
        .buttonStyle(PressableStyle())
        .help(help)
        .accessibilityLabel(help)
    }

    private func toggleChip(_ title: String, icon: String, isOn: Binding<Bool>) -> some View {
        Button {
            withAnimation(Liquid.press) { isOn.wrappedValue.toggle() }
        } label: {
            Label(title, systemImage: isOn.wrappedValue ? "checkmark.circle.fill" : icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(isOn.wrappedValue ? Palette.blue : Palette.muted)
                .contentTransition(.symbolEffect(.replace))
                .padding(.horizontal, 10)
                .frame(height: 28)
                .background(Capsule().fill(isOn.wrappedValue ? Palette.blue.opacity(0.2) : Palette.chip))
        }
        .buttonStyle(PressableStyle())
        .help("Buat juga file Word (.docx)")
        .accessibilityLabel("Buat juga file Word")
        .accessibilityValue(isOn.wrappedValue ? "aktif" : "nonaktif")
    }

    private func stat(_ value: Int, _ label: String?, icon: String, color: Color) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon).foregroundStyle(color)
            Text("\(value)").font(.system(size: 12, weight: .bold, design: .rounded))
            if let label {
                Text(label).foregroundStyle(Palette.muted)
            }
        }
        .font(.system(size: 11, weight: .medium))
        .padding(.horizontal, 8)
        .frame(height: 24)
        .background(Capsule().fill(Palette.chip))
    }
}

// MARK: - Ikon

/// Logo aplikasi: bola bergradien merah muda-oranye dengan gelombang suara putih. Statis (tanpa biaya
/// animasi); memantul sekali saat kursor masuk.
private struct BrandMark: View {
    let size: CGFloat
    let bounce: Bool

    var body: some View {
        Image(systemName: "waveform")
            .font(.system(size: size * 0.5, weight: .heavy))
            .foregroundStyle(.white)
            .symbolEffect(.bounce, value: bounce)
            .frame(width: size, height: size)
            .background(Circle().fill(Palette.brand))
            .overlay(Circle().strokeBorder(Color.white.opacity(0.3), lineWidth: 0.5))
    }
}

/// Ikon rekam di tombol Mulai: lingkaran putih dengan inti merah, seperti tombol rekam kamera.
private struct RecordGlyph: View {
    var body: some View {
        ZStack {
            Circle().strokeBorder(Color.white, lineWidth: 2.5)
            Circle().fill(Color.white).padding(5)
        }
        .frame(width: 22, height: 22)
    }
}

/// Lencana centang yang "tergambar" lalu memancarkan satu riak saat MoM siap (animasi sekali jalan).
private struct CheckBadge: View {
    @State private var drawn = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Circle()
                .stroke(Palette.green, lineWidth: 2)
                .scaleEffect(drawn ? 2.2 : 1)
                .opacity(drawn ? 0 : 0.8)
            Circle().fill(Palette.done)
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
                withAnimation(.easeOut(duration: 0.55).delay(0.15)) { drawn = true }
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

// MARK: - Cahaya dan progres

/// Cahaya lembut dari tepi atas pulau. Gradien statis: digambar sekali, murah.
private struct Glow: View {
    let color: Color
    let strength: Double
    var center: UnitPoint = .top
    var radius: CGFloat = 240

    var body: some View {
        // Warna gradien tetap; kekuatan diatur lewat opacity lapisan (murah, tanpa menggambar ulang gradien).
        RadialGradient(colors: [color, .clear], center: center, startRadius: 0, endRadius: radius)
            .opacity(strength)
            .animation(.easeOut(duration: 0.4), value: strength)
            .allowsHitTesting(false)
    }
}

/// Cahaya merah-oranye yang menguat saat ada suara. Level suara hanya dikirim bila berubah cukup terlihat,
/// jadi cahaya ini jarang digambar ulang.
private struct LevelGlow: View {
    @ObservedObject var meter: LiveMeter

    var body: some View {
        RadialGradient(colors: [Palette.red, Palette.orange.opacity(0.25), .clear],
                       center: .top, startRadius: 0, endRadius: 260)
            .opacity(0.22 + Double(meter.level) * 0.45)
            .animation(.easeOut(duration: 0.18), value: meter.level)
            .allowsHitTesting(false)
    }
}

/// Garis tepi bergradien biru-ungu-pink saat Claude memproses (gaya "AI sedang bekerja"). Gradiennya statis;
/// yang beranimasi hanya opacity lapisannya, sehingga GPU tidak perlu menggambar ulang gradien tiap frame.
private struct Aura: View {
    let shape: UnevenRoundedRectangle
    @State private var bright = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        shape
            .stroke(LinearGradient(colors: [Palette.blue, Palette.purple, Palette.pink, Palette.orange],
                                   startPoint: .leading, endPoint: .trailing), lineWidth: 1.5)
            .opacity(bright ? 1 : 0.45)
            .allowsHitTesting(false)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) { bright = true }
            }
    }
}

/// Garis progres tipis bergradien yang mengisi dengan pegas lembut.
private struct ProgressBar: View {
    let fraction: Double

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Palette.chip)
                Capsule()
                    .fill(Palette.process)
                    .frame(width: max(8, geo.size.width * fraction))
            }
        }
        .frame(height: 6)
        .animation(.spring(duration: 0.6, bounce: 0.1), value: fraction)
        .accessibilityElement()
        .accessibilityLabel("Progres")
        .accessibilityValue("\(Int(fraction * 100)) persen")
    }
}

// MARK: - Komponen kecil yang mengamati LiveMeter
// Hanya komponen ini yang digambar ulang saat timer, level suara, atau transkrip live berubah.

private func timeString(_ seconds: TimeInterval) -> String {
    let total = Int(seconds)
    let (h, m, s) = (total / 3600, total % 3600 / 60, total % 60)
    return h > 0 ? String(format: "%02d:%02d:%02d", h, m, s) : String(format: "%02d:%02d", m, s)
}

private struct ElapsedText: View {
    @ObservedObject var meter: LiveMeter
    let size: CGFloat

    var body: some View {
        Text(timeString(meter.elapsed))
            .font(.system(size: size, weight: .bold, design: .rounded).monospacedDigit())
            .contentTransition(.numericText())
            .animation(.snappy(duration: 0.25), value: Int(meter.elapsed))
    }
}

/// Transkrip live besar; baris lama memudar ke atas seperti pada referensi.
private struct LiveText: View {
    @ObservedObject var meter: LiveMeter

    var body: some View {
        Text(meter.liveText.isEmpty ? "Mendengarkan…" : meter.liveText)
            .font(.system(size: 17, weight: .semibold, design: .rounded))
            .lineLimit(3)
            .frame(maxWidth: .infinity, alignment: .bottomLeading)
            .frame(height: 66, alignment: .bottomLeading)
            // Gradien langsung di warna teks (bukan mask, yang memaksa render offscreen setiap frame).
            .foregroundStyle(meter.liveText.isEmpty
                ? AnyShapeStyle(Palette.muted)
                : AnyShapeStyle(LinearGradient(stops: [.init(color: .white.opacity(0.3), location: 0),
                                                       .init(color: .white, location: 0.5)],
                                               startPoint: .top, endPoint: .bottom)))
    }
}

/// Equalizer 5 batang bergradien yang mengikuti level suara. Hanya bergerak saat level berubah (bukan animasi
/// per frame), dengan pegas sehingga gerakannya tetap mulus. Saat hening, batang turun dan meredup.
private struct EqualizerBars: View {
    @ObservedObject var meter: LiveMeter
    let height: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let weights: [Double] = [0.55, 0.9, 1.0, 0.8, 0.6]

    var body: some View {
        let level = Double(min(max(meter.level, 0), 1))
        // Variasi per batang diturunkan dari level itu sendiri, jadi setiap update terlihat "hidup" tanpa timer.
        let seed = level * 41
        HStack(alignment: .center, spacing: 2.5) {
            ForEach(Self.weights.indices, id: \.self) { i in
                let wobble = 0.65 + 0.35 * abs(sin(seed + Double(i) * 1.7))
                let fraction = level < 0.04 ? 0.18 : min(1, 0.25 + level * 1.4 * Self.weights[i] * wobble)
                Capsule()
                    .fill(Palette.record)
                    .frame(width: 3, height: max(3, height * fraction))
            }
        }
        .frame(height: height)
        .opacity(level < 0.04 ? 0.5 : 1)
        .animation(reduceMotion ? nil : .spring(duration: 0.25, bounce: 0.3), value: meter.level)
        .accessibilityHidden(true)
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
