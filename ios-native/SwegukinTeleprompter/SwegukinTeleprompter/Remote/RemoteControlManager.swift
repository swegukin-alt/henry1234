import SwiftUI
import UIKit

/// Every physical-key action the teleprompter understands. The Desview remote
/// (and any Bluetooth keyboard) arrives here as ordinary key presses — no BLE
/// scanning needed.
enum RemoteAction {
    case togglePlay
    case speedUp
    case speedDown
    case nudgeUp
    case nudgeDown
    case fontUp
    case fontDown
    case reset
    case exit
    case toggleRecord
}

@MainActor
final class RemoteControlManager: ObservableObject {
    var handler: ((RemoteAction) -> Void)?

    func send(_ action: RemoteAction) {
        handler?(action)
    }
}

/// A first-responder UIKit host that turns key presses into RemoteActions.
final class KeyCommandViewController: UIViewController {
    var onAction: ((RemoteAction) -> Void)?
    private var activeObserver: NSObjectProtocol?
    private var keyWindowObserver: NSObjectProtocol?

    override var canBecomeFirstResponder: Bool { true }

    override func viewDidLoad() {
        super.viewDidLoad()
        // Bluetooth remotes (e.g. Desview) briefly drop and re-pair at the
        // radio level — that part is outside the app's control. What IS in
        // the app's control is being first responder when the keys come back:
        // without it, the first presses after a reconnect are silently lost
        // and the remote "feels" disconnected. Re-assert first responder
        // whenever the app becomes active or the window becomes key.
        activeObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.assertFirstResponder()
        }
        keyWindowObserver = NotificationCenter.default.addObserver(
            forName: UIWindow.didBecomeKeyNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.assertFirstResponder()
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        assertFirstResponder()
    }

    /// Grabs first responder now and once more shortly after — a reconnecting
    /// remote often delivers keys a beat after the system focus settles.
    func assertFirstResponder() {
        guard !isFirstResponder, view.window != nil else { return }
        becomeFirstResponder()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self, !self.isFirstResponder, self.view.window != nil else { return }
            self.becomeFirstResponder()
        }
    }

    deinit {
        if let activeObserver { NotificationCenter.default.removeObserver(activeObserver) }
        if let keyWindowObserver { NotificationCenter.default.removeObserver(keyWindowObserver) }
    }

    override var keyCommands: [UIKeyCommand]? {
        let inputs: [String] = [
            UIKeyCommand.inputUpArrow, UIKeyCommand.inputDownArrow,
            UIKeyCommand.inputLeftArrow, UIKeyCommand.inputRightArrow,
            UIKeyCommand.inputPageUp, UIKeyCommand.inputPageDown,
            UIKeyCommand.inputEscape, UIKeyCommand.inputHome,
            " ", "\r", "\t", ".", "k", "K", "p", "P",
            "0", "[", "]", "-", "_", "+", "=", "r", "R",
        ]
        return inputs.map { input in
            let command = UIKeyCommand(input: input, modifierFlags: [], action: #selector(handleKey(_:)))
            command.wantsPriorityOverSystemBehavior = true
            return command
        }
    }

    @objc private func handleKey(_ sender: UIKeyCommand) {
        guard let input = sender.input else { return }
        switch input {
        case UIKeyCommand.inputUpArrow, UIKeyCommand.inputPageUp:
            onAction?(.nudgeUp)
        case UIKeyCommand.inputDownArrow, UIKeyCommand.inputPageDown:
            onAction?(.nudgeDown)
        case UIKeyCommand.inputLeftArrow, "-", "_":
            onAction?(.speedDown)
        case UIKeyCommand.inputRightArrow, "+", "=":
            onAction?(.speedUp)
        case UIKeyCommand.inputEscape:
            onAction?(.exit)
        case UIKeyCommand.inputHome, "0":
            onAction?(.reset)
        case "]":
            onAction?(.fontUp)
        case "[":
            onAction?(.fontDown)
        case "r", "R":
            onAction?(.toggleRecord)
        default:
            onAction?(.togglePlay)
        }
    }

    /// Media keys on remotes arrive as presses, not key commands.
    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var handled = false
        for press in presses {
            switch press.type {
            case .select:
                onAction?(.togglePlay); handled = true
            case .upArrow:
                onAction?(.nudgeUp); handled = true
            case .downArrow:
                onAction?(.nudgeDown); handled = true
            case .leftArrow:
                onAction?(.speedDown); handled = true
            case .rightArrow:
                onAction?(.speedUp); handled = true
            default:
                // playPause exists on iOS 17.2+; the deployment target is 17.0,
                // so it cannot sit in a case pattern.
                if #available(iOS 17.2, *), press.type == .playPause {
                    onAction?(.togglePlay); handled = true
                }
            }
        }
        if !handled { super.pressesBegan(presses, with: event) }
    }
}

struct RemoteKeyCatcher: UIViewControllerRepresentable {
    var onAction: (RemoteAction) -> Void

    func makeUIViewController(context: Context) -> KeyCommandViewController {
        let controller = KeyCommandViewController()
        controller.onAction = onAction
        controller.view.backgroundColor = .clear
        return controller
    }

    func updateUIViewController(_ controller: KeyCommandViewController, context: Context) {
        controller.onAction = onAction
    }
}
