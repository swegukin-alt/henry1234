import SwiftUI

struct SettingsPanel: View {
    @EnvironmentObject private var settings: AppSettings
    @State private var discoveredModes: [CaptureMode] = []
    @State private var cinematicSupported = false
    @State private var appleLogSupported = false
    @State private var apertureRange: ClosedRange<Double> = 1.4...16

    /// Only the modes the camera actually reported are offered.
    var modes: [CaptureMode] = []
    /// Aperture cannot change mid-take.
    var isRecording: Bool = false

    private var cameraModes: [CaptureMode] {
        modes.isEmpty ? discoveredModes : modes
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("SETTINGS")
                .font(.system(size: 13, weight: .medium))
                .tracking(1.5)
                .foregroundStyle(.white.opacity(0.36))

                    slider("Font size", value: $settings.fontSize, range: 24...140, step: 1)
                    slider("Scroll speed", value: $settings.speed, range: 10...250, step: 1)
                    slider("Text width", value: $settings.textWidth, range: 50...100, step: 1)

            HStack(spacing: 8) {
                pill("Mirror ↔", isOn: $settings.mirrorH)
                pill("Mirror ↕", isOn: $settings.mirrorV)
            }

            Text("READING ASSIST")
                .font(.system(size: 13))
                .tracking(1.5)
                .foregroundStyle(.white.opacity(0.36))
            FlowLayout(spacing: 8) {
                pill("Chunk phrases", isOn: $settings.chunking)
                pill("Slow at punctuation", isOn: $settings.pauses)
                pill("Reading highlight", isOn: $settings.readingHighlight)
                pill("Voice-follow", isOn: $settings.voiceFollow)
            }

            HStack(spacing: 4) {
                backgroundButton("Dark", value: "black")
                backgroundButton("Light", value: "white")
                backgroundButton("Sepia", value: "sepia")
            }
            .padding(4)
            .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))

            Button("Reset to defaults") { settings.resetReaderDefaults() }
                .font(.system(size: 14))
                .foregroundStyle(.white.opacity(0.5))
                .frame(maxWidth: .infinity)
                .frame(height: 40)

            if !cameraModes.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("CAMERA").font(.system(size: 13)).tracking(1.5).foregroundStyle(.white.opacity(0.36))
                    Picker("Recording mode", selection: Binding(get: { currentModeID }, set: { apply(modeID: $0) })) {
                        ForEach(cameraModes) { mode in Text(mode.label).tag(mode.id) }
                    }
                    .pickerStyle(.menu)
                    Toggle("Front camera", isOn: $settings.useFrontCamera)
                    Toggle("Stabilization", isOn: $settings.stabilization)

                    Toggle("Cinematic mode", isOn: $settings.cinematicMode)
                        .disabled(isRecording || !cinematicSupported)
                    if !cinematicSupported {
                        Text("Requires Apple's Cinematic capture pipeline.")
                            .font(.system(size: 12))
                            .foregroundStyle(.white.opacity(0.45))
                    } else if settings.cinematicMode {
                        apertureSlider
                    }

                    Toggle("Apple Log", isOn: $settings.appleLog)
                        .disabled(isRecording || !appleLogSupported)
                    if !appleLogSupported {
                        Text("Apple Log not supported on this camera.")
                            .font(.system(size: 12))
                            .foregroundStyle(.white.opacity(0.45))
                    }
                }
                .animation(.easeInOut(duration: 0.2), value: settings.cinematicMode)
            }
        }
        .padding(16)
        .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 16))
        .task(id: settings.useFrontCamera) {
            discoveredModes = CameraManager.availableModes(front: settings.useFrontCamera)
            cinematicSupported = CameraManager.cinematicSupported(front: settings.useFrontCamera)
            appleLogSupported = CameraManager.appleLogSupported(front: settings.useFrontCamera)
            apertureRange = CameraManager.apertureRange(front: settings.useFrontCamera)
            if !cinematicSupported { settings.cinematicMode = false }
            if !appleLogSupported { settings.appleLog = false }
        }

    }

    /// Same slider style as Font size / Scroll speed, with camera f-stop labels.
    private var apertureSlider: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text("Aperture")
                Spacer()
                Text(Format.aperture(settings.simulatedAperture))
                    .foregroundStyle(.secondary)
            }
            Slider(value: $settings.simulatedAperture, in: apertureRange, step: 0.1)
                .tint(.white)
                .disabled(isRecording)
        }
    }

    private var currentModeID: String {
        let id = "\(settings.quality)-\(settings.frameRate)-\(settings.hdr ? 1 : 0)"
        return cameraModes.contains { $0.id == id } ? id : (cameraModes.first?.id ?? id)
    }

    private func apply(modeID: String) {
        guard let mode = cameraModes.first(where: { $0.id == modeID }) else { return }
        settings.quality = mode.quality
        settings.frameRate = mode.fps
        settings.hdr = mode.hdr
    }

    private func slider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, step: Double) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(title)
                Spacer()
                Text(String(format: step < 1 ? "%.2f" : "%.0f", value.wrappedValue))
                    .foregroundStyle(.secondary)
            }
            Slider(value: value, in: range, step: step)
                .tint(.white)
        }
    }

    private func pill(_ title: String, isOn: Binding<Bool>) -> some View {
        Button { isOn.wrappedValue.toggle() } label: {
            Text(title).font(.system(size: 14)).padding(.horizontal, 14).frame(height: 38)
                .foregroundStyle(isOn.wrappedValue ? Color.white : Color.white.opacity(0.72))
                .background(isOn.wrappedValue ? Theme.accent : Color.white.opacity(0.07), in: Capsule())
        }
    }

    private func backgroundButton(_ title: String, value: String) -> some View {
        Button { settings.background = value } label: {
            Text(title).font(.system(size: 14)).frame(maxWidth: .infinity).frame(height: 36)
                .foregroundStyle(settings.background == value ? Color.white : Color.white.opacity(0.55))
                .background(settings.background == value ? Color.white.opacity(0.14) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
        }
    }
}

private struct FlowLayout: Layout {
    var spacing: CGFloat
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 0
        var x: CGFloat = 0; var y: CGFloat = 0; var row: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > width { x = 0; y += row + spacing; row = 0 }
            x += size.width + spacing; row = max(row, size.height)
        }
        return CGSize(width: width, height: y + row)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX; var y = bounds.minY; var row: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX && x + size.width > bounds.maxX { x = bounds.minX; y += row + spacing; row = 0 }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing; row = max(row, size.height)
        }
    }
}
