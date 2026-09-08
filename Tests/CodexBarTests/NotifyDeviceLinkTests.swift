import Foundation
import Testing
@testable import CodexBarCore

/// Coverage for the Notify! credential parser and the ID namespace rules that
/// decide which surfaces a linked device can actually carry.
struct NotifyDeviceLinkTests {
    // MARK: - Parsing

    @Test
    func `accepts a legacy eight character id with a token`() {
        let link = NotifyDeviceLink(deviceId: "ABC12345", token: "secret")
        #expect(link?.deviceId == "ABC12345")
        #expect(link?.token == "secret")
    }

    @Test
    func `trims surrounding whitespace from both halves`() {
        let link = NotifyDeviceLink(deviceId: "  ABC12345\n", token: "\tsecret ")
        #expect(link?.deviceId == "ABC12345")
        #expect(link?.token == "secret")
    }

    @Test
    func `refuses an empty token`() {
        #expect(NotifyDeviceLink(deviceId: "ABC12345", token: "   ") == nil)
    }

    @Test
    func `refuses an id that is too short or not alphanumeric`() {
        #expect(NotifyDeviceLink(deviceId: "ABC123", token: "secret") == nil)
        #expect(NotifyDeviceLink(deviceId: "ABC-1234", token: "secret") == nil)
        #expect(NotifyDeviceLink(deviceId: String(repeating: "A", count: 33), token: "secret") == nil)
    }

    @Test
    func `reads a notification url with its token`() {
        let link = NotifyDeviceLink(pastedText: "https://push.getnotifyapp.com/notify/ABC12345?token=abc123")
        #expect(link?.deviceId == "ABC12345")
        #expect(link?.token == "abc123")
    }

    @Test
    func `reads a live activity url the same way`() {
        let link = NotifyDeviceLink(
            pastedText: "https://push.getnotifyapp.com/live-activity/IO12345678901234?token=xyz")
        #expect(link?.deviceId == "IO12345678901234")
        #expect(link?.token == "xyz")
    }

    @Test
    func `reads an id and token separated by whitespace a comma or a colon`() {
        for separator in [" ", ",", ":"] {
            let link = NotifyDeviceLink(pastedText: "ABC12345\(separator)secret")
            #expect(link?.deviceId == "ABC12345", "separator \(separator)")
            #expect(link?.token == "secret", "separator \(separator)")
        }
    }

    @Test
    func `refuses a url with no token on it`() {
        // The gateway's own /link response hands back a notification_url with the token stripped,
        // so this shape is real rather than hypothetical.
        #expect(NotifyDeviceLink(pastedText: "https://push.getnotifyapp.com/notify/ABC12345") == nil)
    }

    @Test
    func `still recovers the device id from a tokenless url`() {
        let identifier = NotifyDeviceLink.deviceId(inPastedText: "https://push.getnotifyapp.com/notify/ABC12345")
        #expect(identifier == "ABC12345")
    }

    @Test
    func `recovers the device id from a bare id`() {
        #expect(NotifyDeviceLink.deviceId(inPastedText: " ABC12345 ") == "ABC12345")
        #expect(NotifyDeviceLink.deviceId(inPastedText: "nope") == nil)
    }

    // MARK: - Namespaces

    @Test
    func `classifies each namespace the gateway mints`() {
        #expect(NotifyDeviceKind.kind(ofDeviceId: "GRP12345") == .group)
        #expect(NotifyDeviceKind.kind(ofDeviceId: "WB12345678901234") == .web)
        #expect(NotifyDeviceKind.kind(ofDeviceId: "MC12345678901234") == .mac)
        #expect(NotifyDeviceKind.kind(ofDeviceId: "IO12345678901234") == .appDevice)
        #expect(NotifyDeviceKind.kind(ofDeviceId: "ABC12345") == .appDevice)
    }

    @Test
    func `prefers the group prefix over the equally long legacy grammar`() {
        // GRP plus five is eight characters, exactly a legacy id's length, so the two grammars
        // genuinely overlap and the gateway's own tie break is to test the prefix first.
        #expect(NotifyDeviceKind.kind(ofDeviceId: "GRPAB123") == .group)
    }

    @Test
    func `treats a legacy id that merely starts with MC as an app device`() {
        // Prefix alone would refuse a working phone, which is the expensive mistake here.
        #expect(NotifyDeviceKind.kind(ofDeviceId: "MC123456") == .appDevice)
    }

    @Test
    func `accepts lowercase in the legacy format only`() {
        // iOS mints uppercase, but older Mac listeners minted mixed case.
        #expect(NotifyDeviceKind.kind(ofDeviceId: "abc12345") == .appDevice)
        #expect(NotifyDeviceKind.kind(ofDeviceId: "IOabcdefgh123456") == .unrecognized)
    }

    @Test
    func `allows a format it has never seen rather than refusing it`() {
        let kind = NotifyDeviceKind.kind(ofDeviceId: "ZZ9876543210987654")
        #expect(kind == .unrecognized)
        #expect(kind.supportsLiveActivity)
        #expect(kind.supportsWidget)
        #expect(kind.supportsScreenWidget)
    }

    // MARK: - Surface support

    @Test
    func `refuses a live activity for a mac a browser and a group`() {
        #expect(NotifyDeviceKind.mac.supportsLiveActivity == false)
        #expect(NotifyDeviceKind.web.supportsLiveActivity == false)
        #expect(NotifyDeviceKind.group.supportsLiveActivity == false)
        #expect(NotifyDeviceKind.appDevice.supportsLiveActivity)
    }

    @Test
    func `refuses widgets only for a group`() {
        for kind in [NotifyDeviceKind.appDevice, .mac, .web, .unrecognized] {
            #expect(kind.supportsWidget, "\(kind)")
            #expect(kind.supportsScreenWidget, "\(kind)")
        }
        #expect(NotifyDeviceKind.group.supportsWidget == false)
        #expect(NotifyDeviceKind.group.supportsScreenWidget == false)
    }

    @Test
    func `both widget surfaces always agree`() {
        for kind in NotifyDeviceKind.allCases {
            #expect(kind.supportsWidget == kind.supportsScreenWidget, "\(kind)")
            #expect(
                (kind.widgetUnsupportedReason == nil) == (kind.screenWidgetUnsupportedReason == nil),
                "\(kind)")
        }
    }

    @Test
    func `explains a refusal in terms of the device rather than a status code`() {
        #expect(NotifyDeviceKind.mac.liveActivityUnsupportedReason?.contains("Mac ID") == true)
        #expect(NotifyDeviceKind.web.liveActivityUnsupportedReason?.contains("browser ID") == true)
        #expect(NotifyDeviceKind.group.widgetUnsupportedReason?.contains("group ID") == true)
        #expect(NotifyDeviceKind.appDevice.liveActivityUnsupportedReason == nil)
    }

    // MARK: - Device info

    @Test
    func `describes a device with its platform when the gateway named one`() {
        let withPlatform = NotifyDeviceInfo(deviceId: "ABC12345", name: "Apollo", platform: "iOS")
        #expect(withPlatform.displayDescription == "Apollo (iOS)")

        let withoutPlatform = NotifyDeviceInfo(deviceId: "ABC12345", name: "Apollo", platform: nil)
        #expect(withoutPlatform.displayDescription == "Apollo")
    }
}
