import AVFoundation
import CoreAudio

// Core Audio process tap butuh SDK macOS 14.2 (Xcode 15.1, Swift 5.9.2). Dengan Xcode lebih lama berkas ini
// dilewati dan aplikasi memakai ScreenCaptureKit seperti sebelumnya.
#if compiler(>=5.9.2)

/// Menangkap audio yang diputar Mac (Zoom, Teams, Meet di browser, ...) langsung dari Core Audio.
///
/// Dibanding tangkapan layar (ScreenCaptureKit):
/// - Hanya audio, tanpa video; cukup izin "System Audio Recording Only".
/// - Aliran audio rata (tanpa jeda saat hening), sehingga suara peserta tidak patah-patah.
/// - Aplikasi tertentu (pemutar musik, aplikasi ini sendiri) dikecualikan di sumbernya.
/// Saat perangkat output berganti (headset dipasang/dilepas), `onDeviceChange` dipanggil agar tap dipasang ulang.
@available(macOS 14.2, *)
final class SystemAudioTap {
    enum TapError: LocalizedError {
        case status(String, OSStatus)
        case badFormat

        var errorDescription: String? {
            switch self {
            case let .status(step, code): return "\(step) gagal (OSStatus \(code))"
            case .badFormat: return "Format audio tap tidak dikenali"
            }
        }
    }

    /// Dipanggil (di main queue) saat perangkat output default berganti.
    var onDeviceChange: (() -> Void)?
    private(set) var formatText = ""

    private let ioQueue: DispatchQueue
    private let excludedBundleIDs: Set<String>
    private let onBuffer: (AVAudioPCMBuffer) -> Void
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var tapUUID = ""
    private var listener: AudioObjectPropertyListenerBlock?
    private var listenerAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    init(ioQueue: DispatchQueue, excludedBundleIDs: Set<String>, onBuffer: @escaping (AVAudioPCMBuffer) -> Void) {
        self.ioQueue = ioQueue
        self.excludedBundleIDs = excludedBundleIDs
        self.onBuffer = onBuffer
    }

    deinit {
        stop()
    }

    func start() throws {
        do {
            try createTap()
            try createAggregate()
            try startIO()
            addDeviceListener()
        } catch {
            stop()
            throw error
        }
    }

    func stop() {
        removeDeviceListener()
        if aggregateID != AudioObjectID(kAudioObjectUnknown) {
            if let procID {
                _ = AudioDeviceStop(aggregateID, procID)
                _ = AudioDeviceDestroyIOProcID(aggregateID, procID)
            }
            _ = AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        procID = nil
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        if tapID != AudioObjectID(kAudioObjectUnknown) {
            _ = AudioHardwareDestroyProcessTap(tapID)
        }
        tapID = AudioObjectID(kAudioObjectUnknown)
    }

    // MARK: - Langkah-langkah

    private func createTap() throws {
        var excluded = Self.processObjects(bundleIDs: excludedBundleIDs)
        if let own = Self.processObject(pid: getpid()) { excluded.append(own) }
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: excluded)
        description.uuid = UUID()
        description.muteBehavior = .unmuted
        var newTap = AudioObjectID(kAudioObjectUnknown)
        try Self.check(AudioHardwareCreateProcessTap(description, &newTap), "Membuat tap audio")
        tapID = newTap
        tapUUID = description.uuid.uuidString
    }

    private func createAggregate() throws {
        let outputUID = try Self.defaultOutputUID()
        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Meeting Notes Tap",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true, kAudioSubTapUIDKey: tapUUID]],
        ]
        var newAggregate = AudioObjectID(kAudioObjectUnknown)
        try Self.check(AudioHardwareCreateAggregateDevice(description as CFDictionary, &newAggregate),
                       "Membuat perangkat agregat")
        aggregateID = newAggregate
    }

    private func startIO() throws {
        var stream = AudioStreamBasicDescription()
        try Self.read(tapID, kAudioTapPropertyFormat, into: &stream)
        guard let format = AVAudioFormat(streamDescription: &stream) else { throw TapError.badFormat }
        formatText = "\(Int(format.sampleRate)) Hz, \(format.channelCount) kanal"
        let handler = onBuffer
        var newProc: AudioDeviceIOProcID?
        let status = AudioDeviceCreateIOProcIDWithBlock(&newProc, aggregateID, ioQueue) { _, input, _, _, _ in
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: input, deallocator: nil)
            else { return }
            handler(buffer)
        }
        try Self.check(status, "Membuat IOProc")
        procID = newProc
        try Self.check(AudioDeviceStart(aggregateID, newProc), "Memulai tap")
    }

    private func addDeviceListener() {
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.onDeviceChange?()
        }
        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &listenerAddress, DispatchQueue.main, block)
        if status == noErr { listener = block }
    }

    private func removeDeviceListener() {
        guard let listener else { return }
        _ = AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &listenerAddress, DispatchQueue.main, listener)
        self.listener = nil
    }

    // MARK: - Bantuan Core Audio

    private static func check(_ status: OSStatus, _ step: String) throws {
        guard status == noErr else { throw TapError.status(step, status) }
    }

    private static func propertyAddress(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    }

    private static func read<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                                into value: inout T) throws {
        var address = propertyAddress(selector)
        var size = UInt32(MemoryLayout<T>.size)
        try check(AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value), "Membaca properti audio")
    }

    private static func readString(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = propertyAddress(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value)
        guard status == noErr, let string = value?.takeRetainedValue() else { return nil }
        return string as String
    }

    private static func defaultOutputUID() throws -> String {
        var device = AudioDeviceID(kAudioObjectUnknown)
        try read(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice, into: &device)
        guard let uid = readString(device, kAudioDevicePropertyDeviceUID) else {
            throw TapError.status("Membaca perangkat output", -1)
        }
        return uid
    }

    /// Objek proses Core Audio milik aplikasi dengan bundle ID tertentu (termasuk proses pembantunya).
    private static func processObjects(bundleIDs: Set<String>) -> [AudioObjectID] {
        guard !bundleIDs.isEmpty else { return [] }
        let system = AudioObjectID(kAudioObjectSystemObject)
        var address = propertyAddress(kAudioHardwarePropertyProcessObjectList)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var objects = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &objects) == noErr else { return [] }
        return objects.filter { object in
            guard let bundleID = readString(object, kAudioProcessPropertyBundleID) else { return false }
            return bundleIDs.contains { bundleID.hasPrefix($0) }
        }
    }

    private static func processObject(pid: pid_t) -> AudioObjectID? {
        var address = propertyAddress(kAudioHardwarePropertyTranslatePIDToProcessObject)
        var pid = pid
        var object = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, UInt32(MemoryLayout<pid_t>.size), &pid, &size, &object)
        return status == noErr && object != AudioObjectID(kAudioObjectUnknown) ? object : nil
    }
}

#endif
