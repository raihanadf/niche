import AppKit
import AudioToolbox
import CoreAudio
import IOKit.ps
import SwiftUI

@MainActor
@Observable
final class LiveActivityCenter {
    enum Kind: String, CaseIterable, Identifiable {
        case capsLock, focus, volume, brightness, lowBattery, charging, fullyCharged, headphones, noiseControl, headphonesBattery, agentDone, copied
        var id: Self { self }
        var title: String {
            switch self {
            case .capsLock: "Caps Lock"
            case .focus: "Focus"
            case .volume: "Volume"
            case .brightness: "Brightness"
            case .lowBattery: "Low battery"
            case .charging: "Charging"
            case .fullyCharged: "Fully charged"
            case .headphones: "AirPods connected"
            case .noiseControl: "Noise control"
            case .headphonesBattery: "AirPods low battery"
            case .agentDone: "Agent finished"
            case .copied: "Copied to clipboard"
            }
        }
    }

    struct Activity: Equatable {
        let kind: Kind
        var level: Double = 0
        var isOn = false
        var symbol: String?
        var agent: AgentKind?
        var icon: NSImage?
        var image: NSImage?
        var color: Color?
        var mode: ListeningMode?
    }

    private(set) var current: Activity?
    private(set) var isShowing = false

    var isOn: Bool {
        didSet { UserDefaults.standard.set(isOn, forKey: "liveActivities"); restart() }
    }
    private(set) var enabled: Set<Kind>
    var replacesSystemHUD: Bool {
        didSet { UserDefaults.standard.set(replacesSystemHUD, forKey: "replacesSystemHUD"); restart() }
    }
    private(set) var isKeyTapActive = false

    @ObservationIgnored private var hideTask: Task<Void, Never>?
    @ObservationIgnored private var capsTimer: Timer?
    @ObservationIgnored private var lastCaps: Bool?
    @ObservationIgnored private var brightnessRegistered = false
    @ObservationIgnored private var lastBrightness: Double?
    @ObservationIgnored private var brightnessKeyAt = Date.distantPast
    @ObservationIgnored private var focusProcess: Process?
    @ObservationIgnored private var lastFocus: Bool?
    @ObservationIgnored private var focusSymbol = "moon.fill"
    @ObservationIgnored private var batterySource: CFRunLoopSource?
    @ObservationIgnored private var lastBattery: (level: Int, onAC: Bool, full: Bool)?
    @ObservationIgnored private var volumeDevice = AudioObjectID(kAudioObjectUnknown)
    @ObservationIgnored private var volumeSettable = false
    @ObservationIgnored private var volumeMutable = false
    @ObservationIgnored private var isBluetoothOutput = false
    @ObservationIgnored private var lastVolumeKeyAt = 0.0
    @ObservationIgnored private let mediaQueue = DispatchQueue(label: "niche.mediakeys")
    @ObservationIgnored private var lastVolume: (Float, Bool)?
    @ObservationIgnored var showsVolume: () -> Bool = { true }
    @ObservationIgnored private var audioListeners: [(AudioObjectID, AudioObjectPropertyAddress, AudioObjectPropertyListenerProc)] = []
    @ObservationIgnored private let registerBrightness: @convention(c) (UInt32, UnsafeRawPointer?, CFNotificationCallback) -> Int32
    @ObservationIgnored private let unregisterBrightness: @convention(c) (UInt32, UnsafeRawPointer?) -> Int32
    @ObservationIgnored private let smoothBrightness: @convention(c) (UInt32, Float) -> Int32
    @ObservationIgnored private var keyTap: CFMachPort?
    @ObservationIgnored private var keyTapSource: CFRunLoopSource?
    @ObservationIgnored private var headphones: HeadphonesWatcher?

    nonisolated(unsafe) private static weak var shared: LiveActivityCenter?
    private static let lowBatteryThreshold = 20

