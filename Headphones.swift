import AppKit
@preconcurrency import IOBluetooth
import SwiftUI

enum ListeningMode {
    case off, noiseCancellation, transparency, adaptive

    init?(controlCenter name: String) {
        if name.contains("noise-cancellation") { self = .noiseCancellation }
        else if name.contains("transparency") { self = .transparency }
        else if name.contains("adaptive") || name.contains("automatic") { self = .adaptive }
        else if name.contains("off") || name.contains("normal") { self = .off }
        else { return nil }
    }

    private var symbol: (name: String, fallback: String) {
        switch self {
        case .off: ("person.fill", "person.fill")
        case .noiseCancellation: ("person.closed.fill", "person.crop.circle.fill")
        case .transparency: ("person.open.fill", "person.wave.2.fill")
        case .adaptive: ("person.and.sparkles.fill", "sparkles")
        }
    }

    var image: NSImage {
        let loader = NSSelectorFromString("imageWithPrivateSystemSymbolName:")
        let found = NSImage.responds(to: loader)
            ? (NSImage.self as AnyObject).perform(loader, with: symbol.name)?.takeUnretainedValue() as? NSImage : nil
        let base = found ?? NSImage(systemSymbolName: symbol.fallback, accessibilityDescription: nil) ?? NSImage()
        let tint = self == .off ? NSColor.white.withAlphaComponent(0.5) : NSColor.white
        let config = NSImage.SymbolConfiguration(pointSize: 15, weight: .medium)
            .applying(.init(paletteColors: [tint, tint.withAlphaComponent(tint.alphaComponent * 0.55)]))
        return base.withSymbolConfiguration(config) ?? base
    }
}

@MainActor
final class HeadphonesWatcher: NSObject {
    var onConnect: ((String, Double?) -> Void)?
    var onDisconnect: ((String) -> Void)?
    var onMode: ((String, ListeningMode) -> Void)?
    var onLowBattery: ((String, Double) -> Void)?

    private var connectNote: IOBluetoothUserNotification?
    private var disconnectNotes: [String: IOBluetoothUserNotification] = [:]
    private var devices: [String: IOBluetoothDevice] = [:]
    private var batteries: [String: Double] = [:]
    private var modeProcess: Process?
    private var batteryTimer: Timer?
    private var startedAt = Date.distantPast

    static func symbol(for name: String) -> String {
        let name = name.lowercased()
        if name.contains("airpods max") { return "airpods.max" }
        if name.contains("airpods pro") { return "airpods.pro" }
        if name.contains("airpods") { return "airpods" }
        if name.contains("beats") { return "beats.headphones" }
        return "headphones"
    }

