# Research: a SwiftUI client (macOS and iOS) for a Helyx server

Date: 2026-09-26. All versions and dates were read on this date from the GitHub API (`gh api repos/<repo>/releases`), the Hex API (`https://hex.pm/api/packages/<name>`), or the cited page. "Unverified" marks a statement that this note did not confirm from a primary source.

Context from the repo: `docs/features/session-snapshot.md` already defines `Helyx.Session.subscribe/1 -> {:ok, %Snapshot{seq: ...}}` and the rule "drop each event with `seq <= snapshot.seq`". Remote transport is issue #116 (the doc lists it as out of scope). The Swift client needs the same three things over a wire: join (snapshot + seq), an ordered event stream, and session operations.

---

## 1. Transport between a Swift client and an Elixir server

### Options

**A. Phoenix Channels over WebSocket**

| Library | Version, date | Notes |
| --- | --- | --- |
| davidstump/SwiftPhoenixClient | 5.3.5, 2025-01-13 (last release). Repo last push 2026-02-12 (dependabot). 530 stars. | Callback API. `Package.swift` on `master`: iOS 10, macOS 10.12. A `6.x` / `6x/swift-6` branch has Swift 6 work; last commit 2025-10-18, "WIP streams for events". Not released. Open crash issues: "URLSessionTransport: EXC_BAD_ACCESS crash in delegate handling" (2025-08-10) and "Socket.onConnectionError crashes intermittently (EXC_BAD_ACCESS)" (2026-09-08). Source: https://github.com/davidstump/SwiftPhoenixClient |
| jvdvleuten/PhoenixNectar | 0.1.0 (tag). Repo created 2026-03-07, last push 2026-06-20. 10 stars. | Swift 6 strict concurrency, actor runtime, typed `Push<Request, Response>`, auto reconnect and rejoin, `AsyncStream` state. iOS 16+, macOS 15+. Announced 2026-03-18: https://elixirforum.com/t/phoenixnectar-swift-6-client-for-phoenix-channels/74697 . Young, one author. |
| shareup/phoenix-apple | v10.0.3, 2026-06-26. 3 stars. | async/await API per https://swiftpackageregistry.com/shareup/phoenix-apple (API detail unverified). Small user base. |
| liveview-native/phoenix-channels-client | no release. Last push 2026-02-06. | Rust (tokio) client, README says "still a work-in-progress". Used by LiveView Native core through UniFFI. Not a Swift package for direct use. |

Server: Phoenix 1.8.15 (Hex, 2026-09-25). Phoenix Channels have no built-in replay. The client must send its last seq in the join params. SwiftPhoenixClient supports this: `Channel.params` is mutable and the rejoin push reads it (`Sources/SwiftPhoenixClient/Channel.swift`, lines 66-68, master).

Cost for Helyx: `AGENTS.md` says Phoenix is not in core and arrives later as a Transport plugin. Channels add the Phoenix protocol (join/reply/heartbeat/refs) on top of what Helyx needs.

**B. Plain WebSocket**

