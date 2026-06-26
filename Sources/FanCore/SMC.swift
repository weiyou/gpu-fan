import Foundation
import IOKit

/// Low-level interface to the AppleSMC IOKit user client.
///
/// This is the proven `SMCParamStruct` calling convention (same layout used by
/// beltex/SMCKit and macmon). The same user-client works on Apple Silicon; only
/// the data *types* (`flt` vs Intel's `fpe2`) and the key set differ.
public final class SMC {

    // MARK: C structs (must match the kernel layout exactly — total 80 bytes)

    private struct SMCVersion {
        var major: UInt8 = 0
        var minor: UInt8 = 0
        var build: UInt8 = 0
        var reserved: UInt8 = 0
        var release: UInt16 = 0
    }

    private struct SMCPLimitData {
        var version: UInt16 = 0
        var length: UInt16 = 0
        var cpuPLimit: UInt32 = 0
        var gpuPLimit: UInt32 = 0
        var memPLimit: UInt32 = 0
    }

    private struct SMCKeyInfoData {
        var dataSize: UInt32 = 0
        var dataType: UInt32 = 0
        var dataAttributes: UInt8 = 0
    }

    private typealias SMCBytes = (
        UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
        UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
        UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
        UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8
    )

    private struct SMCParamStruct {
        var key: UInt32 = 0
        var vers = SMCVersion()
        var pLimitData = SMCPLimitData()
        var keyInfo = SMCKeyInfoData()
        var padding: UInt16 = 0
        var result: UInt8 = 0
        var status: UInt8 = 0
        var data8: UInt8 = 0
        var data32: UInt32 = 0
        var bytes: SMCBytes = (0,0,0,0,0,0,0,0,
                               0,0,0,0,0,0,0,0,
                               0,0,0,0,0,0,0,0,
                               0,0,0,0,0,0,0,0)
    }

    // Operation selectors carried in param.data8
    private enum Op: UInt8 {
        case readKey = 5
        case writeKey = 6
        case getKeyFromIndex = 8
        case getKeyInfo = 9
    }
    private static let kSMCHandleYPCEvent: UInt32 = 2

    public enum SMCError: Error, CustomStringConvertible {
        case driverNotFound
        case openFailed(kern_return_t)
        case callFailed(kern_return_t)
        case keyError(key: String, result: UInt8)
        case unsupportedType(String)

        public var description: String {
            switch self {
            case .driverNotFound:        return "AppleSMC driver not found"
            case .openFailed(let r):     return "IOServiceOpen failed: \(r)"
            case .callFailed(let r):     return "IOConnectCallStructMethod failed: \(r)"
            case .keyError(let k, let r): return "SMC key \(k) error (result=\(r))"
            case .unsupportedType(let t): return "Unsupported SMC data type: \(t)"
            }
        }
    }

    private var connection: io_connect_t = 0

    public init() throws {
        let service = IOServiceGetMatchingService(kIOMainPortDefault,
                                                  IOServiceMatching("AppleSMC"))
        guard service != 0 else { throw SMCError.driverNotFound }
        defer { IOObjectRelease(service) }

        let result = IOServiceOpen(service, mach_task_self_, 0, &connection)
        guard result == kIOReturnSuccess else { throw SMCError.openFailed(result) }
    }

    deinit {
        if connection != 0 { IOServiceClose(connection) }
    }

    // MARK: Four-char code helpers

    /// "F0Tg" -> UInt32 big-endian code expected by SMC.
    public static func fourCharCode(_ s: String) -> UInt32 {
        precondition(s.utf8.count == 4, "SMC key must be 4 ASCII chars")
        var code: UInt32 = 0
        for b in s.utf8 { code = (code << 8) | UInt32(b) }
        return code
    }

    public static func typeString(_ code: UInt32) -> String {
        let bytes = [UInt8((code >> 24) & 0xff), UInt8((code >> 16) & 0xff),
                     UInt8((code >> 8) & 0xff), UInt8(code & 0xff)]
        return String(bytes: bytes, encoding: .ascii) ?? "?"
    }

    // MARK: Core call

    private func call(_ input: inout SMCParamStruct) throws -> SMCParamStruct {
        var output = SMCParamStruct()
        var outSize = MemoryLayout<SMCParamStruct>.stride
        let inSize = MemoryLayout<SMCParamStruct>.stride

        let result = IOConnectCallStructMethod(
            connection,
            SMC.kSMCHandleYPCEvent,
            &input, inSize,
            &output, &outSize
        )
        guard result == kIOReturnSuccess else { throw SMCError.callFailed(result) }
        return output
    }

    // MARK: Key info

    public struct KeyInfo {
        public let dataSize: UInt32
        public let dataType: UInt32   // four-char code
        public var typeString: String { SMC.typeString(dataType) }
    }

    public func keyInfo(_ key: String) throws -> KeyInfo {
        var input = SMCParamStruct()
        input.key = SMC.fourCharCode(key)
        input.data8 = Op.getKeyInfo.rawValue
        let out = try call(&input)
        guard out.result == 0 else { throw SMCError.keyError(key: key, result: out.result) }
        return KeyInfo(dataSize: out.keyInfo.dataSize, dataType: out.keyInfo.dataType)
    }

