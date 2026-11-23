import UIKit

/// Hides the keyboard everywhere once the user has stopped typing for 3 s.
@MainActor final class KeyboardIdle {
    static let shared = KeyboardIdle()
    private var timer: Timer?
    private var shown = false

    private init() {
        let nc = NotificationCenter.default
        nc.addObserver(forName: UIResponder.keyboardDidShowNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { self.shown = true; self.restart() }
        }
        nc.addObserver(forName: UIResponder.keyboardWillHideNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { self.shown = false; self.timer?.invalidate() }
        }
        for n in [UITextField.textDidChangeNotification, UITextView.textDidChangeNotification] {
            nc.addObserver(forName: n, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { self.restart() }
            }
        }
    }

    func start() {}

    private func restart() {
        timer?.invalidate()
        guard shown else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: false) { _ in
            MainActor.assumeIsolated {
                // Don't cut off a pinyin/IME composition still in progress.
                if let r = Self.firstResponder() as? UITextInput, r.markedTextRange != nil { self.restart(); return }
                UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
            }
        }
    }

    private static weak var found: UIResponder?
    private static func firstResponder() -> UIResponder? {
        found = nil
        UIApplication.shared.sendAction(#selector(UIResponder.kbIdleCapture), to: nil, from: nil, for: nil)
        return found
    }
    fileprivate static func capture(_ r: UIResponder) { found = r }
}

extension UIResponder {
    @objc fileprivate func kbIdleCapture() { KeyboardIdle.capture(self) }
}
