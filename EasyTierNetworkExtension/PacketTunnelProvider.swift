import os
import NetworkExtension
import Network
import Foundation

import EasyTierShared

let loggerSubsystem = "\(APP_BUNDLE_ID).tunnel"
let debounceInterval = 0.5
let logger = Logger(subsystem: loggerSubsystem, category: "swift")

private struct ProviderMessageResponse: Codable {
    let ok: Bool
    let path: String?
    let error: String?
}

class PacketTunnelProvider: NEPacketTunnelProvider {
    // Hold a weak reference to the current provider for C callback bridging
    private static weak var current: PacketTunnelProvider?
    private var lastOptions: EasyTierOptions?
    private var lastAppliedSettings: TunnelNetworkSettingsSnapshot?
    private var needReapplySettings: Bool = false

    private func appendBootstrapDiagnostic(_ message: String) {
        appendSharedDiagnostic(message, component: "EXT")
    }
    
    private func postDarwinNotification(_ name: String) {
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        CFNotificationCenterPostNotification(center, CFNotificationName(name as CFString), nil, nil, true)
    }
    
    private func notifyHostAppError(_ message: String) {
        appendBootstrapDiagnostic("notifyHostAppError: \(message)")
        // Persist the latest error into shared defaults so the host app can read details
        if let defaults = UserDefaults(suiteName: APP_GROUP_ID) {
            defaults.set(message, forKey: "TunnelLastError")
            defaults.synchronize()
        }
        // Wake the host app via Darwin notification
        postDarwinNotification("\(APP_BUNDLE_ID).error")
    }

    private func loadVPNConfigData(startOptions: [String: NSObject]?) -> (data: Data, source: String)? {
        if let data = startOptions?[VPN_CONFIG_KEY] as? Data {
            return (data, "start options")
        }
        if let nsData = startOptions?[VPN_CONFIG_KEY] as? NSData {
            return (nsData as Data, "start options")
        }
        do {
            if let data = try loadSharedVPNConfigDataFromFile() {
                return (data, "app group file")
            }
        } catch {
            appendBootstrapDiagnostic("startTunnel app group file read failed: \(error.localizedDescription)")
        }
        if let data = loadSharedVPNConfigDataFromUserDefaults() {
            return (data, "user defaults")
        }
        return nil
    }
    
    private func registerRunningInfoCallback() {
        let infoChangedCallback: @convention(c) () -> Void = {
            PacketTunnelProvider.current?.handleRunningInfoChanged()
        }
        var errPtr: UnsafePointer<CChar>? = nil
        let ret = register_running_info_callback(infoChangedCallback, &errPtr)
        if ret != 0 {
            let err = extractRustString(errPtr)
            logger.error("registerRunningInfoCallback() failed: \(err ?? "Unknown", privacy: .public)")
            appendBootstrapDiagnostic("register running info callback failed: \(err ?? "Unknown")")
        } else {
            logger.info("registerRunningInfoCallback() registered")
            appendBootstrapDiagnostic("register running info callback succeeded")
        }
    }

    private func handleRunningInfoChanged() {
        logger.warning("handleRunningInfoChanged(): triggered")
        enqueueSettingsUpdate()
    }
    
    private func registerRustStopCallback() {
        // Register FFI stop callback to capture crashes/stop events
        let rustStopCallback: @convention(c) () -> Void = {
            PacketTunnelProvider.current?.handleRustStop()
        }
        var regErrPtr: UnsafePointer<CChar>? = nil
        let regRet = register_stop_callback(rustStopCallback, &regErrPtr)
        if regRet != 0 {
            let regErr = extractRustString(regErrPtr)
            logger.error("startTunnel() failed to register stop callback: \(regErr ?? "Unknown", privacy: .public)")
            appendBootstrapDiagnostic("register stop callback failed: \(regErr ?? "Unknown")")
        } else {
            logger.info("startTunnel() registered FFI stop callback")
            appendBootstrapDiagnostic("register stop callback succeeded")
        }
    }
    
    private func handleRustStop() {
        // Called from FFI callback on an arbitrary thread
        var msgPtr: UnsafePointer<CChar>? = nil
        var errPtr: UnsafePointer<CChar>? = nil
        let ret = get_latest_error_msg(&msgPtr, &errPtr)
        if ret == 0, let msg = extractRustString(msgPtr) {
            logger.error("handleRustStop(): \(msg, privacy: .public)")
            appendBootstrapDiagnostic("rust stopped: \(msg)")
            // Inform host app and cancel the tunnel on global queue
            DispatchQueue.main.async {
                self.notifyHostAppError(msg)
                self.cancelTunnelWithError(msg)
            }
        } else if let err = extractRustString(errPtr) {
            logger.error("handleRustStop() failed to get latest error: \(err, privacy: .public)")
            appendBootstrapDiagnostic("rust stop callback failed to read latest error: \(err)")
        }
    }

