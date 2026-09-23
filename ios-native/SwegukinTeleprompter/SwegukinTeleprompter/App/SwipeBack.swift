import SwiftUI

/// iOS-style navigation swipes used across the app.
/// - `swipeBack`: drag right starting near the left edge to go back.
/// - `swipeDownToDismiss`: drag down to close a full-screen view.
extension View {
    func swipeBack(perform action: @escaping () -> Void) -> some View {
        simultaneousGesture(
            DragGesture(minimumDistance: 20, coordinateSpace: .global)
                .onEnded { value in
                    let dx = value.translation.width
                    let dy = abs(value.translation.height)
                    guard value.startLocation.x < 44, dx > 80, dx > dy * 1.5 else { return }
                    action()
                }
        )
    }

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
