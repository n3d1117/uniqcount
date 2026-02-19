import ArgumentParser
import Foundation

/// Command entry point.
///
/// This file only handles CLI flow:
/// read options, load data, run trials, print results.
@main
struct UniqCount: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "uniqcount",
        abstract: "Run the distinct-count estimator on a UTF-8 text file."
    )

    @Option(help: "Path to UTF-8 text file.")
    var path: String

    @Option(help: "Number of independent trials.")
    var trials: Int = 20

    @Option(help: "Base RNG seed.")
    var seed: Int = 42

    @Flag(help: "Show detailed tables. Default output is just the estimate.")
    var report = false

    /// Threshold source:
    /// - default memory threshold (`1000`)
    /// - `--memory`
    /// - `--epsilon` + `--delta`
    @OptionGroup var thresholdOptions: CVM.ThresholdOptions

    mutating func run() async throws {
        // Validate CLI values early so errors are clear.
        guard trials > 0 else {
            throw ValidationError("--trials must be > 0")
        }
        guard seed >= 0 else {
            throw ValidationError("--seed must be >= 0")
        }

        // Tokenize once and map words to integer IDs.
        // This keeps memory and hashing cost lower in trials.
        let tokenData: CVM.Text.TokenData
        do {
            tokenData = try CVM.Text.loadTokenData(from: path)
        } catch let error as CVM.Error {
            throw ValidationError(error.localizedDescription)
        } catch {
            throw ValidationError("could not process \(path)")
        }

        guard !tokenData.ids.isEmpty else {
            throw ValidationError("no tokens found in \(path)")
        }

        // Threshold sets the memory/accuracy tradeoff.
        let threshold = try thresholdOptions.threshold(streamLength: tokenData.ids.count)

        // Run independent trials with stable seeds.
        // Same input + same seed gives repeatable output.
        var stats = CVM.Stats.Aggregate()
        let results = await CVM.Experiment.runTrials(
            tokenIDs: tokenData.ids,
            exactDistinct: tokenData.exactDistinct,
            threshold: threshold,
            trials: trials,
            baseSeed: UInt64(seed)
        )
        for result in results {
            stats.add(result)
        }

        // Default mode: print one estimate (easy for scripts/pipes).
        // --report mode: print full tables.
        if report {
            CVM.Reporter.printRunInfo(
                path: path,
                tokens: tokenData.ids.count,
                exactDistinct: tokenData.exactDistinct,
                trials: trials,
                threshold: threshold,
                seed: seed
            )
            CVM.Reporter.printTrials(stats.results)
            CVM.Reporter.printSummary(stats: stats, epsilon: thresholdOptions.reportEpsilon)
        } else if let estimate = stats.medianEstimate {
            print(Int(estimate.rounded()))
        } else {
            print("bottom")
        }
    }
}
