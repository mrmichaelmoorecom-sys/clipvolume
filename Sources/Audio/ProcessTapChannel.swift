import Accelerate
import CoreAudio
import Foundation

/// One Core Audio process tap covering the processes of a single app.
///
/// - `.monitor`: an unmuted tap. The app's audio reaches the speakers untouched; we only measure its level.
/// - `.control`: the tap mutes the app at the output device and we play its audio back ourselves,
///   scaled by `gain` (or silenced while `isMuted`). This is how per-app volume works without a
///   virtual audio driver. Creating the first tap triggers the one-time "System Audio Recording" prompt.
final class ProcessTapChannel {
    enum Mode { case monitor, control }

    /// Shared between the main thread and the real-time IO thread. Plain 32-bit loads/stores; no locks.
    struct SharedState {
        var gain: Float
        var muted: UInt32
        var peak: Float
    }

    let mode: Mode
    let processObjectIDs: [AudioObjectID]
    let outputDeviceUID: String

    private var tapID: AudioObjectID = kAudioObjectUnknown
    private var aggregateID: AudioObjectID = kAudioObjectUnknown
    private var ioProcID: AudioDeviceIOProcID?
    private var tapChannels = 2
    private let state: UnsafeMutablePointer<SharedState>

    var gain: Float {
        get { state.pointee.gain }
        set { state.pointee.gain = max(0, min(1, newValue)) }
    }

    var isMuted: Bool {
        get { state.pointee.muted != 0 }
        set { state.pointee.muted = newValue ? 1 : 0 }
    }

    /// Highest sample magnitude (0…1) seen since the previous call.
    func takePeak() -> Float {
        let peak = state.pointee.peak
        state.pointee.peak = 0
        return peak
    }

    init(processObjectIDs: [AudioObjectID], outputDeviceUID: String, mode: Mode, gain: Float, muted: Bool) throws {
        self.mode = mode
        self.processObjectIDs = processObjectIDs
        self.outputDeviceUID = outputDeviceUID
        state = .allocate(capacity: 1)
        state.initialize(to: SharedState(gain: max(0, min(1, gain)), muted: muted ? 1 : 0, peak: 0))
        // All stored properties are set, so deinit runs (and tears down) if this throws.
        try activate()
    }

    deinit {
        teardown()
        state.deinitialize(count: 1)
        state.deallocate()
    }

    // MARK: Setup

    private func activate() throws {
        let description = CATapDescription(stereoMixdownOfProcesses: processObjectIDs)
        description.uuid = UUID()
        description.name = "clipvolume"
        description.isPrivate = true
        description.muteBehavior = mode == .control ? .muted : .unmuted
        if #available(macOS 26.0, *) {
            // Keep following the app if its audio helper process gets relaunched.
            description.isProcessRestoreEnabled = true
        }

        var tap = kAudioObjectUnknown
        var status = AudioHardwareCreateProcessTap(description, &tap)
        guard status == noErr, tap.isValid else {
            throw CoreAudioError(status: status, context: "create process tap")
        }
        tapID = tap

        let format = try tapID.read(.init(kAudioTapPropertyFormat), initial: AudioStreamBasicDescription())
        tapChannels = max(1, Int(format.mChannelsPerFrame))

