import ArgumentParser
import Dispatch
import Foundation

/// Core code for the CVM distinct-count algorithm.
///
/// CVM = Chakraborty, Vinodchandran, Meel.
/// This follows Algorithm 1 from the paper.
enum CVM {

    /// File/tokenization errors shown by the CLI.
    enum Error: Swift.Error, LocalizedError {
        case fileReadFailed(String)
        case fileDecodeFailed

        var errorDescription: String? {
            switch self {
            case .fileReadFailed(let path): "could not read \(path)"
            case .fileDecodeFailed: "could not decode file as UTF-8 text"
            }
        }
    }

    /// Small deterministic RNG.
    ///
    /// We use this so runs are repeatable for a given seed.
    struct SplitMix64: RandomNumberGenerator {
        private var state: UInt64

        init(seed: UInt64) {
            state = seed
        }

        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    /// Streaming estimator (paper Algorithm 1).
    ///
    /// Mapping to paper names:
    /// - `sample` = X
    /// - `level` means p = 2^-level
    /// - `threshold` = thresh
    struct Estimator<Element: Hashable & Comparable> {
        
        /// Current sample set X.
        private(set) var sample = Set<Element>()
        /// Current level k, so sampling probability is p = 2^-k.
        private(set) var level = 0
        /// Max sample size before we thin.
        let threshold: Int

        /// scale = 2^level. Estimate is |X| * scale.
        /// Cached to avoid `pow` in hot paths.
        private var scale: Double = 1
        /// Bit mask used for fast sampling with p = 1/2^level.
        private var sampleMask: UInt64 = 0

        init(threshold: Int) {
            self.threshold = threshold
        }

        /// Consume one stream item.
        /// Returns false when the paper's fail condition ("bottom") happens.
        mutating func consume<R: RandomNumberGenerator>(_ item: Element, using rng: inout R) -> Bool {
            // Paper line 3: X <- X \ {a_i}
            sample.remove(item)

            // Paper line 4: add back with probability p.
            if shouldSample(using: &rng) {
                sample.insert(item)
            }

            // Paper line 5: if |X| hits threshold, thin and lower p.
            if sample.count >= threshold {
                var kept = Set<Element>()
                kept.reserveCapacity(sample.count)

                // Paper line 6: keep each item with probability 1/2.
                //
                // We iterate in sorted order so RNG draws are consumed in a stable sequence.
                // `Set` iteration order changes across process launches, which would otherwise
                // break reproducibility even with a fixed seed.
                for element in sample.sorted() where (rng.next() & 1) == 1 {
                    kept.insert(element)
                }

                sample = kept
                // Paper line 7: p <- p/2.
                advanceLevel()

                // Paper line 8: if still full, fail.
                if sample.count >= threshold {
                    return false
                }
            }

            return true
        }

        /// Final estimate: |X| / p = |X| * 2^level.
        var estimate: Double {
            Double(sample.count) * scale
        }

        /// Move from level k to k+1.
        /// Edge case: level 63 must still mean p = 1/2^63.
        private mutating func advanceLevel() {
            level += 1
            scale *= 2

            if level > 63 {
                sampleMask = UInt64.max
            } else {
                sampleMask = (UInt64(1) << UInt64(level)) - 1
            }
        }

        /// Bernoulli draw with probability p = 1/2^level.
        private func shouldSample<R: RandomNumberGenerator>(using rng: inout R) -> Bool {
            if sampleMask == 0 {
                return true
            }
            return (rng.next() & sampleMask) == 0
        }
    }

    /// Tokenization and compact encoding.
    /// Words are mapped to UInt32 IDs so trials run on integers, not strings.
    enum Text {
        /// Token stream as IDs + exact distinct count.
        struct TokenData {
            let ids: [UInt32]
            let exactDistinct: Int
        }

