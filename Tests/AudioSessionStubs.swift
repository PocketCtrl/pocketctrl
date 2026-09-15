// SPDX-License-Identifier: MPL-2.0

// Test-only stand-ins for AVAudioSession. The production coordinator is loaded
// unchanged except for its AVFoundation import; no microphone or speaker is used.
import Foundation

let AVAudioSessionInterruptionTypeKey = "type"
let AVAudioSessionInterruptionOptionKey = "options"
let AVAudioSessionRouteChangeReasonKey = "reason"

final class AVAudioSession: NSObject {
    static let instance = AVAudioSession()
    static func sharedInstance() -> AVAudioSession { instance }
    static let interruptionNotification = Notification.Name("test.interruption")
    static let routeChangeNotification = Notification.Name("test.route")
    static let mediaServicesWereResetNotification = Notification.Name("test.reset")
    enum Category { case record, playback }
    enum Mode { case measurement, `default` }
    enum InterruptionType: UInt { case began = 1, ended = 0 }
    enum RouteChangeReason: UInt { case categoryChange = 3, oldDeviceUnavailable = 2 }
    struct InterruptionOptions: OptionSet {
        let rawValue: UInt
        static let shouldResume = Self(rawValue: 1)
    }
    struct Options: OptionSet {
        let rawValue: UInt
        static let mixWithOthers = Self(rawValue: 1)
        static let notifyOthersOnDeactivation = Self(rawValue: 2)
    }
    enum Failure: Error { case activation }
    var category: Category = .playback
    var active = false
    var failNextRecordingActivation = false
    func setCategory(_ category: Category, mode: Mode, options: Options = []) throws {
        self.category = category
    }
    func setActive(_ active: Bool, options: Options = []) throws {
        if active, category == .record, failNextRecordingActivation {
            failNextRecordingActivation = false
            throw Failure.activation
        }
        self.active = active
    }
}
enum ClientDiagnostics {
    static func write(_ message: String) {}
}
