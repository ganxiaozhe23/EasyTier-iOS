import Foundation
import SwiftUI

private struct AnyDecodableValue: Decodable {
    init(from decoder: Decoder) throws {
        if var container = try? decoder.unkeyedContainer() {
            while !container.isAtEnd {
                _ = try? container.decode(AnyDecodableValue.self)
            }
            return
        }

        if let container = try? decoder.container(keyedBy: DynamicCodingKey.self) {
            for key in container.allKeys {
                _ = try? container.decode(AnyDecodableValue.self, forKey: key)
            }
            return
        }

        let container = try decoder.singleValueContainer()
        if container.decodeNil() { return }
        if (try? container.decode(Bool.self)) != nil { return }
        if (try? container.decode(Int.self)) != nil { return }
        if (try? container.decode(Double.self)) != nil { return }
        if (try? container.decode(String.self)) != nil { return }
    }
}

private struct DynamicCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int?

    init?(stringValue: String) {
        self.stringValue = stringValue
        intValue = nil
    }

    init?(intValue: Int) {
        stringValue = String(intValue)
        self.intValue = intValue
    }
}

private struct LossyDecodableList<Element: Decodable>: Decodable {
    let elements: [Element]

    init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        var decoded: [Element] = []
        while !container.isAtEnd {
            if let value = try? container.decode(Element.self) {
                decoded.append(value)
            } else {
                _ = try? container.decode(AnyDecodableValue.self)
            }
        }
        elements = decoded
    }
}

private extension KeyedDecodingContainer {
    func decodeSafely<T: Decodable>(_ type: T.Type, forKey key: Key) -> T? {
        try? decodeIfPresent(type, forKey: key)
    }

    func decodeSafely<T: Decodable>(_ type: T.Type, forKey key: Key, defaultValue: T) -> T {
        (try? decodeIfPresent(type, forKey: key)) ?? defaultValue
    }

    func decodeLossyArray<T: Decodable>(_ type: T.Type, forKey key: Key) -> [T] {
        (try? decodeIfPresent(LossyDecodableList<T>.self, forKey: key))?.elements ?? []
    }
}

struct NetworkStatus: Codable {
    enum NATType: Int, Codable {
        case unknown = 0
        case openInternet = 1
        case noPAT = 2
        case fullCone = 3
        case restricted = 4
        case portRestricted = 5
        case symmetric = 6
        case symUDPFirewall = 7
        case symmetricEasyInc = 8
        case symmetricEasyDec = 9

        var description: LocalizedStringKey {
            switch self {
            case .unknown:          return "unknown"
            case .openInternet:     return "open_internet"
            case .noPAT:            return "no_pat"
            case .fullCone:         return "full_cone"
            case .restricted:       return "restricted"
            case .portRestricted:   return "port_restricted"
            case .symmetric:        return "symmetric"
            case .symUDPFirewall:   return "symmetric_udp_firewall"
            case .symmetricEasyInc: return "symmetric_easy_inc"
            case .symmetricEasyDec: return "symmetric_easy_dec"
            }
        }
    }

    struct UUID: Codable, Hashable {
        var part1: UInt32
        var part2: UInt32
        var part3: UInt32
        var part4: UInt32
    }

    struct PeerFeatureFlag: Codable, Hashable {
        var isPublicServer: Bool
        var avoidRelayData: Bool
        var kcpInput: Bool
        var noRelayKcp: Bool
        var supportConnListSync: Bool
        var quicInput: Bool
        var noRelayQuic: Bool

        init(
            isPublicServer: Bool = false,
            avoidRelayData: Bool = false,
            kcpInput: Bool = false,
            noRelayKcp: Bool = false,
            supportConnListSync: Bool = false,
            quicInput: Bool = false,
            noRelayQuic: Bool = false
        ) {
            self.isPublicServer = isPublicServer
            self.avoidRelayData = avoidRelayData
            self.kcpInput = kcpInput
            self.noRelayKcp = noRelayKcp
            self.supportConnListSync = supportConnListSync
            self.quicInput = quicInput
            self.noRelayQuic = noRelayQuic
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            isPublicServer = container.decodeSafely(Bool.self, forKey: .isPublicServer, defaultValue: false)
            avoidRelayData = container.decodeSafely(Bool.self, forKey: .avoidRelayData, defaultValue: false)
            kcpInput = container.decodeSafely(Bool.self, forKey: .kcpInput, defaultValue: false)
            noRelayKcp = container.decodeSafely(Bool.self, forKey: .noRelayKcp, defaultValue: false)
            supportConnListSync = container.decodeSafely(Bool.self, forKey: .supportConnListSync, defaultValue: false)
            quicInput = container.decodeSafely(Bool.self, forKey: .quicInput, defaultValue: false)
            noRelayQuic = container.decodeSafely(Bool.self, forKey: .noRelayQuic, defaultValue: false)
        }

