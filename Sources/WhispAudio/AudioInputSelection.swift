import Foundation
import CoreAudio

/// Resolves the user's chosen input device (stored as a CoreAudio device UID under
/// `audioInputDeviceUID`) to an `AudioDeviceID`. Empty / unset / disconnected → `nil`, so the
/// capturers fall back to their default (built-in mic for dictation, default input for conference).
public enum AudioInputSelection {
    public static func selectedDeviceID() -> AudioDeviceID? {
        guard let uid = UserDefaults.standard.string(forKey: "audioInputDeviceUID"), !uid.isEmpty else { return nil }
        return deviceID(forUID: uid)
    }

    /// The CoreAudio device whose UID matches, or `nil` if it isn't currently connected.
    public static func deviceID(forUID uid: String) -> AudioDeviceID? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr,
              size > 0 else { return nil }
        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr
            else { return nil }
        return ids.first { deviceUID(of: $0) == uid }
    }

    private static func deviceUID(of devID: AudioDeviceID) -> String? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(devID, &addr, 0, nil, &size, $0)
        }
        return status == noErr ? (value as String) : nil
    }
}
