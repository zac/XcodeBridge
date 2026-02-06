//
//  XcodeBridgeApp.swift
//  XcodeBridge
//
//  Created by Zac White on 2/4/26.
//

import AppKit
import SwiftUI

@main
struct XcodeBridgeApp: App {
    @Environment(\.openWindow) private var openWindow
    @State private var bridge = BridgeController()

    var body: some Scene {
        MenuBarExtra("XcodeBridge", systemImage: bridge.statusSymbol) {
            Text("Status: \(bridge.statusText)")
            Divider()
            Button(bridge.isRunning ? "Stop Bridge" : "Start Bridge") {
                bridge.toggle()
            }
            Button("Copy MCP Command") {
                bridge.copyMCPCommand()
            }
            Button("Open Log Window") {
                bridge.bringAppToFront()
                if let window = NSApp.windows.first(where: { $0.title == "MCP Logs" }) {
                    window.makeKeyAndOrderFront(nil)
                } else {
                    openWindow(id: "logs")
                }
            }
            Divider()
            Button("Quit XcodeBridge") {
                NSApplication.shared.terminate(nil)
            }
        }
        Window("MCP Logs", id: "logs") {
            LogView(bridge: bridge)
        }
    }
}