- Server without Phoenix: Bandit 1.12.5 (Hex, 2026-08-20) and websock_adapter 0.6.0 (Hex, 2026-04-15), with Plug 1.20.3 (2026-07-09). A `WebSock` handler is one module.
- Client: `URLSessionWebSocketTask` (Foundation). async `send`/`receive` (availability iOS 15 / macOS 12 is from memory; unverified in this session). No reconnect and no heartbeat logic: the app writes them.
- Client, newer: Network framework `NetworkConnection` with structured concurrency, iOS/macOS 26+ (WWDC25 session 250, https://developer.apple.com/videos/play/wwdc2025/250/). Whether it has a WebSocket protocol option: unverified.
- Replay: the app defines it. For example the first frame is `{"op":"join","session":..., "after_seq": n}`.

**C. HTTP + Server-Sent Events (SSE), with POST for operations**

- Event stream: `GET /sessions/:id/events` with `text/event-stream`. Each event carries `id: <seq>`. The SSE standard sends `Last-Event-ID` on reconnect (https://html.spec.whatwg.org/multipage/server-sent-events.html ).
- Operations: `POST /sessions/:id/prompt`, `/steer`, `/follow_up`, `/abort`, `/model`. Each gets a typed reply (ok or error). This maps well to `Helyx.Session` calls, which are `GenServer.call` with a reply.
- Server: a Plug chunked response on Bandit. No new dependency.
- Swift clients:
  - mattt/EventSource 1.5.1, 2026-08-17. Reconnect with retry, all SSE fields (`id`, `event`, `data`, `retry`), `AsyncSequence`, all Apple platforms. https://github.com/mattt/EventSource
  - Recouse/EventSource 0.1.9, 2026-08-27. Swift concurrency, iOS 13+, macOS 10.15+. https://github.com/Recouse/EventSource
  - launchdarkly/swift-eventsource 3.3.1, 2026-09-16 (the release before was 3.3.0, 2024-05-31). https://github.com/launchdarkly/swift-eventsource
  - swift-openapi-runtime 1.12.1 (2026-09-02) decodes SSE with JSON data: `asDecodedServerSentEventsWithJSONData(of:decoder:)` (`Useful-OpenAPI-patterns.md` in apple/swift-openapi-generator). It does not reconnect. The app writes the reconnect loop.
  - swift-openapi-urlsession 1.3.1 (2026-06-23): "Streaming support only available on macOS 12+, iOS 15+" (README).

### Reconnect and replay (all options)

Helyx already has the gap-free rule for one client in one node. Over a network, two cases exist:

1. The server still has the events after `after_seq`: it sends them, then the live stream. This needs a bounded per-session event buffer on the server (a new bound for the feature doc: count or bytes).
2. The server no longer has them (buffer overflow, server restart): it sends a new snapshot. The client replaces its state.

Case 2 alone is correct and simpler. Case 1 is an optimization for a long transcript on a phone. Start with case 2.

### iOS background limits

- "WebSocket tasks are not supported in background sessions" and "The key factor here is not foreground/background but running/suspended" (Apple DTS, Quinn, https://developer.apple.com/forums/thread/716118 , read 2026-09-26).
- A suspended app loses all its sockets. `UIApplication.beginBackgroundTask` gives a short extension (tens of seconds, same thread and https://developer.apple.com/forums/thread/85066 ).
- The same limit applies to WebSocket and SSE. So the client must reconnect and rejoin when `scenePhase` becomes `.active`. A long agent turn that ends while the phone is locked can reach the user only through a push notification (APNs). APNs is out of scope for a first spike.

### Recommendation

**HTTP + SSE for events, POST for operations**, on Bandit/Plug, as the first Transport plugin.

Reasons:
- No Phoenix in core, and no new server dependency.
- One schema tool (OpenAPI) types both the operations and the event payloads for Swift (section 2).
- `Last-Event-ID` / `id:` is a standard place for the seq.
- Each operation gets its own typed reply and HTTP status. With a WebSocket, the app must build request ids and reply matching.
- `curl -N` can debug the stream. A browser `EventSource` can use the same endpoint later.
- The limit: SSE is one-way. That is fine here because operations are rare and small, and events are many.

Choose a plain WebSocket instead if a later feature needs high-rate client-to-server messages (for example live typing). Do not choose Phoenix Channels for this client now: the mature Swift library has a callback API, an unreleased Swift 6 branch, and open crash issues, and the Swift 6 libraries are months old with few users.

---

## 2. Schema and code generation

### Options

- **Apple swift-openapi-generator** 1.13.1 (2026-09-01); runtime 1.12.1 (2026-09-02); URLSession transport 1.3.1 (2026-06-23). https://github.com/apple/swift-openapi-generator
  - Supports OpenAPI 3.0.3 and 3.1.0 (`Supported-OpenAPI-features.md`). 3.2 is not listed there (unverified whether it works).
  - `oneOf` with a `discriminator` is supported ("each child must be a reference to an object schema"). This gives a Swift enum for a tagged event union such as `{"type":"text_delta", ...}`.
  - Event streams: SSE, JSON Lines, JSON Sequence. OpenAPI 3.0/3.1 cannot type the items of a stream, so the doc puts the event schema in `components/schemas` and the app decodes the body with `asDecodedServerSentEventsWithJSONData(of: Components.Schemas.Event.self)`. Example packages: `event-streams-client-example`, `streaming-chatgpt-proxy`.
  - Runs as a SwiftPM build plugin. Works in an Xcode multiplatform app target.
- **quicktype** v26.0.0 (2026-07-20). JSON Schema or JSON samples to Swift `Codable`. https://github.com/glideapps/quicktype . It generates types only (no client). Its handling of discriminated unions in Swift: unverified.
- **AsyncAPI**: generator 3.4.1 (2026-09-17). The model generator Modelina (v6.0.0-next.18, 2026-09-01) has no Swift generator. Its `src/generators` folder lists cplusplus, csharp, dart, go, java, javascript, kotlin, php, python, rust, scala, typescript (read 2026-09-26). No official Swift template was found. So AsyncAPI gives documentation only, not Swift code.
- **Elixir side**:
  - open_api_spex v3.22.4 (2026-08-30). Its `%OpenApi{}` struct defaults to `openapi: "3.0.0"` (`lib/open_api_spex/open_api.ex`). Issue "Support OpenAPI 3.1 specification" (#496) is open since 2022-09-19. It builds the spec from Elixir modules and can cast/validate requests in Plug.
  - JSV v0.25.0 (2026-09-25), a JSON Schema validator (https://github.com/lud/jsv ). ex_json_schema v0.11.5 (older drafts).
  - Hand-written spec file: one `openapi.yaml` in the repo.

### Recommendation

Hand-write one OpenAPI 3.1 file as the wire contract. Put every event type under `components/schemas` as one `oneOf` with a `type` discriminator. Generate Swift with swift-openapi-generator. On the Elixir side, add one test that encodes a sample of each event and operation reply and validates it against the file with JSV.

Reason: the wire contract is small. A hand-written file is the single source; the Swift side gets checked types, and the Elixir test catches drift. open_api_spex pulls the spec into Elixir macros and stays on 3.0. AsyncAPI has no Swift generator. quicktype gives types but no client.

---

## 3. LiveView Native (DockYard)

- `liveview-native/live_view_native` (the Elixir library) is **archived** on GitHub. Last push 2025-09-11 (`gh api repos/liveview-native/live_view_native`, `archived=true`, read 2026-09-26).
- Hex: latest stable 0.3.1 (2024-10-02); latest pre-release 0.4.0-rc.1 (2025-03-04). About 63 downloads a week (https://hex.pm/api/packages/live_view_native , read 2026-09-26).
- The SwiftUI client `liveview-native/liveview-client-swiftui`: not archived, but the last commit on `main` is 2025-06-19. Same 0.4.0-rc.1 tag (2025-03-04).
- DockYard's last public statements found were positive ("LiveView Native Is Here!", 2024-09-09, https://dockyard.com/blog/2024/09/09/liveview-native-is-here ; a forum thread of May 2025, https://elixirforum.com/t/is-liveview-native-realistic-in-2025/70969 ). No announcement of the archive was found (unverified why it was archived).

Recommendation: **not an option.** The core library is archived and has had no stable release since 2024-10. It also needs Phoenix LiveView on the server and renders server-side templates, which conflicts with the Helyx model (server owns state, client renders from an event stream, Phoenix not in core).

---

## 4. SwiftUI rendering of a long, streamed transcript

### Markdown and code blocks

| Library | Version, date | Notes |
| --- | --- | --- |
| gonzalezreal/textual | 0.5.0, 2026-06-15 | Successor of MarkdownUI. Keeps SwiftUI's `Text` pipeline. `InlineText` and `StructuredText`. Native text selection, tables, code blocks, syntax highlighting (bundled Prism grammars, `Scripts/bundle-prism.sh`), math. Parses with Foundation `AttributedString`. Requires iOS 18, macOS 15 (`Package.swift`). Pre-1.0. https://github.com/gonzalezreal/textual |
| gonzalezreal/swift-markdown-ui (MarkdownUI) | 2.4.1, 2024-10-13 | README: "MarkdownUI is in maintenance mode. New development is happening in Textual". Issue #426 (open, 2025-10-21): "swift-markdown-ui struggles with long Markdown text". |
| LiYanan2004/MarkdownView | 3.0.0, 2026-07-05 | Active. Built on swift-markdown. |
| LiYanan2004/RichText | 1.0.0, 2026-06-29 | Platform text view wrapper for range text selection on iOS and macOS. |
| swiftlang/swift-markdown | active (push 2026-09-26) | Parser only (cmark-gfm). Gives an AST to build views from. |
| Apple `AttributedString(markdown:)` + `Text` | OS | `Text` renders inline styles only. Block structure (`presentationIntent`: lists, code blocks, tables) is parsed but not rendered (https://fatbobman.com/en/posts/attributedstring/ ; https://developer.apple.com/forums/thread/686066 ). |

Syntax highlighting alone: Highlightr 2.3.0 (2025-06-18, highlight.js in JavaScriptCore); Splash 0.16.0 (2021-06-14, Swift only, few languages, inactive); HighlightSwift v1.1.0 (2024-06-25). Textual includes its own highlighter.

Text selection limit: "SwiftUI's `.textSelection(.enabled)` on iOS can only select everything; range selection is only supported on macOS" (https://fatbobman.com/en/posts/a-deep-dive-into-swiftui-rich-text-layout/ , 2025-12-03). Textual claims native selection; its behavior on iOS was not tested here (unverified).

### Performance with many messages and fast streaming

- WWDC25: "On macOS, lists of over 100,000 items now load 6x faster ... update up to 16x faster"; nested lazy stacks now load lazily; lazy stacks prefetch (https://developer.apple.com/videos/play/wwdc2025/256/ ; summary https://mjtsai.com/blog/2025/06/18/swiftui-at-wwdc-2025/ ).
- WWDC26 session 321 "Dive into lazy stacks and scrolling with SwiftUI" (https://developer.apple.com/videos/play/wwdc2026/321/ ): off-screen heights are estimated, so do not use absolute content offset; use `onScrollTargetVisibilityChange` and `ScrollPosition`; filter data before the stack, not with `if` in a row body; set up row state in `init`, not `onAppear`; keep state that must survive scrolling out of `@State` in rows. It does not cover bottom-anchored chat scrolling.
- Known general problem: re-parsing the whole growing markdown message on each delta is O(n^2) (examples: https://github.com/earendil-works/pi/issues/8822 ; https://github.com/gonzalezreal/swift-markdown-ui/issues/426 ).
- Apple forum report of jitter with large data in `List` and `LazyVStack`: https://developer.apple.com/forums/thread/718929 (older; state in 2026 unverified).

### Shared macOS and iOS codebase

One Xcode multiplatform app target builds both. Differences to plan for: text selection (above); Info.plist keys for local network and ATS (section 5; macOS 15 added local network privacy to the Mac); keyboard shortcuts and menus on macOS; `NavigationSplitView` collapses to a stack on iPhone. Textual sets the floor at iOS 18 / macOS 15.

### Recommendation

- `ScrollView` + `LazyVStack`, one row per **block**, not per message. Stable ids from the server (turn id + block index). A finished block never changes, so SwiftUI skips it.
- Only the tail block receives deltas. Append deltas to a buffer and publish to the view at most every 30-60 ms (engineering judgment, not a measured value). Parse markdown only for the tail block.
- Render text with Textual `StructuredText`. Render typed blocks (diff, table) as native SwiftUI views from typed events, not from markdown. The server already knows the type, so the client need not parse a diff.
- Scroll to the bottom with `ScrollPosition` while the user is at the bottom; stop when `onScrollTargetVisibilityChange` shows the last block is not visible.
- Measure with Instruments on a real iPhone with a 1,000-message transcript before any custom work.

---

## 5. Reaching the Mac server from the iPhone

### Facts

- Local network privacy (TN3179, https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy , read 2026-09-26 through its JSON form):
  - "A local network is an IP network associated with a broadcast-capable network interface. Such interfaces include Wi-Fi and Ethernet, but not cellular (WWAN) or VPN."
  - An app that connects to a local address or uses Bonjour triggers the Local Network alert. Add `NSLocalNetworkUsageDescription`. For Bonjour browse or register, list the service types in `NSBonjourServices`.
  - macOS got local network privacy in macOS 15 (WWDC24 session 10123). Command-line tools and launchd daemons get automatic access on macOS. So a `mix` or release process on the Mac is allowed; a signed Mac app that hosts the server is not (it gets the prompt).
  - If an iOS app is in the background and its privilege is undetermined, the system denies the operation with no alert.
- ATS (`NSAllowsLocalNetworking`, https://developer.apple.com/documentation/bundleresources/information-property-list/nsapptransportsecurity/nsallowslocalnetworking ): "In iOS 17, iPadOS 17, and macOS 14, ATS no longer allows connections to IP addresses by default." `NSAllowsLocalNetworking` allows unqualified names, `.local` names, and IP addresses.
- Bonjour advertise from Elixir: mdns_lite 0.9.2 (Hex, 2026-05-20), or the macOS `dns-sd -R` command. Client browse: `NWBrowser`, or `NetworkBrowser` on iOS/macOS 26.
- Tailscale:
  - With MagicDNS and HTTPS certificates on, each node gets a `<machine>.<tailnet>.ts.net` name and a Let's Encrypt certificate (https://tailscale.com/docs/how-to/set-up-https-certificates , seen in search results 2026-09-26; page not opened).
  - `tailscale serve` proxies HTTPS to a local port and "adds a few Tailscale identity headers", `Tailscale-User-Login`, `Tailscale-User-Name`, `Tailscale-User-Profile-Pic`. It advises that the backend "only listen on localhost" when it trusts these headers (https://tailscale.com/kb/1312/serve ).
  - Tailscale on iOS is a VPN. By the TN3179 definition, traffic over it is not local network traffic, so no Local Network alert (inference, not tested).
- Relay (a public server that both sides connect to): needs hosting, TLS, and end-to-end auth. Not needed for one user.

### Auth, in short

- The Helyx server listens on `127.0.0.1` by default. It never exposes plain HTTP to Wi-Fi without a token.
- LAN mode: the Mac shows a pairing code or QR code with a random bearer token (at least 128 bits). The phone stores it in the Keychain and sends `Authorization: Bearer <token>` on every request. Traffic is plain HTTP on the LAN unless the server adds TLS; the token is visible to others on the same Wi-Fi. This is acceptable only for a home network spike.
- Tailscale mode: server on localhost, `tailscale serve` in front. TLS comes from Tailscale. The server checks `Tailscale-User-Login` against an allow list, or keeps the bearer token as well.

### Recommendation

**Tailscale** as the main path. Reasons: it works on Wi-Fi and cellular; it gives real TLS, so ATS needs no exceptions; it avoids the Local Network alert and the `NSBonjourServices` list; the server can stay on localhost. Add a bearer token in the server anyway, so that auth does not depend on one proxy.

For the first spike on one Mac, run the iOS Simulator (it reaches `localhost` on the Mac) and skip network work.

---

## Proposed minimal stack for a first spike

Goal: join a session, show a streamed transcript with one typed block, send a steer.

Server (a new Transport plugin module in `plugins/bundled`, for example `Helyx.Transport.HTTP`):
- Bandit + Plug. No Phoenix.
- `GET /sessions/:id/events?after_seq=n`: calls `Helyx.Session.subscribe/1`, sends `event: snapshot` first (with `id: <seq>`), then each event as `event: <type>`, `id: <seq>`, `data: <json>`. Ignore `after_seq` in the spike; always send a snapshot (case 2 in section 1).
- `POST /sessions/:id/steer` with `{"text": ...}`: calls the session, returns `202` or a typed error.
- Bearer token check in one plug. Listen on `127.0.0.1`.
- Bounds to state in the feature doc: max request body size, max SSE write backlog per client (drop the client when it is slow), heartbeat comment interval (for example `:\n` every 15 s).

Contract:
- `openapi.yaml` (3.1) with the two paths and `components/schemas/Event` as a `oneOf` with a `type` discriminator: `snapshot`, `text_delta`, `block_start`, `block_end`, and one typed block, `diff`.
- One Elixir test validates encoded samples with JSV.

Client (one Xcode multiplatform target, iOS 18 / macOS 15):
- swift-openapi-generator + swift-openapi-urlsession for the types and the POST.
- The event stream through the generated client and `asDecodedServerSentEventsWithJSONData`, with a small reconnect loop in an actor. If that loop becomes complex, switch the stream to mattt/EventSource.
- An `@Observable` store: blocks array, `seq`, drop events with `seq <= store.seq`, reconnect on `scenePhase == .active`.
- `ScrollView` + `LazyVStack` of blocks. Text blocks with Textual `StructuredText`. The `diff` block as a native view (monospaced lines, red and green backgrounds).
- A text field and a Steer button that POSTs.
- Run in the iOS Simulator and as a Mac app against `localhost`. Add Tailscale after the spike works.

Skipped for the spike: replay from a server buffer, APNs, Bonjour, other operations (prompt, follow-up, abort, model switch are the same POST shape as steer), paging of long transcripts.