        /// Read a file and tokenize it into IDs.
        /// Uses a fast ASCII path when possible.
        static func loadTokenData(from path: String) throws -> TokenData {
            let url = URL(fileURLWithPath: path)
            let data: Data
            do {
                data = try Data(contentsOf: url, options: [.mappedIfSafe])
            } catch {
                throw Error.fileReadFailed(path)
            }

            if data.isEmpty {
                return TokenData(ids: [], exactDistinct: 0)
            }

            if isASCII(data) {
                return tokenizeASCII(data)
            }
            return try tokenizeUnicode(data)
        }

        /// Quick check for ASCII-only data.
        private static func isASCII(_ data: Data) -> Bool {
            data.withUnsafeBytes { raw in
                guard let bytes = raw.bindMemory(to: UInt8.self).baseAddress else {
                    return true
                }
                for index in 0..<data.count where bytes[index] >= 0x80 {
                    return false
                }
                return true
            }
        }

        /// Fast tokenizer for ASCII data.
        /// Rule: keep letters/digits/apostrophe, lowercase, split on other chars.
        private static func tokenizeASCII(_ data: Data) -> TokenData {
            var dictionary: [String: UInt32] = [:]
            var ids: [UInt32] = []
            ids.reserveCapacity(max(1_024, data.count / 5))

            var current: [UInt8] = []
            current.reserveCapacity(32)

            func id(for token: String, in dictionary: inout [String: UInt32]) -> UInt32 {
                if let existing = dictionary[token] {
                    return existing
                }
                let next = UInt32(dictionary.count)
                dictionary[token] = next
                return next
            }

            // Emit current token (if any) and map to ID.
            func flush() {
                if !current.isEmpty {
                    let token = String(decoding: current, as: UTF8.self)
                    ids.append(id(for: token, in: &dictionary))
                    current.removeAll(keepingCapacity: true)
                }
            }

            data.withUnsafeBytes { raw in
                guard let bytes = raw.bindMemory(to: UInt8.self).baseAddress else {
                    return
                }

                for index in 0..<data.count {
                    let byte = bytes[index]
                    if isASCIIAlnum(byte) || byte == 39 {
                        current.append(lowercasedASCII(byte))
                    } else {
                        flush()
                    }
                }
            }
            flush()

            return TokenData(ids: ids, exactDistinct: dictionary.count)
        }

        /// Unicode fallback tokenizer for non-ASCII UTF-8.
        private static func tokenizeUnicode(_ data: Data) throws -> TokenData {
            guard let text = String(data: data, encoding: .utf8) else {
                throw Error.fileDecodeFailed
            }

            var dictionary: [String: UInt32] = [:]
            var ids: [UInt32] = []
            ids.reserveCapacity(max(1_024, text.count / 5))

            var current = String.UnicodeScalarView()
            current.reserveCapacity(32)

            func id(for token: String, in dictionary: inout [String: UInt32]) -> UInt32 {
                if let existing = dictionary[token] {
                    return existing
                }
                let next = UInt32(dictionary.count)
                dictionary[token] = next
                return next
            }

            func flush() {
                if !current.isEmpty {
                    let token = String(current).lowercased()
                    ids.append(id(for: token, in: &dictionary))
                    current.removeAll(keepingCapacity: true)
                }
            }

            for scalar in text.unicodeScalars {
                if CharacterSet.alphanumerics.contains(scalar) || scalar == "'" {
                    current.append(scalar)
                } else {
                    flush()
                }
            }
            flush()

            return TokenData(ids: ids, exactDistinct: dictionary.count)
        }

        /// ASCII digit/letter check.
        private static func isASCIIAlnum(_ byte: UInt8) -> Bool {
            (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte)
        }

        /// Lowercase one ASCII byte.
        private static func lowercasedASCII(_ byte: UInt8) -> UInt8 {
            if (65...90).contains(byte) {
                return byte &+ 32
            }
            return byte
        }
    }

