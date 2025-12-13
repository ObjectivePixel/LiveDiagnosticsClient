import Foundation

public protocol TelemetryIdentifierGenerating: Sendable {
    func generateIdentifier() -> String
}

public struct TelemetryIdentifierGenerator: TelemetryIdentifierGenerating {
    private static let alphabet: [Character] = Array("abcdefghjkmnpqrstuvwxyz23456789")
    private let length: Int

    public init(length: Int = 12) {
        self.length = max(10, length)
    }

    /// Generates a short, human-friendly identifier using a restricted base32 alphabet.
    /// With 32^length combinations, collisions are statistically unlikely for interactive use.
    public func generateIdentifier() -> String {
        var scalars: [UnicodeScalar] = []
        scalars.reserveCapacity(length)

        for _ in 0..<length {
            let index = Int.random(in: 0..<Self.alphabet.count)
            let character = Self.alphabet[index]
            if let scalar = character.unicodeScalars.first {
                scalars.append(scalar)
            }
        }

        return String(String.UnicodeScalarView(scalars))
    }
}
