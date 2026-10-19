import CoreAudio
import Foundation

struct CoreAudioError: LocalizedError {
    let status: OSStatus
    let operation: String

    var errorDescription: String? { "\(operation) failed (OSStatus \(status))" }
}

func check(_ status: OSStatus, _ operation: @autoclosure () -> String) throws {
    guard status == noErr else { throw CoreAudioError(status: status, operation: operation()) }
}

extension AudioObjectID {
    static let system = AudioObjectID(kAudioObjectSystemObject)

    static func address(_ selector: AudioObjectPropertySelector,
                        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    func read<T: BitwiseCopyable>(_ selector: AudioObjectPropertySelector, default value: T) throws -> T {
        var address = Self.address(selector)
        var size = UInt32(MemoryLayout<T>.size)
        var result = value
        try check(AudioObjectGetPropertyData(self, &address, 0, nil, &size, &result),
                  "Reading property \(selector) of object \(self)")
        return result
    }

    func readArray<T: BitwiseCopyable>(_ selector: AudioObjectPropertySelector, empty: T) throws -> [T] {
        var address = Self.address(selector)
        var size: UInt32 = 0
        try check(AudioObjectGetPropertyDataSize(self, &address, 0, nil, &size),
                  "Reading size of property \(selector) of object \(self)")
        var result = [T](repeating: empty, count: Int(size) / MemoryLayout<T>.stride)
        guard !result.isEmpty else { return [] }
        try check(AudioObjectGetPropertyData(self, &address, 0, nil, &size, &result),
                  "Reading property \(selector) of object \(self)")
        return Array(result.prefix(Int(size) / MemoryLayout<T>.stride))
    }

    func readString(_ selector: AudioObjectPropertySelector) throws -> String {
        var address = Self.address(selector)
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var value: Unmanaged<CFString>?
        try check(AudioObjectGetPropertyData(self, &address, 0, nil, &size, &value),
                  "Reading string property \(selector) of object \(self)")
        return (value?.takeRetainedValue() as String?) ?? ""
    }

    static func defaultOutputDevice() throws -> AudioObjectID {
        try system.read(kAudioHardwarePropertyDefaultOutputDevice, default: AudioObjectID(kAudioObjectUnknown))
    }

    func deviceUID() throws -> String {
        try readString(kAudioDevicePropertyDeviceUID)
    }
}
