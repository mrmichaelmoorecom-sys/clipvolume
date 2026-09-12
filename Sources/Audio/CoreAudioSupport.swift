import AudioToolbox
import CoreAudio
import Foundation

/// Thin, throwing wrappers over the C Core Audio property API.

struct CoreAudioError: Error, CustomStringConvertible {
    let status: OSStatus
    let context: String

    var description: String { "\(context): \(fourCharCode(status))" }
}

/// Renders an OSStatus as its four-char code when it is one ('!obj', 'who?', …).
func fourCharCode(_ status: OSStatus) -> String {
    let n = UInt32(bitPattern: status)
    let bytes = [UInt8(n >> 24 & 0xFF), UInt8(n >> 16 & 0xFF), UInt8(n >> 8 & 0xFF), UInt8(n & 0xFF)]
    if bytes.allSatisfy({ $0 >= 0x20 && $0 < 0x7F }) {
        return "'" + String(decoding: bytes, as: UTF8.self) + "'"
    }
    return String(status)
}

extension AudioObjectPropertyAddress {
    init(_ selector: AudioObjectPropertySelector,
         scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
         element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) {
        self.init(mSelector: selector, mScope: scope, mElement: element)
    }

    fileprivate var selectorName: String { fourCharCode(OSStatus(bitPattern: mSelector)) }
}

extension AudioObjectID {
    static let system = AudioObjectID(kAudioObjectSystemObject)

    var isValid: Bool { self != kAudioObjectUnknown }

    func hasProperty(_ address: AudioObjectPropertyAddress) -> Bool {
        var address = address
        return AudioObjectHasProperty(self, &address)
    }

    func isSettable(_ address: AudioObjectPropertyAddress) -> Bool {
        var address = address
        var settable: DarwinBoolean = false
        return AudioObjectIsPropertySettable(self, &address, &settable) == noErr && settable.boolValue
    }

    func read<T>(_ address: AudioObjectPropertyAddress, initial: T) throws -> T {
        var address = address
        var size = UInt32(MemoryLayout<T>.size)
        var value = initial
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(self, &address, 0, nil, &size, $0)
        }
        guard status == noErr else {
            throw CoreAudioError(status: status, context: "read \(address.selectorName) on \(self)")
        }
        return value
    }

    func readUInt32(_ address: AudioObjectPropertyAddress) throws -> UInt32 { try read(address, initial: 0) }
    func readFloat(_ address: AudioObjectPropertyAddress) throws -> Float32 { try read(address, initial: 0) }
    func readBool(_ address: AudioObjectPropertyAddress) throws -> Bool { try readUInt32(address) != 0 }
    func readObjectID(_ address: AudioObjectPropertyAddress) throws -> AudioObjectID { try read(address, initial: kAudioObjectUnknown) }
    func readPID(_ address: AudioObjectPropertyAddress) throws -> pid_t { try read(address, initial: -1) }

    func readString(_ address: AudioObjectPropertyAddress) throws -> String {
        var address = address
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(self, &address, 0, nil, &size, $0)
        }
        guard status == noErr else {
            throw CoreAudioError(status: status, context: "read \(address.selectorName) on \(self)")
        }
        guard let value else {
            throw CoreAudioError(status: -1, context: "read \(address.selectorName) on \(self) returned null")
        }
        // Core Audio hands back a +1 reference.
        return value.takeRetainedValue() as String
    }

    func readArray<T>(_ address: AudioObjectPropertyAddress, of type: T.Type) throws -> [T] {
        var address = address
        var size: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(self, &address, 0, nil, &size)
        guard status == noErr else {
            throw CoreAudioError(status: status, context: "size of \(address.selectorName) on \(self)")
        }
        let count = Int(size) / MemoryLayout<T>.stride
        guard count > 0 else { return [] }
        let buffer = UnsafeMutablePointer<T>.allocate(capacity: count)
        defer { buffer.deallocate() }
        status = AudioObjectGetPropertyData(self, &address, 0, nil, &size, buffer)
        guard status == noErr else {
            throw CoreAudioError(status: status, context: "read \(address.selectorName) on \(self)")
        }
        return Array(UnsafeBufferPointer(start: buffer, count: Int(size) / MemoryLayout<T>.stride))
    }

    func write<T>(_ address: AudioObjectPropertyAddress, value: T) throws {
        var address = address
        var value = value
        let status = withUnsafePointer(to: &value) {
            AudioObjectSetPropertyData(self, &address, 0, nil, UInt32(MemoryLayout<T>.size), $0)
        }
        guard status == noErr else {
            throw CoreAudioError(status: status, context: "write \(address.selectorName) on \(self)")
        }
    }

    // MARK: Device conveniences

    func deviceUID() throws -> String { try readString(.init(kAudioDevicePropertyDeviceUID)) }
    func objectName() throws -> String { try readString(.init(kAudioObjectPropertyName)) }

    /// Number of streams the device exposes in the given scope (0 = device has no I/O on that side).
    func streamCount(scope: AudioObjectPropertyScope) -> Int {
        var address = AudioObjectPropertyAddress(kAudioDevicePropertyStreams, scope: scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(self, &address, 0, nil, &size) == noErr else { return 0 }
        return Int(size) / MemoryLayout<AudioObjectID>.stride
    }
}

/// RAII wrapper around `AudioObjectAddPropertyListenerBlock`; the listener is removed on deinit.
/// The handler always runs on the main queue.
final class PropertyListener {
    private let object: AudioObjectID
    private var address: AudioObjectPropertyAddress
    private let block: AudioObjectPropertyListenerBlock

    init?(object: AudioObjectID, address: AudioObjectPropertyAddress, handler: @escaping @MainActor () -> Void) {
        self.object = object
        self.address = address
        self.block = { _, _ in
            MainActor.assumeIsolated { handler() }
        }
        guard AudioObjectAddPropertyListenerBlock(object, &self.address, .main, block) == noErr else { return nil }
    }

    deinit {
        AudioObjectRemovePropertyListenerBlock(object, &address, .main, block)
    }
}