    func start() {
        startedAt = Date()
        connectNote = IOBluetoothDevice.register(forConnectNotifications: self, selector: #selector(connected(_:device:)))
        watchModes()
        batteryTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkBatteries() }
        }
    }

    func stop() {
        connectNote?.unregister()
        connectNote = nil
        disconnectNotes.values.forEach { $0.unregister() }
        disconnectNotes = [:]
        devices = [:]
        batteries = [:]
        modeProcess?.terminationHandler = nil
        modeProcess?.terminate()
        modeProcess = nil
        batteryTimer?.invalidate()
        batteryTimer = nil
    }

    @objc nonisolated private func connected(_ note: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        DispatchQueue.main.async { [weak self] in MainActor.assumeIsolated { self?.track(device) } }
    }

    @objc nonisolated private func disconnected(_ note: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        DispatchQueue.main.async { [weak self] in MainActor.assumeIsolated { self?.forget(device) } }
    }

    private func track(_ device: IOBluetoothDevice) {
        guard device.deviceClassMajor == kBluetoothDeviceClassMajorAudio, let address = device.addressString,
              devices[address] == nil else { return }
        devices[address] = device
        disconnectNotes[address] = device.register(forDisconnectNotification: self, selector: #selector(disconnected(_:device:)))
        let isLaunch = Date().timeIntervalSince(startedAt) < 2
        Task {
            var level = Self.battery(of: device)
            for _ in 0..<6 where level == nil {
                try? await Task.sleep(for: .seconds(0.5))
                level = Self.battery(of: device)
            }
            guard devices[address] != nil else { return }
            batteries[address] = level
            if !isLaunch { onConnect?(device.name ?? "", level) }
        }
    }

    private func forget(_ device: IOBluetoothDevice) {
        guard let address = device.addressString, devices.removeValue(forKey: address) != nil else { return }
        disconnectNotes.removeValue(forKey: address)?.unregister()
        batteries[address] = nil
        onDisconnect?(device.name ?? "")
    }

    private func watchModes() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/log")
        process.arguments = ["stream", "--style", "ndjson", "--predicate",
                             "process == \"ControlCenter\" AND eventMessage BEGINSWITH \"Showing listening mode banner\""]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        readLines(from: pipe.fileHandleForReading, label: "niche.listening") { [weak self] line in
            guard let json = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let message = json["eventMessage"] as? String,
                  let match = message.firstMatch(of: #/mode: ([A-Za-z-]+)/#),
                  let mode = ListeningMode(controlCenter: String(match.1)) else { return }
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.modeChanged(mode) } }
        }
        process.terminationHandler = { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                MainActor.assumeIsolated {
                    guard let self, self.modeProcess === process else { return }
                    self.watchModes()
                }
            }
        }
        do {
            try process.run()
        } catch {
            NSLog("Niche could not start the listening mode log stream: %@", String(describing: error))
            return
        }
        modeProcess = process
    }

    private func modeChanged(_ mode: ListeningMode) {
        let name = devices.values.compactMap(\.name).first { $0.lowercased().contains("airpods") } ?? devices.values.first?.name ?? "AirPods"
        onMode?(name, mode)
    }

    private func checkBatteries() {
        for (address, device) in devices {
            guard let level = Self.battery(of: device) else { continue }
            let last = batteries[address] ?? 1
            batteries[address] = level
            if (last > 0.2 && level <= 0.2) || (last > 0.1 && level <= 0.1) { onLowBattery?(device.name ?? "", level) }
        }
    }

    private static func battery(of device: IOBluetoothDevice) -> Double? {
        let buds = [read(device, "batteryPercentLeft"), read(device, "batteryPercentRight")].filter { $0 > 0 }
        if let low = buds.min() { return Double(low) / 100 }
        let single = read(device, "batteryPercentSingle")
        return single > 0 ? Double(single) / 100 : nil
    }

    private static func read(_ device: IOBluetoothDevice, _ name: String) -> Int {
        let selector = NSSelectorFromString(name)
        guard device.responds(to: selector), let method = device.method(for: selector) else { return 0 }
        return Int(unsafeBitCast(method, to: (@convention(c) (AnyObject, Selector) -> UInt8).self)(device, selector))
    }
}

struct HeadphonesGlyph: View {
    let symbol: String
    let isConnected: Bool
    @State private var plays = 0
    @State private var slash = 0.0

