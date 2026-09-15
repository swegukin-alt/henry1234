import AVFoundation
import Capacitor
import Foundation
import UIKit

/// Capacitor bridge for `TeleprompterCapture`. The JavaScript side reaches this
/// with `registerPlugin("TeleprompterCapture")` — see
/// `src/platform/native-plugins.ts`.
@objc(TeleprompterCapturePlugin)
public class TeleprompterCapturePlugin: CAPPlugin, CAPBridgedPlugin {
    public let identifier = "TeleprompterCapturePlugin"
    public let jsName = "TeleprompterCapture"
    public let pluginMethods: [CAPPluginMethod] = [
        CAPPluginMethod(name: "startPreview", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "stopPreview", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "flip", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "setZoom", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "setTorch", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "startRecording", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "stopRecording", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "recordingState", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "deviceCapabilities", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "audioStatus", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "listAudioInputs", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "setAudioInput", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "checkPermissions", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "requestPermissions", returnType: CAPPluginReturnPromise)
    ]

    private let capture = TeleprompterCapture()

    override public func load() {
        capture.onInterruption = { [weak self] type in
            self?.notifyListeners("audioInterruption", data: ["type": type])
        }
        capture.onRouteChange = { [weak self] route in
            self?.notifyListeners("audioRouteChange", data: ["route": route])
        }
    }

    // MARK: Preview

    @objc func startPreview(_ call: CAPPluginCall) {
        let position: AVCaptureDevice.Position = call.getString("position") == "rear" ? .back : .front
        let quality = call.getString("quality") ?? "1080p"
        let preset: AVCaptureSession.Preset = {
            switch quality {
            case "4k": return .hd4K3840x2160
            case "720p": return .hd1280x720
            default: return .hd1920x1080
            }
        }()
        let targetHeight = quality == "4k" ? 2160 : quality == "720p" ? 720 : 1080
        let fps = call.getInt("fps") ?? 30
        let hdr = call.getBool("hdr") ?? false
        let stabilization = call.getString("stabilization") ?? "auto"
        DispatchQueue.main.async {
            guard let webView = self.webView else {
                call.reject("No web view")
                return
            }
            // The camera layer goes behind a transparent WebView so the
            // teleprompter HTML keeps rendering on top of it.
            webView.isOpaque = false
            webView.backgroundColor = .clear
            webView.scrollView.backgroundColor = .clear
            guard let container = webView.superview else {
                call.reject("No container view")
                return
            }
            do {
                let size = try self.capture.startPreview(in: container,
                                                         position: position,
                                                         preset: preset,
                                                         targetHeight: targetHeight,
                                                         fps: fps,
                                                         hdr: hdr,
                                                         stabilization: stabilization)
                self.capture.startSession { running in
                    guard running else {
                        call.reject("The native camera session did not start.")
                        return
                    }
                    // Follow rotations so the picture always fills the screen.
                    NotificationCenter.default.addObserver(forName: UIDevice.orientationDidChangeNotification,
                                                           object: nil, queue: .main) { [weak self] _ in
                        guard let self = self, let container = self.webView?.superview else { return }
                        self.capture.layoutPreview(in: container)
                    }
                    call.resolve(["width": size.width, "height": size.height])
                }
            } catch {
                call.reject(error.localizedDescription)
            }
        }
    }

    @objc func stopPreview(_ call: CAPPluginCall) {
        DispatchQueue.main.async {
            self.capture.stopPreview()
            if let webView = self.webView {
                webView.isOpaque = true
                webView.backgroundColor = .black
            }
            call.resolve()
        }
    }

    @objc func flip(_ call: CAPPluginCall) {
        let position: AVCaptureDevice.Position = call.getString("position") == "rear" ? .back : .front
        DispatchQueue.main.async {
            do { try self.capture.flip(to: position); call.resolve(["position": call.getString("position") ?? "front"]) }
            catch { call.reject(error.localizedDescription) }
        }
    }

    @objc func setZoom(_ call: CAPPluginCall) {
        let zoom = call.getDouble("zoom") ?? 1
        do { try capture.setZoom(CGFloat(zoom)); call.resolve() }
        catch { call.reject(error.localizedDescription) }
    }

    @objc func setTorch(_ call: CAPPluginCall) {
        do { try capture.setTorch(call.getBool("on") ?? false); call.resolve() }
        catch { call.reject(error.localizedDescription) }
    }

    // MARK: Recording

    @objc func startRecording(_ call: CAPPluginCall) {
        DispatchQueue.main.async {
            do {
                try self.capture.startRecording(recordingId: call.getString("recordingId"))
                call.resolve()
            } catch {
                call.reject(error.localizedDescription)
            }
        }
    }

    @objc func stopRecording(_ call: CAPPluginCall) {
        capture.stopRecording { url, error in
            guard let url = url else {
                call.reject(error?.localizedDescription ?? "The recording could not be finished.")
                return
            }
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
            call.resolve([
                "path": url.absoluteString,
                "relativePath": "recordings/\(url.lastPathComponent)",
                "mimeType": "video/quicktime",
                "sizeBytes": size ?? 0
            ])
        }
    }

    @objc func deviceCapabilities(_ call: CAPPluginCall) {
        call.resolve(capture.deviceCapabilities())
    }

    @objc func recordingState(_ call: CAPPluginCall) {
        call.resolve([
            "state": capture.isRecording ? "recording" : "inactive",
            "durationMs": capture.recordedDurationMs
        ])
    }

    // MARK: Audio

    @objc func audioStatus(_ call: CAPPluginCall) { call.resolve(capture.audioStatus()) }

    @objc func listAudioInputs(_ call: CAPPluginCall) { call.resolve(["inputs": capture.audioInputs()]) }

    @objc func setAudioInput(_ call: CAPPluginCall) {
        guard let id = call.getString("deviceId") else { call.reject("deviceId is required"); return }
        do { try capture.setAudioInput(deviceId: id); call.resolve() }
        catch { call.reject(error.localizedDescription) }
    }

    // MARK: Permissions

    @objc override public func checkPermissions(_ call: CAPPluginCall) {
        call.resolve([
            "camera": TeleprompterCapture.cameraStatus(),
            "microphone": TeleprompterCapture.microphoneStatus()
        ])
    }

    @objc override public func requestPermissions(_ call: CAPPluginCall) {
        let wanted = call.getArray("permissions", String.self) ?? ["camera", "microphone"]
        let group = DispatchGroup()
        var camera = TeleprompterCapture.cameraStatus()
        var microphone = TeleprompterCapture.microphoneStatus()

        if wanted.contains("camera"), camera == "prompt" {
            group.enter()
            TeleprompterCapture.request(.video) { camera = $0; group.leave() }
        }
        if wanted.contains("microphone"), microphone == "prompt" {
            group.enter()
            TeleprompterCapture.request(.audio) { microphone = $0; group.leave() }
        }
        group.notify(queue: .main) {
            call.resolve(["camera": camera, "microphone": microphone])
        }
    }
}
