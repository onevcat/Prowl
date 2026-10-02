import Foundation
import Network
import Security
import Testing

@testable import supacode

struct MirrorConnectionFailureTests {
  @Test func mapsTransportErrorsToClasses() {
    #expect(MirrorConnectionFailure(.posix(.ECONNREFUSED)) == .refused)
    #expect(MirrorConnectionFailure(.posix(.EHOSTUNREACH)) == .unreachable)
    #expect(MirrorConnectionFailure(.posix(.EADDRINUSE)) == .addressInUse)
    #expect(MirrorConnectionFailure(.posix(.EADDRNOTAVAIL)) == .addressUnavailable)
    #expect(MirrorConnectionFailure(.dns(1)) == .unresolvable)
    #expect(
      MirrorConnectionFailure(.tls(errSSLUnknownPSKIdentity)) == .handshakeRejected(errSSLUnknownPSKIdentity))
  }

  @Test func clientMessagesNameTheEndpointAndPairingContext() {
    let rejected = MirrorConnectionFailure.handshakeRejected(errSSLUnknownPSKIdentity)
    #expect(rejected.clientMessage(endpoint: "192.0.2.1:7880", pairing: true).contains("pairing code"))
    #expect(rejected.clientMessage(endpoint: "192.0.2.1:7880", pairing: false).contains("no longer recognizes"))
    #expect(
      MirrorConnectionFailure.refused.clientMessage(endpoint: "192.0.2.1:7880", pairing: false).contains(
        "192.0.2.1:7880"))
    #expect(
      MirrorConnectionFailure.timedOut.clientMessage(endpoint: "mini.local:7880", pairing: false).contains(
        "mini.local:7880"))
    #expect(MirrorConnectionFailure.other("boom").clientMessage(endpoint: "h:1", pairing: false).contains("boom"))
  }

  @Test func listenerMessagesExplainPortAndAddressProblems() {
    #expect(MirrorConnectionFailure.addressInUse.listenerMessage(address: "0.0.0.0", port: "7880").contains("7880"))
    #expect(
      MirrorConnectionFailure.addressUnavailable.listenerMessage(address: "10.0.0.9", port: "7880").contains("10.0.0.9")
    )
    #expect(
      MirrorConnectionFailure.other("boom").listenerMessage(address: "0.0.0.0", port: "7880").hasPrefix(
        "Cannot start Host"))
  }
}

struct MirrorHostAddressesTests {
  private let wifi = MirrorNetworkInterface(
    name: "en0", displayName: "Wi-Fi", address: "192.168.1.5", isIPv4: true, isLoopback: false)
  private let vpn = MirrorNetworkInterface(
    name: "utun3", displayName: nil, address: "100.64.0.2", isIPv4: true, isLoopback: false)
  private let loop = MirrorNetworkInterface(
    name: "lo0", displayName: nil, address: "127.0.0.1", isIPv4: true, isLoopback: true)
  private let six = MirrorNetworkInterface(
    name: "en0", displayName: "Wi-Fi", address: "2001:db8::5", isIPv4: false, isLoopback: false)

  @Test func allInterfacesListsEveryNonLoopbackIPv4Address() {
    let reachable = MirrorHostAddresses.reachable(listenAddress: "0.0.0.0", interfaces: [loop, wifi, vpn, six])
    #expect(reachable == [wifi, vpn])
  }

  @Test func specificListenAddressListsOnlyThatInterface() {
    #expect(MirrorHostAddresses.reachable(listenAddress: "100.64.0.2", interfaces: [loop, wifi, vpn]) == [vpn])
    #expect(MirrorHostAddresses.reachable(listenAddress: "127.0.0.1", interfaces: [loop, wifi]) == [loop])
    #expect(MirrorHostAddresses.reachable(listenAddress: "::", interfaces: [loop, wifi, six]) == [wifi, six])
  }

