# Research: agent-to-UI protocols and generative UI standards (2026)

Date of research: 2026-09-26. All pages were read on this date unless the note gives another date.

Scope. Helyx wants server-driven UI at two levels:

- Level 1: the server sends actions and commands as data.
- Level 2: the transcript holds typed content blocks (diff, table, form, image, progress). The blocks come from a small fixed component catalog. Each client renders them natively. Each block has a plain-text fallback.

Full-screen SDUI is out of scope.

Legend: **[unverified]** marks a claim that I could not confirm from a primary source.

---

## 1. Google A2UI (Agent-to-User Interface)

### What it is

A2UI is a declarative JSON format. An agent uses it to describe UI. The client renders the UI with its own components. The spec says: "A2UI is a declarative data format, not executable code."
Source: https://github.com/google/A2UI (README, read 2026-09-26). The project now also appears at https://github.com/a2ui-project/a2ui.

### Versions and dates

- Public open-source release: January 2026, per a secondary source. https://hia2ui.com/blog/a2ui-official-public-release/ **[unverified against a Google primary source]**.
- v0.9: Google Developers Blog, April 17, 2026. https://developers.googleblog.com/a2ui-v0-9-generative-ui/
- v0.9.1: the current production release. v1.0 is a release candidate. v0.8 is legacy. https://github.com/google/A2UI (README), https://www.infoq.com/news/2026/07/google-a2ui-genui/ (InfoQ, July 2026).
- v1.0 stable: targeted for Q4 2026. The roadmap says "stability guarantees, migration path from v0.9, comprehensive test suite, and certification program for renderers." https://a2ui.org/roadmap/ (page says "Last Updated: June 2026").
- The README calls the project an "Early stage public preview". "Specification and implementations are functional but are still evolving."

### License

Apache 2.0. https://github.com/google/A2UI

### Data shape (v0.9)

The server streams JSONL. Each line is one message. There are four server-to-client messages: `createSurface`, `updateComponents`, `updateDataModel`, `deleteSurface`. Source: https://a2ui.org/specification/v0.9-a2ui/

```json
{"version":"v0.9","createSurface":{"surfaceId":"card1","catalogId":"https://a2ui.org/specification/v0_9/catalogs/basic/catalog.json","sendDataModel":true}}
{"version":"v0.9","updateComponents":{"surfaceId":"card1","components":[
  {"id":"root","component":"Column","children":["name"]},
  {"id":"name","component":"Text","text":{"path":"/user/name"}}]}}
{"version":"v0.9","updateDataModel":{"surfaceId":"card1","path":"/user/name","value":"Jane Doe"}}
```

The client sends an `action` back when the user acts:

```json
{"name":"submit_form","surfaceId":"contact_form_1","sourceComponentId":"submit_button",
 "timestamp":"2026-02-02T15:17:00Z","context":{"formId":"contact_form_1"}}
```

Key points of the shape (same source):

- Components are a flat list with ids. Parents refer to children by id. This makes streaming and partial updates easy.
- Data binding uses JSON Pointer paths. Input components write to a local data model. The client sends the model to the server only with an action (or with every message when `sendDataModel` is true).
- The v1.0 RC adds bidirectional RPC (`callRendererFunction`, `callAgentFunction`), removes `theme` from `createSurface`, allows initial components and data inside `createSurface`, allows `catalogId` per component, and changes the MIME type to `application/a2ui+json`. Source: https://a2ui.org/specification/v1.0-evolution-guide/ (summary from search result; I did not read the full page).

### Who owns the catalog

The client owns it. The server names a `catalogId` in `createSurface`. The client advertises `supportedCatalogIds` in its capabilities. The `catalogId` is "a string identifier, not a resolvable URI". Source: https://a2ui.org/specification/v0.9-a2ui/

v0.9 renamed the "Standard" catalog to "Basic". The intent: organizations bring their own design system, and agents use it. The Basic catalog is optional. Source: https://developers.googleblog.com/a2ui-v0-9-generative-ui/

### Streaming

JSONL over any transport. Google lists "MCP, Websockets, REST, AG UI, A2A". Source: https://developers.googleblog.com/a2ui-v0-9-generative-ui/. The spec asks clients to render placeholders for references that have not arrived yet ("progressive rendering"). Source: https://a2ui.org/specification/v0.9-a2ui/

