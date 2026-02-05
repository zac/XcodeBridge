import SwiftUI

struct LogView: View {
    @Bindable var bridge: BridgeController

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Text("MCP Log")
                    .font(.headline)
                Spacer()
                Button("Clear") {
                    bridge.clearLogs()
                }
            }

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(bridge.logs) { entry in
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 8) {
                                    Text(entry.timestamp, style: .time)
                                        .foregroundStyle(.secondary)
                                    Text(entry.direction)
                                        .fontWeight(.semibold)
                                    if let clientId = entry.clientId {
                                        Text("client \(clientId)")
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                Text(entry.message)
                                    .font(.system(.caption, design: .monospaced))
                                    .textSelection(.enabled)
                            }
                            .id(entry.id)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 4)
                }
                .onChange(of: bridge.logs.count) { _ in
                    if let last = bridge.logs.last {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
        }
        .padding(16)
        .frame(minWidth: 640, minHeight: 420)
    }
}
