import Foundation

/// Shared JSON configuration: snake_case keys and ISO-8601 dates with or without fractional seconds.
enum JSONCoding {
    static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let raw = try container.decode(String.self)
            if let date = ISO8601Flexible.parse(raw) {
                return date
            }
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unrecognised ISO-8601 date: \(raw)"
            )
        }
        return decoder
    }

    static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

/// Accepts `2026-10-15T00:00:00Z`, `2026-10-15T00:00:00.123456Z`, `+00:00` offsets, and naive
/// timestamps (treated as UTC). Formatters are created per call; `ISO8601DateFormatter` is not
/// `Sendable`, and parsing is rare enough that caching is not worth an isolation boundary.
enum ISO8601Flexible {
    static func parse(_ raw: String) -> Date? {
        let candidates: [ISO8601DateFormatter.Options] = [
            [.withInternetDateTime, .withFractionalSeconds],
            [.withInternetDateTime],
        ]
        for options in candidates {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = options
            if let date = formatter.date(from: raw) {
                return date
            }
        }
        // Naive timestamp (no zone): assume UTC.
        let hasZone = raw.hasSuffix("Z") || raw.range(of: #"[+-]\d{2}:?\d{2}$"#, options: .regularExpression) != nil
        if !hasZone {
            return parse(raw + "Z")
        }
        return nil
    }
}
