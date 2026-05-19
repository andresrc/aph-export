import ArgumentParser
import AppKit
import Foundation
import Photos
import UniformTypeIdentifiers

private func printErr(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

@main
struct AphExport: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "aph-export",
        abstract: "A CLI tool to export photos and videos from the Apple Photos library."
    )

    @Argument(help: "Start date (YYYY, YYYYMM, or YYYYMMDD).")
    var dateSpec1: String

    @Argument(help: "End date (YYYY, YYYYMM, or YYYYMMDD).")
    var dateSpec2: String?

    @Option(name: .shortAndLong, help: "Output folder.")
    var output: String?

    @Flag(help: "Shows the operation that would be performed, but does not write any file or create any folder.")
    var dryRun = false

    @Flag(help: "If an output file already exists, skip it and log a message. This is the default behavior.")
    var skipExisting = false

    @Flag(help: "If an output file already exists, overwrite it. Mutually exclusive with --skip-existing.")
    var overwrite = false

    @Option(help: "Maximum number of assets exported concurrently.")
    var maxConcurrency: Int = 4

    @Flag(help: "Export all frames in a burst sequence.")
    var burstAll = false

    @Flag(help: "Interpret date specifications in UTC instead of the local timezone.")
    var utc = false

    @Flag(help: "Skip assets whose full-size original is not already stored locally.")
    var localOnly = false

    mutating func validate() throws {
        try Self.validate(
            dateSpec1: dateSpec1,
            dateSpec2: dateSpec2,
            skipExisting: skipExisting,
            overwrite: overwrite
        )
    }

    static func validate(dateSpec1: String, dateSpec2: String?, skipExisting: Bool, overwrite: Bool) throws {
        if skipExisting && overwrite {
            throw ValidationError("The options --skip-existing and --overwrite are mutually exclusive.")
        }

        guard let res1 = DateUtils.resolution(of: dateSpec1) else {
            throw ValidationError("Invalid date format for '\(dateSpec1)'. Expected YYYY, YYYYMM, or YYYYMMDD.")
        }

        if let spec2 = dateSpec2 {
            guard let res2 = DateUtils.resolution(of: spec2) else {
                throw ValidationError("Invalid date format for '\(spec2)'. Expected YYYY, YYYYMM, or YYYYMMDD.")
            }

            if res1 != res2 {
                throw ValidationError("Date specifications must have the same resolution.")
            }

            if spec2 < dateSpec1 {
                throw ValidationError("The second date specification must be equal to or greater than the first.")
            }
        }
    }

    mutating func run() async throws {
        let calendar = Calendar.current
        let timeZone = utc ? TimeZone(secondsFromGMT: 0)! : TimeZone.current

        var startCalendar = calendar
        startCalendar.timeZone = timeZone

        let startDate = try DateUtils.parseDate(dateSpec1, isEnd: false, calendar: startCalendar)
        let endDate = try DateUtils.parseDate(dateSpec2 ?? dateSpec1, isEnd: true, calendar: startCalendar)

        print("Exporting assets from \(startDate) to \(endDate)...")

        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        guard status == .authorized || status == .limited else {
            printErr("Error: Photo library access denied.")
            throw ExitCode(2)
        }

        if status == .limited {
            print("Warning: Limited access granted. Only authorized assets will be exported.")
        }

        let exporter = Exporter(
            output: output,
            dryRun: dryRun,
            conflictResolution: overwrite ? .overwrite : .skip,
            maxConcurrency: maxConcurrency,
            burstAll: burstAll,
            localOnly: localOnly
        )

        try await exporter.run(startDate: startDate, endDate: endDate)
    }
}

enum DateUtils {
    static func resolution(of spec: String) -> Int? {
        guard spec.allSatisfy(\.isNumber) else { return nil }
        switch spec.count {
        case 4: return 0
        case 6: return 1
        case 8: return 2
        default: return nil
        }
    }

