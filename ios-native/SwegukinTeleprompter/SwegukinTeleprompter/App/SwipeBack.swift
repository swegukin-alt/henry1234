import SwiftUI

/// Native-feeling interactive back swipe, like UINavigationController:
/// drag from the left edge and the page follows your finger while the
/// previous page slides in underneath (parallax + fading dim). Release past
/// a third of the width (or flick) to go back, otherwise it springs home.
struct InteractiveSwipeBack<Back: View, Front: View>: View {
    let onBack: () -> Void
    @ViewBuilder let back: () -> Back
    @ViewBuilder let front: () -> Front

    @State private var offset: CGFloat = 0
    @State private var tracking = false
    @State private var finishing = false

    private let edgeWidth: CGFloat = 32

    var body: some View {
        GeometryReader { geo in
            let width = max(geo.size.width, 1)
            let progress = min(max(offset / width, 0), 1)

            ZStack {
                if offset > 0 || tracking {
                    back()
                        .offset(x: -width * 0.3 * (1 - progress))
                        .overlay(Color.black.opacity(0.35 * (1 - progress)).ignoresSafeArea())
                        .allowsHitTesting(false)
                }

                front()
                    .background(Theme.background.ignoresSafeArea())
                    .offset(x: offset)
                    .shadow(color: .black.opacity(offset > 0 ? 0.35 : 0), radius: 12, x: -4)
                    .simultaneousGesture(
                        DragGesture(minimumDistance: 8, coordinateSpace: .global)
                            .onChanged { value in
                                guard !finishing else { return }
                                if !tracking {
                                    guard value.startLocation.x < edgeWidth,
                                          value.translation.width > abs(value.translation.height) else { return }
                                    tracking = true
                                }
                                offset = max(0, value.translation.width)
                            }
                            .onEnded { value in
                                guard tracking, !finishing else { return }
                                tracking = false
                                let flick = value.predictedEndTranslation.width > width * 0.6
                                if offset > width / 3 || flick {
                                    finishing = true
                                    withAnimation(.spring(response: 0.28, dampingFraction: 1)) { offset = width }
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.28) {
                                        Haptics.tap()
                                        onBack()
                                        offset = 0
                                        finishing = false
                                    }
                                } else {
                                    withAnimation(.spring(response: 0.3, dampingFraction: 0.86)) { offset = 0 }
                                }
                            }
                    )
            }
        }
    }
}

extension View {
    /// Drag down to close a full-screen view (video player).
    func swipeDownToDismiss(perform action: @escaping () -> Void) -> some View {
        simultaneousGesture(
            DragGesture(minimumDistance: 20)
                .onEnded { value in
                    let dy = value.translation.height
                    guard dy > 100, dy > abs(value.translation.width) * 1.5 else { return }
                    action()
                }
        )
    }
}