    private struct Pose {
        var scale = 1.0
        var y = 0.0
        var tilt = 0.0
        var blur = 0.0
    }

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 16, weight: .semibold))
            .keyframeAnimator(initialValue: Pose(), trigger: plays) { content, pose in
                content
                    .scaleEffect(pose.scale)
                    .rotationEffect(.degrees(pose.tilt))
                    .offset(y: pose.y)
                    .blur(radius: pose.blur)
            } keyframes: { _ in
                KeyframeTrack(\.scale) {
                    MoveKeyframe(isConnected ? 0.55 : 1)
                    SpringKeyframe(isConnected ? 1.12 : 0.8, duration: 0.22, spring: Spring(duration: 0.22, bounce: 0))
                    SpringKeyframe(isConnected ? 1 : 0.86, duration: 0.4, spring: Spring(duration: 0.4, bounce: 0.32))
                }
                KeyframeTrack(\.y) {
                    MoveKeyframe(isConnected ? -5 : 0)
                    SpringKeyframe(isConnected ? 0 : 2.5, duration: 0.5, spring: Spring(duration: 0.5, bounce: 0.32))
                }
                KeyframeTrack(\.tilt) {
                    MoveKeyframe(isConnected ? -14 : 0)
                    SpringKeyframe(isConnected ? 6 : 10, duration: 0.2, spring: Spring(duration: 0.2, bounce: 0))
                    SpringKeyframe(isConnected ? 0 : 8, duration: 0.4, spring: Spring(duration: 0.4, bounce: 0.3))
                }
                KeyframeTrack(\.blur) {
                    MoveKeyframe(isConnected ? 4 : 0)
                    CubicKeyframe(0, duration: 0.25)
                }
            }
            .foregroundStyle(.white.opacity(isConnected ? 1 : 0.45))
            .animation(.easeOut(duration: 0.3).delay(0.12), value: isConnected)
            .frame(width: 22, height: 18)
            .overlay {
                SlashLine().trim(from: 0, to: slash).stroke(.black, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                SlashLine().trim(from: 0, to: slash).stroke(.white, style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
            }
            .onAppear { play() }
            .onChange(of: isConnected) { play() }
    }

    private func play() {
        plays += 1
        slash = 0
        guard !isConnected else { return }
        withAnimation(.spring(Spring(duration: 0.35, bounce: 0), blendDuration: 0).delay(0.2)) { slash = 1 }
    }
}

private struct SlashLine: Shape {
    func path(in rect: CGRect) -> Path {
        Path { p in
            p.move(to: CGPoint(x: rect.minX + 5, y: rect.minY + 2.5))
            p.addLine(to: CGPoint(x: rect.maxX - 5, y: rect.maxY - 2.5))
        }
    }
}

struct BatteryRing: View {
    let level: Double
    let isLow: Bool
    @State private var shown = 0.0

    var body: some View {
        let tint: Color = level <= 0.1 ? .red : level <= 0.2 ? .orange : .green
        HStack(spacing: 3) {
            ZStack {
                Circle().stroke(.white.opacity(0.2), lineWidth: 2.2)
                Circle().trim(from: 0, to: shown)
                    .stroke(tint, style: StrokeStyle(lineWidth: 2.2, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            .frame(width: 10, height: 10)
            .phaseAnimator(isLow ? [1.0, 0.35] : [1.0]) { ring, opacity in
                ring.opacity(opacity)
            } animation: { _ in .pulse }
            Text("\(Int((level * 100).rounded()))%")
                .font(.system(size: 11.5, weight: .semibold).monospacedDigit())
                .foregroundStyle(isLow ? tint : .white.opacity(0.85))
                .contentTransition(.numericText(value: level))
        }
        .onAppear {
            withAnimation(.spring(Spring(duration: 0.6, bounce: 0.1), blendDuration: 0).delay(0.15)) { shown = level }
        }
        .onChange(of: level) { withAnimation(.level) { shown = level } }
    }
}

struct ListeningModeGlyph: View {
    let mode: ListeningMode
    @State private var plays = 0

    var body: some View {
        Image(nsImage: mode.image)
            .keyframeAnimator(initialValue: 1.0, trigger: plays) { content, scale in
                content.scaleEffect(scale)
            } keyframes: { _ in
                MoveKeyframe(0.6)
                SpringKeyframe(1.15, duration: 0.2, spring: Spring(duration: 0.2, bounce: 0))
                SpringKeyframe(1, duration: 0.4, spring: Spring(duration: 0.4, bounce: 0.32))
            }
            .id(mode)
            .transition(.blurReplace)
            .animation(.glyph, value: mode)
            .frame(width: 20, height: 18)
            .onAppear { plays += 1 }
            .onChange(of: mode) { plays += 1 }
    }
}
