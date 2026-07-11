import Foundation
import VideoToolbox
import LocalCutDomain

/// Apple-only capability discovery. The portable `Capabilities` value and its
/// decision policy live in LocalCutDomain; this adapter supplies macOS sysctl
/// and VideoToolbox facts at the package boundary.
extension Capabilities {
    public static var current: Capabilities { AppleCapabilityProbe.current }

    public static func probe() -> Capabilities {
        let chip = probeAppleChipFamily()
        let memory = sysctlUInt64("hw.memsize") ?? 0
        let encoders = probeHardwareEncoderCount()
        let os = OSVersion(ProcessInfo.processInfo.operatingSystemVersion)
        return Capabilities(
            chip: chip,
            unifiedMemoryBytes: memory,
            videoEncoderCount: encoders,
            osVersion: os)
    }

    private static func probeAppleChipFamily() -> ChipFamily {
        let isAppleSilicon = sysctlInt("hw.optional.arm64") == 1
        guard isAppleSilicon else { return .intel }
        let board = sysctlString("hw.model") ?? ""
        return .appleSilicon(generation: appleSiliconGeneration(forBoard: board))
    }

    /// Counts hardware-accelerated encoders reported by VideoToolbox.
    public static func probeHardwareEncoderCount() -> Int {
        var listRef: CFArray?
        let status = VTCopyVideoEncoderList(nil, &listRef)
        guard status == noErr, let list = listRef else { return 0 }
        let hardwareKey = kVTVideoEncoderList_IsHardwareAccelerated as String
        return (list as NSArray).reduce(into: 0) { count, entry in
            guard let properties = entry as? [String: Any],
                  properties[hardwareKey] as? Bool == true else { return }
            count += 1
        }
    }
}

private enum AppleCapabilityProbe {
    static let current = Capabilities.probe()
}

private func sysctlString(_ name: String) -> String? {
    var size = 0
    guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
    var buffer = [UInt8](repeating: 0, count: size)
    guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
    if let nul = buffer.firstIndex(of: 0) {
        buffer.removeSubrange(nul...)
    }
    return String(decoding: buffer, as: UTF8.self)
}

private func sysctlInt(_ name: String) -> Int? {
    var value: Int32 = 0
    var size = MemoryLayout<Int32>.size
    guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
    return Int(value)
}

private func sysctlUInt64(_ name: String) -> UInt64? {
    var value: UInt64 = 0
    var size = MemoryLayout<UInt64>.size
    guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
    return value
}
