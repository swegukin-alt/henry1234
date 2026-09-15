import Foundation
import QuartzCore
import Combine

/// Frame-synchronised scrolling. CADisplayLink keeps the text moving in step
/// with the display, so it is equally smooth at 60 Hz and 120 Hz ProMotion.
@MainActor
final class TeleprompterEngine: ObservableObject {
    @Published private(set) var offset: CGFloat = 0
    @Published private(set) var isPlaying = false
    @Published private(set) var progress: Double = 0

    /// Points per second. Changing it never makes the text jump: the next frame
    /// simply advances by a different amount.
    var speed: CGFloat = 70
    /// Momentary multiplier used by punctuation pauses and voice follow.
    var speedScale: CGFloat = 1

    var contentHeight: CGFloat = 0 { didSet { updateProgress() } }
    var viewportHeight: CGFloat = 0 { didSet { updateProgress() } }

    private var link: CADisplayLink?
    private var lastTimestamp: CFTimeInterval = 0

    var maxOffset: CGFloat {
        max(0, contentHeight - viewportHeight)
    }

    func play() {
        guard !isPlaying else { return }
        isPlaying = true
        lastTimestamp = 0
        let link = CADisplayLink(target: DisplayLinkProxy { [weak self] link in
            self?.tick(link)
        }, selector: #selector(DisplayLinkProxy.handle(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    func pause() {
        isPlaying = false
        link?.invalidate()
        link = nil
    }

    func toggle() {
        isPlaying ? pause() : play()
    }

    func reset() {
        offset = 0
        updateProgress()
    }

    func nudge(points: CGFloat) {
        offset = min(max(0, offset + points), maxOffset)
        updateProgress()
    }

    func seek(to value: CGFloat) {
        offset = min(max(0, value), maxOffset)
        updateProgress()
    }

    private func tick(_ link: CADisplayLink) {
        if lastTimestamp == 0 {
            lastTimestamp = link.timestamp
            return
        }
        // Returning from a permission sheet or interruption must never jump.
        let delta = min(link.timestamp - lastTimestamp, 0.05)
        lastTimestamp = link.timestamp
        let step = speed * speedScale * CGFloat(delta)
        let next = offset + step
        if next >= maxOffset {
            offset = maxOffset
            updateProgress()
            pause()
            return
        }
        offset = next
        updateProgress()
    }

    private func updateProgress() {
        guard maxOffset > 0 else { progress = 0; return }
        progress = Double(min(1, max(0, offset / maxOffset)))
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
