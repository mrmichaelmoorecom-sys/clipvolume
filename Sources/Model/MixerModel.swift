import AppKit
import CoreAudio
import Foundation

/// One row in the mixer: an app, its per-app level (relative to master), mute, and live meter.
@MainActor
final class MixerChannel: ObservableObject, Identifiable {
    /// PID of the top-level app. A relaunched app gets a new PID and therefore a fresh channel
    /// at 100% — that is the "resets when the source reloads" behaviour.
    let id: pid_t
    let app: ResolvedApp

    @Published fileprivate(set) var gain: Float = 1
    @Published fileprivate(set) var isMuted = false
    @Published fileprivate(set) var isPlaying = true
    /// Meter value 0…1 on a dB-ish scale, decayed for display.
    @Published fileprivate(set) var level: Float = 0

    fileprivate var processObjectIDs: [AudioObjectID]
    fileprivate var tap: ProcessTapChannel?
    fileprivate var tapIsStale = false

    /// True when the user has moved this app away from "just follow master".
    var isAdjusted: Bool { isMuted || gain < 0.995 }

    fileprivate init(app: ResolvedApp, processObjectIDs: [AudioObjectID]) {
        id = app.pid
        self.app = app
        self.processObjectIDs = processObjectIDs
    }
}

/// A media player that is playing but not through this Mac (Spotify Connect, AirPlay from the app, …),
/// so it has no mixer channel — it still gets a play/pause row.
struct RemotePlayer: Identifiable, Equatable {
    let id: String   // bundle ID
    let name: String
    let icon: NSImage?
    let state: PlayerState

    static func == (lhs: RemotePlayer, rhs: RemotePlayer) -> Bool {
        lhs.id == rhs.id && lhs.name == rhs.name && lhs.state == rhs.state
    }
}

@MainActor
final class MixerModel: ObservableObject {
    static let shared = MixerModel()

    let output = OutputDeviceController()
    let processes = AudioProcessMonitor()
    let playback = PlaybackController()

    @Published private(set) var channels: [MixerChannel] = []
    @Published private(set) var remotePlayers: [RemotePlayer] = []
    @Published private(set) var menuBarSymbol = "speaker.wave.2.fill"
    @Published private(set) var tapError: String?
    @Published private(set) var isPanelOpen = false
    @Published var isExpanded: Bool {
        didSet {
            UserDefaults.standard.set(isExpanded, forKey: Self.expandedKey)
            applyTapPolicy()
            updatePlaybackPolling()
        }
    }
    /// Shown once, before the first tap is created, so the permission prompt isn't a surprise.
    @Published var needsPermissionIntro: Bool {
        didSet {
            UserDefaults.standard.set(!needsPermissionIntro, forKey: Self.introSeenKey)
            applyTapPolicy()
        }
    }

    private static let expandedKey = "mixerExpanded"
    private static let introSeenKey = "permissionIntroSeen"

    private var appCache: [pid_t: ResolvedApp] = [:]
    private var meterTimer: Timer?
    /// Remote players stay listed until the panel closes, so pausing one doesn't make its row vanish.
    private var stickyRemotePlayers: Set<String> = []

    private init() {
        isExpanded = UserDefaults.standard.bool(forKey: Self.expandedKey)
        needsPermissionIntro = !UserDefaults.standard.bool(forKey: Self.introSeenKey)

        output.onChange = { [weak self] in self?.outputChanged() }
        processes.onChange = { [weak self] in self?.rebuildChannels() }
        playback.onChange = { [weak self] in self?.rebuildRemotePlayers() }
        outputChanged()
        rebuildChannels()
    }

    // MARK: Panel lifecycle

    func panelOpened() {
        isPanelOpen = true
        processes.refresh()
        applyTapPolicy()
        updatePlaybackPolling()
    }

    func panelClosed() {
        isPanelOpen = false
        stickyRemotePlayers = []
        applyTapPolicy()
        updatePlaybackPolling()
    }

    private func updatePlaybackPolling() {
        if isPanelOpen && isExpanded {
            playback.startPolling()
        } else {
            playback.stopPolling()
        }
    }

    func toggleExpanded() {
        isExpanded.toggle()
    }

    /// Drops every tap. Called on quit so apps are un-muted immediately rather than on cleanup.
    func shutdown() {
        for channel in channels { channel.tap = nil }
    }

    // MARK: Per-app controls

    func setGain(_ channel: MixerChannel, _ value: Float) {
        channel.gain = max(0, min(1, value))
        if let tap = channel.tap, tap.mode == .control {
            tap.gain = channel.gain
        } else if channel.isAdjusted {
            applyTapPolicy()
        }
    }

    /// Slider released: if the app is back at 100% and unmuted, drop back to a pass-through tap.
    func gainEditingEnded(_ channel: MixerChannel) {
        if !channel.isAdjusted { applyTapPolicy() }
    }

    func setMuted(_ channel: MixerChannel, _ muted: Bool) {
        channel.isMuted = muted
        if let tap = channel.tap, tap.mode == .control {
            tap.isMuted = muted
        }
        applyTapPolicy()
    }

    func reset(_ channel: MixerChannel) {
        channel.gain = 1
        channel.isMuted = false
        applyTapPolicy()
    }

