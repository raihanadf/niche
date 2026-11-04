import AudioToolbox
import CoreAudio
import Foundation

@MainActor
@Observable
final class OutputDevice {
    private(set) var symbol = "laptopcomputer"
    private(set) var transportType: UInt32 = kAudioDeviceTransportTypeBuiltIn
    private(set) var volume: Double = 0
    private(set) var isMuted = false
    private(set) var canSetVolume = false
    var isShowingVolume = false
    @ObservationIgnored var onDeviceChange: (() -> Void)?

    @ObservationIgnored private var device = AudioObjectID(kAudioObjectUnknown)
    @ObservationIgnored private var listeners: [(AudioObjectID, AudioObjectPropertyAddress)] = []

    private static let deviceChanged: AudioObjectPropertyListenerProc = { _, _, _, context in
        let device = Unmanaged<OutputDevice>.fromOpaque(context!).takeUnretainedValue()
        Task { @MainActor in device.follow() }
        return noErr
    }
    private static let propertyChanged: AudioObjectPropertyListenerProc = { _, _, _, context in
        let device = Unmanaged<OutputDevice>.fromOpaque(context!).takeUnretainedValue()
        Task { @MainActor in device.read() }
        return noErr
    }

    func start() {
        var address = Self.address(kAudioHardwarePropertyDefaultOutputDevice, scope: kAudioObjectPropertyScopeGlobal)
        AudioObjectAddPropertyListener(AudioObjectID(kAudioObjectSystemObject), &address, Self.deviceChanged,
                                       Unmanaged.passUnretained(self).toOpaque())
        follow()
    }

    func setVolume(_ level: Double) {
        guard canSetVolume else { return }
        var value = Float32(min(max(level, 0), 1))
        var address = Self.address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume)
        AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<Float32>.size), &value)
        if isMuted && value > 0 { toggleMute() }
        volume = Double(value)
    }

    func toggleMute() {
        var address = Self.address(kAudioDevicePropertyMute)
        guard AudioObjectHasProperty(device, &address) else { return }
        var muted = UInt32(isMuted ? 0 : 1)
        AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &muted)
        isMuted = muted != 0
    }

    private func follow() {
        for (object, address) in listeners {
            var address = address
            AudioObjectRemovePropertyListener(object, &address, Self.propertyChanged, Unmanaged.passUnretained(self).toOpaque())
        }
        listeners = []
        var address = Self.address(kAudioHardwarePropertyDefaultOutputDevice, scope: kAudioObjectPropertyScopeGlobal)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr else {
            NSLog("Niche cannot read the default output device")
            return
        }
        for selector in [kAudioHardwareServiceDeviceProperty_VirtualMainVolume, kAudioDevicePropertyMute, kAudioDevicePropertyDataSource] {
            var address = Self.address(selector)
            guard AudioObjectHasProperty(device, &address) else { continue }
            AudioObjectAddPropertyListener(device, &address, Self.propertyChanged, Unmanaged.passUnretained(self).toOpaque())
            listeners.append((device, address))
        }
        read()
        onDeviceChange?()
    }

    private func read() {
        var address = Self.address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume)
        var settable = DarwinBoolean(false)
        canSetVolume = AudioObjectHasProperty(device, &address)
            && AudioObjectIsPropertySettable(device, &address, &settable) == noErr && settable.boolValue
        var level = Float32(0)
        var size = UInt32(MemoryLayout<Float32>.size)
        if AudioObjectGetPropertyData(device, &address, 0, nil, &size, &level) == noErr { volume = Double(level) }
        address = Self.address(kAudioDevicePropertyMute)
        var muted = UInt32(0)
        size = UInt32(MemoryLayout<UInt32>.size)
        if AudioObjectHasProperty(device, &address) { AudioObjectGetPropertyData(device, &address, 0, nil, &size, &muted) }
        isMuted = muted != 0
        var transport = UInt32(0)
        size = UInt32(MemoryLayout<UInt32>.size)
        address = Self.address(kAudioDevicePropertyTransportType, scope: kAudioObjectPropertyScopeGlobal)
        if AudioObjectGetPropertyData(device, &address, 0, nil, &size, &transport) == noErr {
            transportType = transport
        }
        symbol = deviceSymbol()
    }

    private func deviceSymbol() -> String {
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var address = Self.address(kAudioObjectPropertyName, scope: kAudioObjectPropertyScopeGlobal)
        AudioObjectGetPropertyData(device, &address, 0, nil, &size, &name)
        let label = (name?.takeRetainedValue() as String?)?.lowercased() ?? ""

        switch transportType {
        case kAudioDeviceTransportTypeBuiltIn:
            var source = UInt32(0)
            size = UInt32(MemoryLayout<UInt32>.size)
            address = Self.address(kAudioDevicePropertyDataSource)
            AudioObjectGetPropertyData(device, &address, 0, nil, &size, &source)
            return source == 0x6864_706E ? "headphones" : "laptopcomputer"
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE:
            return label.contains("speaker") ? "hifispeaker.fill" : HeadphonesWatcher.symbol(for: label)
        case kAudioDeviceTransportTypeAirPlay:
            return label.contains("homepod") ? "homepod.fill" : "airplay.audio"
        case kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort:
            return "display"
        default:
            return "hifispeaker.fill"
        }
    }

    private static func address(_ selector: AudioObjectPropertySelector,
                                scope: AudioObjectPropertyScope = kAudioDevicePropertyScopeOutput) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }
}
