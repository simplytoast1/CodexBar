import Foundation
import Testing
@testable import CodexBarCore

/// Coverage for the rules that decide when a payload is worth a request: a
/// minimum gap per surface, and a keep-alive for the two surfaces the gateway
/// reaps or dims when they go stale.
struct NotifyPublishGateTests {
    private static let now = Date(timeIntervalSince1970: 1_782_000_000)

    private func tile(progress: Double) -> NotifyTile {
        NotifyTile(title: "CodexBar", progress: progress)!
    }

    private func gauge(value: String) -> NotifyGauge {
        NotifyGauge(title: "CodexBar", value: value)!
    }

    private func payload(progress: Double = 50, value: String = "50") -> NotifyPayload {
        NotifyPayload(
            tile: self.tile(progress: progress),
            gauge: self.gauge(value: value),
            screenTile: self.tile(progress: progress))
    }

    // MARK: - First publish

    @Test
    func `publishes every surface when there is no record at all`() {
        let decision = NotifyPublishGate().decide(payload: self.payload(), since: nil, now: Self.now)
        #expect(decision.publishesTile)
        #expect(decision.publishesGauge)
        #expect(decision.publishesScreenTile)
    }

    @Test
    func `publishes nothing for an empty payload`() {
        let decision = NotifyPublishGate().decide(payload: .empty, since: nil, now: Self.now)
        #expect(decision.publishesNothing)
    }

    @Test
    func `leaves a surface alone when the payload does not carry it`() {
        let tileOnly = NotifyPayload(tile: self.tile(progress: 50))
        let decision = NotifyPublishGate().decide(payload: tileOnly, since: nil, now: Self.now)
        #expect(decision.publishesTile)
        #expect(decision.publishesGauge == false)
        #expect(decision.publishesScreenTile == false)
    }

    // MARK: - Unchanged content

    @Test
    func `publishes nothing when nothing changed`() {
        let payload = self.payload()
        let record = NotifyPublishRecord(
            payload: payload,
            tileAt: Self.now,
            gaugeAt: Self.now,
            screenTileAt: Self.now)
        let decision = NotifyPublishGate().decide(payload: payload, since: record, now: Self.now)
        #expect(decision.publishesNothing)
    }

    // MARK: - Minimum gap

    @Test
    func `holds a changed tile back until its minute has passed`() {
        let record = NotifyPublishRecord(
            payload: self.payload(),
            tileAt: Self.now,
            gaugeAt: Self.now,
            screenTileAt: Self.now)
        let changed = self.payload(progress: 20, value: "20")

        let tooSoon = NotifyPublishGate().decide(
            payload: changed,
            since: record,
            now: Self.now.addingTimeInterval(30))
        #expect(tooSoon.publishesTile == false)

        let later = NotifyPublishGate().decide(
            payload: changed,
            since: record,
            now: Self.now.addingTimeInterval(61))
        #expect(later.publishesTile)
    }

    @Test
    func `holds a changed gauge back for a quarter hour`() {
        let record = NotifyPublishRecord(
            payload: self.payload(),
            tileAt: Self.now,
            gaugeAt: Self.now,
            screenTileAt: Self.now)
        let changed = self.payload(progress: 20, value: "20")

        let tooSoon = NotifyPublishGate().decide(
            payload: changed,
            since: record,
            now: Self.now.addingTimeInterval(10 * 60))
        #expect(tooSoon.publishesGauge == false)

        let later = NotifyPublishGate().decide(
            payload: changed,
            since: record,
            now: Self.now.addingTimeInterval(15 * 60))
        #expect(later.publishesGauge)
    }

    // MARK: - Keep-alive

    @Test
    func `republishes an unchanged tile before the gateway reaps it`() {
        let payload = self.payload()
        let record = NotifyPublishRecord(
            payload: payload,
            tileAt: Self.now,
            gaugeAt: Self.now,
            screenTileAt: Self.now)

        let decision = NotifyPublishGate().decide(
            payload: payload,
            since: record,
            now: Self.now.addingTimeInterval(90 * 60))
        #expect(decision.publishesTile)
        #expect(decision.publishesScreenTile)
    }

    @Test
    func `never keeps the gauge alive because nothing reaps it`() {
        // The gateway documents neither a reaper nor a freshness deadline for /widgets, so a
        // heartbeat there would prevent nothing and cost a request every ninety minutes forever.
        let payload = self.payload()
        let record = NotifyPublishRecord(
            payload: payload,
            tileAt: Self.now,
            gaugeAt: Self.now,
            screenTileAt: Self.now)

        let decision = NotifyPublishGate().decide(
            payload: payload,
            since: record,
            now: Self.now.addingTimeInterval(24 * 60 * 60))
        #expect(decision.publishesGauge == false)
    }

    // MARK: - Record merging

    @Test
    func `remembers what each surface is showing rather than the last payload built`() {
        // A tile-only publish that filed the whole payload would record the new gauge as already
        // sent, and the gate would then see no change when the gauge's own interval came round,
        // leaving a stale value on the phone until something else happened to move it.
        let first = self.payload(progress: 50, value: "50")
        let record = NotifyPublishRecord(
            payload: first,
            tileAt: Self.now,
            gaugeAt: Self.now,
            screenTileAt: Self.now)

        let changed = self.payload(progress: 20, value: "20")
        let tileOnly = NotifyPublishDecision(
            publishesTile: true,
            publishesGauge: false,
            publishesScreenTile: false)
        let updated = record.updated(with: changed, decision: tileOnly, at: Self.now.addingTimeInterval(61))

        #expect(updated.payload.tile == changed.tile)
        #expect(updated.payload.gauge == first.gauge)
        #expect(updated.gaugeAt == Self.now)

        // And the held-back gauge still publishes once its own interval has passed.
        let later = NotifyPublishGate().decide(
            payload: changed,
            since: updated,
            now: Self.now.addingTimeInterval(16 * 60))
        #expect(later.publishesGauge)
    }
}