        enum CodingKeys: String, CodingKey {
            case isPublicServer = "is_public_server"
            case avoidRelayData = "avoid_relay_data"
            case kcpInput = "kcp_input"
            case noRelayKcp = "no_relay_kcp"
            case supportConnListSync = "support_conn_list_sync"
            case quicInput = "quic_input"
            case noRelayQuic = "no_relay_quic"
        }
    }

    struct IPv4Addr: Codable, Hashable, CustomStringConvertible {
        var addr: UInt32

        init?(_ s: String) {
            let components = s.split(separator: ".").compactMap { UInt32($0) }
            guard components.count == 4 else { return nil }
            let addr =
                (components[0] << 24) | (components[1] << 16)
                | (components[2] << 8) | components[3]
            self.addr = addr
        }

        var description: String {
            let ip = addr
            return
                "\((ip >> 24) & 0xFF).\((ip >> 16) & 0xFF).\((ip >> 8) & 0xFF).\(ip & 0xFF)"
        }
    }

    struct IPv4CIDR: Codable, Hashable, CustomStringConvertible {
        var address: IPv4Addr
        var networkLength: Int

        var description: String {
            return "\(address.description)/\(networkLength)"
        }

        enum CodingKeys: String, CodingKey {
            case address
            case networkLength = "network_length"
        }
    }

    struct IPv6Addr: Codable, Hashable, CustomStringConvertible {
        var part1: UInt32
        var part2: UInt32
        var part3: UInt32
        var part4: UInt32
        
        init?(_ s: String) {
            var addr = in6_addr()
            guard inet_pton(AF_INET6, s, &addr) == 1 else {
                return nil
            }
            
            let data = withUnsafeBytes(of: addr) { Data($0) }
            
            self.part1 = data.subdata(in: 0..<4).withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
            self.part2 = data.subdata(in: 4..<8).withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
            self.part3 = data.subdata(in: 8..<12).withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
            self.part4 = data.subdata(in: 12..<16).withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
        }
        
        var description: String {
            var addr = in6_addr()
            let p1 = part1.bigEndian
            let p2 = part2.bigEndian
            let p3 = part3.bigEndian
            let p4 = part4.bigEndian
            
            withUnsafeMutableBytes(of: &addr) { ptr in
                ptr.storeBytes(of: p1, toByteOffset: 0, as: UInt32.self)
                ptr.storeBytes(of: p2, toByteOffset: 4, as: UInt32.self)
                ptr.storeBytes(of: p3, toByteOffset: 8, as: UInt32.self)
                ptr.storeBytes(of: p4, toByteOffset: 12, as: UInt32.self)
            }
            
            var buffer = [UInt8](repeating: 0, count: Int(INET6_ADDRSTRLEN))
            
            if inet_ntop(AF_INET6, &addr, &buffer, socklen_t(INET6_ADDRSTRLEN)) != nil {
                return String(decoding: buffer.prefix(while: { $0 != 0 }), as: UTF8.self)
            }
            // fallback
            let parts = [part1, part2, part3, part4]
            let segments = parts.flatMap { part -> [UInt16] in
                [UInt16(part >> 16), UInt16(part & 0xFFFF)]
            }
            return segments.map { String(format: "%04x", $0) }.joined(separator: ":")
        }
    }

    struct IPv6CIDR: Codable, Hashable {
        var address: IPv6Addr
        var networkLength: Int

        enum CodingKeys: String, CodingKey {
            case address
            case networkLength = "network_length"
        }
        
        var description: String {
            return "\(address.description)/\(networkLength)"
        }
    }

    struct Url: Codable, Hashable {
        var url: String
    }

    struct MyNodeInfo: Codable {
        struct IPList: Codable {
            var publicIPv4: IPv4Addr?
            var interfaceIPv4s: [IPv4Addr]?
            var publicIPv6: IPv6Addr?
            var interfaceIPv6s: [IPv6Addr]?
            var listeners: [Url]?

