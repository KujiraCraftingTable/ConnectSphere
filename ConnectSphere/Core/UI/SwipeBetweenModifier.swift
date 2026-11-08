import SwiftUI

/// Lets a swipe left/right anywhere on the content move between the segments of a
/// segmented picker: left goes to the next one, right to the previous one.
///
/// It is a simultaneous gesture, so scrolling and taps keep working, and it only
/// counts a clearly horizontal drag, so a vertical scroll that drifts sideways
/// doesn't switch the segment.
private struct SwipeBetween<Value: Hashable>: ViewModifier {
    let values: [Value]
    @Binding var selection: Value

    func body(content: Content) -> some View {
        content.simultaneousGesture(
            DragGesture(minimumDistance: 24)
                .onEnded { drag in
                    let dx = drag.translation.width
                    guard abs(dx) > 60, abs(dx) > abs(drag.translation.height) * 2,
                          let current = values.firstIndex(of: selection) else { return }
                    let next = dx < 0 ? current + 1 : current - 1
                    guard values.indices.contains(next) else { return }
                    withAnimation { selection = values[next] }
                }
        )
    }
}

extension View {
    func swipeBetween<Value: Hashable>(_ values: [Value], selection: Binding<Value>) -> some View {
        modifier(SwipeBetween(values: values, selection: selection))
    }
}
