import PocketKit

/// UI-48 / spec 7.1: what the first-run model pick offers.
/// Just the fields the ranking reads, so it is testable without a core.
struct PickCandidate: Equatable {
    var id: String
    var verdict: FitVerdict
    var isChat: Bool
    var isInstruct: Bool
    var diskBytes: UInt64

    init(_ entry: CatalogEntry) {
        let name = entry.manifest.displayName.lowercased()
        id = entry.manifest.id
        verdict = entry.fit.verdict
        isChat = entry.manifest.curated && entry.manifest.modalities == [.text]
        isInstruct = name.contains("instruct") || name.contains("-it-") || name.contains("-it")
        diskBytes = entry.fit.diskBytes
    }

    init(id: String, verdict: FitVerdict, isChat: Bool = true, isInstruct: Bool = false,
         diskBytes: UInt64) {
        self.id = id; self.verdict = verdict; self.isChat = isChat
        self.isInstruct = isInstruct; self.diskBytes = diskBytes
    }
}

struct OnboardingPicks: Equatable {
    var recommended: String?
    var smaller: String?
    var larger: String?
}

/// Recommended = the strongest chat model that `runsWell`: instruct/chat
/// first, then larger download (the catalog has no parameter count for every
/// entry, size is the stand-in for strength), then newest. The catalog has no
/// release date; a higher id sorts later for versioned names, so that is the
/// newest tiebreak. Alternates: the next-smaller one (faster) and the
/// next-larger one (smarter), either `runsWell` or `runsSlow`.
func onboardingPicks(_ all: [PickCandidate]) -> OnboardingPicks {
    let chat = all.filter { $0.isChat }
    // Higher = better.
    func stronger(_ a: PickCandidate, _ b: PickCandidate) -> Bool {
        if a.isInstruct != b.isInstruct { return a.isInstruct }
        if a.diskBytes != b.diskBytes { return a.diskBytes > b.diskBytes }
        return a.id > b.id
    }
    guard let top = chat.filter({ $0.verdict == .runsWell }).sorted(by: stronger).first else {
        return OnboardingPicks()
    }
    let usable = chat.filter { ($0.verdict == .runsWell || $0.verdict == .runsSlow) && $0.id != top.id }
    // Neighbours by size: the biggest one below, the smallest one above.
    let smaller = usable.filter { $0.diskBytes < top.diskBytes }
        .sorted { ($0.diskBytes, $1.id) > ($1.diskBytes, $0.id) }.first
    let larger = usable.filter { $0.diskBytes > top.diskBytes }
        .sorted { ($0.diskBytes, $0.id) < ($1.diskBytes, $1.id) }.first
    return OnboardingPicks(recommended: top.id, smaller: smaller?.id, larger: larger?.id)
}
