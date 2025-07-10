//
//  EventFileLogger.swift
//  Activehours
//
//  Created by Kamaldeep Singh on 6/23/25.
//  Copyright © 2025 ActiveHours. All rights reserved.
//

import Foundation
import DatadogInternal

public enum EventFileLoggerMode: String {
    case baseline = "baseline"
    case replayed = "replayed"
}

public class EventFileLogger {
    public static var isEnabled: Bool = true
    public static var testName: String = "unknown"
    public static var mode: EventFileLoggerMode = .baseline
    public static var logDirectory: String = NSTemporaryDirectory()

    private static var fileHandle: FileHandle?

    private static var fileURL: URL? {
        let filename = "\(testName)-\(mode.rawValue).jsonl"
        return URL(fileURLWithPath: logDirectory).appendingPathComponent(filename)
    }

    public static func setup(testName: String, mode: EventFileLoggerMode, logDirectory: String? = nil) {
        self.testName = testName
        if let dir = logDirectory {
            self.logDirectory = dir
        }
        
        // Auto-detect mode if baseline file already exists
        let detectedMode = autoDetectMode(for: testName, logDirectory: self.logDirectory)
        self.mode = detectedMode
        
        print("📊 EventFileLogger: Auto-detected mode for \(testName) - \(detectedMode.rawValue)")
        
        isEnabled = true

        // Create file if needed
        if let url = fileURL {
            FileManager.default.createFile(atPath: url.path, contents: nil)
            fileHandle = try? FileHandle(forWritingTo: url)
            print("📊 EventFileLogger: Created log file at \(url.path)")
        }
    }

    public static func teardown() {
        try? fileHandle?.closeFile()
        fileHandle = nil
        isEnabled = false
        print("✅ EventFileLogger: Teardown completed for \(testName)")
    }

    /// Auto-detects whether to use baseline or replayed mode based on existing files
    /// - Parameters:
    ///   - testName: The name of the test method
    ///   - logDirectory: The directory where log files are stored
    /// - Returns: The detected mode
    private static func autoDetectMode(for testName: String, logDirectory: String) -> EventFileLoggerMode {
        let fileManager = FileManager.default
        let baselineFilename = "\(testName)-baseline.jsonl"
        let baselinePath = URL(fileURLWithPath: logDirectory).appendingPathComponent(baselineFilename).path
        
        // Check if baseline file already exists
        if fileManager.fileExists(atPath: baselinePath) {
            print("📊 EventFileLogger: Baseline exists for \(testName), using replayed mode")
            return .replayed
        } else {
            print("📊 EventFileLogger: No baseline found for \(testName), using baseline mode")
            return .baseline
        }
    }
    
    /// Extracts a timestamp (as Double) from the event's JSON data.
    private static func extractTimestamp(from event: Event) -> Double {
        guard
            let json = try? JSONSerialization.jsonObject(with: event.data, options: []) as? [String: Any]
        else { return 0 }
        if let ms = json["date"] as? Int64 {
            return Double(ms) / 1000.0 // Convert ms to seconds
        }
        if let ms = json["date"] as? Int {
            return Double(ms) / 1000.0
        }
        if let ms = json["date"] as? Double {
            return ms / 1000.0
        }
        return 0
    }

    /// Call this with the array of events to log, sorted by timestamp.
    public static func log(events: [Event]) {
        guard isEnabled, let handle = fileHandle else { return }
        // Sort events by extracted timestamp
        let sortedEvents = events.sorted { extractTimestamp(from: $0) < extractTimestamp(from: $1) }
        for event in sortedEvents {
            // Try to decode event.data as JSON
            if let jsonObject = try? JSONSerialization.jsonObject(with: event.data, options: []),
               let jsonData = try? JSONSerialization.data(withJSONObject: jsonObject, options: []),
               let jsonString = String(data: jsonData, encoding: .utf8),
               let lineData = (jsonString + "\n").data(using: .utf8) {
                handle.write(lineData)
            } else {
                // Fallback: write base64 if not JSON
                let fallback: [String: Any] = [
                    "data_base64": event.data.base64EncodedString(),
                    "metadata_base64": event.metadata?.base64EncodedString() ?? ""
                ]
                if let jsonData = try? JSONSerialization.data(withJSONObject: fallback, options: []),
                   let jsonString = String(data: jsonData, encoding: .utf8),
                   let lineData = (jsonString + "\n").data(using: .utf8) {
                    handle.write(lineData)
                }
            }
        }
    }
}
