import Foundation

/// One path the search kept, with where the query landed in it.
struct FuzzyMatch: Equatable, Sendable {
    let path: String
    let score: Int
    /// UTF-16 offsets into `path`, ascending — what an `NSRange` counts in, so
    /// the row can bold them without converting.
    let positions: [Int]
}

/// The paths under the Files card's root, prepared once for matching, and
/// the search over them.
///
/// A query matches a path when its characters appear in it in order, gaps
/// allowed — `fbv` finds `Files/FileBrowserView.swift`. Which of the many
/// ways a query fits a path counts is a small dynamic programme in the shape
/// fzf uses: a character scores more where a word starts (after `/`, after
/// `-_. `, at a camel hump), more again when it follows the last one, less for
/// every character skipped between them, and more inside the file's own name
/// than in the folders above it, because a file is looked for by its name.
/// Equal scores go to the shorter path.
///
/// Smart case, as in fzf and every editor's quick-open: a query with a
/// capital in it is matched exactly, one without ignores case. Spaces in the
/// query are dropped rather than matched, so `file view` reads as `fileview`.
///
/// Immutable, so a search can run off the main thread while the next
/// keystroke is typed.
final class FuzzyIndex: Sendable {
    struct Result: Sendable {
        /// The best `limit`, best first.
        let matches: [FuzzyMatch]
        /// How many paths matched at all.
        let total: Int
    }

    fileprivate struct Candidate: Sendable {
        let path: String
        let units: [UInt16]
        let folded: [UInt16]
        /// Where the last path component starts.
        let nameStart: Int
    }

    private let candidates: [Candidate]

    var count: Int { candidates.count }

    init(paths: [String]) {
        candidates = paths.map { path in
            let units = Array(path.utf16)
            let slash = units.lastIndex(of: ascii("/")).map { $0 + 1 } ?? 0
            return Candidate(path: path, units: units, folded: units.map(FuzzyScorer.fold), nameStart: slash)
        }
    }

    func search(_ query: String, limit: Int) -> Result {
        guard let pattern = FuzzyScorer.Pattern(query) else { return Result(matches: [], total: 0) }
        var scorer = FuzzyScorer()
        var scored: [(score: Int, index: Int)] = []
        for (index, candidate) in candidates.enumerated() {
            if let (score, _) = scorer.score(pattern, candidate, tracking: false) {
                scored.append((score, index))
            }
        }
        scored.sort { first, second in
            if first.score != second.score { return first.score > second.score }
            let a = candidates[first.index].units.count, b = candidates[second.index].units.count
            if a != b { return a < b }
            return candidates[first.index].path < candidates[second.index].path
        }
        let matches = scored.prefix(limit).map { entry -> FuzzyMatch in
            let candidate = candidates[entry.index]
            let positions = scorer.score(pattern, candidate, tracking: true)?.positions ?? []
            return FuzzyMatch(path: candidate.path, score: entry.score, positions: positions)
        }
        return Result(matches: matches, total: scored.count)
    }

    /// One path against one query, for the tests.
    static func match(_ query: String, in path: String) -> FuzzyMatch? {
        FuzzyIndex(paths: [path]).search(query, limit: 1).matches.first
    }
}

/// The scoring itself, with its scratch rows kept between candidates: a
/// search scores every path in the index on every keystroke, and allocating
/// two matrices per path is most of what that would otherwise cost.
private struct FuzzyScorer {
    struct Pattern {
        let units: [UInt16]
        let caseSensitive: Bool

        init?(_ query: String) {
            let kept = query.utf16.filter { $0 != ascii(" ") && $0 != ascii("\t") }
            guard !kept.isEmpty else { return nil }
            caseSensitive = kept.contains { $0 >= 65 && $0 <= 90 }
            units = caseSensitive ? kept : kept.map(FuzzyScorer.fold)
        }
    }

    static let match = 16
    static let gapStart = 3
    static let gapExtension = 1
    static let consecutive = 6
    static let boundarySlash = 10
    static let boundaryDelimiter = 8
    static let camel = 7
    static let inName = 8
    static let firstCharMultiplier = 2
    static let none = Int32.min / 2

    private var scores: [Int32] = []
    private var previous: [Int32] = []

    static func fold(_ unit: UInt16) -> UInt16 {
        unit >= 65 && unit <= 90 ? unit + 32 : unit
    }

