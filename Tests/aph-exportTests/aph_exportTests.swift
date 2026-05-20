import Testing
import Foundation
import ArgumentParser
@testable import aph_export

// MARK: - DateUtils.resolution

@Suite("DateUtils.resolution")
struct ResolutionTests {
    @Test(arguments: [("2023", 0), ("202310", 1), ("20231027", 2)])
    func validSpecs(spec: String, expected: Int) {
        #expect(DateUtils.resolution(of: spec) == expected)
    }

    @Test(arguments: ["ABCD", "2023AB", "20231A27", "123", "12345", "1234567", ""])
    func invalidSpecs(spec: String) {
        #expect(DateUtils.resolution(of: spec) == nil)
    }
}

// MARK: - DateUtils.parseDate

@Suite("DateUtils.parseDate")
struct DateParsingTests {
    var calendar: Calendar

    init() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        self.calendar = cal
    }

    private func components(from date: Date) -> DateComponents {
        calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
    }

    // MARK: Year

    @Test func yearStart() throws {
        let c = components(from: try DateUtils.parseDate("2023", isEnd: false, calendar: calendar))
        #expect(c.year == 2023 && c.month == 1 && c.day == 1)
        #expect(c.hour == 0 && c.minute == 0 && c.second == 0)
    }

    @Test func yearEnd() throws {
        let c = components(from: try DateUtils.parseDate("2023", isEnd: true, calendar: calendar))
        #expect(c.year == 2023 && c.month == 12 && c.day == 31)
        #expect(c.hour == 23 && c.minute == 59 && c.second == 59)
    }

    // MARK: Month

    @Test func monthStart() throws {
        let c = components(from: try DateUtils.parseDate("202310", isEnd: false, calendar: calendar))
        #expect(c.year == 2023 && c.month == 10 && c.day == 1)
        #expect(c.hour == 0 && c.minute == 0 && c.second == 0)
    }

    @Test func monthEnd_october() throws {
        let c = components(from: try DateUtils.parseDate("202310", isEnd: true, calendar: calendar))
        #expect(c.year == 2023 && c.month == 10 && c.day == 31)
        #expect(c.hour == 23 && c.minute == 59 && c.second == 59)
    }

    @Test func monthEnd_february_nonLeap() throws {
        let c = components(from: try DateUtils.parseDate("202302", isEnd: true, calendar: calendar))
        #expect(c.year == 2023 && c.month == 2 && c.day == 28)
    }

    @Test func monthEnd_february_leap() throws {
        let c = components(from: try DateUtils.parseDate("202402", isEnd: true, calendar: calendar))
        #expect(c.year == 2024 && c.month == 2 && c.day == 29)
    }

    // December triggers the month+1 overflow path (month 13 → next Jan).
    @Test func monthEnd_december_overflow() throws {
        let c = components(from: try DateUtils.parseDate("202312", isEnd: true, calendar: calendar))
        #expect(c.year == 2023 && c.month == 12 && c.day == 31)
        #expect(c.hour == 23 && c.minute == 59 && c.second == 59)
    }

    // MARK: Day

    @Test func dayStart() throws {
        let c = components(from: try DateUtils.parseDate("20231027", isEnd: false, calendar: calendar))
        #expect(c.year == 2023 && c.month == 10 && c.day == 27)
        #expect(c.hour == 0 && c.minute == 0 && c.second == 0)
    }

    @Test func dayEnd() throws {
        let c = components(from: try DateUtils.parseDate("20231027", isEnd: true, calendar: calendar))
        #expect(c.year == 2023 && c.month == 10 && c.day == 27)
        #expect(c.hour == 23 && c.minute == 59 && c.second == 59)
    }
}

// MARK: - AphExport.validate

@Suite("AphExport.validate")
struct ValidationTests {
    // MARK: Should pass

    @Test func singleSpec_valid() throws {
        try AphExport.validate(dateSpec1: "2023", dateSpec2: nil, skipExisting: false, overwrite: false)
    }

    @Test func range_valid() throws {
        try AphExport.validate(dateSpec1: "2023", dateSpec2: "2025", skipExisting: false, overwrite: false)
    }

    @Test func range_equalBounds_valid() throws {
        try AphExport.validate(dateSpec1: "202310", dateSpec2: "202310", skipExisting: false, overwrite: false)
    }