    static func parseDate(_ spec: String, isEnd: Bool, calendar: Calendar) throws -> Date {
        let year, month, day: Int

        switch spec.count {
        case 4:
            year = Int(spec)!
            if isEnd {
                let components = DateComponents(year: year + 1, month: 1, day: 1, hour: 0, minute: 0, second: 0)
                guard let date = calendar.date(from: components) else { throw ValidationError("Invalid year.") }
                return calendar.date(byAdding: .second, value: -1, to: date)!
            } else {
                month = 1
                day = 1
            }
        case 6:
            year = Int(spec.prefix(4))!
            month = Int(spec.suffix(2))!
            if isEnd {
                var components = DateComponents(year: year, month: month + 1, day: 1, hour: 0, minute: 0, second: 0)
                if month == 12 {
                    components.year = year + 1
                    components.month = 1
                }
                guard let date = calendar.date(from: components) else { throw ValidationError("Invalid month.") }
                return calendar.date(byAdding: .second, value: -1, to: date)!
            } else {
                day = 1
            }
        case 8:
            let start = spec.index(spec.startIndex, offsetBy: 4)
            let end = spec.index(spec.startIndex, offsetBy: 6)
            year = Int(spec.prefix(4))!
            month = Int(spec[start..<end])!
            day = Int(spec.suffix(2))!
        default:
            throw ValidationError("Unexpected date format.")
        }

        var components = DateComponents(year: year, month: month, day: day)
        if isEnd {
            components.hour = 23
            components.minute = 59
            components.second = 59
        } else {
            components.hour = 0
            components.minute = 0
            components.second = 0
        }

        guard let date = calendar.date(from: components) else {
            throw ValidationError("Invalid date components in '\(spec)'.")
        }

        return date
    }
}

final class Exporter: Sendable {
    enum ConflictResolution: Sendable {
        case skip
        case overwrite
    }

    struct ExportOutcome: Sendable {
        var successes: Int = 0
        var skipped: Int = 0
        var errors: Int = 0
    }

