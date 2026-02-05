# XcodeBridge

`XcodeBridge` is a macOS menu bar app plus a CLI (`xcbridge`) that sits in front of Xcode's MCP bridge (`xcrun mcpbridge`).

It provides:

- A persistent local Unix socket for MCP clients
- A single long-running backend connection to Xcode MCP
- JSON-RPC multiplexing across multiple local clients
- A log window for live request/response debugging
- One-click CLI install to `/usr/local/bin/xcbridge`

## Project Layout

- `XcodeBridge/XcodeBridge`: SwiftUI menu bar app
- `XcodeBridge/xcbridge`: CLI source
- `XcodeBridge/XcodeBridge.xcodeproj`: Xcode project

## Requirements

- macOS
- Xcode 26.3+ installed
- At least one running Xcode instance when using the bridge backend

## Build and Run

### App (recommended)

1. Open `XcodeBridge/XcodeBridge.xcodeproj`.
2. Select the `XcodeBridge` scheme.
3. Run from Xcode.

From the menu bar extra:

- `Start Bridge` / `Stop Bridge`
- `Copy MCP Command` (copies active CLI path)
- `Open Log Window`
- `Install CLI...` or `Upgrade CLI...` (installs to `/usr/local/bin/xcbridge`)

### CLI target directly

Build the CLI scheme:

```bash
xcodebuild -project XcodeBridge/XcodeBridge.xcodeproj -scheme xcbridge -configuration Debug build
```

Or install using the app menu as above.

## CLI Usage

The executable is `xcbridge`. It supports two modes:

- `serve`: starts the local socket server and launches `xcrun mcpbridge` as backend
- `connect`: bridges current stdin/stdout to the local socket

Examples:

```bash
# Start server on default socket: ~/.xcode-bridge.sock
xcbridge serve

# Connect stdin/stdout to running bridge
xcbridge connect

# Use a custom socket
xcbridge serve --socket ~/tmp/xcode-bridge.sock
xcbridge connect --socket ~/tmp/xcode-bridge.sock
```

## Environment Variables

- `XCODE_BRIDGE_SOCKET`: override socket path
- `XCODE_BRIDGE_SERVER_FRAMING`: `line` or `content-length`
- `XCODE_BRIDGE_PROTOCOL_VERSION`: override `initialize.params.protocolVersion`
- `MCP_XCODE_PID`: optional explicit Xcode PID passed through to `xcrun mcpbridge`
- `MCP_XCODE_SESSION_ID`: optional Xcode session UUID passed through

## MCP Client Integration

Point your MCP client command to `xcbridge connect` (not `xcrun mcpbridge` directly):

```json
{
  "command": "xcbridge",
  "args": ["connect"]
}
```

If your client expects a socket command, use the same `connect` mode and let `xcbridge` handle transport details.

## Logging and Debugging

`Open Log Window` shows live events, including:

- `client_in` / `client_out`
- `server_in` / `server_out`
- connection and timeout events

The bridge emits `MUXLOG` events on stderr, which the app parses and renders in the log UI.

## Notes

- This project is currently intended for local/personal use.
- The bridge is local-socket based and does not implement strong multi-user auth controls.
- Keep Xcode running while using the backend bridge.