    /// Runs independent trials.
    /// Trials run in parallel, but output order stays deterministic.
    enum Experiment {
        static func runTrials(
            tokenIDs: [UInt32],
            exactDistinct: Int,
            threshold: Int,
            trials: Int,
            baseSeed: UInt64
        ) async -> [Stats.TrialResult] {
            await withTaskGroup(of: (Int, Stats.TrialResult).self, returning: [Stats.TrialResult].self) { group in
                for index in 0..<trials {
                    group.addTask {
                        let trialNumber = index + 1
                        // Stable derived seed keeps runs repeatable.
                        let seed = baseSeed &+ UInt64(trialNumber) &* 0x94D0_49BB
                        let result = runSingleTrial(
                            tokenIDs: tokenIDs,
                            exactDistinct: exactDistinct,
                            threshold: threshold,
                            seed: seed
                        )
                        return (index, result)
                    }
                }

                var values: [Stats.TrialResult?] = Array(repeating: nil, count: trials)
                for await (index, result) in group {
                    values[index] = result
                }

                // Do not silently drop missing trial writes.
                for (index, value) in values.enumerated() {
                    precondition(value != nil, "missing trial result at index \(index)")
                }
                return values.compactMap { $0 }
            }
        }

        /// Run one full pass over the token stream.
        private static func runSingleTrial(
            tokenIDs: [UInt32],
            exactDistinct: Int,
            threshold: Int,
            seed: UInt64
        ) -> Stats.TrialResult {
            // Monotonic clock for reliable elapsed timing.
            let start = DispatchTime.now().uptimeNanoseconds

            var rng = SplitMix64(seed: seed)
            var estimator = Estimator<UInt32>(threshold: threshold)
            var failed = false

            for token in tokenIDs where !failed {
                failed = !estimator.consume(token, using: &rng)
            }

            let elapsedNanos = DispatchTime.now().uptimeNanoseconds - start
            let elapsed = Double(elapsedNanos) / 1_000_000_000

            return Stats.TrialResult(
                exact: exactDistinct,
                estimate: failed ? nil : estimator.estimate,
                elapsedSeconds: elapsed
            )
        }
    }

    /// Threshold options.
    /// - default: memory threshold = 1000
    /// - `--memory`: fixed threshold
    /// - `--epsilon/--delta`: threshold from paper formula
    struct ThresholdOptions: ParsableArguments {
        @Option(help: "Fixed sample cap (threshold). Default is 1000 when epsilon/delta are not set.")
        var memory: Int?

        @Option(help: "Target relative error bound (0 < epsilon < 1).")
        var epsilon: Double?

        @Option(help: "Failure probability (0 < delta < 1).")
        var delta: Double?

        /// Resolve and validate threshold for this stream length.
        func threshold(streamLength: Int) throws -> Int {
            guard streamLength > 0 else {
                throw ValidationError("stream length must be > 0")
            }

            if epsilon != nil || delta != nil {
                guard memory == nil else {
                    throw ValidationError("choose either --memory or (--epsilon and --delta)")
                }
                guard let epsilon, let delta else {
                    throw ValidationError("use both --epsilon and --delta")
                }
                guard epsilon > 0, epsilon < 1 else {
                    throw ValidationError("--epsilon must be between 0 and 1")
                }
                guard delta > 0, delta < 1 else {
                    throw ValidationError("--delta must be between 0 and 1")
                }

                // Paper formula (Algorithm 1): ceil((12 / epsilon^2) * log2(8m / delta))
                let raw = (12.0 / (epsilon * epsilon)) * log2((8.0 * Double(streamLength)) / delta)
                return max(1, Int(ceil(raw)))
            }

            let threshold = memory ?? 1000
            guard threshold > 0 else {
                throw ValidationError("--memory must be > 0")
            }
            return threshold
        }

        /// Optional epsilon shown in summary table.
        var reportEpsilon: Double? {
            epsilon
        }
    }
}