            init(
                publicIPv4: IPv4Addr? = nil,
                interfaceIPv4s: [IPv4Addr]? = nil,
                publicIPv6: IPv6Addr? = nil,
                interfaceIPv6s: [IPv6Addr]? = nil,
                listeners: [Url]? = nil
            ) {
                self.publicIPv4 = publicIPv4
                self.interfaceIPv4s = interfaceIPv4s
                self.publicIPv6 = publicIPv6
                self.interfaceIPv6s = interfaceIPv6s
                self.listeners = listeners
            }

            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                publicIPv4 = container.decodeSafely(IPv4Addr.self, forKey: .publicIPv4)
                interfaceIPv4s = container.decodeLossyArray(IPv4Addr.self, forKey: .interfaceIPv4s)
                publicIPv6 = container.decodeSafely(IPv6Addr.self, forKey: .publicIPv6)
                interfaceIPv6s = container.decodeLossyArray(IPv6Addr.self, forKey: .interfaceIPv6s)
                listeners = container.decodeLossyArray(Url.self, forKey: .listeners)
            }

            enum CodingKeys: String, CodingKey {
                case publicIPv4 = "public_ipv4"
                case interfaceIPv4s = "interface_ipv4s"
                case publicIPv6 = "public_ipv6"
                case interfaceIPv6s = "interface_ipv6s"
                case listeners
            }
        }
        var virtualIPv4: IPv4CIDR?
        var hostname: String
        var version: String
        var ips: IPList?
        var stunInfo: STUNInfo?
        var listeners: [Url]? = nil
        var vpnPortalCfg: String?
        var peerID: Int?

        init(
            virtualIPv4: IPv4CIDR? = nil,
            hostname: String = "",
            version: String = "",
            ips: IPList? = nil,
            stunInfo: STUNInfo? = nil,
            listeners: [Url]? = nil,
            vpnPortalCfg: String? = nil,
            peerID: Int? = nil
        ) {
            self.virtualIPv4 = virtualIPv4
            self.hostname = hostname
            self.version = version
            self.ips = ips
            self.stunInfo = stunInfo
            self.listeners = listeners
            self.vpnPortalCfg = vpnPortalCfg
            self.peerID = peerID
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            virtualIPv4 = container.decodeSafely(IPv4CIDR.self, forKey: .virtualIPv4)
            hostname = container.decodeSafely(String.self, forKey: .hostname, defaultValue: "")
            version = container.decodeSafely(String.self, forKey: .version, defaultValue: "")
            ips = container.decodeSafely(IPList.self, forKey: .ips)
            stunInfo = container.decodeSafely(STUNInfo.self, forKey: .stunInfo)
            listeners = container.decodeLossyArray(Url.self, forKey: .listeners)
            vpnPortalCfg = container.decodeSafely(String.self, forKey: .vpnPortalCfg)
            peerID = container.decodeSafely(Int.self, forKey: .peerID)
        }

