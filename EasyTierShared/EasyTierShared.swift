import Foundation
@preconcurrency import NetworkExtension
import os

public let APP_BUNDLE_ID: String = "site.yinmo.easytier"
public let APP_GROUP_ID: String = "group.site.yinmo.easytier"
public let ICLOUD_CONTAINER_ID: String = "iCloud.site.yinmo.easytier"
public let LOG_FILENAME: String = "easytier.log"
public let HOST_DIAGNOSTIC_LOG_FILENAME: String = "easytier-host.log"
public let VPN_CONFIG_KEY: String = "VPNConfig"
public let VPN_CONFIG_FILENAME: String = "vpn-config.json"

public enum SharedVPNConfigStoreError: LocalizedError {
    case appGroupUnavailable
    case providerSessionUnavailable

    public var errorDescription: String? {
        switch self {
        case .appGroupUnavailable:
            return "App Group container is unavailable."
        case .providerSessionUnavailable:
            return "VPN provider session is unavailable."
        }
    }
}

public func sharedAppGroupContainerURL() throws -> URL {
    guard let containerURL = FileManager.default.containerURL(
        forSecurityApplicationGroupIdentifier: APP_GROUP_ID
    ) else {
        throw SharedVPNConfigStoreError.appGroupUnavailable
    }
    return containerURL
}

public func sharedVPNConfigFileURL() throws -> URL {
    try sharedAppGroupContainerURL().appendingPathComponent(VPN_CONFIG_FILENAME)
}

public func saveSharedVPNConfigData(_ data: Data) throws {
    let url = try sharedVPNConfigFileURL()
    try data.write(to: url, options: .atomic)
}

public func loadSharedVPNConfigDataFromFile() throws -> Data? {
    let url = try sharedVPNConfigFileURL()
    guard FileManager.default.fileExists(atPath: url.path) else {
        return nil
    }
    return try Data(contentsOf: url)
}

public func loadSharedVPNConfigDataFromUserDefaults() -> Data? {
    UserDefaults(suiteName: APP_GROUP_ID)?.data(forKey: VPN_CONFIG_KEY)
}

public func tunnelStartOptions(configData: Data) -> [String: NSObject] {
    [VPN_CONFIG_KEY: configData as NSData]
}

