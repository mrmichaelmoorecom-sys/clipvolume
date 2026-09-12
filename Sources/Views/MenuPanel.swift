import SwiftUI

struct MenuPanel: View {
    @EnvironmentObject private var mixer: MixerModel

    var body: some View {
        VStack(spacing: 0) {
            MasterVolumeSection(output: mixer.output)
            Divider().padding(.horizontal, 12)
            MixerDisclosureRow()
            if mixer.isExpanded {
                MixerSection()
            }
            Divider().padding(.horizontal, 12)
            FooterRow()
        }
        .frame(width: 320)
        .onAppear { mixer.panelOpened() }
        .onDisappear { mixer.panelClosed() }
    }
}

// MARK: - Master volume

struct MasterVolumeSection: View {
    @ObservedObject var output: OutputDeviceController

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Button(action: output.toggleMute) {
                    Image(systemName: output.isMuted ? "speaker.slash.fill" : "speaker.fill")
                        .font(.system(size: 13))
                        .frame(width: 18)
                        .foregroundStyle(output.isMuted ? Color.red : Color.primary)
                }
                .buttonStyle(.plain)
                .disabled(!output.canMute)
                .help(output.isMuted ? "Unmute" : "Mute")

                Slider(value: Binding(get: { output.volume }, set: { output.setVolume($0) }), in: 0...1)
                    .disabled(!output.canSetVolume)

                Text(output.canSetVolume ? "\(Int((output.volume * 100).rounded()))%" : "—")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 36, alignment: .trailing)
            }

            Menu {
                ForEach(output.availableDevices) { device in
                    Button {
                        output.selectDevice(device.id)
                    } label: {
                        if device.id == output.deviceID {
                            Label(device.name, systemImage: "checkmark")
                        } else {
                            Text(device.name)
                        }
                    }
                }
            } label: {
                Label(output.deviceName, systemImage: "hifispeaker")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 10)
    }
}

// MARK: - "Mixer >" row

struct MixerDisclosureRow: View {
    @EnvironmentObject private var mixer: MixerModel

    var body: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.15)) { mixer.toggleExpanded() }
        } label: {
            HStack(spacing: 6) {
                Text("Mixer")
                    .font(.callout.weight(.medium))
                if !mixer.isExpanded, !mixer.channels.isEmpty {
                    Text("· \(mixer.channels.count) playing")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(mixer.isExpanded ? 90 : 0))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }
}

// MARK: - Mixer

struct MixerSection: View {
    @EnvironmentObject private var mixer: MixerModel

    var body: some View {
        VStack(spacing: 0) {
            if mixer.needsPermissionIntro {
                PermissionIntro()
            } else {
                if let error = mixer.tapError {
                    TapErrorRow(message: error)
                }
                if mixer.channels.isEmpty, mixer.remotePlayers.isEmpty {
                    Text("Nothing is playing audio right now.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                } else {
                    ForEach(mixer.channels) { channel in
                        MixerRow(channel: channel, playback: mixer.playback)
                    }
                    ForEach(mixer.remotePlayers) { player in
                        RemotePlayerRow(player: player, playback: mixer.playback)
                    }
                    Spacer().frame(height: 4)
                }
            }
        }
    }
}

struct MixerRow: View {
    @EnvironmentObject private var mixer: MixerModel
    @ObservedObject var channel: MixerChannel
    @ObservedObject var playback: PlaybackController

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: channel.app.icon ?? NSWorkspace.shared.icon(for: .applicationBundle))
                .resizable()
                .frame(width: 24, height: 24)

            VStack(alignment: .leading, spacing: 4) {
                Text(channel.app.name)
                    .font(.callout)
                    .lineLimit(1)
                    .truncationMode(.tail)
                LevelMeter(level: channel.level)
            }
            .frame(width: 100, alignment: .leading)
            .help(playback.states[channel.app.bundleID ?? ""]?.track ?? channel.app.name)

            Slider(value: Binding(get: { channel.gain }, set: { mixer.setGain(channel, $0) }), in: 0...1) { editing in
                if !editing { mixer.gainEditingEnded(channel) }
            }
            .controlSize(.small)
            .disabled(channel.isMuted)

            if PlaybackController.supports(channel.app.bundleID) {
                PlayPauseButton(bundleID: channel.app.bundleID ?? "", appName: channel.app.name, playback: playback)
            }

