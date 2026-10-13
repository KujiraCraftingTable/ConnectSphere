import UIKit

/// Hiding the system back button (screens with their own Liquid Glass back
/// button, e.g. `ChatView`) also switches off iOS's swipe-from-the-left-edge
/// to go back. Taking over the gesture's delegate turns it back on for every
/// pushed screen; on a stack's root screen there is nothing to go back to.
extension UINavigationController: @retroactive UIGestureRecognizerDelegate {
    override open func viewDidLoad() {
        super.viewDidLoad()
        interactivePopGestureRecognizer?.delegate = self
    }

    public func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        gestureRecognizer === interactivePopGestureRecognizer ? viewControllers.count > 1 : true
    }
}
