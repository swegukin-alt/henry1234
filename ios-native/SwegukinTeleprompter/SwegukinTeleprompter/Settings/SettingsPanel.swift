import SwiftUI

struct SettingsPanel: View {
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.dismiss) private var dismiss

    /// Only the modes the camera actually reported are offered.
    var modes: [CaptureMode] = []

    var body: some View {
        NavigationStack {
            Form {
                Section("Reading") {
                    slider("Font size", value: $settings.fontSize, range: 24...140, step: 1)
                    slider("Speed", value: $settings.speed, range: 10...250, step: 1)
                    slider("Line height", value: $settings.lineHeight, range: 1.0...2.2, step: 0.05)
                    slider("Text width", value: $settings.textWidth, range: 50...100, step: 1)
                    slider("Margins", value: $settings.margin, range: 0...80, step: 1)
                    Stepper("Countdown: \(settings.countdown)s", value: $settings.countdown, in: 0...10)
                    Toggle("Reading highlight", isOn: $settings.readingHighlight)
                    Toggle("Voice follow", isOn: $settings.voiceFollow)
                }

                Section("Mirror") {
                    Toggle("Mirror horizontally", isOn: $settings.mirrorH)
                    Toggle("Flip vertically", isOn: $settings.mirrorV)
                }

                Section("Camera") {
                    Toggle("Front camera", isOn: $settings.useFrontCamera)
                    if modes.isEmpty {
                        Text("Open video mode once to read this iPhone's supported recording modes.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else {
                        Picker("Recording mode", selection: Binding(
                            get: { currentModeID },
                            set: { apply(modeID: $0) }
                        )) {
                            ForEach(modes) { mode in
                                Text(mode.label).tag(mode.id)
                            }
                        }
                    }
                    Toggle("Stabilization", isOn: $settings.stabilization)
                }
            }
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private var currentModeID: String {
        let id = "\(settings.quality)-\(settings.frameRate)-\(settings.hdr ? 1 : 0)"
        return modes.contains { $0.id == id } ? id : (modes.first?.id ?? id)
    }

    private func apply(modeID: String) {
        guard let mode = modes.first(where: { $0.id == modeID }) else { return }
        settings.quality = mode.quality
        settings.frameRate = mode.fps
        settings.hdr = mode.hdr
    }

    private func slider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, step: Double) -> some View {
        VStack(alignment: .leading) {
            HStack {
                Text(title)
                Spacer()
                Text(String(format: step < 1 ? "%.2f" : "%.0f", value.wrappedValue))
                    .foregroundStyle(.secondary)
            }
            Slider(value: value, in: range, step: step)
        }
    }
}
