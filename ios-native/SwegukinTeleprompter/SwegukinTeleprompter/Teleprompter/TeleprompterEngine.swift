import Foundation
import QuartzCore
import Combine

/// Frame-synchronised scrolling. CADisplayLink keeps the text moving in step
/// with the display. The web reader advances once per rendered frame; using a
/// fixed 60 Hz here avoids asking SwiftUI to reposition a very tall script 120
/// times per second while the camera is encoding 4K video.
@MainActor
final class TeleprompterEngine: ObservableObject {
    @Published private(set) var offset: CGFloat = 0
    @Published private(set) var isPlaying = false

    /// Points per second. Changing it never makes the text jump: the next frame
    /// simply advances by a different amount.
    var speed: CGFloat = 70
    /// Momentary multiplier used by punctuation pauses and voice follow.
    var speedScale: CGFloat = 1

    var contentHeight: CGFloat = 0
    var viewportHeight: CGFloat = 0

    private var link: CADisplayLink?
    private var lastTimestamp: CFTimeInterval = 0
    private var dragOrigin: CGFloat?
    private var glideVelocity: CGFloat = 0

    nonisolated init() {}

    var maxOffset: CGFloat {
        max(0, contentHeight - viewportHeight)
    }

    /// Derived from the same frame value as the text offset. Publishing a
    /// second progress value on every display refresh caused two SwiftUI update
    /// passes per frame and made long scripts visibly judder.
    var progress: Double {
        guard maxOffset > 0 else { return 0 }
        return Double(min(1, max(0, offset / maxOffset)))
    }

    func play() {
        guard !isPlaying else { return }
        isPlaying = true
        lastTimestamp = 0
        ensureDisplayLink()
    }

    private func ensureDisplayLink() {
        guard link == nil else { return }
        let link = CADisplayLink(target: DisplayLinkProxy { [weak self] link in
            self?.tick(link)
        }, selector: #selector(DisplayLinkProxy.handle(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 60, preferred: 60)
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    func pause() {
        isPlaying = false
        glideVelocity = 0
        dragOrigin = nil
        link?.invalidate()
        link = nil
    }

    func toggle() {
        isPlaying ? pause() : play()
    }

    func reset() {
        offset = 0
    }

    func nudge(points: CGFloat) {
        offset = min(max(0, offset + points), maxOffset)
    }

    func seek(to value: CGFloat) {
        offset = min(max(0, value), maxOffset)
    }

    /// Match the browser's native touch scrolling without putting a UIScrollView
    /// around the very tall SwiftUI text hierarchy. Dragging follows the finger;
    /// release uses iOS's normal deceleration rate and can coexist with playback.
    func drag(translation: CGFloat) {
        if dragOrigin == nil {
            dragOrigin = offset
            glideVelocity = 0
        }
        guard let dragOrigin else { return }
        seek(to: dragOrigin - translation)
    }

    func endDrag(velocity: CGFloat) {
        dragOrigin = nil
        glideVelocity = -velocity
        if abs(glideVelocity) >= 5 { ensureDisplayLink() }
    }

    private func tick(_ link: CADisplayLink) {
        if lastTimestamp == 0 {
            lastTimestamp = link.timestamp
            return
        }
        // Returning from a permission sheet or interruption must never jump.
        let delta = min(link.timestamp - lastTimestamp, 0.05)
        lastTimestamp = link.timestamp
        if dragOrigin != nil { return }

        let seconds = CGFloat(delta)
        let automaticVelocity = isPlaying ? speed * speedScale : 0
        let step = (automaticVelocity + glideVelocity) * seconds
        let next = offset + step
        if next >= maxOffset || next <= 0 {
            offset = min(max(0, next), maxOffset)
            glideVelocity = 0
            if next >= maxOffset { isPlaying = false }
            if !isPlaying {
                self.link?.invalidate()
                self.link = nil
            }
            return
        }
        offset = next

        // UIScrollView.DecelerationRate.normal is 0.998 per millisecond.
        if glideVelocity != 0 {
            glideVelocity *= CGFloat(pow(0.998, delta * 1_000))
            if abs(glideVelocity) < 5 { glideVelocity = 0 }
        }
        if !isPlaying && glideVelocity == 0 {
            self.link?.invalidate()
            self.link = nil
        }
    }
}

/// CADisplayLink needs an Objective-C target; this keeps the engine itself pure.
final class DisplayLinkProxy: NSObject {
    private let handler: (CADisplayLink) -> Void

    init(handler: @escaping (CADisplayLink) -> Void) {
        self.handler = handler
    }

    @objc func handle(_ link: CADisplayLink) {
        handler(link)
    }
}
