/// COM-06 / D138: one PocketAI Pro licence covers 5 devices, counted over
/// licensed Macs plus paired phones, and the Mac enforces it when pairing.
/// ponytail: counts this Mac and its paired phones only; other licensed Macs
/// need the Worker's activation list (server piece, not built).
enum DeviceCap {
    static let limit = 5

    /// True when one more phone can be paired.
    static func canPair(pairedPhones: Int, otherLicensedMacs: Int = 0, limit: Int = DeviceCap.limit) -> Bool {
        1 + otherLicensedMacs + pairedPhones < limit
    }
}
