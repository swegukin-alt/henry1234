import SwiftUI
import CoreMotion
import UIKit

/// Gravity-backed, screen-relative roll for the pre-recording camera level.
/// Core Motion performs the accelerometer/gyroscope fusion; no camera frames or
/// recording objects are involved.
@MainActor
final class HorizonLevelMonitor: ObservableObject {
    @Published private(set) var rollDegrees: Double = 0
    @Published private(set) var isAvailable = false

    private let manager = CMMotionManager()
    private var filteredRoll = 0.0
    private var hasReading = false

    func start() {
        guard !manager.isDeviceMotionActive, manager.isDeviceMotionAvailable else {
            return
        }

        manager.deviceMotionUpdateInterval = 1.0 / 30.0
        manager.startDeviceMotionUpdates(to: .main) { [weak self] motion, _ in
            guard let motion else { return }
            Task { @MainActor [weak self] in
                self?.consume(gravity: motion.gravity)
            }
        }
    }

    func stop() {
        manager.stopDeviceMotionUpdates()
        hasReading = false
        isAvailable = false
    }

    private func consume(gravity: CMAcceleration) {
        let radians: Double
        switch interfaceOrientation {
        case .landscapeLeft:
            radians = atan2(-gravity.y, -gravity.x)
        case .landscapeRight:
            radians = atan2(gravity.y, gravity.x)
        case .portraitUpsideDown:
            radians = atan2(-gravity.x, gravity.y)
        default:
            radians = atan2(gravity.x, -gravity.y)
        }

        let measured = radians * 180 / .pi
        if hasReading {
            // A light low-pass filter removes hand tremor without making the
            // display lag behind deliberate levelling movements.
            filteredRoll += shortestDelta(from: filteredRoll, to: measured) * 0.24
        } else {
            filteredRoll = measured
            hasReading = true
        }
        isAvailable = true
        rollDegrees = normalized(filteredRoll)
    }

    private var interfaceOrientation: UIInterfaceOrientation {
        UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.interfaceOrientation }
            .first ?? .portrait
    }

    private func normalized(_ degrees: Double) -> Double {
        var value = degrees.truncatingRemainder(dividingBy: 360)
        if value > 180 { value -= 360 }
        if value < -180 { value += 360 }
        return value
    }

    private func shortestDelta(from: Double, to: Double) -> Double {
        normalized(to - from)
    }
}

/// Compact camera-operator level inspired by Sony's FX6 status overlays.
struct HorizonLevelGauge: View {
    @ObservedObject var monitor: HorizonLevelMonitor

    private var isLevel: Bool { abs(monitor.rollDegrees) <= 1.0 }
    private var displayRoll: Double {
        let value = abs(monitor.rollDegrees) < 0.05 ? 0 : monitor.rollDegrees
        return min(12, max(-12, value))
    }
    private var statusColor: Color { isLevel ? .green : .red }

    var body: some View {
        if monitor.isAvailable {
            VStack(alignment: .trailing, spacing: 4) {
                Text(String(format: "%+.1f°", monitor.rollDegrees))
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(statusColor)
                    .monospacedDigit()

                ZStack {
                    HStack(spacing: 4) {
                        Rectangle().frame(width: 28, height: 1)
                        Rectangle().frame(width: 8, height: 2)
                        Rectangle().frame(width: 28, height: 1)
                    }
                    .foregroundStyle(.white.opacity(0.72))

                    HStack(spacing: 5) {
                        Rectangle().frame(width: 29, height: 2)
                        Circle().frame(width: 5, height: 5)
                        Rectangle().frame(width: 29, height: 2)
                    }
                    .foregroundStyle(statusColor)
                    .rotationEffect(.degrees(displayRoll))
                    .animation(.linear(duration: 0.06), value: displayRoll)
                }
                .frame(width: 82, height: 30)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(.black.opacity(0.62), in: RoundedRectangle(cornerRadius: 3, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .stroke(.white.opacity(0.24), lineWidth: 1)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Horizon level")
            .accessibilityValue(isLevel ? "Level" : String(format: "%+.1f degrees", monitor.rollDegrees))
            .allowsHitTesting(false)
        }
    }
}