        enum CodingKeys: String, CodingKey {
            case virtualIPv4 = "virtual_ipv4"
            case hostname, version
            case ips
            case stunInfo = "stun_info"
            case listeners
            case vpnPortalCfg = "vpn_portal_cfg"
            case peerID = "peer_id"
        }
    }

    struct STUNInfo: Codable, Hashable {
        var udpNATType: NATType
        var tcpNATType: NATType
        var lastUpdateTime: TimeInterval
        var publicIPs: [String] = []
        var minPort: Int? = nil
        var maxPort: Int? = nil

        init(
            udpNATType: NATType = .unknown,
            tcpNATType: NATType = .unknown,
            lastUpdateTime: TimeInterval = 0,
            publicIPs: [String] = [],
            minPort: Int? = nil,
            maxPort: Int? = nil
        ) {
            self.udpNATType = udpNATType
            self.tcpNATType = tcpNATType
            self.lastUpdateTime = lastUpdateTime
            self.publicIPs = publicIPs
            self.minPort = minPort
            self.maxPort = maxPort
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            udpNATType = container.decodeSafely(NATType.self, forKey: .udpNATType, defaultValue: .unknown)
            tcpNATType = container.decodeSafely(NATType.self, forKey: .tcpNATType, defaultValue: .unknown)
            lastUpdateTime = container.decodeSafely(TimeInterval.self, forKey: .lastUpdateTime, defaultValue: 0)
            if let publicIPs = container.decodeSafely([String].self, forKey: .publicIPs) {
                self.publicIPs = publicIPs
            } else if let publicIP = container.decodeSafely(String.self, forKey: .publicIPs) {
                self.publicIPs = [publicIP]
            } else {
                self.publicIPs = []
            }
            minPort = container.decodeSafely(Int.self, forKey: .minPort)
            maxPort = container.decodeSafely(Int.self, forKey: .maxPort)
        }

        enum CodingKeys: String, CodingKey {
            case udpNATType = "udp_nat_type"
            case tcpNATType = "tcp_nat_type"
            case lastUpdateTime = "last_update_time"
            case publicIPs = "public_ip"
            case minPort = "min_port"
            case maxPort = "max_port"
        }
    }

    struct Route: Codable, Hashable, Identifiable {
        var id: Int { peerId }
        var peerId: Int
        var ipv4Addr: IPv4CIDR?
        var ipv6Addr: IPv6CIDR?
        var nextHopPeerId: Int
        var cost: Int
        var pathLatency: Int
        var proxyCIDRs: [String] = []
        var hostname: String
        var stunInfo: STUNInfo?
        var instId: String
        var version: String
        var nextHopPeerIdLatencyFirst: UInt?
        var costLatencyFirst: Int? = nil
        var pathLatencyLatencyFirst: Int? = nil
        var featureFlag: PeerFeatureFlag? = nil

        init(
            peerId: Int,
            ipv4Addr: IPv4CIDR? = nil,
            ipv6Addr: IPv6CIDR? = nil,
            nextHopPeerId: Int,
            cost: Int,
            pathLatency: Int,
            proxyCIDRs: [String] = [],
            hostname: String,
            stunInfo: STUNInfo? = nil,
            instId: String,
            version: String,
            nextHopPeerIdLatencyFirst: UInt? = nil,
            costLatencyFirst: Int? = nil,
            pathLatencyLatencyFirst: Int? = nil,
            featureFlag: PeerFeatureFlag? = nil
        ) {
            self.peerId = peerId
            self.ipv4Addr = ipv4Addr
            self.ipv6Addr = ipv6Addr
            self.nextHopPeerId = nextHopPeerId
            self.cost = cost
            self.pathLatency = pathLatency
            self.proxyCIDRs = proxyCIDRs
            self.hostname = hostname
            self.stunInfo = stunInfo
            self.instId = instId
            self.version = version
            self.nextHopPeerIdLatencyFirst = nextHopPeerIdLatencyFirst
            self.costLatencyFirst = costLatencyFirst
            self.pathLatencyLatencyFirst = pathLatencyLatencyFirst
            self.featureFlag = featureFlag
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            peerId = container.decodeSafely(Int.self, forKey: .peerId, defaultValue: 0)
            ipv4Addr = container.decodeSafely(IPv4CIDR.self, forKey: .ipv4Addr)
            ipv6Addr = container.decodeSafely(IPv6CIDR.self, forKey: .ipv6Addr)
            nextHopPeerId = container.decodeSafely(Int.self, forKey: .nextHopPeerId, defaultValue: peerId)
            cost = container.decodeSafely(Int.self, forKey: .cost, defaultValue: 0)
            pathLatency = container.decodeSafely(Int.self, forKey: .pathLatency, defaultValue: 0)
            proxyCIDRs = container.decodeLossyArray(String.self, forKey: .proxyCIDRs)
            hostname = container.decodeSafely(String.self, forKey: .hostname, defaultValue: "")
            stunInfo = container.decodeSafely(STUNInfo.self, forKey: .stunInfo)
            instId = container.decodeSafely(String.self, forKey: .instId, defaultValue: "")
            version = container.decodeSafely(String.self, forKey: .version, defaultValue: "")
            nextHopPeerIdLatencyFirst = container.decodeSafely(UInt.self, forKey: .nextHopPeerIdLatencyFirst)
            costLatencyFirst = container.decodeSafely(Int.self, forKey: .costLatencyFirst)
            pathLatencyLatencyFirst = container.decodeSafely(Int.self, forKey: .pathLatencyLatencyFirst)
            featureFlag = container.decodeSafely(PeerFeatureFlag.self, forKey: .featureFlag)
        }

        enum CodingKeys: String, CodingKey {
            case peerId = "peer_id"
            case ipv4Addr = "ipv4_addr"
            case ipv6Addr = "ipv6_addr"
            case nextHopPeerId = "next_hop_peer_id"
            case cost
            case pathLatency = "path_latency"
            case hostname, version
            case proxyCIDRs = "proxy_cidrs"
            case stunInfo = "stun_info"
            case instId = "inst_id"
            case nextHopPeerIdLatencyFirst = "next_hop_peer_id_latency_first"
            case costLatencyFirst = "cost_latency_first"
            case pathLatencyLatencyFirst = "path_latency_latency_first"
            case featureFlag = "feature_flag"
        }
    }

    struct PeerInfo: Codable, Hashable, Identifiable {
        var id: Int { peerId }
        var peerId: Int
        var conns: [PeerConnInfo]
        var defaultConnId: UUID? = nil
        var directlyConnectedConns: [UUID] = []

        init(
            peerId: Int,
            conns: [PeerConnInfo],
            defaultConnId: UUID? = nil,
            directlyConnectedConns: [UUID] = []
        ) {
            self.peerId = peerId
            self.conns = conns
            self.defaultConnId = defaultConnId
            self.directlyConnectedConns = directlyConnectedConns
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            peerId = container.decodeSafely(Int.self, forKey: .peerId, defaultValue: 0)
            conns = container.decodeLossyArray(PeerConnInfo.self, forKey: .conns)
            defaultConnId = container.decodeSafely(UUID.self, forKey: .defaultConnId)
            directlyConnectedConns = container.decodeLossyArray(UUID.self, forKey: .directlyConnectedConns)
        }

        enum CodingKeys: String, CodingKey {
            case peerId = "peer_id"
            case conns
            case defaultConnId = "default_conn_id"
            case directlyConnectedConns = "directly_connected_conns"
        }
    }

    struct PeerConnInfo: Codable, Hashable {
        var connId: String
        var myPeerId: Int
        var isClient: Bool
        var peerId: Int
        var features: [String]
        var tunnel: TunnelInfo?
        var stats: PeerConnStats?
        var lossRate: Double
        var networkName: String? = nil
        var isClosed: Bool? = nil

        init(
            connId: String,
            myPeerId: Int,
            isClient: Bool,
            peerId: Int,
            features: [String],
            tunnel: TunnelInfo? = nil,
            stats: PeerConnStats? = nil,
            lossRate: Double,
            networkName: String? = nil,
            isClosed: Bool? = nil
        ) {
            self.connId = connId
            self.myPeerId = myPeerId
            self.isClient = isClient
            self.peerId = peerId
            self.features = features
            self.tunnel = tunnel
            self.stats = stats
            self.lossRate = lossRate
            self.networkName = networkName
            self.isClosed = isClosed
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            connId = container.decodeSafely(String.self, forKey: .connId, defaultValue: "")
            myPeerId = container.decodeSafely(Int.self, forKey: .myPeerId, defaultValue: 0)
            isClient = container.decodeSafely(Bool.self, forKey: .isClient, defaultValue: false)
            peerId = container.decodeSafely(Int.self, forKey: .peerId, defaultValue: 0)
            features = container.decodeLossyArray(String.self, forKey: .features)
            tunnel = container.decodeSafely(TunnelInfo.self, forKey: .tunnel)
            stats = container.decodeSafely(PeerConnStats.self, forKey: .stats)
            lossRate = container.decodeSafely(Double.self, forKey: .lossRate, defaultValue: 0)
            networkName = container.decodeSafely(String.self, forKey: .networkName)
            isClosed = container.decodeSafely(Bool.self, forKey: .isClosed)
        }

        enum CodingKeys: String, CodingKey {
            case connId = "conn_id"
            case myPeerId = "my_peer_id"
            case isClient = "is_client"
            case peerId = "peer_id"
            case features, tunnel, stats
            case lossRate = "loss_rate"
            case networkName = "network_name"
            case isClosed = "is_closed"
        }
    }

    struct PeerRoutePair: Codable, Hashable, Identifiable {
        var id: Int { route.id }
        var route: Route
        var peer: PeerInfo?

        init(route: Route, peer: PeerInfo? = nil) {
            self.route = route
            self.peer = peer
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            route = try container.decode(Route.self, forKey: .route)
            peer = container.decodeSafely(PeerInfo.self, forKey: .peer)
        }

        enum CodingKeys: String, CodingKey {
            case route, peer
        }
    }

    struct TunnelInfo: Codable, Hashable {
        var tunnelType: String
        var localAddr: Url
        var remoteAddr: Url

        init(tunnelType: String, localAddr: Url, remoteAddr: Url) {
            self.tunnelType = tunnelType
            self.localAddr = localAddr
            self.remoteAddr = remoteAddr
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            tunnelType = container.decodeSafely(String.self, forKey: .tunnelType, defaultValue: "")
            localAddr = container.decodeSafely(Url.self, forKey: .localAddr, defaultValue: Url(url: ""))
            remoteAddr = container.decodeSafely(Url.self, forKey: .remoteAddr, defaultValue: Url(url: ""))
        }

        enum CodingKeys: String, CodingKey {
            case tunnelType = "tunnel_type"
            case localAddr = "local_addr"
            case remoteAddr = "remote_addr"
        }
    }

    struct PeerConnStats: Codable, Hashable {
        var rxBytes: Int
        var txBytes: Int
        var rxPackets: Int
        var txPackets: Int
        var latencyUs: Int

        init(rxBytes: Int, txBytes: Int, rxPackets: Int, txPackets: Int, latencyUs: Int) {
            self.rxBytes = rxBytes
            self.txBytes = txBytes
            self.rxPackets = rxPackets
            self.txPackets = txPackets
            self.latencyUs = latencyUs
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            rxBytes = container.decodeSafely(Int.self, forKey: .rxBytes, defaultValue: 0)
            txBytes = container.decodeSafely(Int.self, forKey: .txBytes, defaultValue: 0)
            rxPackets = container.decodeSafely(Int.self, forKey: .rxPackets, defaultValue: 0)
            txPackets = container.decodeSafely(Int.self, forKey: .txPackets, defaultValue: 0)
            latencyUs = container.decodeSafely(Int.self, forKey: .latencyUs, defaultValue: 0)
        }

        enum CodingKeys: String, CodingKey {
            case rxBytes = "rx_bytes"
            case txBytes = "tx_bytes"
            case rxPackets = "rx_packets"
            case txPackets = "tx_packets"
            case latencyUs = "latency_us"
        }
    }

    var devName: String
    var myNodeInfo: MyNodeInfo?
    var events: [String]
    var routes: [Route]
    var peers: [PeerInfo]
    var peerRoutePairs: [PeerRoutePair]
    var running: Bool
    var errorMsg: String?

    init(
        devName: String,
        myNodeInfo: MyNodeInfo? = nil,
        events: [String] = [],
        routes: [Route] = [],
        peers: [PeerInfo] = [],
        peerRoutePairs: [PeerRoutePair] = [],
        running: Bool,
        errorMsg: String? = nil
    ) {
        self.devName = devName
        self.myNodeInfo = myNodeInfo
        self.events = events
        self.routes = routes
        self.peers = peers
        self.peerRoutePairs = peerRoutePairs
        self.running = running
        self.errorMsg = errorMsg
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        devName = container.decodeSafely(String.self, forKey: .devName, defaultValue: "")
        myNodeInfo = container.decodeSafely(MyNodeInfo.self, forKey: .myNodeInfo)
        events = container.decodeLossyArray(String.self, forKey: .events)
        routes = container.decodeLossyArray(Route.self, forKey: .routes)
        peers = container.decodeLossyArray(PeerInfo.self, forKey: .peers)
        peerRoutePairs = container.decodeLossyArray(PeerRoutePair.self, forKey: .peerRoutePairs)
        if peerRoutePairs.isEmpty && !routes.isEmpty {
            peerRoutePairs = routes.map { route in
                PeerRoutePair(route: route, peer: peers.first { $0.peerId == route.peerId })
            }
        }
        running = container.decodeSafely(Bool.self, forKey: .running, defaultValue: false)
        errorMsg = container.decodeSafely(String.self, forKey: .errorMsg)
    }

    enum CodingKeys: String, CodingKey {
        case devName = "dev_name"
        case myNodeInfo = "my_node_info"
        case events, routes, peers, running
        case peerRoutePairs = "peer_route_pairs"
        case errorMsg = "error_msg"
    }

    func sum(of keyPath: KeyPath<PeerConnStats, Int>) -> Int {
        peers
            .flatMap { $0.conns }
            .compactMap { $0.stats }
            .map { $0[keyPath: keyPath] }
            .reduce(0, +)
    }
}