        // A private aggregate of the tap plus the real output device gives us one IO callback
        // with the tapped audio as input and the speakers as output.
        let aggregateDescription: [String: Any] = [
            kAudioAggregateDeviceNameKey: "clipvolume tap",
            kAudioAggregateDeviceUIDKey: "com.clipvolume.tap." + description.uuid.uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputDeviceUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputDeviceUID]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapUIDKey: description.uuid.uuidString,
                kAudioSubTapDriftCompensationKey: true,
            ]],
        ]
        var aggregate = kAudioObjectUnknown
        status = AudioHardwareCreateAggregateDevice(aggregateDescription as CFDictionary, &aggregate)
        guard status == noErr, aggregate.isValid else {
            throw CoreAudioError(status: status, context: "create aggregate device")
        }
        aggregateID = aggregate

        let state = self.state
        let control = mode == .control
        let tapChannels = self.tapChannels
        var procID: AudioDeviceIOProcID?
        status = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, nil) { _, input, _, output, _ in
            Self.render(input: input, output: output, tapChannels: tapChannels, control: control, state: state)
        }
        guard status == noErr, let procID else {
            throw CoreAudioError(status: status, context: "create IO proc")
        }
        ioProcID = procID

        status = AudioDeviceStart(aggregateID, procID)
        guard status == noErr else {
            throw CoreAudioError(status: status, context: "start aggregate device")
        }
    }

    private func teardown() {
        if aggregateID.isValid, let procID = ioProcID {
            AudioDeviceStop(aggregateID, procID)
            AudioDeviceDestroyIOProcID(aggregateID, procID)
        }
        ioProcID = nil
        if aggregateID.isValid { AudioHardwareDestroyAggregateDevice(aggregateID) }
        aggregateID = kAudioObjectUnknown
        if tapID.isValid { AudioHardwareDestroyProcessTap(tapID) }
        tapID = kAudioObjectUnknown
    }

    // MARK: Real-time render (HAL IO thread: no allocation, no locks, no Objective-C)

    private struct ChannelView {
        let data: UnsafeMutablePointer<Float>
        let stride: Int
        let frames: Int
    }

    private static func render(input: UnsafePointer<AudioBufferList>,
                               output: UnsafeMutablePointer<AudioBufferList>,
                               tapChannels: Int,
                               control: Bool,
                               state: UnsafeMutablePointer<SharedState>) {
        let inputList = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        let outputList = UnsafeMutableAudioBufferListPointer(output)

        // The tap's channels are the last `tapChannels` channels of the input list. Anything before
        // them belongs to the output device's own input streams (an AirPods mic, say), which we ignore.
        let tapOffset = max(0, totalChannels(inputList) - tapChannels)

        var peak: Float = 0
        for t in 0..<tapChannels {
            guard let ch = channel(inputList, index: tapOffset + t), ch.frames > 0 else { continue }
            var channelPeak: Float = 0
            vDSP_maxmgv(ch.data, ch.stride, &channelPeak, vDSP_Length(ch.frames))
            peak = max(peak, channelPeak)
        }
        if peak > state.pointee.peak { state.pointee.peak = peak }

        var gain: Float = state.pointee.muted != 0 ? 0 : state.pointee.gain
        for o in 0..<totalChannels(outputList) {
            guard let out = channel(outputList, index: o), out.frames > 0 else { continue }
            // Stereo tap → first two output channels; mono tap → every output channel; extra channels stay silent.
            let source: Int? = o < tapChannels ? o : (tapChannels == 1 ? 0 : nil)
            if control, let source, let src = channel(inputList, index: tapOffset + source), src.frames > 0 {
                vDSP_vsmul(src.data, src.stride, &gain, out.data, out.stride, vDSP_Length(min(src.frames, out.frames)))
            } else {
                vDSP_vclr(out.data, out.stride, vDSP_Length(out.frames))
            }
        }
    }

    private static func totalChannels(_ list: UnsafeMutableAudioBufferListPointer) -> Int {
        var count = 0
        for buffer in list { count += Int(buffer.mNumberChannels) }
        return count
    }

    /// Locates channel `index` in a buffer list, whether its buffers are interleaved or not.
    private static func channel(_ list: UnsafeMutableAudioBufferListPointer, index: Int) -> ChannelView? {
        var remaining = index
        for buffer in list {
            let channels = Int(buffer.mNumberChannels)
            if remaining < channels {
                guard channels > 0, let data = buffer.mData else { return nil }
                let frames = Int(buffer.mDataByteSize) / (MemoryLayout<Float>.size * channels)
                return ChannelView(data: data.assumingMemoryBound(to: Float.self) + remaining, stride: channels, frames: frames)
            }
            remaining -= channels
        }
        return nil
    }
}
