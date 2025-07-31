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
    
    // Track sequence numbers with stable hierarchical context
    private static var eventSequenceCounters: [String: Int] = [:]
    private static var currentViewName: String?

    private static var fileURL: URL? {
        var filename = "\(testName)-\(mode.rawValue).jsonl"
//        if mode == .replayed {
//            filename = "\(testName)-\(UUID().uuidString)-\(mode.rawValue).jsonl"
//        }
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
        
        // Reset sequence counters and context for new test run
        eventSequenceCounters.removeAll()
        currentViewName = nil

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
    
    /// Generates a sequence number for an event based on stable RUM hierarchy
    /// - Parameters:
    ///   - eventName: The name of the event
    ///   - eventType: The type of the event (view, action, etc.)
    ///   - viewName: The name of the view (optional, for actions)
    /// - Returns: A sequence number for this event
    private static func getSequenceNumber(for eventName: String, eventType: String, viewName: String?) -> Int {
        // Update current view context
        if let viewName = viewName {
            currentViewName = viewName
        }
        
        // Create stable hierarchical key based on event type
        let key: String
        switch eventType {
        case "view":
            // Views are globally scoped (only one sequence per view name)
            key = "view_\(eventName)"
        case "action":
            // Actions are scoped to view name (stable across runs)
            let viewContext = currentViewName ?? "unknown_view"
            key = "action_\(eventName)_\(viewContext)"
        default:
            // Other events (custom, error, etc.) are globally scoped
            key = "\(eventType)_\(eventName)"
        }
        
        let currentSequence = eventSequenceCounters[key] ?? 0
        eventSequenceCounters[key] = currentSequence + 1
        return currentSequence
    }
    
    /// Extracts event name, type, and view context from JSON data
    /// - Parameter json: The JSON object representing the event
    /// - Returns: Tuple of (eventName, eventType, viewName) or nil if not found
    private static func extractEventInfo(from json: [String: Any]) -> (name: String, type: String, viewName: String?)? {
        // Events are directly structured, no ddrum_payload wrapper
        
        // Extract view name for context
        let viewName = (json["view"] as? [String: Any])?["name"] as? String
        
        // Extract view name
        if let view = json["view"] as? [String: Any],
           let viewName = view["name"] as? String {
            return (viewName, "view", viewName)
        }
        
        // Extract action name
        if let action = json["action"] as? [String: Any],
           let actionTarget = action["target"] as? [String: Any],
           let actionName = actionTarget["name"] as? String {
            return (actionName, "action", viewName)
        }
        
        // Extract custom event name
        if let customEventName = json["name"] as? String {
            let eventType = json["type"] as? String ?? "custom"
            return (customEventName, eventType, viewName)
        }
        
        return nil
    }

    /// Call this with the array of events to log, sorted by timestamp.
    public static func log(events: [Event]) {
        guard isEnabled, let handle = fileHandle else { return }
        // Sort events by extracted timestamp
        let sortedEvents = events.sorted { extractTimestamp(from: $0) < extractTimestamp(from: $1) }
        for event in sortedEvents {
            // Try to decode event.data as JSON
            if let jsonObject = try? JSONSerialization.jsonObject(with: event.data, options: []) as? [String: Any] {
                
                // Extract event info and add sequence number
                if let eventInfo = extractEventInfo(from: jsonObject) {
                    let sequenceNumber = getSequenceNumber(for: eventInfo.name, eventType: eventInfo.type, viewName: eventInfo.viewName)
                    
                    // Add sequence number to the JSON
                    var updatedJson = jsonObject
                    updatedJson["sequence_number"] = sequenceNumber
                    updatedJson["event_name"] = eventInfo.name
                    updatedJson["event_type"] = eventInfo.type
                    
                    if let jsonData = try? JSONSerialization.data(withJSONObject: updatedJson, options: []),
                       let jsonString = String(data: jsonData, encoding: .utf8),
                       let lineData = (jsonString + "\n").data(using: .utf8) {
                        handle.write(lineData)
                    }
                } else {
                    // Fallback: write original JSON without sequence number
                    if let jsonData = try? JSONSerialization.data(withJSONObject: jsonObject, options: []),
                       let jsonString = String(data: jsonData, encoding: .utf8),
                       let lineData = (jsonString + "\n").data(using: .utf8) {
                        handle.write(lineData)
                    }
                }
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
