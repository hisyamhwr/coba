import SwiftUI

private enum Palette {
    static let red = Color(red: 1.0, green: 0.27, blue: 0.23)
    static let orange = Color(red: 1.0, green: 0.62, blue: 0.04)
    static let green = Color(red: 0.19, green: 0.82, blue: 0.35)
    static let mint = Color(red: 0.4, green: 0.83, blue: 0.81)
    static let blue = Color(red: 0.04, green: 0.52, blue: 1.0)
    static let purple = Color(red: 0.75, green: 0.35, blue: 0.95)
    static let chip = Color.white.opacity(0.12)
    static let muted = Color.white.opacity(0.55)

    static let record = LinearGradient(colors: [red, orange], startPoint: .leading, endPoint: .trailing)
    static let process = LinearGradient(colors: [blue, purple], startPoint: .leading, endPoint: .trailing)
    static let done = LinearGradient(colors: [green, mint], startPoint: .leading, endPoint: .trailing)
}

/// Kurva animasi ala Dynamic Island: pegas cepat yang sedikit memantul sehingga bentuknya terasa "cair".
enum Liquid {
    static let morph = Animation.spring(response: 0.38, dampingFraction: 0.78)
    static let appear = Animation.spring(response: 0.55, dampingFraction: 0.68)
    static let hover = Animation.spring(response: 0.28, dampingFraction: 0.75)
    static let press = Animation.spring(response: 0.2, dampingFraction: 0.65)
    /// Isi baru muncul sedikit setelah bentuk mulai melebar; isi lama hilang cepat.
    static let contentIn = Animation.easeOut(duration: 0.2).delay(0.07)
    static let contentOut = Animation.easeIn(duration: 0.08)
}

/// "Pulau" ala Dynamic Island. Gaya mengikuti docs/design-references: kartu hitam dengan cahaya warna sesuai
/// status, satu hal utama yang besar (timer, transkrip live, judul rapat), dan tombol kapsul. Teks pelengkap
/// (versi, shortcut, nama mic) sengaja tidak ditampilkan; semuanya tetap ada di menu bar.
///
/// Jendelanya berukuran tetap (IslandPanel.canvas); yang beranimasi hanya bentuk hitam di dalamnya. Isi pulau
/// disusun sekali pada ukuran akhirnya (tidak ikut menyusut/melebar tiap frame) lalu cukup dipotong oleh
/// bentuk yang beranimasi, jadi setiap frame animasi murah.
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
            glow
            content
                .id(contentKey)
                .transition(.asymmetric(
                    insertion: .opacity.combined(with: .scale(scale: 0.94, anchor: .top))
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
        .overlay(shape.stroke(Color.white.opacity(state.isCompact ? 0 : 0.08), lineWidth: 1))
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
            Glow(color: Palette.red, strength: state.expanded ? 0.35 : 0)
        case .recording:
            LevelGlow(meter: meter, compact: !state.expanded)
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
                Image(systemName: "waveform")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Palette.record)
            }
            Text(state.starting ? "Menyiapkan" : "Catat rapat")
                .font(.system(size: 12, weight: .semibold, design: .rounded))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .onTapGesture(perform: expand)
    }

    private var idleExpanded: some View {
        VStack(spacing: 12) {
            Button { controller.start() } label: {
                HStack(spacing: 8) {
                    if state.starting {
                        ProgressView().controlSize(.small).tint(.white)
                    } else {
                        Image(systemName: "record.circle.fill").font(.system(size: 18, weight: .bold))
                    }
                    Text(state.starting ? "Menyiapkan…" : "Mulai catat")
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                }
                .frame(maxWidth: .infinity)
                .frame(height: 46)
                .background(Capsule().fill(Palette.record))
                .shadow(color: Palette.red.opacity(0.45), radius: 12, y: 2)
            }
            .buttonStyle(PressableStyle())
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
            }
            Waveform(meter: meter)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .onTapGesture(perform: expand)
    }

    private var recordingExpanded: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                RecordingDot()
                ElapsedText(meter: meter, size: 15)
                Spacer()
                Waveform(meter: meter)
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
                    withAnimation(Liquid.press) { controller.markImportant() }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: state.marks.isEmpty ? "star" : "star.fill")
                            .symbolEffect(.bounce, value: state.marks.count)
                        Text("Penting")
                        if !state.marks.isEmpty {
                            Text("\(state.marks.count)")
                                .font(.system(size: 11, weight: .bold, design: .rounded))
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
                Button(action: controller.stop) {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 14, weight: .bold))
                        .frame(width: 38, height: 38)
                        .background(Circle().fill(Palette.record))
                        .shadow(color: Palette.red.opacity(0.5), radius: 10)
                }
                .buttonStyle(PressableStyle())
                .help("Selesai & susun MoM")
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
                    .symbolEffect(.variableColor.iterative, options: .repeating)
                Text(state.step == 0 ? "Mentranskrip" : "Menyusun MoM")
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                Spacer()
                if state.step == 0, let percent = stepPercent {
                    Text("\(percent)%")
                        .font(.system(size: 15, weight: .bold, design: .rounded).monospacedDigit())
                        .foregroundStyle(Palette.muted)
                        .contentTransition(.numericText())
                        .animation(.snappy, value: percent)
                }
            }
            ProgressBar(fraction: progressFraction)
        }
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
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Palette.done)
                    .symbolEffect(.bounce, value: state.phase)
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