    init() {
        let defaults = UserDefaults.standard
        defaults.register(defaults: Dictionary(uniqueKeysWithValues: Kind.allCases.map { ("liveActivity.\($0.rawValue)", true) })
            .merging(["liveActivities": true, "replacesSystemHUD": true]) { a, _ in a })
        isOn = defaults.bool(forKey: "liveActivities")
        replacesSystemHUD = defaults.bool(forKey: "replacesSystemHUD")
        enabled = Set(Kind.allCases.filter { defaults.bool(forKey: "liveActivity.\($0.rawValue)") })
        guard let handle = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_NOW),
              let register = dlsym(handle, "DisplayServicesRegisterForBrightnessChangeNotifications"),
              let unregister = dlsym(handle, "DisplayServicesUnregisterForBrightnessChangeNotifications"),
              let smooth = dlsym(handle, "DisplayServicesSetBrightnessSmooth") else {
            fatalError("DisplayServices brightness symbols not found")
        }
        registerBrightness = unsafeBitCast(register, to: (@convention(c) (UInt32, UnsafeRawPointer?, CFNotificationCallback) -> Int32).self)
        unregisterBrightness = unsafeBitCast(unregister, to: (@convention(c) (UInt32, UnsafeRawPointer?) -> Int32).self)
        smoothBrightness = unsafeBitCast(smooth, to: (@convention(c) (UInt32, Float) -> Int32).self)
        Self.shared = self
    }

    func isEnabled(_ kind: Kind) -> Bool { enabled.contains(kind) }

    func setEnabled(_ kind: Kind, _ on: Bool) {
        if on { enabled.insert(kind) } else { enabled.remove(kind) }
        UserDefaults.standard.set(on, forKey: "liveActivity.\(kind.rawValue)")
        restart()
    }

    func start() {
        restart()
    }

    func requestAccessibility() {
        _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary)
    }

    func stop() {
        headphones?.stop()
        focusProcess?.terminationHandler = nil
        focusProcess?.terminate()
        focusProcess = nil
    }

    func agentFinished(_ kind: AgentKind) {
        guard watching(.agentDone) else { return }
        show(Activity(kind: .agentDone, agent: kind), for: 2.5)
    }

    func copied(icon: NSImage?, image: NSImage?, color: Color?, symbol: String) {
        guard watching(.copied) else { return }
        show(Activity(kind: .copied, symbol: symbol, icon: icon, image: image, color: color), for: 1.6)
    }

    private func watching(_ kind: Kind) -> Bool { isOn && enabled.contains(kind) }

    private func restart() {
        capsTimer?.invalidate()
        capsTimer = nil
        if brightnessRegistered {
            _ = unregisterBrightness(CGMainDisplayID(), nil)
            brightnessRegistered = false
        }
        focusProcess?.terminationHandler = nil
        focusProcess?.terminate()
        focusProcess = nil
        if let batterySource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), batterySource, .defaultMode)
            self.batterySource = nil
        }
        for (object, address, proc) in audioListeners {
            var address = address
            AudioObjectRemovePropertyListener(object, &address, proc, nil)
        }
        audioListeners = []
        lastCaps = nil
        lastBrightness = nil
        lastFocus = nil
        lastBattery = nil
        lastVolume = nil
        isBluetoothOutput = false
        lastVolumeKeyAt = 0
        if let keyTapSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), keyTapSource, .commonModes)
            self.keyTapSource = nil
        }
        if let keyTap {
            CGEvent.tapEnable(tap: keyTap, enable: false)
            CFMachPortInvalidate(keyTap)
            self.keyTap = nil
        }
        isKeyTapActive = false
        if let current, !watching(current.kind) { hide() }

        if needsKeyTap { startKeyTap() }

        if watching(.capsLock) {
            readCaps()
            capsTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.readCaps() }
            }
        }
        if watching(.brightness) {
            brightnessRegistered = registerBrightness(CGMainDisplayID(), nil) { _, _, _, _, info in
                guard let value = (info as NSDictionary?)?["value"] as? NSNumber else { return }
                let level = value.doubleValue
                Task { @MainActor in LiveActivityCenter.shared?.brightnessChanged(level) }
            } == 0
            if !brightnessRegistered { NSLog("Niche could not register for brightness changes") }
        }
        if watching(.focus) { watchFocus() }
        if watching(.lowBattery) || watching(.charging) || watching(.fullyCharged) || watching(.brightness) { watchBattery() }
        if watching(.volume) { watchVolume() }
        if !(watching(.headphones) || watching(.noiseControl) || watching(.headphonesBattery)) {
            headphones?.stop()
            headphones = nil
        } else if headphones == nil {
            watchHeadphones()
        }
    }

    private func watchHeadphones() {
        let watcher = HeadphonesWatcher()
        watcher.onConnect = { [weak self] name, level in
            guard let self, self.watching(.headphones) else { return }
            self.show(Activity(kind: .headphones, level: level ?? 0, isOn: true, symbol: HeadphonesWatcher.symbol(for: name)), for: 2.5)
        }
        watcher.onDisconnect = { [weak self] name in
            guard let self, self.watching(.headphones) else { return }
            self.show(Activity(kind: .headphones, isOn: false, symbol: HeadphonesWatcher.symbol(for: name)), for: 2)
        }
        watcher.onMode = { [weak self] name, mode in
            guard let self, self.watching(.noiseControl) else { return }
            self.show(Activity(kind: .noiseControl, symbol: HeadphonesWatcher.symbol(for: name), mode: mode), for: 1.8)
        }
        watcher.onLowBattery = { [weak self] name, level in
            guard let self, self.watching(.headphonesBattery) else { return }
            self.show(Activity(kind: .headphonesBattery, level: level, symbol: HeadphonesWatcher.symbol(for: name)), for: 3)
        }
        watcher.start()
        headphones = watcher
    }

    private enum MediaKey { case volumeUp, volumeDown, mute, brightnessUp, brightnessDown }

    private var needsKeyTap: Bool { watching(.brightness) || (replacesSystemHUD && watching(.volume)) }

    private func startKeyTap() {
        guard AXIsProcessTrusted() else {
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(3))
                guard let self, self.keyTap == nil, self.needsKeyTap else { return }
                self.startKeyTap()
            }
            return
        }
        let mask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue) | (1 << 14)
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                          eventsOfInterest: CGEventMask(mask), callback: { _, type, event, _ in
            MainActor.assumeIsolated {
                guard let center = LiveActivityCenter.shared else { return Unmanaged.passUnretained(event) }
                return center.handleTap(type: type, event: event) ? nil : Unmanaged.passUnretained(event)
            }
        }, userInfo: nil) else {
            NSLog("Niche could not create the media key tap")
            return
        }
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        keyTap = tap
        keyTapSource = source
        isKeyTapActive = true
    }

    private func handleTap(type: CGEventType, event: CGEvent) -> Bool {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let keyTap { CGEvent.tapEnable(tap: keyTap, enable: true) }
            return false
        }
        let key: MediaKey
        let isDown: Bool
        if type.rawValue == 14 {
            guard let ns = NSEvent(cgEvent: event), ns.subtype.rawValue == 8 else { return false }
            let data = ns.data1
            isDown = (data & 0xFF00) >> 8 == 0xA
            switch (data & 0xFFFF0000) >> 16 {
            case 0: key = .volumeUp
            case 1: key = .volumeDown
            case 7: key = .mute
            case 2: key = .brightnessUp
            case 3: key = .brightnessDown
            default: return false
            }
        } else {
            switch event.getIntegerValueField(.keyboardEventKeycode) {
            case 144: key = .brightnessUp
            case 145: key = .brightnessDown
            default: return false
            }
            isDown = type == .keyDown
        }
        let isVolume = key == .volumeUp || key == .volumeDown || key == .mute
        guard watching(isVolume ? .volume : .brightness) else { return false }
        let fine = event.flags.contains(.maskShift) && event.flags.contains(.maskAlternate)
        let step: Float = fine ? 1.0 / 64 : 1.0 / 16
        if !isVolume && isDown { brightnessKeyAt = Date() }
        guard replacesSystemHUD else { return false }
        if isVolume && (isBluetoothOutput || Self.isBluetooth(volumeDevice)) { return false }
        guard isDown else { return true }
        if isVolume {
            let now = CACurrentMediaTime()
            guard now - lastVolumeKeyAt >= 0.04 else { return true }
            lastVolumeKeyAt = now
        }
        if !isVolume {
            guard brightnessRegistered else { return false }
            let smooth = smoothBrightness
            let delta = key == .brightnessUp ? step : -step
            mediaQueue.async {
                if smooth(CGMainDisplayID(), delta) != 0 { NSLog("Niche could not change the brightness") }
            }
            return true
        }
        guard key == .mute ? volumeMutable : volumeSettable else { return false }
        let device = volumeDevice
        mediaQueue.async { Self.changeVolume(key, step: step, on: device) }
        return true
    }

    nonisolated private static func changeVolume(_ key: MediaKey, step: Float, on device: AudioObjectID) {
        var volume = AudioObjectPropertyAddress(mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
                                                mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
        var mute = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyMute,
                                              mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
        var muted = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        let hasMute = AudioObjectGetPropertyData(device, &mute, 0, nil, &size, &muted) == noErr
        if key == .mute {
            muted = muted == 0 ? 1 : 0
            AudioObjectSetPropertyData(device, &mute, 0, nil, size, &muted)
            return
        }
        var level = Float32(0)
        size = UInt32(MemoryLayout<Float32>.size)
        guard AudioObjectGetPropertyData(device, &volume, 0, nil, &size, &level) == noErr else {
            NSLog("Niche could not read the output volume")
            return
        }
        let target = key == .volumeUp ? level + step : level - step
        var newLevel = min(max((target / step).rounded() * step, 0), 1)
        guard abs(newLevel - level) > 0.0001 || (hasMute && muted != 0 && key == .volumeUp) else { return }
        if hasMute && muted != 0 && key == .volumeUp {
            muted = 0
            AudioObjectSetPropertyData(device, &mute, 0, nil, UInt32(MemoryLayout<UInt32>.size), &muted)
        }
        AudioObjectSetPropertyData(device, &volume, 0, nil, size, &newLevel)
    }
    nonisolated private static func isBluetooth(_ device: AudioObjectID) -> Bool {
        var transport = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyTransportType,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &transport) == noErr else { return false }
        return transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE
    }


    private func readCaps() {
        let caps = CGEventSource.flagsState(.combinedSessionState).contains(.maskAlphaShift)
        if let lastCaps, lastCaps != caps { show(Activity(kind: .capsLock, isOn: caps), for: 1.4) }
        lastCaps = caps
    }

    private func brightnessChanged(_ level: Double) {
        let byKey = Date().timeIntervalSince(brightnessKeyAt) < 1.5
        if byKey && lastBrightness.map({ abs($0 - level) > 0.001 }) != false {
            show(Activity(kind: .brightness, level: level), for: 1.4)
        }
        lastBrightness = level
    }

    private func watchFocus() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/log")
        process.arguments = ["stream", "--style", "ndjson", "--predicate",
                             "process == \"donotdisturbd\" AND eventMessage BEGINSWITH \"Delivering active mode update\""]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        readLines(from: pipe.fileHandleForReading, label: "niche.focus") { [weak self] line in
            guard let json = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let message = json["eventMessage"] as? String,
                  let match = message.firstMatch(of: #/activeModeIdentifier=([A-Za-z0-9._-]+|\(null\))/#) else { return }
            let mode = String(match.1)
            let active = mode != "(null)"
            Task { @MainActor in self?.focusChanged(active: active, mode: mode) }
        }
        process.terminationHandler = { [weak self] _ in
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(2))
                guard let self, self.focusProcess === process else { return }
                self.watchFocus()
            }
        }
        do {
            try process.run()
        } catch {
            NSLog("Niche could not start the focus log stream: %@", String(describing: error))
            return
        }
        focusProcess = process
    }

    private func focusChanged(active: Bool, mode: String?) {
        if active, let mode { focusSymbol = Self.focusSymbol(for: mode) }
        if lastFocus != active { show(Activity(kind: .focus, isOn: active, symbol: focusSymbol), for: 1.6) }
        lastFocus = active
    }

    private static func focusSymbol(for mode: String) -> String {
        switch mode {
        case let m where m.hasSuffix("mode.driving"): "car.fill"
        case let m where m.hasSuffix("mode.workout") || m.hasSuffix("fitness"): "figure.run"
        case let m where m.hasSuffix(".work"): "briefcase.fill"
        case let m where m.hasSuffix("personal-time"): "person.fill"
        case let m where m.hasSuffix("reading"): "book.fill"
        case let m where m.hasSuffix("gaming"): "gamecontroller.fill"
        case let m where m.hasSuffix("mindfulness"): "brain.head.profile"
        case let m where m.contains("sleep"): "bed.double.fill"
        default: "moon.fill"
        }
    }

    private func watchBattery() {
        guard let source = IOPSNotificationCreateRunLoopSource({ _ in
            Task { @MainActor in LiveActivityCenter.shared?.readBattery() }
        }, nil)?.takeRetainedValue() else {
            NSLog("Niche could not watch the power source")
            return
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
        batterySource = source
        readBattery()
    }

    private func readBattery() {
        let info = IOPSCopyPowerSourcesInfo().takeRetainedValue()
        let sources = IOPSCopyPowerSourcesList(info).takeRetainedValue() as [CFTypeRef]
        guard let battery = sources.lazy
                .compactMap({ IOPSGetPowerSourceDescription(info, $0)?.takeUnretainedValue() as? [String: Any] })
                .first(where: { $0[kIOPSTypeKey] as? String == kIOPSInternalBatteryType }),
              let capacity = battery[kIOPSCurrentCapacityKey] as? Int,
              let maximum = battery[kIOPSMaxCapacityKey] as? Int, maximum > 0,
              let state = battery[kIOPSPowerSourceStateKey] as? String else { return }
        let level = capacity * 100 / maximum
        let onAC = state == kIOPSACPowerValue
        let full = onAC && (level >= 100 || battery[kIOPSIsChargedKey] as? Bool == true)
        let now = (level: level, onAC: onAC, full: full)
        if let last = lastBattery {
            let fraction = Double(level) / 100
            if full && !last.full && watching(.fullyCharged) {
                show(Activity(kind: .fullyCharged, level: fraction), for: 2.5)
            } else if onAC && !last.onAC && watching(.charging) {
                show(Activity(kind: .charging, level: fraction), for: 2)
            } else if !onAC && level <= Self.lowBatteryThreshold
                        && (last.onAC || last.level > Self.lowBatteryThreshold || (level <= 10 && last.level > 10))
                        && watching(.lowBattery) {
                show(Activity(kind: .lowBattery, level: fraction), for: 3)
            }
        }
        lastBattery = now
    }

    private func watchVolume() {
        var defaultOutput = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                       mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        let system = AudioObjectID(kAudioObjectSystemObject)
        let deviceChanged: AudioObjectPropertyListenerProc = { _, _, _, _ in
            Task { @MainActor in LiveActivityCenter.shared?.restart() }
            return noErr
        }
        AudioObjectAddPropertyListener(system, &defaultOutput, deviceChanged, nil)
        audioListeners.append((system, defaultOutput, deviceChanged))

        volumeSettable = false
        volumeMutable = false
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &defaultOutput, 0, nil, &size, &volumeDevice) == noErr else {
            NSLog("Niche cannot read the default output device")
            return
        }
        isBluetoothOutput = Self.isBluetooth(volumeDevice)
        var volume = AudioObjectPropertyAddress(mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
                                                mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
        var mute = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyMute,
                                              mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
        var settable = DarwinBoolean(false)
        volumeSettable = AudioObjectHasProperty(volumeDevice, &volume)
            && AudioObjectIsPropertySettable(volumeDevice, &volume, &settable) == noErr && settable.boolValue
        volumeMutable = AudioObjectHasProperty(volumeDevice, &mute)
        for selector in [kAudioHardwareServiceDeviceProperty_VirtualMainVolume, kAudioDevicePropertyMute] {
            var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioDevicePropertyScopeOutput,
                                                     mElement: kAudioObjectPropertyElementMain)
            guard AudioObjectHasProperty(volumeDevice, &address) else { continue }
            let volumeChanged: AudioObjectPropertyListenerProc = { _, _, _, _ in
                Task { @MainActor in LiveActivityCenter.shared?.readVolume() }
                return noErr
            }
            AudioObjectAddPropertyListener(volumeDevice, &address, volumeChanged, nil)
            audioListeners.append((volumeDevice, address, volumeChanged))
        }
        readVolume()
    }

    private func readVolume() {
        var level = Float32(0)
        var muted = UInt32(0)
        var size = UInt32(MemoryLayout<Float32>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
                                                 mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(volumeDevice, &address, 0, nil, &size, &level) == noErr else { return }
        address.mSelector = kAudioDevicePropertyMute
        size = UInt32(MemoryLayout<UInt32>.size)
        if AudioObjectHasProperty(volumeDevice, &address) {
            AudioObjectGetPropertyData(volumeDevice, &address, 0, nil, &size, &muted)
        }
        let now = (level, muted != 0)
        if let lastVolume, lastVolume != now, showsVolume() {
            show(Activity(kind: .volume, level: Double(level), isOn: muted == 0), for: 1.4)
        }
        lastVolume = now
    }

    private func show(_ activity: Activity, for seconds: Double) {
        let animation: Animation = current?.kind == activity.kind
            ? .smooth(duration: 0.25) : .spring(Spring(duration: 0.4, bounce: 0.25), blendDuration: 0)
        withAnimation(animation) {
            current = activity
            isShowing = true
        }
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            self?.hide()
        }
    }

    private func hide() {
        hideTask?.cancel()
        withAnimation(.easeOut(duration: 0.25)) { isShowing = false }
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(0.25))
            guard !Task.isCancelled, let self else { return }
            withAnimation(.spring(response: 0.45, dampingFraction: 0.95)) { self.current = nil }
        }
    }
}

