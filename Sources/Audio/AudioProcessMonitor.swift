import CoreAudio
import Foundation

/// A process that Core Audio knows about, i.e. one that has opened an audio device.
struct AudioProcess: Hashable {
    let objectID: AudioObjectID
    let pid: pid_t
    let bundleID: String?
}

/// Watches Core Audio's process list and reports which processes are currently
/// producing output. This is a plain property read — no permission needed.
@MainActor
final class AudioProcessMonitor: ObservableObject {
    @Published private(set) var playing: [AudioProcess] = []

    /// Called on the main actor whenever `playing` changes.
    var onChange: (@MainActor () -> Void)?

    private let ownPID = ProcessInfo.processInfo.processIdentifier

    /// System daemons that keep an output stream open even when silent; listing them is only noise.
    private static let hiddenBundleIDs: Set<String> = [
        "com.apple.CoreSpeech",   // Siri / dictation
        "com.apple.audiomxd",     // system audio mixer daemon
    ]
    private var listListener: PropertyListener?
    private var processListeners: [AudioObjectID: PropertyListener] = [:]
    private var pollTimer: Timer?

    init() {
        listListener = PropertyListener(
            object: .system, address: .init(kAudioHardwarePropertyProcessObjectList)
        ) { [weak self] in self?.refresh() }
        // IsRunningOutput notifications are not always delivered, so poll as a backstop.
        pollTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        refresh()
    }

    func refresh() {
        let ids = (try? AudioObjectID.system.readArray(.init(kAudioHardwarePropertyProcessObjectList), of: AudioObjectID.self)) ?? []
        var current: [AudioProcess] = []
        var seen = Set<AudioObjectID>()

        for id in ids {
            seen.insert(id)
            guard let pid = try? id.readPID(.init(kAudioProcessPropertyPID)), pid != ownPID else { continue }
            if processListeners[id] == nil {
                processListeners[id] = PropertyListener(
                    object: id, address: .init(kAudioProcessPropertyIsRunningOutput)
                ) { [weak self] in self?.refresh() }
            }
            let running = (try? id.readBool(.init(kAudioProcessPropertyIsRunningOutput))) ?? false
            guard running else { continue }
            let bundleID = try? id.readString(.init(kAudioProcessPropertyBundleID))
            if let bundleID, Self.hiddenBundleIDs.contains(bundleID) { continue }
            current.append(AudioProcess(objectID: id, pid: pid, bundleID: bundleID))
        }

        for id in processListeners.keys where !seen.contains(id) {
            processListeners[id] = nil
        }

        if current != playing {
            playing = current
            onChange?()
        }
    }
}
