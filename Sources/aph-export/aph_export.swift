import ArgumentParser
import AppKit
import Foundation
import Photos
import UniformTypeIdentifiers
import ImageIO

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

        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        guard status == .authorized || status == .limited else {
            printErr("Error: Photo library access denied.")
            throw ExitCode(2)
        }

        let outputURL = URL(fileURLWithPath: output ?? FileManager.default.currentDirectoryPath)

        let logger: ExportLogger
        do {
            logger = try ExportLogger(outputURL: outputURL, isDryRun: dryRun)
        } catch {
            printErr("Error: \(error.localizedDescription)")
            throw ExitCode(2)
        }

        await logger.logMsg("Exporting assets from \(startDate) to \(endDate)...")

        if status == .limited {
            await logger.logWarning("Warning: Limited access granted. Only authorized assets will be exported.")
        }

        let exporter = Exporter(
            logger: logger,
            outputURL: outputURL,
            dryRun: dryRun,
            conflictResolution: overwrite ? .overwrite : .skip,
            maxConcurrency: maxConcurrency,
            burstAll: burstAll,
            localOnly: localOnly
        )

        do {
            try await exporter.run(startDate: startDate, endDate: endDate)
            await logger.close()
        } catch {
            await logger.close()
            throw error
        }
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

actor ExportLogger {
    private let isDryRun: Bool
    private let logFileURL: URL?
    private var fileHandle: FileHandle?
    private let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withYear, .withMonth, .withDay, .withTime, .withTimeZone]
        f.timeZone = TimeZone(secondsFromGMT: 0)
        return f
    }()
    
    // Progress tracking
    private var totalCount = 0
    private var successes = 0
    private var skipped = 0
    private var errors = 0
    private var completedAssets = 0
    private var hasActiveProgress = false
    
    init(outputURL: URL, isDryRun: Bool) throws {
        self.isDryRun = isDryRun
        
        if isDryRun {
            self.logFileURL = nil
            self.fileHandle = nil
            return
        }
        
        // 1. Ensure output directory exists or create it
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: outputURL.path, isDirectory: &isDir)
        if !exists {
            do {
                try FileManager.default.createDirectory(at: outputURL, withIntermediateDirectories: true)
            } catch {
                throw NSError(domain: "AphExport", code: 2, userInfo: [NSLocalizedDescriptionKey: "Failed to create output directory '\(outputURL.path)': \(error.localizedDescription)"])
            }
        } else if !isDir.boolValue {
            throw NSError(domain: "AphExport", code: 2, userInfo: [NSLocalizedDescriptionKey: "Output path '\(outputURL.path)' exists but is not a directory."])
        }
        
        // 2. Perform write validation check
        let testFileURL = outputURL.appendingPathComponent(".write_test_\(UUID().uuidString)")
        do {
            try "test".write(to: testFileURL, atomically: true, encoding: .utf8)
            try FileManager.default.removeItem(at: testFileURL)
        } catch {
            throw NSError(domain: "AphExport", code: 2, userInfo: [NSLocalizedDescriptionKey: "Output directory '\(outputURL.path)' is not writable: \(error.localizedDescription)"])
        }
        
        // 3. Create log file: YYYYMMDD-HHMMSS-export.log in UTC
        let formatter = DateFormatter()
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let dateString = formatter.string(from: Date())
        let filename = "\(dateString)-export.log"
        let fileURL = outputURL.appendingPathComponent(filename)
        
        self.logFileURL = fileURL
        
        if !FileManager.default.createFile(atPath: fileURL.path, contents: nil) {
            throw NSError(domain: "AphExport", code: 2, userInfo: [NSLocalizedDescriptionKey: "Failed to create log file at '\(fileURL.path)'"])
        }
        
        guard let handle = try? FileHandle(forWritingTo: fileURL) else {
            throw NSError(domain: "AphExport", code: 2, userInfo: [NSLocalizedDescriptionKey: "Failed to open log file for writing at '\(fileURL.path)'"])
        }
        self.fileHandle = handle
    }
    
    func close() {
        clearProgressLine()
        hasActiveProgress = false
        try? fileHandle?.synchronize()
        try? fileHandle?.close()
        fileHandle = nil
    }
    
    private func writeToFile(_ line: String) {
        guard let handle = fileHandle else { return }
        if let data = line.data(using: .utf8) {
            try? handle.write(contentsOf: data)
        }
    }
    
    func setTotalCount(_ count: Int) {
        self.totalCount = count
        self.successes = 0
        self.skipped = 0
        self.errors = 0
        self.completedAssets = 0
        self.hasActiveProgress = count > 0
        if hasActiveProgress {
            printProgress()
        }
    }
    
    func updateCounts(successes: Int, skipped: Int, errors: Int) {
        self.successes += successes
        self.skipped += skipped
        self.errors += errors
        self.completedAssets += 1
        printProgress()
    }
    
    private func clearProgressLine() {
        if hasActiveProgress {
            print("\r\u{1B}[K", terminator: "")
            fflush(stdout)
        }
    }
    
    private func printProgress() {
        guard hasActiveProgress, totalCount > 0 else { return }
        let completed = min(completedAssets, totalCount)
        let percentage = Int((Double(completed) / Double(totalCount) * 100.0).rounded())
        
        let barWidth = 20
        let completedBlocks = Int((Double(completed) / Double(totalCount) * Double(barWidth)).rounded())
        let safeCompletedBlocks = min(barWidth, max(0, completedBlocks))
        let bar = String(repeating: "█", count: safeCompletedBlocks) + String(repeating: "░", count: barWidth - safeCompletedBlocks)
        
        print("\rExporting: \(bar) \(percentage)% | \(completed)/\(totalCount) | Success: \(successes), Skip: \(skipped), Error: \(errors)", terminator: "")
        fflush(stdout)
    }
    
    func logMsg(_ message: String) {
        let timestamp = isoFormatter.string(from: Date())
        let logLine = "[\(timestamp)] \(message)\n"
        
        if !isDryRun {
            writeToFile(logLine)
        }
        clearProgressLine()
        print(message)
        fflush(stdout)
        printProgress()
    }
    
    func logWarning(_ message: String) {
        let timestamp = isoFormatter.string(from: Date())
        let logLine = "[\(timestamp)] WARNING: \(message)\n"
        
        if !isDryRun {
            writeToFile(logLine)
        }
        clearProgressLine()
        print(message)
        fflush(stdout)
        printProgress()
    }
    
    func logAssetProcessing(filename: String, sourceDate: Date, targetPath: String) {
        let timestamp = isoFormatter.string(from: Date())
        let sourceDateStr = isoFormatter.string(from: sourceDate)
        
        let fileLogLine = "[\(timestamp)] Processing \(filename) (Source Date: \(sourceDateStr)) -> Target: \(targetPath)\n"
        
        if isDryRun {
            clearProgressLine()
            print("[DRY RUN] Would export \(filename) to \(targetPath)")
            fflush(stdout)
            printProgress()
        } else {
            writeToFile(fileLogLine)
        }
    }
    
    func logAssetSkipped(filename: String, reason: String) {
        let timestamp = isoFormatter.string(from: Date())
        
        let fileLogLine = "[\(timestamp)] SKIPPED \(filename): \(reason)\n"
        
        if isDryRun {
            clearProgressLine()
            print("[DRY RUN] Would skip \(filename): \(reason)")
            fflush(stdout)
            printProgress()
        } else {
            writeToFile(fileLogLine)
        }
    }
    
    func logAssetError(filename: String, errorDescription: String) {
        let timestamp = isoFormatter.string(from: Date())
        
        let fileLogLine = "[\(timestamp)] ERROR exporting \(filename): \(errorDescription)\n"
        let consoleLogLine = "Error exporting \(filename): \(errorDescription)"
        
        if isDryRun {
            clearProgressLine()
            let errLine = "Error exporting \(filename): \(errorDescription)\n"
            FileHandle.standardError.write(Data(errLine.utf8))
            printProgress()
        } else {
            writeToFile(fileLogLine)
            clearProgressLine()
            let errLine = consoleLogLine + "\n"
            FileHandle.standardError.write(Data(errLine.utf8))
            printProgress()
        }
    }
    
    func logTranscoding(filename: String) {
        let timestamp = isoFormatter.string(from: Date())
        
        let fileLogLine = "[\(timestamp)] Transcoding \(filename) to JPEG...\n"
        
        if isDryRun {
            clearProgressLine()
            print("[DRY RUN] Would transcode \(filename) to JPEG")
            fflush(stdout)
            printProgress()
        } else {
            writeToFile(fileLogLine)
        }
    }
    
    func logSummary(successes: Int, skipped: Int, errors: Int) {
        let timestamp = isoFormatter.string(from: Date())
        
        clearProgressLine()
        hasActiveProgress = false
        
        let summaryText = """
        
        Summary:
        Successfully exported: \(successes)
        Skipped: \(skipped)
        Errors: \(errors)
        """
        
        let fileLogLine = "[\(timestamp)] Summary:\nSuccessfully exported: \(successes)\nSkipped: \(skipped)\nErrors: \(errors)\n"
        
        if isDryRun {
            print(summaryText)
            fflush(stdout)
        } else {
            writeToFile(fileLogLine)
            print(summaryText)
            fflush(stdout)
        }
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

    let logger: ExportLogger
    let outputURL: URL
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
        logger: ExportLogger,
        outputURL: URL,
        dryRun: Bool,
        conflictResolution: ConflictResolution,
        maxConcurrency: Int,
        burstAll: Bool,
        localOnly: Bool
    ) {
        self.logger = logger
        self.outputURL = outputURL
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
        await logger.logMsg("Found \(assets.count) assets to process.")

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

        await logger.logMsg("Total items to process (including bursts): \(allAssets.count)")
        await logger.setTotalCount(allAssets.count)

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
                        await self.process(asset: asset)
                    }
                    assetIndex += 1
                    activeCount += 1
                }

                if let outcome = await group.next() {
                    activeCount -= 1
                    totalSuccesses += outcome.successes
                    totalSkipped += outcome.skipped
                    totalErrors += outcome.errors
                    await logger.updateCounts(successes: outcome.successes, skipped: outcome.skipped, errors: outcome.errors)
                }
            }
        }

        await logger.logSummary(successes: totalSuccesses, skipped: totalSkipped, errors: totalErrors)

        if totalErrors > 0 {
            throw ExitCode(1)
        }
    }

    private func process(asset: PHAsset) async -> ExportOutcome {
        guard let creationDate = asset.creationDate else {
            await logger.logAssetError(filename: asset.localIdentifier, errorDescription: "Asset has no creation date.")
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
                await logger.logAssetError(filename: "Directory Creation", errorDescription: "Failed to create directory \(targetFolderURL.path): \(error.localizedDescription)")
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
                    await logger.logAssetSkipped(filename: originalFilename, reason: "file already exists at \(targetURL.path)")
                    outcome.skipped += 1
                    continue resourceLoop
                case .overwrite:
                    break
                }
            }

            if dryRun {
                await logger.logAssetProcessing(filename: originalFilename, sourceDate: creationDate, targetPath: targetURL.path)
                outcome.successes += 1
                continue
            }

            await logger.logAssetProcessing(filename: originalFilename, sourceDate: creationDate, targetPath: targetURL.path)

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
                        await logger.logTranscoding(filename: originalFilename)
                        try await transcodeToJPEG(at: targetURL, to: jpegURL)
                    }
                }

                outcome.successes += 1
            } catch let error as NSError where localOnly && error.domain == "com.apple.photos.error" && error.code == 3164 {
                await logger.logAssetSkipped(filename: originalFilename, reason: "original not stored locally.")
                outcome.skipped += 1
            } catch {
                await logger.logAssetError(filename: originalFilename, errorDescription: error.localizedDescription)
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
                guard let imageSource = CGImageSourceCreateWithURL(sourceURL as CFURL, nil) else {
                    continuation.resume(throwing: NSError(
                        domain: "AphExport",
                        code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "Failed to create image source for transcoding."]
                    ))
                    return
                }
                
                guard let destination = CGImageDestinationCreateWithURL(destinationURL as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
                    continuation.resume(throwing: NSError(
                        domain: "AphExport",
                        code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "Failed to create image destination for transcoding."]
                    ))
                    return
                }
                
                let options = [
                    kCGImageDestinationLossyCompressionQuality as String: 0.9
                ] as CFDictionary
                
                CGImageDestinationAddImageFromSource(destination, imageSource, 0, options)
                
                if CGImageDestinationFinalize(destination) {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: NSError(
                        domain: "AphExport",
                        code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "Failed to finalize JPEG transcode."]
                    ))
                }
            }
        }
    }
}
