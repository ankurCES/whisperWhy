import Foundation

// Pure transcript helpers — unit-testable without AppKit or audio.

enum TranscriptCore {
    /// Collapses whitespace runs, trims, and appends one space after final
    /// sentence punctuation so consecutive dictations don't jam together
    /// (FreeFlow behavior).
    static func finalize(_ raw: String) -> String {
        var t = raw
            .replacingOccurrences(of: "\r", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        while t.contains("  ") { t = t.replacingOccurrences(of: "  ", with: " ") }
        if let last = t.last, ".!?".contains(last) { t += " " }
        return t
    }
}

// WAV reading for the transcription path: locate the data chunk, decode
// 16-bit PCM → Float32. Pure over Data so it is testable.

enum WAVCore {
    /// Returns mono 16 kHz samples from a 16-bit PCM WAV, or nil if malformed.
    static func samples(from data: Data) -> [Float]? {
        guard data.count > 44 else { return nil }
        let bytes = [UInt8](data)
        guard String(decoding: bytes[0..<4], as: UTF8.self) == "RIFF",
              String(decoding: bytes[8..<12], as: UTF8.self) == "WAVE"
        else { return nil }

        var offset = 12
        var dataRange: Range<Int>?
        while offset + 8 <= bytes.count {
            let id = String(decoding: bytes[offset..<offset + 4], as: UTF8.self)
            let size = Int(bytes[offset + 4])
                | Int(bytes[offset + 5]) << 8
                | Int(bytes[offset + 6]) << 16
                | Int(bytes[offset + 7]) << 24
            let start = offset + 8
            guard start + size <= bytes.count else { return nil }
            if id == "data" { dataRange = start..<min(start + size, bytes.count); break }
            offset = start + size + (size % 2) // chunks are word-aligned
        }
        guard let range = dataRange else { return nil }

        // Materialize: `bytes[range]` is an ArraySlice whose indices start at
        // `range.lowerBound`, so payload[i] below would be out of bounds.
        let payload = Array(bytes[range])
        var out = [Float]()
        out.reserveCapacity(payload.count / 2)
        var i = 0
        while i + 1 < payload.count {
            let s = Int16(bitPattern: UInt16(payload[i]) | (UInt16(payload[i + 1]) << 8))
            out.append(Float(s) / 32768.0)
            i += 2
        }
        return out.isEmpty ? nil : out
    }
}
