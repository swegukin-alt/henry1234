import Capacitor

/// Required for an app-local Capacitor plugin. Merely adding the plugin Swift
/// files to the App target does not register them with the bridge.
@objc(TeleprompterViewController)
public class TeleprompterViewController: CAPBridgeViewController {
    override public func capacitorDidLoad() {
        bridge?.registerPluginInstance(TeleprompterCapturePlugin())
    }
}