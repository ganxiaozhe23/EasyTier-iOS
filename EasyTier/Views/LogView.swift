import SwiftUI
import NetworkExtension
import EasyTierShared

private let visibleLogFilenames = [HOST_DIAGNOSTIC_LOG_FILENAME, LOG_FILENAME]

private enum LogExportError: LocalizedError {
    case containerUnavailable
    case emptyLogs

    var errorDescription: String? {
        switch self {
        case .containerUnavailable:
            return "Log container is unavailable."
        case .emptyLogs:
            return "Log file is empty."
        }
    }
}

struct LogView<Manager: NetworkExtensionManagerProtocol>: View {
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject var manager: Manager
    @StateObject private var tailer = LogTailer()
    @Namespace private var bottomID
    @State private var wasWatchingBeforeBackground = false
#if os(iOS)
    @State private var exportURL: URL?
    @State private var isExportPresented = false
#endif
    @State private var exportErrorMessage: TextItem?
    
    var body: some View {
        AdaptiveNavigationRoot {
            VStack(alignment: .leading) {
                // Log Content
                ScrollView {
                    ScrollViewReader { proxy in
                        LazyVStack(alignment: .leading) {
                            ForEach(tailer.logContent) { line in
                                Text(line.text)
                                    .font(.system(.footnote, design: .monospaced))
                                    .textSelection(.enabled)
                            }
                            Text("").id(bottomID)
                        }
                        .padding()
                        .onChange(of: tailer.logContent) { _ in
                            // Auto-scroll to bottom on update
                            withAnimation {
                                proxy.scrollTo(bottomID, anchor: .bottom)
                            }
                        }
                    }
                }
#if os(iOS)
                .background(Color(UIColor.systemGroupedBackground))
#endif
            }
            .navigationTitle("logging")
            .adaptiveNavigationBarTitleInline()
            .toolbar {
                ToolbarItem(placement: ToolbarLeading) {
                    Button(action: {
                        Task {
                            await clearLog()
                        }
                    }) {
                        Image(systemName: "trash")
                    }.tint(.red)
                }
                ToolbarItem(placement: ToolbarTrailing) {
                    Button(action: {
                        presentExport()
                    }) {
                        Image(systemName: "square.and.arrow.up")
                    }
                }
                ToolbarItem(placement: ToolbarTrailing) {
                    Button(action: {
                        if tailer.isWatching {
                            tailer.stop()
                        } else {
                            tailer.startWatching(appGroupID: APP_GROUP_ID, filenames: visibleLogFilenames, fromStart: false)
                        }
                    }) {
                        Image(systemName: tailer.isWatching ? "pause" : "play")
                    }
                }
            }
        }
        .onAppear {
            if !tailer.isWatching {
                tailer.startWatching(appGroupID: APP_GROUP_ID, filenames: visibleLogFilenames, fromStart: true)
            }
        }
        .onDisappear {
            tailer.stop()
            wasWatchingBeforeBackground = false
        }
        .onChange(of: scenePhase) { newPhase in
            switch newPhase {
            case .active:
                if wasWatchingBeforeBackground {
                    tailer.startWatching(appGroupID: APP_GROUP_ID, filenames: visibleLogFilenames, fromStart: false)
                    wasWatchingBeforeBackground = false
                }
            case .inactive, .background:
                wasWatchingBeforeBackground = tailer.isWatching
                tailer.stop()
            @unknown default:
                break
            }
        }
        .alert(item: $tailer.errorMessage) { msg in
            Alert(title: Text("common.error"), message: Text(msg.text))
        }
        .alert(item: $exportErrorMessage) { msg in
            Alert(title: Text("common.error"), message: Text(msg.text))
        }
#if os(iOS)
        .sheet(isPresented: $isExportPresented) {
            if let url = exportURL {
                ShareSheet(activityItems: [url])
            }
        }
#endif
    }

    private func presentExport() {
        let url: URL
        do {
            url = try makeCombinedLogExport()
        } catch {
            exportErrorMessage = .init(error.localizedDescription)
            return
        }
#if os(iOS)
        exportURL = url
        isExportPresented = true
#elseif os(macOS)
        do {
            try saveExportedFileToDisk(url)
        } catch {
            exportErrorMessage = .init(error.localizedDescription)
        }
#endif
    }

    private func makeCombinedLogExport() throws -> URL {
        guard let containerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: APP_GROUP_ID
        ) else {
            throw LogExportError.containerUnavailable
        }

        var output = ""
        for filename in visibleLogFilenames {
            let url = containerURL.appendingPathComponent(filename)
            guard FileManager.default.fileExists(atPath: url.path) else {
                continue
            }

            let content = try String(contentsOf: url, encoding: .utf8)
            guard !content.isEmpty else {
                continue
            }

            output.append("===== \(filename) =====\n")
            output.append(content)
            if !output.hasSuffix("\n") {
                output.append("\n")
            }
        }

        guard !output.isEmpty else {
            throw LogExportError.emptyLogs
        }

        let filename = "EasyTier-logs-\(Int(Date().timeIntervalSince1970)).log"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
        try output.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func clearLog() async {
        let providerClear: (() async throws -> Void)?
        if shouldUseProviderClear {
            providerClear = { try await manager.clearCoreLog() }
        } else {
            providerClear = nil
        }
        await tailer.clear(appGroupID: APP_GROUP_ID, filenames: visibleLogFilenames, providerClear: providerClear)
    }

    private var shouldUseProviderClear: Bool {
        switch manager.status {
        case .connecting, .connected, .reasserting:
            return true
        case .disconnecting:
            return true
        case .disconnected, .invalid:
            return false
        @unknown default:
            return true
        }
    }
}

#if DEBUG
#Preview("Log") {
    LogView(manager: MockNEManager())
}
#endif
