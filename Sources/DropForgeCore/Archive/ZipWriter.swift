import Foundation
import Compression

/// Minimal in-memory ZIP writer used for generated packages (EPUB, PPTX). User files are archived with the
/// system `ditto`, which streams and keeps macOS metadata.
public struct ZipWriter {
    private struct Entry {
        let name: Data
        let crc: UInt32
        let compressedSize: UInt32
        let size: UInt32
        let method: UInt16
        let offset: UInt32
    }

    private var body = Data()
    private var entries: [Entry] = []
    private let dosTime: UInt16
    private let dosDate: UInt16

    public init(date: Date = Date()) {
        let c = Calendar(identifier: .gregorian).dateComponents(in: .current, from: date)
        dosTime = UInt16((c.hour ?? 0) << 11 | (c.minute ?? 0) << 5 | ((c.second ?? 0) / 2))
        dosDate = UInt16(max(0, (c.year ?? 1980) - 1980) << 9 | (c.month ?? 1) << 5 | (c.day ?? 1))
    }

    /// Adds a file. `store` keeps it uncompressed (required for the EPUB `mimetype` entry).
    public mutating func add(_ path: String, data: Data, store: Bool = false) {
        let crc = CRC32.checksum(data)
        var payload = data
        var method: UInt16 = 0
        if !store, data.count > 64, let deflated = Self.deflate(data), deflated.count < data.count {
            payload = deflated
            method = 8
        }
        let name = Data(path.utf8)
        let offset = UInt32(body.count)
        body.appendLE(UInt32(0x04034b50))
        body.appendLE(UInt16(20))            // version needed
        body.appendLE(UInt16(0x0800))        // UTF-8 names
        body.appendLE(method)
        body.appendLE(dosTime)
        body.appendLE(dosDate)
        body.appendLE(crc)
        body.appendLE(UInt32(payload.count))
        body.appendLE(UInt32(data.count))
        body.appendLE(UInt16(name.count))
        body.appendLE(UInt16(0))
        body.append(name)
        body.append(payload)
        entries.append(Entry(name: name, crc: crc, compressedSize: UInt32(payload.count), size: UInt32(data.count),
                             method: method, offset: offset))
    }

    public mutating func add(_ path: String, text: String, store: Bool = false) {
        add(path, data: Data(text.utf8), store: store)
    }

    public func finalize() -> Data {
        var out = body
        let directoryOffset = UInt32(out.count)
        for e in entries {
            out.appendLE(UInt32(0x02014b50))
            out.appendLE(UInt16(0x031E))     // made by: Unix, spec 3.0
            out.appendLE(UInt16(20))
            out.appendLE(UInt16(0x0800))
            out.appendLE(e.method)
            out.appendLE(dosTime)
            out.appendLE(dosDate)
            out.appendLE(e.crc)
            out.appendLE(e.compressedSize)
            out.appendLE(e.size)
            out.appendLE(UInt16(e.name.count))
            out.appendLE(UInt16(0)); out.appendLE(UInt16(0)); out.appendLE(UInt16(0)); out.appendLE(UInt16(0))
            out.appendLE(UInt32(0o100644) << 16)
            out.appendLE(e.offset)
            out.append(e.name)
        }
        let directorySize = UInt32(out.count) - directoryOffset
        out.appendLE(UInt32(0x06054b50))
        out.appendLE(UInt16(0)); out.appendLE(UInt16(0))
        out.appendLE(UInt16(entries.count)); out.appendLE(UInt16(entries.count))
        out.appendLE(directorySize)
        out.appendLE(directoryOffset)
        out.appendLE(UInt16(0))
        return out
    }

    /// Raw DEFLATE (Apple's COMPRESSION_ZLIB emits RFC 1951 without a zlib header, as ZIP expects).
    static func deflate(_ data: Data) -> Data? {
        let capacity = data.count + data.count / 10 + 1024
        var dst = Data(count: capacity)
        let written = dst.withUnsafeMutableBytes { d in
            data.withUnsafeBytes { s in
                compression_encode_buffer(d.bindMemory(to: UInt8.self).baseAddress!, capacity,
                                          s.bindMemory(to: UInt8.self).baseAddress!, data.count, nil, COMPRESSION_ZLIB)
            }
        }
        guard written > 0 else { return nil }
        return dst.prefix(written)
    }
}

public enum CRC32 {
    static let table: [UInt32] = (0..<256).map { i -> UInt32 in
        var c = UInt32(i)
        for _ in 0..<8 { c = (c & 1) != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1 }
        return c
    }

    public static func checksum(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        data.withUnsafeBytes { buf in
            for b in buf { crc = table[Int((crc ^ UInt32(b)) & 0xFF)] ^ (crc >> 8) }
        }
        return crc ^ 0xFFFF_FFFF
    }
}

extension Data {
    mutating func appendLE<T: FixedWidthInteger>(_ v: T) {
        var le = v.littleEndian
        Swift.withUnsafeBytes(of: &le) { append(contentsOf: $0) }
    }
}
