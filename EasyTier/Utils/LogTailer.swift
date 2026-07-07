import Foundation
import SwiftUI
import Combine

import EasyTierShared

struct LogLine: Identifiable, Equatable {
    let id = UUID()
    let text: String
}

@MainActor
class LogTailer: ObservableObject {
    @Published var logContent: [LogLine] = []
    @Published var errorMessage: TextItem?
    @Published var isWatching: Bool = false
    
    @AppStorage("logPreservedLines") var logPreservedLines: Int = 1000
    
    private var fileHandles: [String: FileHandle] = [:]
    private var sources: [String: DispatchSourceFileSystemObject] = [:]
    
    /// Starts watching a specific file in an App Group
    func startWatching(appGroupID: String, filename: String, fromStart: Bool) {
        startWatching(appGroupID: appGroupID, filenames: [filename], fromStart: fromStart)
    }

    /// Starts watching files in an App Group and renders them as one stream.
    func startWatching(appGroupID: String, filenames: [String], fromStart: Bool) {
        stop()

        guard let containerURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID) else {
            self.errorMessage = .init("Invalid App Group ID.")
            return
        }

        var initialLogs = ""

        for filename in filenames {
            let fileURL = containerURL.appendingPathComponent(filename)

            // Ensure file exists to avoid crash when opening; create if missing
            if !FileManager.default.fileExists(atPath: fileURL.path) {
                try? "".write(to: fileURL, atomically: true, encoding: .utf8)
            }

            do {
                let handle = try FileHandle(forReadingFrom: fileURL)
                self.fileHandles[filename] = handle

                // Initial Read
                if fromStart {
                    let data = handle.readDataToEndOfFile()
                    if let str = String(data: data, encoding: .utf8), !str.isEmpty {
                        initialLogs.append(str)
                        if !initialLogs.hasSuffix("\n") {
                            initialLogs.append("\n")
                        }
                    }
                } else {
                    handle.seekToEndOfFile()
                }

                // Setup DispatchSource to watch for writes
                let fileDescriptor = handle.fileDescriptor
                let source = DispatchSource.makeFileSystemObjectSource(
                    fileDescriptor: fileDescriptor,
                    eventMask: .write,
                    queue: DispatchQueue.main
                )

                source.setEventHandler { [weak self] in
                    self?.readNewData(filename: filename)
                }

                source.setCancelHandler {
                    try? handle.close()
                }

                source.resume()
                self.sources[filename] = source

            } catch {
                DispatchQueue.main.async {
                    self.errorMessage = .init("Could not open file: \(error.localizedDescription)")
                }
            }
        }

        if fromStart {
            updateLog(initialLogs, replaceAll: true)
        }
        self.isWatching = !fileHandles.isEmpty
    }
    
    private func readNewData(filename: String) {
        guard let handle = fileHandles[filename] else { return }
        
        // Read only what has been appended
        let data = handle.readDataToEndOfFile()
        
        if let newString = String(data: data, encoding: .utf8), !newString.isEmpty {
            updateLog(newString)
        }
    }
    
    private func updateLog(_ logs: String, replaceAll: Bool = false) {
        let newLines = logs
            .split(separator: "\n")
            .suffix(logPreservedLines)
            .map { LogLine(text: String($0)) }
        let preservedExistingCount = max(logPreservedLines - newLines.count, 0)
        let lines =
            (replaceAll ? [] : self.logContent).suffix(
                preservedExistingCount
            ) + newLines

        if Thread.isMainThread {
            self.logContent = lines
        } else {
            DispatchQueue.main.async {
                self.logContent = lines
            }
        }
    }
    
    func stop() {
        sources.values.forEach { $0.cancel() }
        sources = [:]
        fileHandles = [:]
        isWatching = false
    }

    func clear(
        appGroupID: String,
        filename: String,
        providerClear: (() async throws -> Void)? = nil
    ) async {
        await clear(appGroupID: appGroupID, filenames: [filename], providerClear: providerClear)
    }

    func clear(
        appGroupID: String,
        filenames: [String],
        providerClear: (() async throws -> Void)? = nil
    ) async {
        let wasWatching = isWatching
        stop()

        do {
            if let providerClear {
                try await providerClear()
            }
            try filenames.forEach { try clearLogFile(appGroupID: appGroupID, filename: $0) }

            logContent = []
        } catch {
            errorMessage = .init("Could not clear log: \(error.localizedDescription)")
        }

        if wasWatching {
            startWatching(appGroupID: appGroupID, filenames: filenames, fromStart: true)
        }
    }

    private func clearLogFile(appGroupID: String, filename: String) throws {
        guard let containerURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID) else {
            throw CocoaError(.fileNoSuchFile)
        }

        let fileURL = containerURL.appendingPathComponent(filename)

        if !FileManager.default.fileExists(atPath: fileURL.path) {
            FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        }

        let handle = try FileHandle(forWritingTo: fileURL)
        try handle.truncate(atOffset: 0)
        try handle.close()
    }
    
    deinit {
        sources.values.forEach { $0.cancel() }
        sources = [:]
        fileHandles = [:]
    }
}