public func redactSensitiveLogText(_ text: String) -> String {
    let replacements: [(String, String)] = [
        (#"network_secret\s*=\s*"[^"]*""#, #"network_secret = "<redacted>""#),
        (#"network_secret:\s*Some\("[^"]*"\)"#, #"network_secret: Some("<redacted>")"#),
        (#""network_secret"\s*:\s*"[^"]*""#, #""network_secret":"<redacted>""#),
        (#"network_secret_digest:\s*Some\(\[[^\]]*\]\)"#, #"network_secret_digest: Some(<redacted>)"#),
        (#"network_secret_digest:\s*\[[^\]]*\]"#, #"network_secret_digest: <redacted>"#),
        (#""network_secret_digest"\s*:\s*\[[^\]]*\]"#, #""network_secret_digest":"<redacted>""#)
    ]

    return replacements.reduce(text) { current, replacement in
        current.replacingOccurrences(
            of: replacement.0,
            with: replacement.1,
            options: .regularExpression
        )
    }
}

public func appendSharedDiagnostic(_ message: String, component: String) {
    let timestamp = ISO8601DateFormatter().string(from: Date())
    let line = "[\(timestamp)] [\(component)] \(redactSensitiveLogText(message))\n"

    guard let containerURL = try? sharedAppGroupContainerURL() else {
        return
    }

    let url = containerURL.appendingPathComponent(HOST_DIAGNOSTIC_LOG_FILENAME)
    guard let data = line.data(using: .utf8) else { return }

    do {
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        handle.write(data)
        try handle.close()
    } catch {
        return
    }
}

public enum LogLevel: String, Codable, CaseIterable {
    case trace = "trace"
    case debug = "debug"
    case info = "info"
    case warn = "warn"
    case error = "error"
}

public struct EasyTierOptions: Codable {
    public var config: String = ""
    public var ipv4: String?
    public var ipv6: String?
    public var mtu: Int?
    public var routes: [String] = []
    public var logLevel: LogLevel = .info
    public var magicDNS: Bool = false
    public var dns: [String] = []

    public init() {}
}

public struct TunnelNetworkSettingsSnapshot: Codable, Equatable {
    public struct IPv4Subnet: Codable, Hashable {
        public var address: String
        public var subnetMask: String

        public init(address: String, subnetMask: String) {
            self.address = address
            self.subnetMask = subnetMask
        }
    }

    public struct IPv6Subnet: Codable, Hashable {
        public var address: String
        public var networkPrefixLength: Int

        public init(address: String, networkPrefixLength: Int) {
            self.address = address
            self.networkPrefixLength = networkPrefixLength
        }
    }

    public struct IPv4: Codable, Equatable {
        public var subnets: Set<IPv4Subnet>
        public var includedRoutes: Set<IPv4Subnet>?
        public var excludedRoutes: Set<IPv4Subnet>?

        public init(
            addresses: [String],
            subnetMasks: [String],
            includedRoutes: [IPv4Subnet]? = nil,
            excludedRoutes: [IPv4Subnet]? = nil
        ) {
            subnets = .init()
            for (index, address) in addresses.enumerated() {
                subnets.insert(
                    IPv4Subnet(address: address, subnetMask: subnetMasks[index])
                )
            }
            if let includedRoutes, !includedRoutes.isEmpty {
                self.includedRoutes = Set(includedRoutes)
            }
            if let excludedRoutes, !excludedRoutes.isEmpty {
                self.excludedRoutes = Set(excludedRoutes)
            }
        }
    }

    public struct IPv6: Codable, Equatable {
        public var subnets: Set<IPv6Subnet>
        public var includedRoutes: Set<IPv6Subnet>?
        public var excludedRoutes: Set<IPv6Subnet>?

        public init(
            addresses: [String],
            networkPrefixLengths: [Int],
            includedRoutes: [IPv6Subnet]? = nil,
            excludedRoutes: [IPv6Subnet]? = nil
        ) {
            subnets = .init()
            for (index, address) in addresses.enumerated() {
                subnets.insert(
                    IPv6Subnet(
                        address: address,
                        networkPrefixLength: networkPrefixLengths[index]
                    )
                )
            }
            if let includedRoutes {
                self.includedRoutes = Set(includedRoutes)
            }
            if let excludedRoutes {
                self.excludedRoutes = Set(excludedRoutes)
            }
        }
    }

    public struct DNS: Codable, Equatable {
        public var servers: Set<String>
        public var searchDomains: Set<String>?
        public var matchDomains: Set<String>?

        public init(
            servers: [String],
            searchDomains: [String]? = nil,
            matchDomains: [String]? = nil
        ) {
            self.servers = Set(servers)
            if let searchDomains {
                self.searchDomains = Set(searchDomains)
            }
            if let matchDomains {
                self.matchDomains = Set(matchDomains)
            }
        }
    }

    public var ipv4: IPv4?
    public var ipv6: IPv6?
    public var dns: DNS?
    public var mtu: UInt32?

    public init(ipv4: IPv4? = nil, ipv6: IPv6? = nil, dns: DNS? = nil, mtu: UInt32? = nil) {
        self.ipv4 = ipv4
        self.ipv6 = ipv6
        self.dns = dns
        self.mtu = mtu
    }
}

private func applyNetworkPreferences(to manager: NETunnelProviderManager, logger: Logger?) {
    manager.isEnabled = true
    if let defaults = UserDefaults(suiteName: APP_GROUP_ID) {
        manager.protocolConfiguration?.includeAllNetworks = defaults.bool(forKey: "includeAllNetworks")
        manager.protocolConfiguration?.excludeLocalNetworks = defaults.bool(forKey: "excludeLocalNetworks")
        if #available(iOS 16.4, macOS 13.3, *) {
            manager.protocolConfiguration?.excludeCellularServices = defaults.bool(forKey: "excludeCellularServices")
            manager.protocolConfiguration?.excludeAPNs = defaults.bool(forKey: "excludeAPNs")
        }
        if #available(iOS 17.4, macOS 14.4, *) {
            manager.protocolConfiguration?.excludeDeviceCommunication = defaults.bool(forKey: "excludeDeviceCommunication")
        }
        manager.protocolConfiguration?.enforceRoutes = defaults.bool(forKey: "enforceRoutes")
        if let logger {
            logger.debug("connect with protocol configuration: \(manager.protocolConfiguration)")
        }
    }
}

public enum ProviderCommand: String, Codable, CaseIterable {
    case clearLog = "clear_log"
    case exportOSLog = "export_oslog"
    case runningInfo = "running_info"
    case lastNetworkSettings = "last_network_settings"
}

public func connectWithManager(_ manager: NETunnelProviderManager, configData: Data, logger: Logger? = nil, completionHandler: (@Sendable ((any Error)?) -> Void)? = nil) {
    applyNetworkPreferences(to: manager, logger: logger)
    manager.saveToPreferences() { error in
        if let error {
            completionHandler?(error)
            return
        }

        manager.loadFromPreferences { error in
            if let error {
                completionHandler?(error)
                return
            }

            do {
                guard let session = manager.connection as? NETunnelProviderSession else {
                    completionHandler?(SharedVPNConfigStoreError.providerSessionUnavailable)
                    return
                }
                try session.startTunnel(options: tunnelStartOptions(configData: configData))
            } catch {
                completionHandler?(error)
                return
            }
            completionHandler?(nil)
        }
    }
}