    func openPrivacySettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture")!
        NSWorkspace.shared.open(url)
    }

    // MARK: Internals

    private func outputChanged() {
        menuBarSymbol = Self.symbol(volume: output.volume, muted: output.isMuted, adjustable: output.canSetVolume)
        // Taps are bound to a specific output device; rebuild them when the default changes.
        for channel in channels where channel.tap?.outputDeviceUID != output.deviceUID {
            channel.tapIsStale = true
        }
        applyTapPolicy()
    }

    private static func symbol(volume: Float, muted: Bool, adjustable: Bool) -> String {
        guard adjustable else { return "speaker.wave.2.fill" }
        if muted || volume <= 0.001 { return "speaker.slash.fill" }
        if volume < 0.34 { return "speaker.wave.1.fill" }
        if volume < 0.67 { return "speaker.wave.2.fill" }
        return "speaker.wave.3.fill"
    }

    private func resolve(_ process: AudioProcess) -> ResolvedApp {
        if let cached = appCache[process.pid] { return cached }
        let app = AppResolver.resolve(pid: process.pid, bundleID: process.bundleID)
        appCache[process.pid] = app
        return app
    }

    private func rebuildChannels() {
        var groups: [pid_t: (app: ResolvedApp, ids: [AudioObjectID])] = [:]
        for process in processes.playing {
            let app = resolve(process)
            groups[app.pid, default: (app, [])].ids.append(process.objectID)
        }

        var next: [MixerChannel] = []
        for (pid, group) in groups {
            if let existing = channels.first(where: { $0.id == pid }) {
                existing.isPlaying = true
                if existing.processObjectIDs != group.ids {
                    existing.processObjectIDs = group.ids
                    existing.tapIsStale = true
                }
                next.append(existing)
            } else {
                next.append(MixerChannel(app: group.app, processObjectIDs: group.ids))
            }
        }

        // An app that went quiet keeps its row (and its mute) as long as it is still running.
        for channel in channels where groups[channel.id] == nil {
            if channel.isAdjusted, Self.isRunning(pid: channel.id) {
                channel.isPlaying = false
                next.append(channel)
            } else {
                channel.tap = nil
            }
        }

        let livePIDs = Set(next.map(\.id))
        appCache = appCache.filter { livePIDs.contains($0.key) }

        channels = next.sorted { $0.app.name.localizedCaseInsensitiveCompare($1.app.name) == .orderedAscending }
        applyTapPolicy()
        rebuildRemotePlayers()
    }

    private func rebuildRemotePlayers() {
        let local = Set(channels.compactMap(\.app.bundleID))
        var next: [RemotePlayer] = []
        for (bundleID, state) in playback.states where !local.contains(bundleID) {
            guard state.isPlaying || stickyRemotePlayers.contains(bundleID) else { continue }
            guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else { continue }
            stickyRemotePlayers.insert(bundleID)
            next.append(RemotePlayer(id: bundleID, name: app.localizedName ?? bundleID, icon: app.icon, state: state))
        }
        next.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        if next != remotePlayers { remotePlayers = next }
    }

    private static func isRunning(pid: pid_t) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }

    /// Decides which channels need a tap and in which mode:
    /// - adjusted (muted or below 100%): a control tap, kept alive even while the panel is closed;
    /// - otherwise, a monitor tap only while the mixer is visible, so untouched apps stay untouched.
    private func applyTapPolicy() {
        let showMeters = isPanelOpen && isExpanded && !needsPermissionIntro
        var failure: String?

        for channel in channels {
            let desired: ProcessTapChannel.Mode?
            if channel.isAdjusted {
                desired = needsPermissionIntro ? nil : .control
            } else {
                desired = showMeters && channel.isPlaying ? .monitor : nil
            }

            guard let desired else {
                channel.tap = nil
                channel.level = 0
                continue
            }
            if let tap = channel.tap, tap.mode == desired, !channel.tapIsStale {
                tap.gain = channel.gain
                tap.isMuted = channel.isMuted
                continue
            }
            channel.tap = nil
            channel.tapIsStale = false
            guard !output.deviceUID.isEmpty else { continue }
            do {
                channel.tap = try ProcessTapChannel(processObjectIDs: channel.processObjectIDs,
                                                    outputDeviceUID: output.deviceUID,
                                                    mode: desired,
                                                    gain: channel.gain,
                                                    muted: channel.isMuted)
            } catch {
                failure = "\(error)"
            }
        }

        tapError = failure
        updateMeterTimer(running: channels.contains { $0.tap != nil } && showMeters)
    }

    private func updateMeterTimer(running: Bool) {
        if running, meterTimer == nil {
            meterTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.tickMeters() }
            }
        } else if !running, let timer = meterTimer {
            timer.invalidate()
            meterTimer = nil
            for channel in channels { channel.level = 0 }
        }
    }

    private func tickMeters() {
        for channel in channels {
            guard let tap = channel.tap else { continue }
            let peak = tap.takePeak()
            // Map -60 dB…0 dB onto 0…1 so quiet sources still register.
            let scaled = peak > 0 ? max(0, 1 + 20 * log10(peak) / 60) : 0
            let decayed = channel.level * 0.8
            let next = max(scaled, decayed)
            if abs(next - channel.level) > 0.005 { channel.level = next }
        }
    }
}
