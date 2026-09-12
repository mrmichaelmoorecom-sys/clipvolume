import AppKit
import Foundation

struct PlayerState: Equatable {
    enum Status: String { case playing, paused, stopped, unknown }

    let bundleID: String
    let status: Status
    let track: String?

    var isPlaying: Bool { status == .playing }
}

/// Play/pause for media apps that expose it over Apple Events: Spotify, Music, TV, QuickTime Player, VLC.
/// Browsers don't (Chrome/Safari only allow JavaScript injection, and only when the user enables it),
/// so a YouTube tab gets mute but not pause.
///
/// Scripts run in an `osascript` subprocess so a hung player can never freeze the panel. macOS shows
/// a one-time "clipvolume wants to control Spotify" prompt per player (Automation, not Accessibility).
@MainActor
final class PlaybackController: ObservableObject {
    struct Player {
        let bundleID: String
        /// AppleScript run inside `tell application id …`; must set `playState` (playing/paused/stopped) and may set `trackName`.
        let stateScript: String
        /// AppleScript run inside `tell application id …` that toggles playback.
        let playPauseScript: String
    }

    private static let iTunesStyle = """
        set playState to (player state as string)
        try
            set trackName to (name of current track) & "  ·  " & (artist of current track)
        end try
        """

    static let players: [Player] = [
        Player(bundleID: "com.spotify.client", stateScript: iTunesStyle, playPauseScript: "playpause"),
        Player(bundleID: "com.apple.Music", stateScript: iTunesStyle, playPauseScript: "playpause"),
        Player(bundleID: "com.apple.TV",
               stateScript: """
                   set playState to (player state as string)
                   try
                       set trackName to name of current track
                   end try
                   """,
               playPauseScript: "playpause"),
        Player(bundleID: "com.apple.QuickTimePlayerX",
               stateScript: """
                   if (count of documents) > 0 then
                       if playing of document 1 then
                           set playState to "playing"
                       else
                           set playState to "paused"
                       end if
                       set trackName to name of document 1
                   else
                       set playState to "stopped"
                   end if
                   """,
               playPauseScript: """
                   if (count of documents) > 0 then
                       if playing of document 1 then
                           pause document 1
                       else
                           play document 1
                       end if
                   end if
                   """),
        Player(bundleID: "org.videolan.vlc",
               stateScript: """
                   if playing then
                       set playState to "playing"
                   else
                       set playState to "paused"
                   end if
                   try
                       set trackName to name of current item
                   end try
                   """,
               playPauseScript: "play"),
    ]

    static func supports(_ bundleID: String?) -> Bool {
        guard let bundleID else { return false }
        return players.contains { $0.bundleID == bundleID }
    }

    @Published private(set) var states: [String: PlayerState] = [:]
    /// Supported players that are running but didn't answer — almost always a declined Automation prompt.
    @Published private(set) var unresponsive: Set<String> = []

    var onChange: (@MainActor () -> Void)?

    private var timer: Timer?
    private var inFlight = false

    func startPolling() {
        guard timer == nil else { return }
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    func stopPolling() {
        timer?.invalidate()
        timer = nil
    }

    static func runningPlayers() -> [Player] {
        players.filter { !NSRunningApplication.runningApplications(withBundleIdentifier: $0.bundleID).isEmpty }
    }

    func refresh() {
        let running = Self.runningPlayers()
        guard !running.isEmpty else {
            if !states.isEmpty || !unresponsive.isEmpty {
                states = [:]
                unresponsive = []
                onChange?()
            }
            return
        }
        guard !inFlight else { return }
        inFlight = true

        Self.run(Self.stateScript(for: running)) { [weak self] output in
            guard let self else { return }
            self.inFlight = false
            var next: [String: PlayerState] = [:]
            for line in output.split(separator: "\n") {
                let parts = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
                guard parts.count >= 2 else { continue }
                let track = parts.count > 2 ? parts[2].trimmingCharacters(in: .whitespaces) : ""
                next[parts[0]] = PlayerState(bundleID: parts[0],
                                             status: PlayerState.Status(rawValue: parts[1]) ?? .unknown,
                                             track: track.isEmpty ? nil : track)
            }
            let missing = Set(running.map(\.bundleID)).subtracting(next.keys)
            if next != self.states || missing != self.unresponsive {
                self.states = next
                self.unresponsive = missing
                self.onChange?()
            }
        }
    }

    func playPause(_ bundleID: String) {
        guard let player = Self.players.first(where: { $0.bundleID == bundleID }) else { return }
        // Flip optimistically so the button responds before the round trip completes.
        if let current = states[bundleID] {
            states[bundleID] = PlayerState(bundleID: bundleID, status: current.isPlaying ? .paused : .playing, track: current.track)
            onChange?()
        }
        Self.run(Self.commandScript(player, player.playPauseScript)) { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                MainActor.assumeIsolated { self?.refresh() }
            }
        }
    }

    func openAutomationSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")!)
    }

    // MARK: Scripts

    static func stateScript(for players: [Player]) -> String {
        var script = "set out to \"\"\n"
        for player in players {
            // `is running` never launches the app; every player is isolated in its own try block.
            script += """
                try
                    if application id "\(player.bundleID)" is running then
                        set playState to "unknown"
                        set trackName to ""
                        with timeout of 2 seconds
                            tell application id "\(player.bundleID)"
                                try
                \(player.stateScript)
                                end try
                            end tell
                        end timeout
                        set out to out & "\(player.bundleID)" & tab & playState & tab & trackName & linefeed
                    end if
                end try

                """
        }
        return script + "return out"
    }

    static func commandScript(_ player: Player, _ body: String) -> String {
        """
        try
            if application id "\(player.bundleID)" is running then
                with timeout of 3 seconds
                    tell application id "\(player.bundleID)"
        \(body)
                    end tell
                end timeout
            end if
        end try
        """
    }

    private static func run(_ script: String, completion: @escaping @MainActor (String) -> Void) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-"]
        let stdin = Pipe()
        let stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { _ in
            let text = String(decoding: stdout.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            DispatchQueue.main.async { MainActor.assumeIsolated { completion(text) } }
        }
        do {
            try process.run()
        } catch {
            DispatchQueue.main.async { MainActor.assumeIsolated { completion("") } }
            return
        }
        stdin.fileHandleForWriting.write(Data(script.utf8))
        try? stdin.fileHandleForWriting.close()
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
            if process.isRunning { process.terminate() }
        }
    }
}
