import SwiftUI

private enum Palette {
    static let red = Color(red: 1.0, green: 0.27, blue: 0.23)
    static let orange = Color(red: 1.0, green: 0.62, blue: 0.04)
    static let green = Color(red: 0.19, green: 0.82, blue: 0.35)
    static let blue = Color(red: 0.25, green: 0.56, blue: 1.0)
    static let chip = Color.white.opacity(0.12)
    static let muted = Color.white.opacity(0.6)
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

/// "Pulau" ala Dynamic Island. Gaya mengikuti docs/design-references.
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
        state.isCompact ? size.height / 2 : 28
    }

    private var island: some View {
        let shape = UnevenRoundedRectangle(
            topLeadingRadius: 0, bottomLeadingRadius: radius,
            bottomTrailingRadius: radius, topTrailingRadius: 0, style: .continuous
        )
        let target = state.islandSize
        return ZStack(alignment: .top) {
            shape.fill(Color.black)
            content
                .id(contentKey)
                .transition(.asymmetric(
                    insertion: .opacity.combined(with: .scale(scale: 0.94, anchor: .top))
                        .animation(Liquid.contentIn),
                    removal: .opacity.animation(Liquid.contentOut)
                ))
                .padding(.horizontal, 16)
                .padding(.vertical, state.isCompact ? 0 : 12)
                // Ukuran akhir, bukan ukuran yang sedang beranimasi: isi tidak disusun ulang tiap frame.
                .frame(width: target.width, height: target.height)
                .opacity(appeared ? 1 : 0)
        }
        .frame(width: size.width, height: size.height, alignment: .top)
        .clipShape(shape)
        .scaleEffect(pressed ? 0.96 : 1, anchor: .top)
        .foregroundStyle(.white)
        .contentShape(shape)
        .onHover { inside in
            withAnimation(Liquid.hover) { hovering = inside }
        }
        .animation(Liquid.morph, value: target)
    }

    /// Kunci isi pulau; bila berubah, isi lama memudar-blur dan isi baru muncul.
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
        HStack(spacing: 8) {
            Image(systemName: "mic.fill").foregroundStyle(Palette.green)
            Text("Meeting Notes").font(.system(size: 12, weight: .semibold))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .onTapGesture(perform: expand)
    }

    private var idleExpanded: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Meeting Notes", systemImage: "mic.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Palette.green)
                Spacer()
                Text("v\(Config.version)").font(.system(size: 11)).foregroundStyle(Palette.muted)
                closeButton(action: collapse)
            }
            HStack(spacing: 8) {
                chip("Mulai Catat", icon: "record.circle", color: Palette.green, filled: true) { controller.start() }
                chip("Folder", icon: "folder") { controller.openFolder() }
            }
            Toggle("Buat juga Word (.docx)", isOn: $state.exportDocx)
                .toggleStyle(.checkbox)
                .font(.system(size: 12))
            Text("Shortcut: ⌃⌥M").font(.system(size: 11)).foregroundStyle(Palette.muted)
        }
    }

    // MARK: Merekam

    private var recordingCompact: some View {
        HStack(spacing: 10) {
            RecordingDot()
            ElapsedText(meter: meter, size: 13)
            Spacer()
            if !state.marks.isEmpty {
                Label("\(state.marks.count)", systemImage: "star.fill")
                    .font(.system(size: 11, weight: .semibold)).foregroundStyle(Palette.orange)
            }
            Waveform(meter: meter)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .onTapGesture(perform: expand)
    }

    private var recordingExpanded: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                RecordingDot()
                ElapsedText(meter: meter, size: 22)
                Text(state.micName).font(.system(size: 11)).foregroundStyle(Palette.muted).lineLimit(1)
                Spacer()
                Waveform(meter: meter)
                closeButton(systemImage: "chevron.up", action: collapse)
            }
            LiveText(meter: meter)
            HStack(spacing: 8) {
                chip(state.marks.isEmpty ? "Tandai penting" : "Tandai penting (\(state.marks.count))",
                     icon: "star.fill", color: Palette.orange) {
                    withAnimation(Liquid.press) { controller.markImportant() }
                }
                if let warning = state.warning {
                    Text(warning).font(.system(size: 10)).foregroundStyle(Palette.muted).lineLimit(2)
                }
                Spacer()
                Button(action: controller.stop) {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 14, weight: .bold))
                        .frame(width: 34, height: 34)
                        .background(Circle().fill(Palette.orange))
                }
                .buttonStyle(PressableStyle())
                .help("Selesai & susun MoM (⌃⌥M)")
            }
        }
    }

    // MARK: Memproses

    private var processing: some View {
        let steps = ["Mentranskrip", "Mengoreksi", "Menyusun MoM"]
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small).tint(.white)
                Text("Memproses rapat").font(.system(size: 14, weight: .semibold))
                ElapsedText(meter: meter, size: 14).foregroundStyle(Palette.muted)
            }
            HStack(spacing: 6) {
                ForEach(steps.indices, id: \.self) { i in
                    VStack(alignment: .leading, spacing: 4) {
                        Capsule().fill(stepColor(i)).frame(height: 4)
                        Text(steps[i]).font(.system(size: 10, weight: .medium))
                            .foregroundStyle(i <= stepIndex ? .white : Palette.muted)
                    }
                }
            }
            .animation(Liquid.morph, value: state.step)
            Text(state.stepDetail).font(.system(size: 11)).foregroundStyle(Palette.muted).lineLimit(1)
        }
    }

    /// Langkah "Mengoreksi" dan "Menyusun MoM" dikerjakan Claude dalam satu proses.
    private var stepIndex: Int { state.step == 0 ? 0 : (state.step == 1 ? 2 : 3) }

    private func stepColor(_ i: Int) -> Color {
        i < stepIndex ? Palette.green : (i == stepIndex ? Palette.blue : Palette.chip)
    }

    // MARK: Selesai / gagal

    private var done: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("MoM siap", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(Palette.green)
                Spacer()
                closeButton { controller.dismiss() }
            }
            Text(state.result?.title ?? "Rapat").font(.system(size: 16, weight: .semibold)).lineLimit(1)
            Text("\(state.result?.decisions ?? 0) keputusan · \(state.result?.action_items ?? 0) action item"
                 + (state.marks.isEmpty ? "" : " · \(state.marks.count) momen penting"))
                .font(.system(size: 12)).foregroundStyle(Palette.muted)
            HStack(spacing: 8) {
                chip("Buka MoM", icon: "doc.text", color: Palette.blue, filled: true) { controller.openResult() }
                chip("Salin", icon: "doc.on.doc") { controller.copyResult() }
                chip("Folder", icon: "folder") { controller.openFolder() }
            }
        }
    }

    private var failed: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Gagal memproses", systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(Palette.orange)
                Spacer()
                closeButton { controller.dismiss() }
            }
            Text(state.errorMessage).font(.system(size: 12)).foregroundStyle(Palette.muted).lineLimit(3)
                .textSelection(.enabled)
            HStack(spacing: 8) {
                if state.recordingDir != nil {
                    chip("Proses ulang", icon: "arrow.clockwise", color: Palette.orange, filled: true) {
                        controller.retry()
                    }
                }
                chip("Buka folder rekaman", icon: "folder") { controller.openFolder() }
            }
        }
    }

    // MARK: Komponen

    private func chip(
        _ title: String, icon: String, color: Color = .white, filled: Bool = false, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.system(size: 12, weight: .semibold))
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .foregroundStyle(filled ? .white : color)
                .background(Capsule().fill(filled ? color : Palette.chip))
        }
        .buttonStyle(PressableStyle())
    }

    private func closeButton(systemImage: String = "xmark", action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 10, weight: .bold))
                .frame(width: 22, height: 22)
                .background(Circle().fill(Palette.chip))
        }
        .buttonStyle(PressableStyle())
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
            .font(.system(size: size, weight: size > 16 ? .bold : .semibold, design: .rounded).monospacedDigit())
            .contentTransition(.numericText())
            .animation(.snappy(duration: 0.25), value: Int(meter.elapsed))
    }
}

private struct LiveText: View {
    @ObservedObject var meter: LiveMeter

    var body: some View {
        Text(meter.liveText.isEmpty ? "Mendengarkan…" : meter.liveText)
            .font(.system(size: 15, weight: .medium))
            .lineLimit(3)
            .frame(maxWidth: .infinity, alignment: .bottomLeading)
            .frame(height: 58, alignment: .bottomLeading)
    }
}

/// Gelombang suara memakai efek simbol bawaan macOS yang dirender sistem, jauh lebih ringan daripada
/// menggambar batang sendiri tiap frame. Aktif saat ada suara, redup saat hening.
private struct Waveform: View {
    @ObservedObject var meter: LiveMeter

    var body: some View {
        Image(systemName: "waveform")
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(Palette.red)
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
