import Foundation
import CoreAudio
import AudioToolbox
import AVFoundation
import Darwin
import FloatingVoiceCore

// Device helpers adapted from agent-voice native/audio.swift. Devices are matched by persistent CoreAudio UID
// (or name), as agent-voice saves them.

public struct AudioDeviceChoice: Sendable {
    public let id: AudioDeviceID
    public let uid: String
    public let name: String
    public let input: Bool
    public let output: Bool
}

func audioString(_ id: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> String {
    var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size), value: Unmanaged<CFString>?
    guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr, let string = value?.takeRetainedValue() else { return "" }
    return string as String
}

public func audioDevices() -> [AudioDeviceChoice] {
    var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return [] }
    var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
    guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr else { return [] }
    func hasStreams(_ id: AudioDeviceID, _ input: Bool) -> Bool {
        var property = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: input ? kAudioObjectPropertyScopeInput : kAudioObjectPropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
        var count: UInt32 = 0
        return AudioObjectGetPropertyDataSize(id, &property, 0, nil, &count) == noErr && count > 0
    }
    return ids.compactMap { id in
        let uid = audioString(id, kAudioDevicePropertyDeviceUID), name = audioString(id, kAudioObjectPropertyName)
        if uid.isEmpty || uid.hasPrefix("local.agent-voice.") { return nil }
        return AudioDeviceChoice(id: id, uid: uid, name: name, input: hasStreams(id, true), output: hasStreams(id, false))
    }
}

/// Four-character CoreAudio codes, e.g. transport "blue"/"blea" (Bluetooth) or output data source "hdpn".
func fourCC(_ value: UInt32) -> String {
    let bytes = [24, 16, 8, 0].map { UInt8((value >> UInt32($0)) & 0xff) }
    return bytes.allSatisfy { $0 >= 32 && $0 < 127 } ? String(bytes: bytes, encoding: .ascii) ?? "" : ""
}

func audioCode(_ id: AudioDeviceID, _ selector: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope) -> String {
    var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    var value: UInt32 = 0, size = UInt32(MemoryLayout<UInt32>.size)
    guard AudioObjectHasProperty(id, &address), AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr else { return "" }
    return fourCC(value)
}

func defaultAudioDevice(input: Bool) -> AudioDeviceID? {
    var address = AudioObjectPropertyAddress(mSelector: input ? kAudioHardwarePropertyDefaultInputDevice : kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var id: AudioDeviceID = 0, size = UInt32(MemoryLayout<AudioDeviceID>.size)
    return AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id) == noErr && id != 0 ? id : nil
}

func selectDevice(_ choices: [AudioDeviceChoice], _ wanted: String, input: Bool) -> AudioDeviceChoice? {
    if wanted.isEmpty || wanted == "default" {
        let def = defaultAudioDevice(input: input)
        return choices.first { $0.id == def }
    }
    return choices.first { ($0.uid == wanted || $0.name == wanted) && (input ? $0.input : $0.output) }
}

func audioError(_ code: Int, _ text: String) -> NSError {
    NSError(domain: "floating-voice", code: code, userInfo: [NSLocalizedDescriptionKey: text])
}

func assignAudioDevice(_ node: AVAudioIONode, _ device: AudioDeviceID, _ element: UInt32 = 0) throws {
    guard let unit = node.audioUnit else { throw audioError(4, "Audio unit unavailable") }
    var value = device
    let status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, element, &value, UInt32(MemoryLayout<AudioDeviceID>.size))
    if status != noErr { throw audioError(Int(status), "Selected audio device could not be routed (\(status))") }
    var actual: AudioDeviceID = 0, size = UInt32(MemoryLayout<AudioDeviceID>.size)
    let readStatus = AudioUnitGetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, element, &actual, &size)
    if readStatus != noErr || actual != device { throw audioError(5, "The audio engine did not confirm the selected device.") }
}

func audioDeviceMatches(_ node: AVAudioIONode, _ device: AudioDeviceID, _ element: UInt32) -> Bool {
    guard let unit = node.audioUnit else { return false }
    var actual: AudioDeviceID = 0, size = UInt32(MemoryLayout<AudioDeviceID>.size)
    return AudioUnitGetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, element, &actual, &size) == noErr && actual == device
}

/// Echo cancellation "auto" turns Apple's voice processing off for headphones (no speaker-to-mic path): Bluetooth /
/// Bluetooth LE transports, or built-in output on its headphones data source. Same rule as agent-voice.
public func resolveEcho(setting: String, outputDevice: String) -> (effective: Bool, reason: String) {
    if setting == "on" { return (true, "setting") }
    if setting == "off" { return (false, "setting") }
    if let headphones = headphoneOutput(outputDevice) { return (false, headphones) }
    return (true, "speakers")
}

/// "Bluetooth output" / "headphones" when the output has no speaker-to-mic path, else nil (speakers, or unknown).
public func headphoneOutput(_ outputDevice: String) -> String? {
    guard let out = selectDevice(audioDevices(), outputDevice, input: false) else { return nil }
    let transport = audioCode(out.id, kAudioDevicePropertyTransportType, kAudioObjectPropertyScopeGlobal)
    if ["blue", "blea"].contains(transport) { return "Bluetooth output" }
    if transport == "bltn" && audioCode(out.id, kAudioDevicePropertyDataSource, kAudioObjectPropertyScopeOutput) == "hdpn" { return "headphones" }
    return nil
}

/// Which other processes are capturing microphone input now (CoreAudio process objects, macOS 14+). Read-only:
/// it opens no device and needs no microphone permission.
public final class CoreAudioMicHolders: MicHolderCheck {
    public init() {}

    public func otherCapturers() -> [MicHolder] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr else { return [] }
        let me = getpid()
        return ids.compactMap { object in
            guard let pid: pid_t = Self.property(object, kAudioProcessPropertyPID), pid != me,
                  let running: UInt32 = Self.property(object, kAudioProcessPropertyIsRunningInput), running != 0 else { return nil }
            let path = Self.path(pid)
            return MicHolder(pid: pid, path: path, isAgentVoice: Self.isAgentVoice(path))
        }
    }

    /// agent-voice's native helper is `<agent-voice>/bin/audio-macos`, spawned by the OpenCode / Pi process.
    public static func isAgentVoice(_ path: String) -> Bool {
        path.hasSuffix("/bin/audio-macos") || path.contains("/agent-voice/")
    }

    static func property<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> T? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<T>.size)
        let pointer = UnsafeMutableRawPointer.allocate(byteCount: MemoryLayout<T>.size, alignment: MemoryLayout<T>.alignment)
        defer { pointer.deallocate() }
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, pointer) == noErr else { return nil }
        return pointer.load(as: T.self)
    }

    static func path(_ pid: pid_t) -> String {
        var buffer = [CChar](repeating: 0, count: 4096)
        let n = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        return n > 0 ? String(cString: buffer) : "pid \(pid)"
    }
}