    // MARK: Raw read / write

    /// Returns the raw little-endian bytes for `key` plus its type.
    public func readBytes(_ key: String) throws -> (type: UInt32, bytes: [UInt8]) {
        let info = try keyInfo(key)

        var input = SMCParamStruct()
        input.key = SMC.fourCharCode(key)
        input.keyInfo.dataSize = info.dataSize
        input.data8 = Op.readKey.rawValue
        let out = try call(&input)
        guard out.result == 0 else { throw SMCError.keyError(key: key, result: out.result) }

        let n = Int(info.dataSize)
        var raw = withUnsafeBytes(of: out.bytes) { Array($0) }
        raw = Array(raw.prefix(n))
        return (info.dataType, raw)
    }

    public func writeBytes(_ key: String, type: UInt32? = nil, bytes: [UInt8]) throws {
        let info = try keyInfo(key)

        var input = SMCParamStruct()
        input.key = SMC.fourCharCode(key)
        input.keyInfo.dataSize = info.dataSize
        input.keyInfo.dataType = type ?? info.dataType
        input.data8 = Op.writeKey.rawValue

        // pack into the 32-byte tuple
        var tuple: SMCBytes = (0,0,0,0,0,0,0,0,
                               0,0,0,0,0,0,0,0,
                               0,0,0,0,0,0,0,0,
                               0,0,0,0,0,0,0,0)
        withUnsafeMutableBytes(of: &tuple) { dst in
            for (i, b) in bytes.prefix(Int(info.dataSize)).enumerated() {
                dst[i] = b
            }
        }
        input.bytes = tuple

        let out = try call(&input)
        guard out.result == 0 else { throw SMCError.keyError(key: key, result: out.result) }
    }

    // MARK: Typed convenience reads

    /// Decode a numeric key to Double, handling Apple Silicon `flt` and the
    /// classic `fpe2`/`ui8`/`ui16`/`ui32`/`si8`/`si16` encodings.
    public func readDouble(_ key: String) throws -> Double {
        let (type, bytes) = try readBytes(key)
        let t = SMC.typeString(type)
        switch t {
        case "flt ", "flt":
            guard bytes.count >= 4 else { return 0 }
            let bits = UInt32(bytes[0]) | (UInt32(bytes[1]) << 8)
                     | (UInt32(bytes[2]) << 16) | (UInt32(bytes[3]) << 24)
            return Double(Float(bitPattern: bits))
        case "fpe2":
            guard bytes.count >= 2 else { return 0 }
            let v = (UInt16(bytes[0]) << 8) | UInt16(bytes[1])
            return Double(v) / 4.0
        case "ui8 ", "ui8", "si8 ", "si8":
            return Double(bytes.first ?? 0)
        case "ui16", "si16":
            guard bytes.count >= 2 else { return 0 }
            return Double((UInt16(bytes[0]) << 8) | UInt16(bytes[1]))
        case "ui32":
            guard bytes.count >= 4 else { return 0 }
            let v = (UInt32(bytes[0]) << 24) | (UInt32(bytes[1]) << 16)
                  | (UInt32(bytes[2]) << 8) | UInt32(bytes[3])
            return Double(v)
        default:
            throw SMCError.unsupportedType(t)
        }
    }

    /// Encode a Double for a key, matching its native type.
    public func writeDouble(_ key: String, _ value: Double) throws {
        let info = try keyInfo(key)
        let t = SMC.typeString(info.dataType)
        switch t {
        case "flt ", "flt":
            let bits = Float(value).bitPattern
            let bytes = [UInt8(bits & 0xff), UInt8((bits >> 8) & 0xff),
                         UInt8((bits >> 16) & 0xff), UInt8((bits >> 24) & 0xff)]
            try writeBytes(key, bytes: bytes)
        case "fpe2":
            let v = UInt16(max(0, min(65535, value * 4.0)))
            try writeBytes(key, bytes: [UInt8(v >> 8), UInt8(v & 0xff)])
        case "ui8 ", "ui8":
            try writeBytes(key, bytes: [UInt8(max(0, min(255, value)))])
        default:
            throw SMCError.unsupportedType(t)
        }
    }

    public func writeUInt8(_ key: String, _ value: UInt8) throws {
        try writeBytes(key, bytes: [value])
    }

    // MARK: Key enumeration

    /// Total number of SMC keys exposed by this machine (the `#KEY` value).
    public func keyCount() throws -> Int {
        Int(try readDouble("#KEY"))
    }

    /// The 4-char key name at `index` in the SMC key table.
    public func key(at index: Int) throws -> String {
        var input = SMCParamStruct()
        input.data8 = Op.getKeyFromIndex.rawValue
        input.data32 = UInt32(index)
        let out = try call(&input)
        guard out.result == 0 else {
            throw SMCError.keyError(key: "#\(index)", result: out.result)
        }
        return SMC.typeString(out.key)
    }

    /// Enumerate every key name on this machine. Useful for discovering the
    /// real temperature-sensor keys empirically on a given model.
    public func allKeys() throws -> [String] {
        let count = try keyCount()
        var keys: [String] = []
        keys.reserveCapacity(count)
        for i in 0..<count {
            if let k = try? key(at: i) { keys.append(k) }
        }
        return keys
    }
}
