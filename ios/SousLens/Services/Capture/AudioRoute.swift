import AVFoundation
import Foundation
import Observation

/// One audio input of `AVAudioSession.currentRoute`, reduced to what the label needs.
struct AudioInputPort: Equatable, Sendable {
    let type: AVAudioSession.Port
    let name: String
}

/// CLAUDE.md "honest device state": the microphone is named from the verified route only.
/// "Glasses microphone" requires a Bluetooth HFP *input* whose name is a Meta glasses name, in the
/// glasses build. An A2DP-only route (output, no input) can never produce it.
enum AudioInputLabel {
    static let iPhone = "iPhone microphone"
    static let glasses = "Glasses microphone"

    /// Port-name fragments of Ray-Ban / Oakley Meta glasses.
    static let glassesNameHints = ["ray-ban", "rayban", "oakley", "meta"]

    static func label(for inputs: [AudioInputPort], glassesBuild: Bool) -> String {
        if let hfp = inputs.first(where: { $0.type == .bluetoothHFP }) {
            let lower = hfp.name.lowercased()
            if glassesBuild, glassesNameHints.contains(where: lower.contains) {
                return glasses
            }
            return hfp.name.isEmpty ? "Bluetooth microphone" : "Bluetooth microphone (\(hfp.name))"
        }
        if let first = inputs.first {
            switch first.type {
            case .builtInMic: return iPhone
            case .headsetMic: return "Headset microphone"
            case .usbAudio, .carAudio, .lineIn: return first.name.isEmpty ? "External microphone" : first.name
            default: return first.name.isEmpty ? "External microphone" : first.name
            }
        }
        // No input listed: the session isn't recording, and SousLens records with the iPhone
        // microphone unless a Bluetooth HFP input is verified once listening starts.
        return iPhone
    }

    /// True only for a verified glasses HFP input.
    static func isGlassesMic(_ inputs: [AudioInputPort], glassesBuild: Bool) -> Bool {
        label(for: inputs, glassesBuild: glassesBuild) == glasses
    }
}

/// Reads `AVAudioSession.currentRoute` and re-reads it on every `routeChangeNotification`.
@MainActor
@Observable
final class AudioRouteMonitor {
    private(set) var inputs: [AudioInputPort] = []
    let glassesBuild: Bool
    private let read: @MainActor () -> [AudioInputPort]
    private let observers = NotificationObserverBag()

    var inputLabel: String { AudioInputLabel.label(for: inputs, glassesBuild: glassesBuild) }
    var isGlassesMic: Bool { AudioInputLabel.isGlassesMic(inputs, glassesBuild: glassesBuild) }

    init(glassesBuild: Bool,
         notificationCenter: NotificationCenter = .default,
         read: @escaping @MainActor () -> [AudioInputPort] = AudioRouteMonitor.currentInputs) {
        self.glassesBuild = glassesBuild
        self.read = read
        inputs = read()
        observers.add(notificationCenter.addObserver(
            forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        })
    }

    func refresh() {
        inputs = read()
    }

    static func currentInputs() -> [AudioInputPort] {
        AVAudioSession.sharedInstance().currentRoute.inputs.map {
            AudioInputPort(type: $0.portType, name: $0.portName)
        }
    }
}