struct LiveActivityView: View {
    let activity: LiveActivityCenter.Activity

    static let valueWidth: CGFloat = 24

    static func room(for activity: LiveActivityCenter.Activity) -> CGFloat {
        switch activity.kind {
        case .volume, .brightness: LevelBar.width + 5 + valueWidth + 11 - MusicClosedView.slot
        case .lowBattery, .charging, .fullyCharged: 12
        case .headphonesBattery: 16
        case .headphones: activity.isOn && activity.level > 0 ? 16 : 0
        default: 0
        }
    }

    var body: some View {
        let room = Self.room(for: activity)
        HStack(spacing: 0) {
            icon
                .frame(width: MusicClosedView.slot)
            Spacer(minLength: 0)
            trailing
                .padding(.trailing, room == 0 ? 0 : [.lowBattery, .charging, .fullyCharged].contains(activity.kind) ? 9 : 11)
                .frame(width: MusicClosedView.slot + room, alignment: room > 0 ? .trailing : .center)
        }
        .foregroundStyle(.white)
        .offset(y: LabState.closedOffset)
    }

    @ViewBuilder private var icon: some View {
        switch activity.kind {
        case .capsLock:
            symbol(activity.isOn ? "capslock.fill" : "capslock", tint: activity.isOn ? .green : .white)
        case .focus:
            symbol(activity.symbol ?? "moon.fill", tint: activity.isOn ? Color(red: 0.58, green: 0.5, blue: 1) : .white.opacity(0.5))
        case .volume:
            symbol(activity.isOn ? "speaker.wave.3.fill" : "speaker.slash.fill", tint: .white, value: activity.isOn ? activity.level : 1)
        case .brightness:
            SunGlyph(level: activity.level)
        case .lowBattery:
            symbol(activity.level <= 0.1 ? "battery.0percent" : "battery.25percent", tint: .red)
        case .charging:
            symbol("battery.100percent.bolt", tint: .green)
        case .fullyCharged:
            symbol("battery.100percent", tint: .green)
        case .headphones, .noiseControl, .headphonesBattery:
            HeadphonesGlyph(symbol: activity.symbol ?? "airpods", isConnected: activity.kind != .headphones || activity.isOn)
        case .agentDone:
            if let agent = activity.agent { AgentGlyph(kind: agent, size: 13) }
        case .copied:
            if let icon = activity.icon {
                Image(nsImage: icon).resizable().frame(width: 16, height: 16)
            } else {
                symbol("list.clipboard.fill", tint: .white)
            }
        }
    }

