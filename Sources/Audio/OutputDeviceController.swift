import AudioToolbox
import CoreAudio
import Foundation

struct OutputDeviceInfo: Identifiable, Hashable {
    let id: AudioObjectID
    let name: String
}

/// Tracks the system's default output device and exposes its master volume and mute.
/// No permissions are required for anything in here.
@MainActor
final class OutputDeviceController: ObservableObject {
    @Published private(set) var deviceID: AudioObjectID = kAudioObjectUnknown
    @Published private(set) var deviceUID: String = ""
    @Published private(set) var deviceName: String = "No Output Device"
    @Published private(set) var volume: Float = 0
    @Published private(set) var isMuted = false
    @Published private(set) var canSetVolume = false
    @Published private(set) var canMute = false
    @Published private(set) var availableDevices: [OutputDeviceInfo] = []

    /// Called on the main actor after the default device, volume or mute changes.
    var onChange: (@MainActor () -> Void)?

    private var defaultDeviceListener: PropertyListener?
    private var deviceListListener: PropertyListener?
    private var deviceListeners: [PropertyListener] = []

    private static let virtualVolume = AudioObjectPropertyAddress(
        kAudioHardwareServiceDeviceProperty_VirtualMainVolume, scope: kAudioObjectPropertyScopeOutput)
    private static let mainVolume = AudioObjectPropertyAddress(
        kAudioDevicePropertyVolumeScalar, scope: kAudioObjectPropertyScopeOutput)
    private static let mainMute = AudioObjectPropertyAddress(
        kAudioDevicePropertyMute, scope: kAudioObjectPropertyScopeOutput)

    private static func channelVolume(_ channel: UInt32) -> AudioObjectPropertyAddress {
        .init(kAudioDevicePropertyVolumeScalar, scope: kAudioObjectPropertyScopeOutput, element: channel)
    }

    private static func channelMute(_ channel: UInt32) -> AudioObjectPropertyAddress {
        .init(kAudioDevicePropertyMute, scope: kAudioObjectPropertyScopeOutput, element: channel)
    }

    init() {
        defaultDeviceListener = PropertyListener(
            object: .system, address: .init(kAudioHardwarePropertyDefaultOutputDevice)
        ) { [weak self] in self?.reloadDefaultDevice() }
        deviceListListener = PropertyListener(
            object: .system, address: .init(kAudioHardwarePropertyDevices)
        ) { [weak self] in self?.reloadDeviceList() }
        reloadDeviceList()
        reloadDefaultDevice()
    }

    // MARK: Actions

    func setVolume(_ value: Float) {
        let clamped = max(0, min(1, value))
        guard deviceID.isValid else { return }
        let device = deviceID
        if device.isSettable(Self.virtualVolume) {
            try? device.write(Self.virtualVolume, value: clamped)
        } else if device.isSettable(Self.mainVolume) {
            try? device.write(Self.mainVolume, value: clamped)
        } else {
            for channel: UInt32 in 1...2 where device.isSettable(Self.channelVolume(channel)) {
                try? device.write(Self.channelVolume(channel), value: clamped)
            }
        }
        volume = clamped
        // Nudging the slider is a natural "unmute" gesture, same as the system slider.
        if isMuted, clamped > 0 { setMuted(false) }
    }

    func setMuted(_ muted: Bool) {
        guard deviceID.isValid else { return }
        let device = deviceID
        let value: UInt32 = muted ? 1 : 0
        if device.isSettable(Self.mainMute) {
            try? device.write(Self.mainMute, value: value)
        } else {
            for channel: UInt32 in 1...2 where device.isSettable(Self.channelMute(channel)) {
                try? device.write(Self.channelMute(channel), value: value)
            }
        }
        isMuted = muted
    }

    func toggleMute() { setMuted(!isMuted) }

    func selectDevice(_ id: AudioObjectID) {
        try? AudioObjectID.system.write(.init(kAudioHardwarePropertyDefaultOutputDevice), value: id)
    }

    // MARK: Refresh

    private func reloadDefaultDevice() {
        let id = (try? AudioObjectID.system.readObjectID(.init(kAudioHardwarePropertyDefaultOutputDevice))) ?? kAudioObjectUnknown
        deviceID = id
        deviceUID = (try? id.deviceUID()) ?? ""
        deviceName = (try? id.objectName()) ?? "No Output Device"

        deviceListeners = []
        if id.isValid {
            let addresses: [AudioObjectPropertyAddress] = [
                Self.virtualVolume,
                .init(kAudioDevicePropertyVolumeScalar, scope: kAudioObjectPropertyScopeOutput, element: kAudioObjectPropertyElementWildcard),
                .init(kAudioDevicePropertyMute, scope: kAudioObjectPropertyScopeOutput, element: kAudioObjectPropertyElementWildcard),
            ]
            deviceListeners = addresses.compactMap { address in
                PropertyListener(object: id, address: address) { [weak self] in self?.refreshLevels() }
            }
        }
        refreshLevels()
    }

    private func refreshLevels() {
        let device = deviceID
        guard device.isValid else {
            volume = 0; isMuted = false; canSetVolume = false; canMute = false
            onChange?()
            return
        }

        if device.hasProperty(Self.virtualVolume) {
            volume = (try? device.readFloat(Self.virtualVolume)) ?? 0
            canSetVolume = device.isSettable(Self.virtualVolume)
        } else if device.hasProperty(Self.mainVolume) {
            volume = (try? device.readFloat(Self.mainVolume)) ?? 0
            canSetVolume = device.isSettable(Self.mainVolume)
        } else if device.hasProperty(Self.channelVolume(1)) {
            volume = (try? device.readFloat(Self.channelVolume(1))) ?? 0
            canSetVolume = device.isSettable(Self.channelVolume(1))
        } else {
            volume = 1
            canSetVolume = false
        }

        if device.hasProperty(Self.mainMute) {
            isMuted = (try? device.readBool(Self.mainMute)) ?? false
            canMute = device.isSettable(Self.mainMute)
        } else if device.hasProperty(Self.channelMute(1)) {
            isMuted = (try? device.readBool(Self.channelMute(1))) ?? false
            canMute = device.isSettable(Self.channelMute(1))
        } else {
            isMuted = false
            canMute = false
        }
        onChange?()
    }

    private func reloadDeviceList() {
        let ids = (try? AudioObjectID.system.readArray(.init(kAudioHardwarePropertyDevices), of: AudioObjectID.self)) ?? []
        availableDevices = ids.compactMap { id in
            guard id.streamCount(scope: kAudioObjectPropertyScopeOutput) > 0,
                  let name = try? id.objectName() else { return nil }
            return OutputDeviceInfo(id: id, name: name)
        }
    }
}