    let output: String?
    let dryRun: Bool
    let conflictResolution: ConflictResolution
    let maxConcurrency: Int
    let burstAll: Bool
    let localOnly: Bool

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd_HHmmss"
        return f
    }()

    init(
        output: String?,
        dryRun: Bool,
        conflictResolution: ConflictResolution,
        maxConcurrency: Int,
        burstAll: Bool,
        localOnly: Bool
    ) {
        self.output = output
        self.dryRun = dryRun
        self.conflictResolution = conflictResolution
        self.maxConcurrency = maxConcurrency
        self.burstAll = burstAll
        self.localOnly = localOnly
    }

    func run(startDate: Date, endDate: Date) async throws {
        let fetchOptions = PHFetchOptions()
        fetchOptions.predicate = NSPredicate(
            format: "creationDate >= %@ AND creationDate <= %@",
            startDate as NSDate,
            endDate as NSDate
        )
        fetchOptions.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]

        let assets = PHAsset.fetchAssets(with: fetchOptions)
        print("Found \(assets.count) assets to process.")

        let outputURL = URL(fileURLWithPath: output ?? FileManager.default.currentDirectoryPath)

        // Expand bursts, filtering expanded frames to the requested date range.
        var allAssets: [PHAsset] = []
        for i in 0..<assets.count {
            let asset = assets.object(at: i)
            if burstAll && asset.representsBurst, let burstIdentifier = asset.burstIdentifier {
                let burstOptions = PHFetchOptions()
                burstOptions.includeAllBurstAssets = true
                let burstAssets = PHAsset.fetchAssets(withBurstIdentifier: burstIdentifier, options: burstOptions)
                for j in 0..<burstAssets.count {
                    let burstAsset = burstAssets.object(at: j)
                    if let date = burstAsset.creationDate, date >= startDate && date <= endDate {
                        allAssets.append(burstAsset)
                    }
                }
            } else {
                allAssets.append(asset)
            }
        }

        print("Total items to process (including bursts): \(allAssets.count)")

        var totalSuccesses = 0
        var totalSkipped = 0
        var totalErrors = 0

        await withTaskGroup(of: ExportOutcome.self) { group in
            var activeCount = 0
            var assetIndex = 0

            while assetIndex < allAssets.count || activeCount > 0 {
                while activeCount < maxConcurrency && assetIndex < allAssets.count {
                    let asset = allAssets[assetIndex]
                    group.addTask {
                        await self.process(asset: asset, outputURL: outputURL)
                    }
                    assetIndex += 1
                    activeCount += 1
                }

                if let outcome = await group.next() {
                    activeCount -= 1
                    totalSuccesses += outcome.successes
                    totalSkipped += outcome.skipped
                    totalErrors += outcome.errors
                }
            }
        }

        print("\nSummary:")
        print("Successfully exported: \(totalSuccesses)")
        print("Skipped: \(totalSkipped)")
        print("Errors: \(totalErrors)")

        if totalErrors > 0 {
            throw ExitCode(1)
        }
    }

    private func process(asset: PHAsset, outputURL: URL) async -> ExportOutcome {
        guard let creationDate = asset.creationDate else {
            printErr("Error: Asset \(asset.localIdentifier) has no creation date.")
            return ExportOutcome(successes: 0, skipped: 0, errors: 1)
        }

        let calendar = Calendar.current
        let year = calendar.component(.year, from: creationDate)
        let month = calendar.component(.month, from: creationDate)
        let day = calendar.component(.day, from: creationDate)

        let yearStr = String(format: "%04d", year)
        let monthStr = String(format: "%04d%02d", year, month)
        let dayStr = String(format: "%04d%02d%02d", year, month, day)

        let relativeFolder = "\(yearStr)/\(monthStr)/\(dayStr)"
        let targetFolderURL = outputURL.appendingPathComponent(relativeFolder)

        if !dryRun {
            do {
                try FileManager.default.createDirectory(at: targetFolderURL, withIntermediateDirectories: true)
            } catch {
                printErr("Error creating directory \(targetFolderURL.path): \(error.localizedDescription)")
                return ExportOutcome(successes: 0, skipped: 0, errors: 1)
            }
        }

        let resources = PHAssetResource.assetResources(for: asset)
        let datePart = Self.dateFormatter.string(from: creationDate)

        var outcome = ExportOutcome()

        resourceLoop: for resource in resources {
            let originalFilename = resource.originalFilename
            let baseName = (originalFilename as NSString).deletingPathExtension
            let extensionName = (originalFilename as NSString).pathExtension

            let finalBaseName = "\(datePart)_\(baseName)"
            let targetFilename = "\(finalBaseName).\(extensionName)"
            let targetURL = targetFolderURL.appendingPathComponent(targetFilename)

            if FileManager.default.fileExists(atPath: targetURL.path) {
                switch conflictResolution {
                case .skip:
                    print("Skipping \(targetURL.path): file already exists.")
                    outcome.skipped += 1
                    continue resourceLoop
                case .overwrite:
                    break
                }
            }

            if dryRun {
                print("[DRY RUN] Would export \(originalFilename) to \(targetURL.path)")
                outcome.successes += 1
                continue
            }

            print("Exporting \(originalFilename) to \(targetURL.path)...")

            let options = PHAssetResourceRequestOptions()
            options.isNetworkAccessAllowed = !localOnly

            do {
                try await downloadResource(resource, to: targetURL, options: options)

                if let uti = UTType(resource.uniformTypeIdentifier),
                   uti.conforms(to: .image),
                   resource.uniformTypeIdentifier != "public.jpeg" {
                    let jpegFilename = "\(targetFilename.dropLast(extensionName.count))jpg"
                    let jpegURL = targetFolderURL.appendingPathComponent(jpegFilename)
                    if !FileManager.default.fileExists(atPath: jpegURL.path) || conflictResolution == .overwrite {
                        print("Transcoding \(originalFilename) to JPEG...")
                        try await transcodeToJPEG(at: targetURL, to: jpegURL)
                    }
                }

                outcome.successes += 1
            } catch let error as NSError where localOnly && error.domain == "com.apple.photos.error" && error.code == 3164 {
                print("Skipping \(originalFilename): original not stored locally.")
                outcome.skipped += 1
            } catch {
                printErr("Error exporting \(originalFilename): \(error.localizedDescription)")
                outcome.errors += 1
            }
        }

        return outcome
    }

    private func downloadResource(
        _ resource: PHAssetResource,
        to url: URL,
        options: PHAssetResourceRequestOptions
    ) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            PHAssetResourceManager.default().writeData(for: resource, toFile: url, options: options) { error in
                if let error = error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }

    private func transcodeToJPEG(at sourceURL: URL, to destinationURL: URL) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            DispatchQueue.global(qos: .utility).async {
                guard let image = NSImage(contentsOf: sourceURL),
                      let tiffData = image.tiffRepresentation,
                      let bitmap = NSBitmapImageRep(data: tiffData),
                      let jpegData = bitmap.representation(using: .jpeg, properties: [:]) else {
                    continuation.resume(throwing: NSError(
                        domain: "AphExport",
                        code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "Failed to transcode image to JPEG."]
                    ))
                    return
                }
                do {
                    try jpegData.write(to: destinationURL)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}