    private func enqueueSettingsUpdate() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if self.reasserting {
                logger.info("enqueueSettingsUpdate() update in progress, waiting")
                self.needReapplySettings = true
                return
            }
            logger.info("enqueueSettingsUpdate() starting settings update")
            self.applyNetworkSettings() { error in
                guard let error else { return }
                logger.info("enqueueSettingsUpdate() failed with error: \(error)")
            }
        }
    }

    private func applyNetworkSettings(_ completion: @escaping ((any Error)?) -> Void) {
        appendBootstrapDiagnostic("applyNetworkSettings entered")
        guard !self.reasserting else {
            logger.error("applyNetworkSettings() still in progress")
            appendBootstrapDiagnostic("applyNetworkSettings rejected: still in progress")
            completion("still in progress")
            return
        }
        self.reasserting = true
        Thread.sleep(forTimeInterval: debounceInterval)
        guard let options = lastOptions else {
            logger.error("applyNetworkSettings() cannot get options")
            appendBootstrapDiagnostic("applyNetworkSettings failed: missing options")
            completion("cannot get options")
            return
        }
        self.needReapplySettings = false
        let settings = buildSettings(options)
        let newSnapshot = snapshotSettings(settings)
        let wrappedCompletion: (Error?) -> Void = { error in
            DispatchQueue.main.async {
                if error == nil {
                    self.lastAppliedSettings = newSnapshot
                }
                completion(error)
                self.reasserting = false
                if self.needReapplySettings {
                    self.needReapplySettings = false
                    self.applyNetworkSettings(completion)
                }
            }
        }
        if newSnapshot == lastAppliedSettings {
            logger.warning("applyNetworkSettings() new settings are excatly the same as last applied, skipping")
            appendBootstrapDiagnostic("applyNetworkSettings skipped: settings unchanged")
            wrappedCompletion(nil)
            return
        }
        let needSetTunFd = shouldUpdateTunFd(old: lastAppliedSettings, new: newSnapshot)
        logger.info("applyNetworkSettings() need set tunfd: \(needSetTunFd), settings: \(settings, privacy: .public)")
        appendBootstrapDiagnostic("applyNetworkSettings setting tunnel network settings: needSetTunFd=\(needSetTunFd)")
        self.setTunnelNetworkSettings(settings) { [weak self] error in
            guard let self else {
                wrappedCompletion(error)
                return
            }
            if let error {
                logger.error("handleRunningInfoChanged() failed to setTunnelNetworkSettings: \(error, privacy: .public)")
                self.appendBootstrapDiagnostic("setTunnelNetworkSettings failed: \(error.localizedDescription)")
                self.notifyHostAppError(error.localizedDescription)
                wrappedCompletion(error)
                return
            }
            if needSetTunFd {
                let tunFd = self.packetFlow.value(forKeyPath: "socket.fileDescriptor") as? Int32 ?? tunnelFileDescriptor()
                if let tunFd {
                    var errPtr: UnsafePointer<CChar>? = nil
                    let ret = set_tun_fd(tunFd, &errPtr)
                    guard ret == 0 else {
                        let err = extractRustString(errPtr)
                        logger.error("handleRunningInfoChanged() failed to set tun fd to \(tunFd): \(err, privacy: .public)")
                        self.appendBootstrapDiagnostic("set_tun_fd failed: fd=\(tunFd), error=\(err ?? "Unknown")")
                        self.notifyHostAppError(err ?? "Unknown")
                        wrappedCompletion("failed to set tun fd")
                        return
                    }
                    self.appendBootstrapDiagnostic("set_tun_fd succeeded: fd=\(tunFd)")
                } else {
                    logger.error("handleRunningInfoChanged() no available tun fd")
                    self.appendBootstrapDiagnostic("set_tun_fd failed: no available tun fd")
                    self.notifyHostAppError("no available tun fd")
                    wrappedCompletion("no available tun fd")
                    return
                }
            }
            logger.info("applyNetworkSettings() settings applied")
            self.appendBootstrapDiagnostic("applyNetworkSettings succeeded")
            wrappedCompletion(nil)
        }
    }

    override func startTunnel(options: [String : NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        appendBootstrapDiagnostic("startTunnel entered")
        logger.warning("startTunnel(): triggered")
        PacketTunnelProvider.current = self

        if UserDefaults(suiteName: APP_GROUP_ID) == nil {
            logger.error("startTunnel() App Group defaults unavailable")
            appendBootstrapDiagnostic("startTunnel App Group defaults unavailable")
        } else {
            appendBootstrapDiagnostic("startTunnel App Group defaults available")
        }

        guard let loadedConfig = loadVPNConfigData(startOptions: options) else {
            let message = "VPNConfig missing from start options, app group file, and user defaults"
            logger.error("startTunnel() \(message, privacy: .public)")
            appendBootstrapDiagnostic("startTunnel failed: \(message)")
            self.notifyHostAppError(message)
            completionHandler(message)
            return
        }
        let configData = loadedConfig.data
        appendBootstrapDiagnostic("startTunnel VPNConfig found from \(loadedConfig.source): bytes=\(configData.count)")

        let options: EasyTierOptions
        do {
            options = try JSONDecoder().decode(EasyTierOptions.self, from: configData)
            appendBootstrapDiagnostic("startTunnel VPNConfig decoded: logLevel=\(options.logLevel.rawValue), configBytes=\(options.config.utf8.count)")
        } catch {
            logger.error("startTunnel() failed to decode options: \(error.localizedDescription, privacy: .public)")
            appendBootstrapDiagnostic("startTunnel failed: VPNConfig decode error=\(error.localizedDescription)")
            self.notifyHostAppError("VPNConfig decode failed: \(error.localizedDescription)")
            completionHandler(error)
            return
        }
        self.lastOptions = options

        appendBootstrapDiagnostic("initRustLogger starting")
        initRustLogger(level: options.logLevel)
        appendBootstrapDiagnostic("run_network_instance starting")
        var errPtr: UnsafePointer<CChar>? = nil
        let ret = options.config.withCString { strPtr in
            return run_network_instance(strPtr, &errPtr)
        }
        guard ret == 0 else {
            let err = extractRustString(errPtr)
            logger.error("startTunnel() failed to run: \(err ?? "Unknown", privacy: .public)")
            appendBootstrapDiagnostic("run_network_instance failed: \(err ?? "Unknown")")
            self.notifyHostAppError(err ?? "Unknown")
            completionHandler(err)
            return
        }
        appendBootstrapDiagnostic("run_network_instance succeeded")
        appendBootstrapDiagnostic("registering callbacks")
        registerRustStopCallback()
        registerRunningInfoCallback()
        appendBootstrapDiagnostic("applying initial network settings")
        applyNetworkSettings(completionHandler)
    }
    
    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        logger.warning("stopTunnel(): triggered")
        appendBootstrapDiagnostic("stopTunnel entered: reason=\(String(describing: reason))")
        let ret = stop_network_instance()
        if ret != 0 {
            logger.error("stopTunnel() failed")
            appendBootstrapDiagnostic("stop_network_instance failed")
        } else {
            appendBootstrapDiagnostic("stop_network_instance succeeded")
        }
        PacketTunnelProvider.current = nil
        completionHandler()
    }
    
    override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)?) {
        logger.debug("handleAppMessage(): triggered")
        // Add code here to handle the message.
        guard let completionHandler else { return }
        if let raw = String(data: messageData, encoding: .utf8),
           let command = ProviderCommand(rawValue: raw) {
            switch command {
            case .clearLog:
                var errPtr: UnsafePointer<CChar>? = nil
                if clear_logger(&errPtr) == 0 {
                    let response = ProviderMessageResponse(ok: true, path: nil, error: nil)
                    let data = try? JSONEncoder().encode(response)
                    completionHandler(data)
                } else {
                    let err = extractRustString(errPtr) ?? "Unknown"
                    logger.error("handleAppMessage() clear logger failed: \(err, privacy: .public)")
                    let response = ProviderMessageResponse(ok: false, path: nil, error: err)
                    let data = try? JSONEncoder().encode(response)
                    completionHandler(data)
                }
            case .exportOSLog:
                do {
                    let url = try OSLogExporter.exportToAppGroup(appGroupID: APP_GROUP_ID)
                    let response = ProviderMessageResponse(ok: true, path: url.path, error: nil)
                    let data = try JSONEncoder().encode(response)
                    completionHandler(data)
                } catch {
                    let response = ProviderMessageResponse(ok: false, path: nil, error: error.localizedDescription)
                    let data = try? JSONEncoder().encode(response)
                    completionHandler(data)
                }
            case .runningInfo:
                appendBootstrapDiagnostic("running_info request received")
                var infoPtr: UnsafePointer<CChar>? = nil
                var errPtr: UnsafePointer<CChar>? = nil
                if get_running_info(&infoPtr, &errPtr) == 0, let info = extractRustString(infoPtr) {
                    let data = info.data(using: .utf8)
                    appendBootstrapDiagnostic("get_running_info succeeded: bytes=\(data?.count ?? 0)")
                    completionHandler(data)
                } else if let err = extractRustString(errPtr) {
                    logger.error("handleAppMessage() failed: \(err, privacy: .public)")
                    appendBootstrapDiagnostic("get_running_info failed: \(err)")
                    completionHandler(nil)
                } else {
                    appendBootstrapDiagnostic("get_running_info failed: nil response and nil error")
                    completionHandler(nil)
                }
            case .lastNetworkSettings:
                guard let lastAppliedSettings else {
                    completionHandler(nil)
                    return
                }
                do {
                    let data = try JSONEncoder().encode(lastAppliedSettings)
                    completionHandler(data)
                } catch {
                    logger.error("handleAppMessage() encode settings failed: \(error, privacy: .public)")
                    completionHandler(nil)
                }
            }
            return
        }
        completionHandler(nil)
    }
    
    override func sleep(completionHandler: @escaping () -> Void) {
        // Add code here to get ready to sleep.
        completionHandler()
    }
    
    override func wake() {
        // Add code here to wake up.
    }
}

extension String: @retroactive Error {}
