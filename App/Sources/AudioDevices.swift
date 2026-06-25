import Foundation
import CoreAudio
import Observation

struct AudioDeviceInfo: Identifiable, Hashable {
    let id: AudioDeviceID
    let uid: String
    let name: String
}

/// Live list of input / output audio devices and the current system defaults, for the Audio settings
/// section. Refreshes when devices are plugged/unplugged or the default device changes, so the menus
/// always reflect what's in use.
@Observable @MainActor
final class AudioDevicesModel {
    private(set) var inputs: [AudioDeviceInfo] = []
    private(set) var outputs: [AudioDeviceInfo] = []
    private(set) var defaultInputName = ""
    private(set) var defaultOutputName = ""

    @ObservationIgnored private var listening = false
    @ObservationIgnored private lazy var onChange: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
        Task { @MainActor in self?.refresh() }
    }

    private static let watched: [AudioObjectPropertySelector] = [
        kAudioHardwarePropertyDevices,
        kAudioHardwarePropertyDefaultInputDevice,
        kAudioHardwarePropertyDefaultOutputDevice,
    ]

    func start() {
        refresh()
        guard !listening else { return }
        listening = true
        let system = AudioObjectID(kAudioObjectSystemObject)
        for selector in Self.watched {
            var addr = Self.address(selector)
            AudioObjectAddPropertyListenerBlock(system, &addr, DispatchQueue.main, onChange)
        }
    }

    func stop() {
        guard listening else { return }
        listening = false
        let system = AudioObjectID(kAudioObjectSystemObject)
        for selector in Self.watched {
            var addr = Self.address(selector)
            AudioObjectRemovePropertyListenerBlock(system, &addr, DispatchQueue.main, onChange)
        }
    }

    func refresh() {
        let all = Self.allDevices()
        inputs = all.filter { Self.channelCount($0.id, scope: kAudioObjectPropertyScopeInput) > 0 }
        outputs = all.filter { Self.channelCount($0.id, scope: kAudioObjectPropertyScopeOutput) > 0 }
        defaultInputName = Self.defaultDeviceName(kAudioHardwarePropertyDefaultInputDevice)
        defaultOutputName = Self.defaultDeviceName(kAudioHardwarePropertyDefaultOutputDevice)
    }

    // MARK: - CoreAudio

    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector,
                                   mScope: kAudioObjectPropertyScopeGlobal,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    private static func allDevices() -> [AudioDeviceInfo] {
        var addr = address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap { id in
            guard let uid = stringProperty(id, kAudioDevicePropertyDeviceUID),
                  let name = stringProperty(id, kAudioObjectPropertyName) else { return nil }
            return AudioDeviceInfo(id: id, uid: uid, name: name)
        }
    }

    private static func channelCount(_ devID: AudioDeviceID, scope: AudioObjectPropertyScope) -> Int {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration,
                                              mScope: scope, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(devID, &addr, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let ptr = UnsafeMutableRawPointer.allocate(byteCount: Int(size),
                                                   alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { ptr.deallocate() }
        guard AudioObjectGetPropertyData(devID, &addr, 0, nil, &size, ptr) == noErr else { return 0 }
        let abl = UnsafeMutableAudioBufferListPointer(ptr.assumingMemoryBound(to: AudioBufferList.self))
        return abl.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private static func defaultDeviceName(_ selector: AudioObjectPropertySelector) -> String {
        var addr = address(selector)
        var devID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &devID) == noErr,
              devID != 0 else { return "" }
        return stringProperty(devID, kAudioObjectPropertyName) ?? ""
    }

    private static func stringProperty(_ devID: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> String? {
        var addr = address(selector)
        var value: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(devID, &addr, 0, nil, &size, $0)
        }
        return status == noErr ? (value as String) : nil
    }
}
