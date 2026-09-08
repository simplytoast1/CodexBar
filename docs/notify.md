# Notify!

CodexBar already knows every quota worth knowing, and the phone is where the
user actually looks. [Notify!](https://getnotifyapp.com) already exists, runs on
iPhone and iPad, and has a documented gateway API, so CodexBar can put a quota on
a Lock Screen and a Home Screen — and send an alert that survives a closed lid —
without shipping an iOS app of its own.

---

## The problem

Every surface CodexBar has is on the Mac, and every one of them needs the Mac
awake and in front of you.

| Surface | Failure mode |
|---|---|
| **16 px status item** | One number, on a screen you have to be looking at. |
| **Menu card** | A click on a target you have to aim for, on a machine you have to be sitting at. |
| **User notifications** | Delivered to the Mac. Focus modes swallow them, and a locked screen in another room is a missed alert. |
| **macOS widget** | The best of the four, and still the same machine, the same desk. |

The question the app exists to answer is *"can I start another long run?"*, and
it gets asked away from the desk as often as at it.

**One honest limit, stated up front.** CodexBar publishes from a running Mac. If
the Mac is asleep, nothing refreshes and nothing is sent. What this feature
actually buys is the case where the Mac is awake and you are not at it — in a
meeting, in another room, screen locked. The Home Screen widget shows the last
value CodexBar published, not a live one, and it says so on the phone once that
value goes stale.

## The four surfaces

The gateway derives the Home Screen widget's content contract from the same
module its Live Activity uses: same fields, same caps, same merge rules. So
CodexBar builds the tile once, as one `NotifyTile` that `NotifyPayloadBuilder`
hands to both, and `NotifyGatewayClient` encodes it through the same `tileBody`
for both routes. Building it twice would only produce two things that were meant
to be identical and one day were not, which on a phone reads as two different
pictures of one quota.

- **The Live Activity** is the dense one: the title `CodexBar`, a progress bar, a
  compact reset countdown where a timer would sit, and a row of up to six quota
  windows, each with its own label, value, unit and color. Six is the gateway's
  ceiling and also about the point at which a Lock Screen row stops being
  readable, so the two limits agree.
- **The Home Screen widget** carries that same tile, and differs in when you meet
  it. A Live Activity appears while something is happening; a Home Screen widget
  stays where it was placed and always shows the latest thing stored for it.
  Creating one over the gateway puts nothing on a screen by itself: it fills a
  slot you still place through iOS's own widget picker.
- **The Lock Screen widget** is the glanceable one, and the only surface with a
  shape of its own. Its gauge is a single chosen quota, drawn as a bar on the
  rectangular widget and a ring on the circular one.
- **Notifications** are the only surface that goes and finds you. CodexBar
  already decides when an alert is worth posting — quota warning thresholds,
  session depletion and restore, predictive pace — so this adds a second
  destination to that decision rather than a second decision.

## What the tile shows

Five rules, all in `NotifyPayloadBuilder`:

- **The user's chosen providers lead.** CodexBar tracks far more than six windows
  across its providers and their accounts, so "worst six wins" alone would give a
  row whose membership churns every refresh. Naming instances in the pane keeps
  the same rows in the same order; naming none leaves severity in charge. This is
  the one piece with no counterpart in ClaudeBar, which never had enough
  providers to need it.
- **Within that, the worst quota leads.** Readings sort by status severity, then
  by how little is left. The headline is the first one, and the tile takes its
  tint, its bar and its countdown from it.
- **Percentages are remaining, not used.** A 42% quota publishes `progress: 42`.
  Every other CodexBar surface reads that way, and a full ring meaning a full
  quota is the only intuitive mapping a gauge has.
- **Labels drop the provider name when they can.** A tile covering one provider
  reads `5h 7d`, not `Codex 5h Codex 7d`.
- **Ordering is total**, down to a provider-instance tiebreak. Two payloads built
  from the same readings must compare equal, or the driver would republish
  forever.

Credit balances have no percentage to draw. Their value is the formatted balance
with no unit, and the tile's bar falls through to the worst quota that *does*
have a percentage, rather than vanishing whenever a balance leads.

## Where the numbers come from

`WidgetSnapshot`, not a second pass across the providers.

`UsageStore` already reduces its main-actor usage state to a `Sendable`,
already-filtered `WidgetSnapshot` on every refresh, and that snapshot is what the
macOS widget draws. `NotifyReadingsBuilder` reads it and nothing else, so the
phone and the desktop widget cannot describe one quota differently, and one fix
fixes both. It prefers `usageRows` — the labeled per-window list a provider fills
in — and falls back to the fixed primary/secondary/tertiary slots. Row ids, not
display titles, become quota keys: a key is persisted as half of a gauge
selection and has to survive a relaunch and a change of language.

Publishing hangs off `persistWidgetSnapshot`, which already runs on exactly the
"usage changed" edge and already coalesces back-to-back writes.

## Publish cadence

Quota numbers move on every refresh and the reset countdown moves every minute,
so "publish whenever the payload differs" is a request per refresh, forever.
`NotifyPublishGate` adds four rules on top of the difference:

| Rule | Value | Why |
|---|---|---|
| Minimum gap, tile | 60 s | The tile is a push, so it can afford to be prompt. |
| Minimum gap, gauge | 15 min | iOS decides when a widget redraws, roughly every quarter hour. Pushing faster buys nothing. |
| Minimum gap, Home Screen tile | 15 min | Also a poll, on the same quarter hour and for the same reason. |
| Keep alive, tile and Home Screen tile | 90 min | Two deadlines, both at **two hours**, both measured from the last write: the gateway ends a progress-only Live Activity that has gone that long without an update, and a Home Screen widget's `staleAt` lands there too. Ninety minutes clears both with room to spare. |

The gauge is the one surface with no keep-alive. The gateway documents neither a
reaper nor a freshness deadline for `/widgets`, so there is nothing a heartbeat
there would prevent.

The keep-alive is why `NotifyPublishDriver` runs a one-minute tick at all. Both
time-based rules are unreachable from state changes alone: a change the gate
suppressed for arriving too soon has to be offered again once its interval has
passed, and nothing in observable state fires on the mere passage of time.

Saving credentials or pressing **Publish Now** bypasses the gate entirely by
clearing the record, because waiting a quarter of an hour to find out whether a
token works is not an answer. The pane does that through
`NotifyPublishDriver.publishNow()` rather than publishing for itself: the driver
holds the stored handles and the single in-flight publish, and two publishers
racing over one nil activity id is precisely how a phone ends up with two Live
Activities.

## Recovery

Each failure mode has a remedy of its own, and each is a distinct case on
`NotifyPublishError` for exactly that reason.

| What happened | HTTP | What CodexBar does |
|---|---|---|
| The user swiped the tile away | 410 | Forget the stored activity id and start a fresh tile, once. A retry loop here is a retry loop against the gateway. |
| A stored handle is refused | 403 | Forget that one handle, so the next publish creates a replacement. The gateway answers a missing token, a wrong token, an unknown id and somebody else's id identically, so a 403 is not evidence the credentials are bad: far more often the user deleted that one tile or widget in the Notify! app. The other surfaces' handles are left alone, because clearing one would abandon something alive and put a duplicate beside it. |
| Push-to-start backoff | 429 | Suppress tile writes until the gateway's own wait has passed. Both widgets keep publishing. |
| The phone has never opened Notify! | 409 | Report it and stop. No Live Activity can start until the device has a push-to-start credential, which only opening the app once produces. |
| Apple never answered a start | 502 `unknown` | Keep the activity id the gateway returned and update it next tick. Starting again could leave two tiles. |
| Apple refused a start | 502 `not-delivered` | Wait. No tile exists, so starting again is safe, but every unanswered start counts toward the same ladder as a 429, so the gateway's own `retryAfterSeconds` is honored and 30 minutes assumed when it names none. |
| Home Screen widgets are not being served | 503 | Pause that one surface for six hours and say so at info level, not as an error. This is the gateway's own kill switch, and nothing on this Mac moves it. The other surfaces are untouched. |

Some failures are not worth discovering over the wire. A Live Activity aimed at a
`GRP`, `MC` or `WB` id is refused locally, because the outcome is already known.
Either widget aimed at a `GRP` id is refused for a different reason: a group is
not a device and owns no widget list to write into. What the user reads in both
cases is the id's own reason, which names the kind of device they linked, rather
than a status code that reads as CodexBar failing at something it should have
managed.

## Privacy

Every other network call CodexBar makes fetches a quota from the provider that
owns it. This one is the first that sends CodexBar's own state outward, to a
service that is neither the user's machine nor a provider they already have an
account with, so it is worth being explicit.

- **What leaves the machine:** provider names, quota window labels, remaining
  percentages or credit balances, and reset countdowns. For an alert, the same
  notification text CodexBar shows on the Mac. No prompts, no repository names,
  no file paths, no session content.
- **Account labels are dropped**, even when `hidePersonalInfo` is off. That
  setting governs what appears on this Mac's own screen; sending an email address
  to a gateway is a stronger step than showing it on the machine it came from,
  and the phone alert reads perfectly well without it. The outbound copy is built
  with the label omitted rather than stripped back out of a finished sentence.
- **Where it goes:** `push.getnotifyapp.com`, a third-party service, and from
  there to the user's own phone.
- **Off by default.** `notifyEnabled` is false and stays false until the user
  links a device. A feature that talks to someone else's server cannot ship
  enabled.
- **The token is a secret.** It goes to the Keychain under the
  `notify-device-token` account, `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`,
  and never to defaults. It is never logged, and neither is the device id above
  debug level.
- **Nothing here syncs.** `SyncedPreferences` is an explicit allow-list and no
  `notify` key is on it. That is deliberate: the three handles name a tile and
  two widgets *this* Mac created, and a second Mac adopting them would put two
  publishers on one Live Activity.

## Architecture

Notify! is a **destination**, not a provider. Nothing in this feature reads a
quota from anywhere: it reads the ones already in the widget snapshot.

```
Sources/CodexBarCore/Notify/
├── NotifyLimits.swift            # the gateway's field limits, enforced at construction
├── NotifyDeviceLink.swift        # device id + token; NotifyDeviceKind; NotifyDeviceInfo
├── NotifyTile.swift              # NotifyMetric, NotifyTile: the content both tiles carry
├── NotifyGauge.swift             # the Lock Screen widget's content; progress is the gauge
├── NotifyNotification.swift      # one push through /notify-json
├── NotifyQuotaStatus.swift       # severity thresholds, tint hex, SF Symbol
├── NotifyPayload.swift           # readings, both selections, the payload
├── NotifyReadingsBuilder.swift   # WidgetSnapshot to readings; the seam
├── NotifyPayloadBuilder.swift    # readings to one tile + a gauge; the whole decision layer
├── NotifyAlertBuilder.swift      # a CodexBar alert to an outbound notification
├── NotifyPublishGate.swift       # whether a payload is worth a request; pure, clock free
├── NotifyPublishError.swift      # every way a publish fails, and the remedy each implies
├── NotifyPublishing.swift        # the protocol; the app layer's only view of the API
└── NotifyGatewayClient.swift     # the only file that knows HTTP exists

Sources/CodexBar/
├── NotifyTokenStore.swift        # the Keychain-backed device token
├── SettingsStore+Notify.swift    # the notify* keys; the token is not among them
├── NotifyPublishDriver.swift     # the tick, the handles, the single in-flight publish
├── UsageStore+Notify.swift       # hooks the driver into persistWidgetSnapshot
├── UsageStore+NotifyAlerts.swift # relays quota warnings, depletion and pace to the phone
└── PreferencesNotifyPane.swift   # link, verify, surface switches, pickers, publish now
```

Everything that decides anything is a pure value type in `CodexBarCore`, with no
clock, no network and no settings lookups of its own.
`NotifyGatewayClient.failure(status:data:retryAfterHeader:)` is static and takes
the raw body, so every status code is driven through it without a network stub.

## Prior art

The gateway is the prior art, read from its own OpenAPI document
(`https://getnotifyapp.com/apidocs/openapi.json`). Host
`https://push.getnotifyapp.com`. These routes declare `security: []`: there is no
bearer token, and the per-device secret travels in `?token=`.

### The id namespaces, and which of them have a screen

| Id | What it names | Notification | Live Activity | Lock Screen widget | Home Screen widget |
|---|---|---|---|---|---|
| `GRP` + 5 | A notification group | yes | no | no | no |
| `MC` + 14 | A push-capable Mac listener | yes | no | yes | yes |
| `WB` + 14 | A web push browser | yes | no | yes | yes |
| `IO` + 14 | An iPhone or iPad | yes | yes | yes | yes |
| 8 characters | The legacy app device format | yes | yes | yes | yes |
| anything else | A format newer than this document | yes | yes | yes | yes |

Note which way round the Live Activity rule is written. The namespaces that
*cannot* show one are named and everything else is allowed, rather than the
reverse, because app device ids are not one fixed shape: the legacy format is 8
characters, `IO` is 16, and more will follow. A list of what may pass would
refuse a real phone on the day Notify! mints a format CodexBar has never heard
of, and a refused phone reads as CodexBar being broken.

`GRP` plus 5 is itself eight characters, so the two grammars genuinely overlap.
The prefix is tested first, which is the gateway's own tiebreak.

### The fields are the type

There is no tile type and no widget display format. Which fields are populated
decides how the thing draws, and they compose: a title plus a progress bar plus a
metrics row **is** the metrics tile.

Saying nothing is load bearing in a second way, and it cuts both ways. Updates
are JSON merge-patch: an absent field is left alone, a value replaces, an
explicit `null` deletes. So `NotifyGatewayClient` deliberately never mentions
`status`, `endsIn`, `steps`, `step` or `button`, and a CodexBar update can share
a tile with whatever else the user configured. But the same rule makes silence
dangerous for the fields CodexBar *does* drive: omitting one it previously set
does not clear it, it freezes it. So every field CodexBar owns is stated on every
write, as an explicit `null` when it has no value. `title` is the one exception:
the gateway treats it as an identity and refuses to clear it.

### Two dialects, and why CodexBar only uses one

All three write routes take either a device id (the *upsert* dialect) or a handle
(the *precise* dialect). The upsert dialect is the shorter code and it is wrong
here: a user with a Notify! tile running from some other script of their own
would find CodexBar had silently taken it over. So CodexBar always creates its
own — the first write carries `"new": true` against the device id, the returned
`LA…`, `WG…` or `SW…` handle is persisted, and every write after that addresses
the handle. `new` never appears on an update, where it would leave the device
with two tiles.

### The one call that is rate limited

`GET /link?id=&token=` validates a pair and describes the device it names, and
the gateway allows **five calls a minute per IP**. It lives behind the pane's
**Verify Device** button and nothing else. Nothing on a timer may call it.

## Testing

The whole decision layer is in `CodexBarCore` and testable without a network, a
clock or a Keychain:

- `NotifyDeviceLinkTests` — parsing and the namespace rules
- `NotifyLimitsTests` — field caps, including UTF-8 byte truncation
- `NotifyPublishGateTests` — intervals, keep-alive, per-surface record merging
- `NotifyPayloadBuilderTests` — ordering, selection, labels, words
- `NotifyReadingsBuilderTests` — the `WidgetSnapshot` seam
- `NotifyGatewayClientTests` — routes, bodies, and every status code
- `NotifyAlertBuilderTests` — interruption level and threading
- `NotifySettingsStoreTests` — defaults, handle lifecycle, token storage, sync
- `NotifyPublishDriverTests` — what is written when, and every failure branch

Every test that touches credentials uses `InMemoryNotifyTokenStore`. Nothing in
the suite reaches the real Keychain, and nothing calls a live gateway.