    @Test func skipExistingAlone_valid() throws {
        try AphExport.validate(dateSpec1: "2023", dateSpec2: nil, skipExisting: true, overwrite: false)
    }

    @Test func overwriteAlone_valid() throws {
        try AphExport.validate(dateSpec1: "2023", dateSpec2: nil, skipExisting: false, overwrite: true)
    }

    // MARK: Should throw

    @Test func mutuallyExclusiveFlags_throws() {
        #expect(throws: ValidationError.self) {
            try AphExport.validate(dateSpec1: "2023", dateSpec2: nil, skipExisting: true, overwrite: true)
        }
    }

    @Test func mismatchedResolution_throws() {
        #expect(throws: ValidationError.self) {
            try AphExport.validate(dateSpec1: "2023", dateSpec2: "202310", skipExisting: false, overwrite: false)
        }
    }

    @Test func reversedRange_throws() {
        #expect(throws: ValidationError.self) {
            try AphExport.validate(dateSpec1: "202312", dateSpec2: "202310", skipExisting: false, overwrite: false)
        }
    }

    @Test func invalidFormat_wrongLength_throws() {
        #expect(throws: ValidationError.self) {
            try AphExport.validate(dateSpec1: "202", dateSpec2: nil, skipExisting: false, overwrite: false)
        }
    }

    // Regression: non-digit strings of valid length must be rejected, not crash at force-unwrap.
    @Test func invalidFormat_nonDigits_dateSpec1_throws() {
        #expect(throws: ValidationError.self) {
            try AphExport.validate(dateSpec1: "ABCD", dateSpec2: nil, skipExisting: false, overwrite: false)
        }
    }

    @Test func invalidFormat_nonDigits_dateSpec2_throws() {
        #expect(throws: ValidationError.self) {
            try AphExport.validate(dateSpec1: "2023", dateSpec2: "ABCD", skipExisting: false, overwrite: false)
        }
    }
}

// MARK: - ExportLogger Tests

@Suite("ExportLogger Tests")
struct ExportLoggerTests {
    @Test func testDryRunDoesNotCreateFile() async throws {
        let tempDir = FileManager.default.temporaryDirectory
        let outputURL = tempDir.appendingPathComponent("dry_run_test_\(UUID().uuidString)")
        
        let logger = try ExportLogger(outputURL: outputURL, isDryRun: true)
        await logger.close()
        
        // Ensure no directory or file was created
        #expect(!FileManager.default.fileExists(atPath: outputURL.path))
    }
    
    @Test func testSuccessfulInitializationCreatesLogFile() async throws {
        let tempDir = FileManager.default.temporaryDirectory
        let outputURL = tempDir.appendingPathComponent("logger_test_\(UUID().uuidString)")
        
        // Initialize logger (this should create the directory and the log file)
        let logger = try ExportLogger(outputURL: outputURL, isDryRun: false)
        await logger.close()
        
        defer {
            try? FileManager.default.removeItem(at: outputURL)
        }
        
        // Directory must exist
        var isDir: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: outputURL.path, isDirectory: &isDir))
        #expect(isDir.boolValue)
        
        // Log file must exist inside directory
        let files = try FileManager.default.contentsOfDirectory(atPath: outputURL.path)
        #expect(files.count == 1)
        #expect(files[0].hasSuffix("-export.log"))
    }
    
    @Test func testUnwritableDirectoryThrows() {
        // A system directory like /usr/bin or /private/var/root is not writable by normal users
        let unwritableURL = URL(fileURLWithPath: "/usr/bin/invalid_subdir_name")
        
        #expect(throws: Error.self) {
            _ = try ExportLogger(outputURL: unwritableURL, isDryRun: false)
        }
    }
    
    @Test func testProgressBarTracking() async throws {
        let tempDir = FileManager.default.temporaryDirectory
        let outputURL = tempDir.appendingPathComponent("progress_test_\(UUID().uuidString)")
        
        let logger = try ExportLogger(outputURL: outputURL, isDryRun: true)
        
        // We can set total count and update counts without errors
        await logger.setTotalCount(10)
        await logger.updateCounts(successes: 3, skipped: 2, errors: 1)
        
        await logger.close()
        #expect(!FileManager.default.fileExists(atPath: outputURL.path))
    }
}
