import Foundation

/// Stats and table output.
/// Kept separate so core algorithm code stays focused.
extension CVM {
    
    enum Stats {
        /// Result from one full trial.
        struct TrialResult: Sendable {
            /// Exact distinct count for this dataset.
            let exact: Int
            /// Estimator output. Nil means the "bottom" fail case.
            let estimate: Double?
            /// Trial runtime in seconds.
            let elapsedSeconds: Double

            var failed: Bool {
                estimate == nil
            }

            /// Relative error = |estimate - exact| / exact.
            var relativeError: Double? {
                guard let estimate else { return nil }
                guard exact > 0 else { return estimate == 0 ? 0 : .infinity }
                return abs(estimate - Double(exact)) / Double(exact)
            }
        }

        /// Running summary over all trials.
        struct Aggregate {
            private(set) var results: [TrialResult] = []
            private(set) var totalTrials = 0
            private(set) var failureCount = 0
            private(set) var maxRelativeError: Double = .nan

            private var relativeErrorSum: Double = 0
            private var relativeErrorCount: Int = 0
            private var elapsedSumSeconds: Double = 0

            /// Add one trial and update running totals.
            mutating func add(_ result: TrialResult) {
                results.append(result)
                totalTrials += 1
                elapsedSumSeconds += result.elapsedSeconds

                if result.failed {
                    failureCount += 1
                }

                if let rel = result.relativeError {
                    relativeErrorSum += rel
                    relativeErrorCount += 1

                    if maxRelativeError.isNaN || rel > maxRelativeError {
                        maxRelativeError = rel
                    }
                }
            }

            /// Mean relative error for successful trials.
            var meanRelativeError: Double {
                guard relativeErrorCount > 0 else { return .nan }
                return relativeErrorSum / Double(relativeErrorCount)
            }

            /// Median estimate across successful trials.
            /// Returns nil when every trial failed (bottom).
            var medianEstimate: Double? {
                let values = results.compactMap(\.estimate).sorted()
                guard !values.isEmpty else { return nil }
                let mid = values.count / 2
                if values.count % 2 == 1 {
                    return values[mid]
                }
                return (values[mid - 1] + values[mid]) / 2
            }

            /// Average trial runtime.
            var meanElapsedSeconds: Double {
                guard totalTrials > 0 else { return .nan }
                return elapsedSumSeconds / Double(totalTrials)
            }

            /// Percent of successful trials with relative error <= epsilon.
            func inRangeRate(epsilon: Double) -> Double {
                let inRange = results.filter {
                    guard let rel = $0.relativeError else { return false }
                    return rel <= epsilon
                }.count
                return Double(inRange) / Double(max(1, totalTrials))
            }
        }
    }

    /// User-facing formatting and ASCII table output.
    enum Reporter {
        
        /// Fixed decimal formatting used in tables.
        static func format(_ value: Double) -> String {
            String(format: "%.3f", value)
        }

        /// Print run info table.
        static func printRunInfo(path: String, tokens: Int, exactDistinct: Int, trials: Int, threshold: Int, seed: Int) {
            let rows = [
                ["path", path],
                ["tokens", "\(tokens)"],
                ["exact_distinct", "\(exactDistinct)"],
                ["trials", "\(trials)"],
                ["threshold", "\(threshold)"],
                ["seed", "\(seed)"]
            ]
            printTable(title: "Run", headers: ["Field", "Value"], rows: rows, rightAlignedColumns: [1])
        }

        /// Print one row per trial.
        static func printTrials(_ results: [Stats.TrialResult]) {
            let rows: [[String]] = results.enumerated().map { index, result in
                let trial = "\(index + 1)"
                let exact = "\(result.exact)"
                let estimate = result.estimate.map { "\(Int($0.rounded()))" } ?? "bottom"
                let relError = result.relativeError.map { "\(format($0 * 100))%" } ?? "n/a"
                let timeMs = "\(format(result.elapsedSeconds * 1000))"
                let status = result.failed ? "fail" : "ok"
                return [trial, exact, estimate, relError, timeMs, status]
            }

            printTable(
                title: "Trials",
                headers: ["Trial", "Exact", "Estimate", "RelError", "TimeMs", "Status"],
                rows: rows,
                rightAlignedColumns: [0, 1, 2, 3, 4]
            )
        }

        /// Print summary table.
        static func printSummary(stats: Stats.Aggregate, epsilon: Double?) {
            var rows = [
                ["trials", "\(stats.totalTrials)"],
                ["failures(bottom)", "\(stats.failureCount)"]
            ]

            let failPct = 100.0 * Double(stats.failureCount) / Double(max(1, stats.totalTrials))
            rows.append(["failure_rate", "\(format(failPct))%"])

            if stats.meanRelativeError.isFinite {
                rows.append(["mean_relative_error", "\(format(stats.meanRelativeError * 100))%"])
                rows.append(["max_relative_error", "\(format(stats.maxRelativeError * 100))%"])
            } else {
                rows.append(["mean_relative_error", "n/a"])
                rows.append(["max_relative_error", "n/a"])
            }

            rows.append(["mean_trial_time", "\(format(stats.meanElapsedSeconds * 1000)) ms"])

            if let epsilon {
                let inRange = stats.inRangeRate(epsilon: epsilon)
                rows.append(["fraction_within_+/-\(format(epsilon * 100))%", "\(format(inRange * 100))%"])
            }

            printTable(title: "Summary", headers: ["Metric", "Value"], rows: rows, rightAlignedColumns: [1])
        }

        /// Generic ASCII table printer.
        private static func printTable(title: String, headers: [String], rows: [[String]], rightAlignedColumns: Set<Int>) {
            let columnCount = headers.count
            var widths = headers.map(\.count)

            for row in rows {
                for index in 0..<columnCount {
                    let value = index < row.count ? row[index] : ""
                    widths[index] = max(widths[index], value.count)
                }
            }

            print("\(title):")
            print(border(widths: widths))
            print(rowLine(headers, widths: widths, rightAlignedColumns: rightAlignedColumns))
            print(border(widths: widths))
            for row in rows {
                print(rowLine(row, widths: widths, rightAlignedColumns: rightAlignedColumns))
            }
            print(border(widths: widths))
            print("")
        }

        /// Separator row, like: +------+------+
        private static func border(widths: [Int]) -> String {
            let pieces = widths.map { String(repeating: "-", count: $0 + 2) }
            return "+" + pieces.joined(separator: "+") + "+"
        }

        /// One row with per-column padding/alignment.
        private static func rowLine(_ columns: [String], widths: [Int], rightAlignedColumns: Set<Int>) -> String {
            let padded = widths.indices.map { index -> String in
                let value = index < columns.count ? columns[index] : ""
                let diff = widths[index] - value.count
                let spaces = String(repeating: " ", count: max(0, diff))
                if rightAlignedColumns.contains(index) {
                    return " " + spaces + value + " "
                }
                return " " + value + spaces + " "
            }
            return "|" + padded.joined(separator: "|") + "|"
        }
    }
}