    private static func bonus(_ units: [UInt16], at index: Int) -> Int {
        guard index > 0 else { return boundarySlash }
        let before = units[index - 1], here = units[index]
        switch before {
        case ascii("/"):
            return boundarySlash
        case ascii("-"), ascii("_"), ascii("."), ascii(" "):
            return boundaryDelimiter
        default:
            let lowerBefore = before >= 97 && before <= 122
            let upperHere = here >= 65 && here <= 90
            let digitBefore = before >= 48 && before <= 57
            let digitHere = here >= 48 && here <= 57
            return (lowerBefore && upperHere) || (!digitBefore && digitHere) ? camel : 0
        }
    }

    /// The best score `pattern` can make in `candidate`, or nil when it does
    /// not fit at all. `tracking` also answers where that best alignment put
    /// each character of the query; without it `positions` is empty.
    mutating func score(_ pattern: Pattern, _ candidate: FuzzyIndex.Candidate, tracking: Bool) -> (score: Int, positions: [Int])? {
        let query = pattern.units
        let text = pattern.caseSensitive ? candidate.units : candidate.folded
        let m = query.count, n = text.count
        guard m <= n else { return nil }

        // Every alignment lies between the first place the query can start
        // and the last place it can end, and finding the two is also the
        // test for whether it fits at all — which most paths fail, cheaply.
        var q = 0, low = 0
        for j in 0..<n where text[j] == query[q] {
            if q == 0 { low = j }
            q += 1
            if q == m { break }
        }
        guard q == m else { return nil }
        q = m - 1
        var high = n - 1
        for j in stride(from: n - 1, through: low, by: -1) where text[j] == query[q] {
            if q == m - 1 { high = j }
            if q == 0 { break }
            q -= 1
        }

        let width = high - low + 1
        let cells = m * width
        if scores.count < cells { scores = Array(repeating: 0, count: cells) }
        if tracking, previous.count < cells { previous = Array(repeating: 0, count: cells) }

        for i in 0..<m {
            let row = i * width, above = (i - 1) * width
            // Best of the row above ending two or more cells back, less the
            // gap to here — carried along the row rather than searched for.
            var gapBest = Self.none
            var gapFrom: Int32 = -1
            for k in 0..<width {
                if i > 0, k >= 2 {
                    let opened = scores[above + k - 2]
                    let extended = gapBest == Self.none ? Self.none : gapBest - Int32(Self.gapExtension)
                    if opened != Self.none, opened - Int32(Self.gapStart) >= extended {
                        gapBest = opened - Int32(Self.gapStart)
                        gapFrom = Int32(k - 2)
                    } else {
                        gapBest = extended
                    }
                }
                let j = low + k
                guard text[j] == query[i] else {
                    scores[row + k] = Self.none
                    continue
                }
                var gain = Self.bonus(candidate.units, at: j)
                if i == 0 { gain *= Self.firstCharMultiplier }
                if j >= candidate.nameStart { gain += Self.inName }
                let base = Int32(Self.match + gain)
                if i == 0 {
                    scores[row + k] = base
                    if tracking { previous[row + k] = -1 }
                    continue
                }
                var best = gapBest
                var from = gapFrom
                if k >= 1, scores[above + k - 1] != Self.none {
                    let run = scores[above + k - 1] + Int32(Self.consecutive)
                    if run >= best {
                        best = run
                        from = Int32(k - 1)
                    }
                }
                guard best != Self.none else {
                    scores[row + k] = Self.none
                    continue
                }
                scores[row + k] = base + best
                if tracking { previous[row + k] = from }
            }
        }

        let last = (m - 1) * width
        var bestScore = Self.none
        var bestEnd = -1
        for k in 0..<width where scores[last + k] != Self.none && scores[last + k] > bestScore {
            bestScore = scores[last + k]
            bestEnd = k
        }
        guard bestEnd >= 0 else { return nil }
        guard tracking else { return (Int(bestScore), []) }
        var found = [Int](repeating: 0, count: m)
        var k = bestEnd
        for i in stride(from: m - 1, through: 0, by: -1) {
            found[i] = low + k
            k = Int(previous[i * width + k])
        }
        return (Int(bestScore), found)
    }
}

/// A UTF-16 code unit for an ASCII character; `UInt16` has no `ascii:`
/// initialiser of its own.
private func ascii(_ scalar: Unicode.Scalar) -> UInt16 {
    UInt16(scalar.value)
}