            Button {
                mixer.setMuted(channel, !channel.isMuted)
            } label: {
                Image(systemName: channel.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .font(.system(size: 12))
                    .frame(width: 18)
                    .foregroundStyle(channel.isMuted ? Color.red : Color.primary)
            }
            .buttonStyle(.plain)
            .help(channel.isMuted ? "Unmute \(channel.app.name)" : "Mute \(channel.app.name)")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .opacity(channel.isPlaying ? 1 : 0.55)
        .contextMenu {
            Button("Reset to 100%") { mixer.reset(channel) }
                .disabled(!channel.isAdjusted)
            Button("Show \(channel.app.name)") {
                NSRunningApplication(processIdentifier: channel.id)?.activate()
            }
        }
    }
}

struct LevelMeter: View {
    var level: Float

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule()
                    .fill(level > 0.92 ? Color.red : Color.green)
                    .frame(width: geo.size.width * CGFloat(min(1, max(0, level))))
            }
        }
        .frame(height: 4)
        .animation(.linear(duration: 1.0 / 30.0), value: level)
    }
}

/// A player that is playing somewhere other than this Mac's output (Spotify Connect, AirPlay…).
struct RemotePlayerRow: View {
    let player: RemotePlayer
    @ObservedObject var playback: PlaybackController

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: player.icon ?? NSWorkspace.shared.icon(for: .applicationBundle))
                .resizable()
                .frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(player.name)
                    .font(.callout)
                    .lineLimit(1)
                Text(player.state.isPlaying ? "Playing on another device" : "Paused")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .help(player.state.track ?? player.name)
            Spacer()
            PlayPauseButton(bundleID: player.id, appName: player.name, playback: playback)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
    }
}

struct PlayPauseButton: View {
    let bundleID: String
    let appName: String
    @ObservedObject var playback: PlaybackController

    var body: some View {
        if playback.unresponsive.contains(bundleID) {
            Button {
                playback.openAutomationSettings()
            } label: {
                Image(systemName: "exclamationmark.circle")
                    .font(.system(size: 12))
                    .frame(width: 18)
                    .foregroundStyle(.orange)
            }
            .buttonStyle(.plain)
            .help("clipvolume isn't allowed to control \(appName). Turn it on under Privacy & Security → Automation.")
        } else {
            let playing = playback.states[bundleID]?.isPlaying ?? false
            Button {
                playback.playPause(bundleID)
            } label: {
                Image(systemName: playing ? "pause.fill" : "play.fill")
                    .font(.system(size: 12))
                    .frame(width: 18)
            }
            .buttonStyle(.plain)
            .help(playing ? "Pause \(appName)" : "Play \(appName)")
        }
    }
}

struct PermissionIntro: View {
    @EnvironmentObject private var mixer: MixerModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("One-time permission", systemImage: "waveform.badge.mic")
                .font(.callout.weight(.medium))
            Text("To show each app's level and control it separately, macOS will ask to allow **System Audio Recording** for clipvolume. Audio is never recorded or saved — it's only measured and, when you turn an app down, passed through at the new volume.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Continue") { mixer.needsPermissionIntro = false }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(14)
    }
}

struct TapErrorRow: View {
    @EnvironmentObject private var mixer: MixerModel
    let message: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Couldn't tap app audio", systemImage: "exclamationmark.triangle")
                .font(.caption.weight(.medium))
            Text("If you declined the permission, allow clipvolume under System Audio Recording and try again. (\(message))")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Open Privacy Settings…") { mixer.openPrivacySettings() }
                .controlSize(.small)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }
}

// MARK: - Footer

struct FooterRow: View {
    @State private var launchAtLogin = LaunchAtLogin.isEnabled

    var body: some View {
        HStack {
            Toggle("Launch at Login", isOn: $launchAtLogin)
                .toggleStyle(.checkbox)
                .font(.caption)
                .onChange(of: launchAtLogin) { _, enabled in
                    LaunchAtLogin.isEnabled = enabled
                    launchAtLogin = LaunchAtLogin.isEnabled
                }
            Spacer()
            Button("Quit") { NSApp.terminate(nil) }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundStyle(.secondary)
                .keyboardShortcut("q")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }
}