  @Test func unknownListenAddressStillShowsTheConfiguredValue() {
    let reachable = MirrorHostAddresses.reachable(listenAddress: "10.9.9.9", interfaces: [wifi])
    #expect(reachable.map(\.address) == ["10.9.9.9"])
    #expect(reachable.first?.label == "10.9.9.9")
  }

  @Test func labelPrefersTheLocalizedInterfaceName() {
    #expect(wifi.label == "Wi-Fi")
    #expect(vpn.label == "utun3")
  }

  @Test func presentableDropsUnnamedVirtualInterfacesAndLabelsTunnels() {
    let bridge = MirrorNetworkInterface(
      name: "bridge100", displayName: nil, address: "192.168.137.1", isIPv4: true, isLoopback: false)
    let awdl = MirrorNetworkInterface(
      name: "awdl0", displayName: nil, address: "2001:db8::9", isIPv4: false, isLoopback: false)
    let shown = MirrorHostAddresses.presentable([awdl, vpn, bridge, loop, wifi])
    #expect(shown.map(\.name) == ["en0", "utun3", "lo0"])
    #expect(shown.map(\.label) == ["Wi-Fi", "VPN", "lo0"])
  }
}

struct MirrorEndpointInputTests {
  @Test func acceptsAddressesAndHostNames() throws {
    #expect(
      try MirrorEndpointInput.endpoint(address: " 192.168.1.5 ", port: "7880")
        == .init(address: "192.168.1.5", port: 7880))
    #expect(
      try MirrorEndpointInput.endpoint(address: "mini.local", port: " 7880 ")
        == .init(address: "mini.local", port: 7880))
    #expect(try MirrorEndpointInput.endpoint(address: "fe80::1", port: "1") == .init(address: "fe80::1", port: 1))
  }

  @Test func rejectsEmptySpacedPortedAndInvalidValues() {
    #expect(throws: MirrorEndpointInput.Problem.emptyAddress) {
      try MirrorEndpointInput.endpoint(address: "  ", port: "7880")
    }
    #expect(throws: MirrorEndpointInput.Problem.invalidAddress) {
      try MirrorEndpointInput.endpoint(address: "my mac", port: "7880")
    }
    #expect(throws: MirrorEndpointInput.Problem.addressContainsPort) {
      try MirrorEndpointInput.endpoint(address: "192.168.1.5:7880", port: "7880")
    }
    #expect(throws: MirrorEndpointInput.Problem.invalidPort) {
      try MirrorEndpointInput.endpoint(address: "mini.local", port: "0")
    }
    #expect(throws: MirrorEndpointInput.Problem.invalidPort) {
      try MirrorEndpointInput.endpoint(address: "mini.local", port: "70000")
    }
  }

  @Test func pairingCodeIsRequiredOnlyForUnknownHosts() throws {
    #expect(try MirrorEndpointInput.pairingCode("", required: false) == "")
    #expect(try MirrorEndpointInput.pairingCode("r5vu-dwc5", required: true) == "R5VUDWC5")
    #expect(throws: MirrorEndpointInput.Problem.missingPairingCode) {
      try MirrorEndpointInput.pairingCode(" ", required: true)
    }
    #expect(throws: MirrorEndpointInput.Problem.invalidPairingCode) {
      try MirrorEndpointInput.pairingCode("R5VU-DWC", required: false)
    }
    #expect(throws: MirrorEndpointInput.Problem.invalidPairingCode) {
      try MirrorEndpointInput.pairingCode("R5VU-DWC0", required: true)
    }
  }

  @Test func liveFormattingUppercasesAndHyphenates() {
    #expect(MirrorPairingCode.formatted("r5v") == "R5V")
    #expect(MirrorPairingCode.formatted("r5vu") == "R5VU")
    #expect(MirrorPairingCode.formatted("r5vud") == "R5VU-D")
    #expect(MirrorPairingCode.formatted("R5VU-DWC5") == "R5VU-DWC5")
    #expect(MirrorPairingCode.formatted("r5vu dwc5 extra") == "R5VU-DWC5")
    #expect(MirrorPairingCode.formatted("") == "")
  }
}
