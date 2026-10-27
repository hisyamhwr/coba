import SwiftUI

private enum Palette {
    static let red = Color(red: 1.0, green: 0.27, blue: 0.23)
    static let orange = Color(red: 1.0, green: 0.62, blue: 0.04)
    static let green = Color(red: 0.19, green: 0.82, blue: 0.35)
    static let blue = Color(red: 0.25, green: 0.56, blue: 1.0)
    static let chip = Color.white.opacity(0.12)
    static let muted = Color.white.opacity(0.6)
}

/// "Pulau" ala Dynamic Island. Gaya mengikuti docs/design-references.
struct IslandView: View {
    @ObservedObject var state: AppState
    let controller: MeetingController

    var body: some View {
        content
            .padding(.horizontal, 16)
            .padding(.vertical, isCompact ? 0 : 12)
            .frame(width: state.panelSize.width, height: state.panelSize.height)
            .background(
                UnevenRoundedRectangle(
                    topLeadingRadius: 0, bottomLeadingRadius: isCompact ? 16 : 26,
                    bottomTrailingRadius: isCompact ? 16 : 26, topTrailingRadius: 0, style: .continuous
                )
                .fill(Color.black)
            )
            .foregroundStyle(.white)
            .animation(.spring(response: 0.35, dampingFraction: 0.85), value: state.phase)
            .animation(.spring(response: 0.35, dampingFraction: 0.85), value: state.expanded)
    }

    private var isCompact: Bool {
        (state.phase == .idle || state.phase == .recording) && !state.expanded
    }

    @ViewBuilder
    private var content: some View {
        switch state.phase {
        case .idle: state.expanded ? AnyView(idleExpanded) : AnyView(idleCompact)
        case .recording: state.expanded ? AnyView(recordingExpanded) : AnyView(recordingCompact)
        case .processing: AnyView(processing)
        case .done: AnyView(done)
        case .failed: AnyView(failed)
        }
    }

    // MARK: Siap

    private var idleCompact: some View {
        HStack(spacing: 8) {
            Image(systemName: "mic.fill").foregroundStyle(Palette.green)
            Text("Meeting Notes").font(.system(size: 12, weight: .semibold))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .onTapGesture { state.expanded = true }
    }

    private var idleExpanded: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Meeting Notes", systemImage: "mic.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Palette.green)
                Spacer()
                Text("v\(Config.version)").font(.system(size: 11)).foregroundStyle(Palette.muted)
                closeButton { state.expanded = false }
            }
            HStack(spacing: 8) {
                chip("Mulai Catat", icon: "record.circle", color: Palette.green, filled: true) { controller.start() }
                chip("Folder", icon: "folder") { controller.openFolder() }
            }
            Text("Shortcut: ⌃⌥M").font(.system(size: 11)).foregroundStyle(Palette.muted)
        }
    }

    // MARK: Merekam

    private var recordingCompact: some View {
        HStack(spacing: 10) {
            Circle().fill(Palette.red).frame(width: 8, height: 8)
            Text(timeString(state.elapsed))
                .font(.system(size: 13, weight: .semibold, design: .rounded).monospacedDigit())
            Spacer()
            if !state.marks.isEmpty {
                Label("\(state.marks.count)", systemImage: "star.fill")
                    .font(.system(size: 11, weight: .semibold)).foregroundStyle(Palette.orange)
            }
            Waveform(level: state.level, tick: state.elapsed)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .onTapGesture { state.expanded = true }
    }

    private var recordingExpanded: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Circle().fill(Palette.red).frame(width: 8, height: 8)
                Text(timeString(state.elapsed))
                    .font(.system(size: 22, weight: .bold, design: .rounded).monospacedDigit())
                Text(state.micName).font(.system(size: 11)).foregroundStyle(Palette.muted).lineLimit(1)
                Spacer()
                Waveform(level: state.level, tick: state.elapsed)
                closeButton(systemImage: "chevron.up") { state.expanded = false }
            }
            Text(state.liveText.isEmpty ? "Mendengarkan…" : state.liveText)
                .font(.system(size: 15, weight: .medium))
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .bottomLeading)
                .frame(height: 58, alignment: .bottomLeading)
            HStack(spacing: 8) {
                chip(state.marks.isEmpty ? "Tandai penting" : "Tandai penting (\(state.marks.count))",
                     icon: "star.fill", color: Palette.orange) { controller.markImportant() }
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
                .buttonStyle(.plain)
                .help("Selesai & susun MoM (⌃⌥M)")
            }
        }
    }

    // MARK: Memproses

    private var processing: some View {
        let steps = ["Mentranskrip", "Mengoreksi", "Menyusun MoM"]
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                ProgressView().controlSize(.small).tint(.white)
                Text("Memproses rapat \(timeString(state.elapsed))").font(.system(size: 14, weight: .semibold))
            }
            HStack(spacing: 6) {
                ForEach(steps.indices, id: \.self) { i in
                    VStack(alignment: .leading, spacing: 4) {
                        Capsule()
                            .fill(stepColor(i))
                            .frame(height: 4)
                        Text(steps[i]).font(.system(size: 10, weight: .medium))
                            .foregroundStyle(i <= stepIndex ? .white : Palette.muted)
                    }
                }
            }
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
            chip("Buka folder rekaman", icon: "folder") { controller.openFolder() }
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
        .buttonStyle(.plain)
    }

    private func closeButton(systemImage: String = "xmark", action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 10, weight: .bold))
                .frame(width: 22, height: 22)
                .background(Circle().fill(Palette.chip))
        }
        .buttonStyle(.plain)
    }

    private func timeString(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        let (h, m, s) = (total / 3600, total % 3600 / 60, total % 60)
        return h > 0 ? String(format: "%02d:%02d:%02d", h, m, s) : String(format: "%02d:%02d", m, s)
    }
}

/// Gelombang suara sederhana: 5 batang yang tingginya mengikuti level audio.
private struct Waveform: View {
    let level: Float
    let tick: TimeInterval
    private let weights: [CGFloat] = [0.5, 0.8, 1.0, 0.7, 0.45]

    var body: some View {
        HStack(spacing: 2) {
            ForEach(weights.indices, id: \.self) { i in
                let wobble = 0.75 + 0.25 * sin(CGFloat(tick) * 3 + CGFloat(i))
                Capsule()
                    .fill(Color(red: 1.0, green: 0.27, blue: 0.23))
                    .frame(width: 3, height: max(3, 16 * CGFloat(level) * weights[i] * wobble))
            }
        }
        .frame(height: 16)
        .animation(.easeOut(duration: 0.15), value: level)
    }
}