    @ViewBuilder private var trailing: some View {
        switch activity.kind {
        case .capsLock, .focus:
            label(activity.isOn ? "On" : "Off")
        case .volume, .brightness:
            let muted = activity.kind == .volume && !activity.isOn
            HStack(spacing: 5) {
                LevelBar(level: muted ? 0 : activity.level)
                Group {
                    if muted {
                        label("Off").foregroundStyle(.white.opacity(0.5))
                    } else {
                        label("\(Int((activity.level * 100).rounded()))")
                            .contentTransition(.numericText(value: activity.level))
                    }
                }
                .fixedSize()
                .frame(width: Self.valueWidth, alignment: .trailing)
            }
        case .lowBattery, .charging, .fullyCharged:
            label("\(Int((activity.level * 100).rounded()))%")
                .foregroundStyle(activity.kind == .lowBattery ? Color.red : .white.opacity(0.85))
        case .headphones:
            if !activity.isOn {
                Text("Off")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.5))
            } else if activity.level > 0 {
                BatteryRing(level: activity.level, isLow: false)
            } else {
                symbol("checkmark.circle.fill", tint: .green)
            }
        case .headphonesBattery:
            BatteryRing(level: activity.level, isLow: true)
        case .noiseControl:
            if let mode = activity.mode { ListeningModeGlyph(mode: mode) }
        case .agentDone:
            symbol("checkmark.circle.fill", tint: .green)
        case .copied:
            if let color = activity.color {
                Circle().fill(color)
                    .frame(width: 14, height: 14)
                    .overlay(Circle().strokeBorder(.white.opacity(0.3), lineWidth: 1))
            } else if let image = activity.image {
                Image(nsImage: image).resizable().scaledToFill()
                    .frame(width: 18, height: 18)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            } else {
                symbol(activity.symbol ?? "doc.on.doc", tint: Color(red: 0.45, green: 0.85, blue: 0.8))
            }
        }
    }

    private func symbol(_ name: String, tint: Color, value: Double) -> some View {
        Image(systemName: name, variableValue: value)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: 16)
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .semibold).monospacedDigit())
            .foregroundStyle(.white.opacity(0.85))
    }

    private func symbol(_ name: String, tint: Color) -> some View {
        Image(systemName: name)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(tint)
            .contentTransition(.symbolEffect(.replace))
    }
}

private struct SunGlyph: View {
    let level: Double

    var body: some View {
        let level = min(max(level, 0), 1)
        ZStack {
            Circle().frame(width: 4.6 + 1.2 * level, height: 4.6 + 1.2 * level)
            ForEach(0..<8, id: \.self) { i in
                Capsule()
                    .frame(width: 1.4, height: 1.2 + 1.8 * level)
                    .offset(y: -(4.6 + 1.5 * level))
                    .rotationEffect(.degrees(Double(i) * 45))
                    .opacity(min(max(level * 8 - Double(i), 0.3), 1))
            }
        }
        .foregroundStyle(.yellow)
        .frame(width: 16, height: 16)
        .animation(.smooth(duration: 0.25), value: level)
    }
}

private struct LevelBar: View {
    static let width: CGFloat = 34
    let level: Double

    var body: some View {
        Capsule().fill(.white.opacity(0.2))
            .overlay(alignment: .leading) {
                Capsule().fill(.white)
                    .frame(width: Self.width * min(max(level, 0), 1))
            }
            .frame(width: Self.width, height: 5)
            .animation(.smooth(duration: 0.25), value: level)
    }
}
