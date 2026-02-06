# XcodeBridge

`XcodeBridge` is a macOS menu bar app plus a CLI (`xcbridge`) that sits in front of Xcode's MCP bridge (`xcrun mcpbridge`).

## Purpose

This project exists to work around the repeated Xcode permission popups for MCP connections.

In practice, Xcode can prompt for approval per connecting process. That becomes a blocker for tools like the Codex app, which may spawn many `codex` CLI processes during one session. MCP access can stall until each process is approved.

`XcodeBridge` keeps one long-running bridge process connected to Xcode MCP, then lets other local clients connect through that bridge.

It provides:

- A persistent local Unix socket for MCP clients
- A single long-running backend connection to Xcode MCP
- JSON-RPC multiplexing across multiple local clients
- A log window for live request/response debugging
- An embedded CLI binary inside the app bundle

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
- `Copy MCP Command` (copies embedded `xcbridge` binary path)
- `Open Log Window`

Use `Copy MCP Command` each time after a rebuild, since the app-bundle path can change with DerivedData.

### CLI target directly

Build the CLI scheme:

```bash
xcodebuild -project XcodeBridge/XcodeBridge.xcodeproj -scheme xcbridge -configuration Debug build
```

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

## MCP Client Integration

Use the path copied by `Copy MCP Command`, and point your MCP client command to `connect` (not `xcrun mcpbridge` directly):

```json
{
  "command": "/path/to/XcodeBridge.app/Contents/Resources/xcbridge",
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