// MARK: - Cahaya dan progres

/// Cahaya lembut dari tepi atas pulau. Gradien statis: digambar sekali, murah.
private struct Glow: View {
    let color: Color
    let strength: Double

    var body: some View {
        RadialGradient(colors: [color.opacity(strength), .clear], center: .top, startRadius: 0, endRadius: 240)
            .animation(.easeOut(duration: 0.4), value: strength)
            .allowsHitTesting(false)
    }
}

/// Cahaya merah-oranye yang menguat saat ada suara. Level suara hanya dikirim bila berubah cukup terlihat,
/// jadi cahaya ini jarang digambar ulang.
private struct LevelGlow: View {
    @ObservedObject var meter: LiveMeter
    let compact: Bool

    var body: some View {
        let level = Double(meter.level)
        RadialGradient(
            colors: [Palette.red.opacity(compact ? 0.18 + level * 0.3 : 0.25 + level * 0.45),
                     Palette.orange.opacity(compact ? 0.05 : 0.12), .clear],
            center: compact ? .leading : .top, startRadius: 0, endRadius: compact ? 140 : 260
        )
        .animation(.easeOut(duration: 0.18), value: meter.level)
        .allowsHitTesting(false)
    }
}

/// Garis progres tipis bergradien; bagian yang sedang dikerjakan berdenyut pelan.
private struct ProgressBar: View {
    let fraction: Double
    @State private var pulse = false

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Palette.chip)
                Capsule()
                    .fill(Palette.process)
                    .frame(width: max(8, geo.size.width * fraction))
                    .opacity(pulse ? 1 : 0.7)
            }
        }
        .frame(height: 6)
        .animation(.spring(response: 0.5, dampingFraction: 0.85), value: fraction)
        .onAppear {
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { pulse = true }
        }
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
            .foregroundStyle(meter.liveText.isEmpty ? Palette.muted : .white)
            .lineLimit(3)
            .frame(maxWidth: .infinity, alignment: .bottomLeading)
            .frame(height: 66, alignment: .bottomLeading)
            .mask(LinearGradient(stops: [.init(color: .black.opacity(0.25), location: 0),
                                         .init(color: .black, location: 0.45)],
                                 startPoint: .top, endPoint: .bottom))
    }
}

/// Gelombang suara memakai efek simbol bawaan macOS yang dirender sistem, jauh lebih ringan daripada
/// menggambar batang sendiri tiap frame. Aktif saat ada suara, redup saat hening.
private struct Waveform: View {
    @ObservedObject var meter: LiveMeter

    var body: some View {
        Image(systemName: "waveform")
            .font(.system(size: 16, weight: .bold))
            .foregroundStyle(Palette.record)
            .symbolEffect(.variableColor.iterative.dimInactiveLayers, options: .repeating,
                          isActive: meter.level > 0.04)
            .opacity(meter.level > 0.04 ? 1 : 0.45)
            .animation(.easeOut(duration: 0.2), value: meter.level > 0.04)
    }
}

/// Titik merah yang berdenyut pelan selama merekam (efek simbol sistem, tanpa animasi per frame).
private struct RecordingDot: View {
    var body: some View {
        Image(systemName: "circle.fill")
            .font(.system(size: 8))
            .foregroundStyle(Palette.red)
            .shadow(color: Palette.red, radius: 4)
            .symbolEffect(.pulse, options: .repeating)
    }
}

/// Tombol yang sedikit mengecil saat ditekan, lalu memantul kembali.
private struct PressableStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.92 : 1)
            .animation(Liquid.press, value: configuration.isPressed)
    }
}