### Security model

Data, not code. The client renders only components from a catalog that it trusts. No script from the agent runs. Source: https://github.com/google/A2UI (README). Critics raise UI impersonation risk (an agent can draw a UI that looks like a trusted UI). Source: InfoQ, https://www.infoq.com/news/2026/07/google-a2ui-genui/

### Renderers

Official, from https://github.com/google/A2UI/blob/main/docs/public/reference/renderers.md (read 2026-09-26):

| Renderer | Status |
|---|---|
| React, Lit, Angular | v0.8, v0.9.1 stable; v1.0 planned |
| Flutter GenUI SDK | v0.8, v0.9.1 stable; v1.0 planned |
| Jetpack Compose | v0.9.1 alpha |
| SwiftUI (iOS/macOS) | v1.0 planned, no status |

The roadmap put SwiftUI in Q2 2026 (https://a2ui.org/roadmap/). The renderer list in September 2026 still shows no official SwiftUI release. So the official SwiftUI renderer is late.

Community Swift renderers:

- `BBC6BAE9/a2ui-swift`: MIT, about 62 stars, version 0.3.0. Supports A2UI v0.9 and v0.9.1. SwiftUI, UIKit, and AppKit through a shared core. iOS 17+, macOS 14+, and others. 17 built-in components (Text, Image, Row, Column, List, Card, Tabs, Button, TextField, CheckBox, Slider, DateTimeInput, ChoicePicker, and more). "300+ tests". Listed in the official ecosystem. https://github.com/BBC6BAE9/a2ui-swift
- `vpm238/a2ui-swiftui`: iOS 17+, macOS 14+, no third-party dependencies, own small component set. https://github.com/vpm238/a2ui-swiftui (from search result; I did not read the README).
- AGenUI: cross-platform native renderer for iOS, Android, HarmonyOS (v0.9). Source: the official renderers list above.
- Stream published an iOS + server A2UI tutorial. https://getstream.io/blog/a2ui-chat-integration/ (search result only).

### Text fallback

No text fallback field exists in the message shape. The spec asks for placeholders and error reports, not for alternative text. Source: https://a2ui.org/specification/v0.9-a2ui/. A Helyx block would need its own `text` field next to the A2UI payload.

### Fit for Helyx

- Level 1 (actions as data): partial fit. The `action` message is a clean client-to-server shape. But A2UI actions start from a user click on a surface. A2UI has no model for server-sent commands that a client runs (for example "open file", "focus session"). The v1.0 RC `callRendererFunction` comes close.
- Level 2 (typed blocks): good fit for the idea, weak fit for the details. The catalog model matches Helyx exactly: client owns the catalog, server names components, client renders natively. But the Basic catalog is layout-level (Row, Column, Text, Button). It has no Diff, Table, or Progress component. Helyx would define its own catalog. A2UI also models a surface as a mutable component tree with a data model. That is more than a transcript block needs. The spec is pre-1.0 and changes each version (v0.8, v0.9, v0.9.1, v1.0 RC in about nine months).

---

## 2. MCP Apps (and MCP-UI)

### What it is

MCP Apps is the first official MCP extension (SEP-1865). A tool declares a UI resource with a `ui://` URI. The host renders that resource in a sandboxed iframe. The UI talks to the host with MCP JSON-RPC over `postMessage`.
Sources: https://modelcontextprotocol.io/seps/1865-mcp-apps-interactive-user-interfaces-for-mcp, https://github.com/modelcontextprotocol/ext-apps/blob/main/specification/2026-01-26/apps.mdx

### Versions and dates

- Proposal announced 2025-11-21. https://blog.modelcontextprotocol.io/posts/2025-11-21-mcp-apps/
- Stable spec: 2026-01-26. https://github.com/modelcontextprotocol/ext-apps/blob/main/specification/2026-01-26/apps.mdx
- A secondary source names a "2026-07-28" spec revision. https://ecorpit.com/mcp-apps-server-rendered-ui-extension-build-guide-2026/ **[unverified]**.

### Data shape

Resource:

```json
{"uri":"ui://weather-server/dashboard-template","name":"weather_dashboard",
 "mimeType":"text/html;profile=mcp-app"}
```

Tool that links to it:

```json
{"name":"get_weather","_meta":{"ui":{"resourceUri":"ui://weather-server/dashboard-template",
 "visibility":["model","app"]}}}
```

Host-UI messages: `ui/initialize`, `tools/call`, `ui/message`, `ui/notifications/tool-input`, `ui/notifications/tool-result`. Source: the 2026-01-26 spec above.

### Who defines the components

The MCP server. It ships its own HTML and JavaScript. The host defines no components. It only supplies a sandbox and a bridge.

### How a native client renders it

It must embed a web view. The only content type in the stable spec is `text/html;profile=mcp-app`. Other types are "reserved for future extensions". Web hosts use a double iframe: an outer proxy on another origin enforces CSP, and an inner iframe holds the content. Source: the 2026-01-26 spec. A SwiftUI client would need `WKWebView` plus the bridge. I found no native (non-web) renderer. **[No iOS client support confirmed]**: my search found no statement that Claude iOS or ChatGPT iOS render MCP Apps.

### Security model

Sandboxed iframe. Strict CSP built from domains that the resource declares. "No undeclared domains." Source: the 2026-01-26 spec.

### Text fallback

Good. The tool result keeps a `content` array with text for text-only hosts and for the model. `structuredContent` feeds the UI. Source: the 2026-01-26 spec, and https://developers.openai.com/apps-sdk/build/chatgpt-ui

### Adoption

Claude (web and desktop), ChatGPT, VS Code with GitHub Copilot, Goose, Postman, MCPJam, Microsoft 365 Copilot, and others. Support varies per host. Sources: https://blog.modelcontextprotocol.io/posts/2026-01-26-mcp-apps/ (search result), https://alpic.ai/blog/mcp-apps-goes-official-claude-chatgpt-support (search result).

### MCP-UI

MCP-UI was the community project that led to MCP Apps. Its README now says "MCP Apps is the official standard for interactive UI in MCP. The MCP-UI packages implement the spec." Content types: `rawHtml`, `externalUrl`, `remoteDom` (MIME `application/vnd.mcp-ui.remote-dom`). Remote DOM sends a component tree that the host maps to its own components. That was the one path toward native rendering. It is not part of the stable MCP Apps spec. SDKs: TypeScript, Python, Ruby. No Swift or Android SDK. License Apache 2.0. Sources: https://mcpui.dev/, https://github.com/MCP-UI-Org/mcp-ui

### Fit for Helyx

- Level 1: no fit. It is a way to embed third-party web apps, not a command model.
- Level 2: poor fit. The server owns the components and ships HTML. That is the opposite of a client-owned native catalog. It is relevant later only if Helyx wants to host third-party MCP tool UIs. Then a SwiftUI client can show them in a `WKWebView`, and the text `content` is the fallback.

---

## 3. OpenAI Apps SDK

### What it is

The Apps SDK builds apps for ChatGPT on top of MCP. UI is "an iframe HTML component". The resource MIME type is `text/html;profile=mcp-app`. The preferred bridge is the MCP Apps `ui/*` JSON-RPC over `postMessage`. `window.openai` adds optional ChatGPT extras (`requestCheckout`, `uploadFile`, `selectFiles`, `setWidgetState`). `_meta.ui.resourceUri` is preferred over the old alias `_meta["openai/outputTemplate"]`. Display modes: inline card, inline carousel, fullscreen, picture-in-picture. Source: https://developers.openai.com/apps-sdk/build/chatgpt-ui (no date on the page).

So in 2026 the Apps SDK is MCP Apps plus ChatGPT extensions.

### Text fallback

Tool results have `structuredContent` (for the model and the UI) and `content` (text blocks for the conversation). Same source.

### Native clients

ChatGPT mobile apps render these widgets, but I did not find a primary source that says how. **[unverified]**. Any rendering is web-based. There is no native component catalog.

### Fit for Helyx

Same as MCP Apps: no fit for level 1, poor fit for level 2. The `structuredContent` plus text `content` split is a useful pattern to copy.

---

## 4. AG-UI (CopilotKit Agent-User Interaction protocol)

### What it is

An event protocol between an agent backend and a frontend. It is transport-agnostic (SSE, WebSocket, webhook) and bidirectional. AG-UI docs state that it is "not a generative UI specification". It is "a User Interaction protocol that provides the bi-directional runtime connection between the agent and the application". It carries A2UI, MCP-UI, Open-JSON-UI, or custom specs.
Sources: https://docs.ag-ui.com/concepts/generative-ui-specs, https://www.copilotkit.ai/ag-ui-and-a2ui

### Event types

From https://docs.ag-ui.com/concepts/events (read 2026-09-26):

- Lifecycle: `RunStarted`, `RunFinished`, `RunError`, `StepStarted`, `StepFinished`
- Text: `TextMessageStart`, `TextMessageContent`, `TextMessageEnd`, `TextMessageChunk`
- Tool calls: `ToolCallStart`, `ToolCallArgs`, `ToolCallEnd`, `ToolCallResult`, `ToolCallChunk`
- State: `StateSnapshot`, `StateDelta` (RFC 6902 JSON Patch), `MessagesSnapshot`
- Activity: `ActivitySnapshot`, `ActivityDelta` (`messageId`, `activityType`, content or patch)
- Reasoning: `ReasoningStart` ... `ReasoningEnd`, `ReasoningEncryptedValue`
- Subagent: `SubagentStarted`, `SubagentFinished`, `SubagentError`
- Special: `Raw`, `Custom` (`name`, `value`)
- Draft: `MetaEvent`, extended `RunStarted` and `RunFinished`

Human in the loop: `RunFinished` can end with `{ type: "interrupt", interrupts: [...] }`. The client resumes with a new run that carries a `resume` array. Same source.

Shape example (field names from the docs page; the exact casing of `type` values is SCREAMING_SNAKE_CASE per secondary sources such as https://www.codecademy.com/article/ag-ui-agent-user-interaction-protocol):

```json
{"type":"STATE_DELTA","delta":[{"op":"replace","path":"/progress","value":0.4}]}
{"type":"TEXT_MESSAGE_CONTENT","messageId":"m1","delta":"Hello"}
```

### State streaming

Snapshot plus JSON Patch deltas. The same pattern exists for activities. Source: https://docs.ag-ui.com/concepts/events

### Typed blocks

AG-UI has no component catalog. `ActivitySnapshot` with an `activityType` string is the closest thing to a typed block. Custom block kinds go through `Custom` or through an embedded A2UI payload.

### Maturity, license, SDKs

MIT license, about 16.1k GitHub stars. Official TypeScript and Python. Community SDKs: Kotlin, Go, Dart, Java, Rust, Ruby, C++, .NET. **No Swift and no Elixir SDK.** Integrations include LangGraph, CrewAI, Google ADK, AWS Strands, Mastra, Pydantic AI, Microsoft Agent Framework, and a community Claude Agent SDK integration. Sources: https://github.com/ag-ui-protocol/ag-ui, https://github.com/ag-ui-protocol/ag-ui/tree/main/sdks/community (read 2026-09-26). I did not find the latest release number and date.

### Fit for Helyx

- Level 1: medium. Interrupts and resume give a model for approvals. The event list is a good checklist for the Helyx event stream. But Helyx already owns its event stream and session state on the server. AG-UI assumes a run-per-request model, and its client sends the message history. Helyx keeps history on the server.
- Level 2: no direct fit. It is transport only. It is useful as a reference for snapshot plus JSON Patch updates of a block (for example a progress block).

---

## 5. Other relevant work (one line each)

- **Agent Client Protocol (ACP, Zed)**: editor-to-agent JSON-RPC. Tool calls carry typed content: `content` (text, image, resource), `diff` (`path`, `oldText`, `newText`), `terminal` (`terminalId`); kinds `read`, `edit`, `execute`, and more; status `pending`, `in_progress`, `completed`, `failed`. This is the closest existing shape to Helyx level 2 for a coding agent. https://agentclientprotocol.com/protocol/tool-calls (read 2026-09-26, no version on the page).
- **Vercel AI SDK generative UI**: `message.parts` with typed tool parts (for example `tool-getWeather`, `state: "output-available"`); the React app maps each part to a component. React-only. https://vercel.com/academy/ai-sdk/multi-step-and-generative-ui
- **Vercel json-render**: catalog of allowed components (Zod schemas), the model emits JSON limited to the catalog; React-first; listed as an A2UI catalog renderer. https://github.com/vercel-labs/json-render, https://www.infoq.com/news/2026/03/vercel-json-render
- **OpenUI (Thesys)**: compact streaming "OpenUI Lang" (claims up to 67% fewer tokens than JSON), typed Zod contracts, React official. https://github.com/thesysdev/openui, https://www.openui.com/blog/state-of-generative-ui-report
- **Microsoft Adaptive Cards**: mature JSON card format with an official native iOS SDK and a spec rule that a renderer MUST show `fallbackText` when the card version is too new. https://learn.microsoft.com/en-us/adaptive-cards/rendering-cards/implement-a-renderer, https://learn.microsoft.com/en-us/adaptive-cards/sdk/rendering-cards/ios/getting-started
- **Anthropic**: co-author and adopter of MCP Apps (Claude web and desktop render them). I found no separate Anthropic UI-block standard. **[unverified: absence only]**.

---

## 6. Comparison

| | A2UI | MCP Apps / MCP-UI | OpenAI Apps SDK | AG-UI | ACP tool-call content |
|---|---|---|---|---|---|
| Kind | Declarative UI format | UI resource extension to MCP | MCP Apps + ChatGPT extras | Event transport | Typed content in an agent protocol |
| Who defines components | Client catalog | Server (HTML) | Server (HTML) | Nobody | Protocol (fixed small set) |
| Native SwiftUI render | Yes in principle; community renderers only; official planned | No; needs WKWebView | No; web view | Not applicable; no Swift SDK | Yes; small set, easy to render |
| Text fallback | None in the shape | Yes: `content` text | Yes: `content` text | Not applicable | `content` text blocks |
| Streaming | JSONL, flat component list, data model patches | Tool input and result notifications | Same as MCP Apps | Snapshot + JSON Patch | Tool call updates |
| Security | Data only, trusted catalog | Sandboxed iframe + CSP | Same | Not applicable | Data only |
| Maturity | v0.9.1 production, v1.0 RC, stable planned Q4 2026 | Stable 2026-01-26, wide host adoption | Production in ChatGPT | MIT, ~16.1k stars, many integrations | In use in Zed and other editors |
| License | Apache 2.0 | Apache 2.0 (MCP-UI) | Proprietary platform | MIT | Not checked |
| Helyx level 1 | Partial (`action`, v1.0 RPC) | No | No | Medium (interrupts, resume) | Partial (permission requests) **[not checked in detail]** |
| Helyx level 2 | Good concept, heavy and unstable | Poor | Poor | No | Good, but too small (no table, form, progress) |

---

## 7. Recommendation

Define a small Helyx-owned block catalog now, and do not adopt a full external standard as the wire format. Each block is a Helyx event payload with a `type` (for example `diff`, `table`, `form`, `image`, `progress`), a typed body, and a required `text` fallback. Copy the proven parts: the client-owned catalog and catalog id negotiation from A2UI, the `diff` shape from ACP, the `content` text plus `structuredContent` split from MCP Apps, and snapshot plus JSON Patch updates from AG-UI. For level 1, send commands as Helyx events with a name and arguments, and send user actions back in an A2UI-like `action` shape (`name`, source block id, `context`).

The reason: no standard fits both levels today. MCP Apps and the Apps SDK are HTML in iframes, which a native SwiftUI client can only show in a web view. AG-UI is a transport, and Helyx already has its own server-owned event stream. A2UI has the right catalog model, but its official SwiftUI renderer is not released, its Basic catalog has no diff, table, or progress block, it has no text fallback, and it changed shape four times in 2026 before v1.0. A small own catalog keeps Core small, lets each client render natively, and keeps a clear exit: after A2UI v1.0 is stable (planned Q4 2026), a Helyx `form` or `table` block can carry an A2UI surface as its body, and a Transport plugin can map Helyx events to AG-UI or MCP Apps when the need is real.
