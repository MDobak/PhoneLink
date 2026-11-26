import AppKit
import SwiftUI

/// Settings > Agents: lets MCP agents on this Mac use the phone.
struct AgentsSettings: View {
    @ObservedObject private var settings = AgentSettings.shared
    @ObservedObject private var server = AgentServer.shared
    @State private var copied: String?

    private var addCommand: String { "claude mcp add phone-link -- \"" + AgentServer.helperPath + "\"" }

    var body: some View {
        Form {
            Section {
                Toggle("Allow agents on this Mac to use your phone", isOn: $settings.enabled)
                if settings.enabled, !server.clients.isEmpty {
                    Label("Connected: " + server.clients.joined(separator: ", "), systemImage: "point.3.connected.trianglepath.dotted")
                        .foregroundStyle(.secondary)
                }
                if let e = server.error {
                    Label(e, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
            } footer: {
                Text("Agents such as Claude Code connect through MCP. Phone Link does not ask before each action. Turn on only the items that the agent needs.")
                    .settingsFooter()
            }

            Section {
                ForEach(AgentRow.all) { row in
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(row.title)
                            Text(row.detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 8)
                        box(row.read, "Read")
                        box(row.change, label(for: row.change))
                    }
                    if row.read == .notificationsRead {
                        Toggle(isOn: $settings.notificationHistory) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Keep a notification history on the phone")
                                Text("The phone saves its notifications for 7 days, so agents can read older notifications and chat messages without opening the apps. Turning this off deletes the history.")
                                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .padding(.leading, 16)
                        .disabled(!settings.isOn(.notificationsRead))
                    }
                }
            } header: {
                Text("Permissions")
            } footer: {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(settings.riskyMix && settings.enabled ? .orange : .secondary)
                    Text("Do not turn on Read items together with Send or Change items unless you trust the agent. Text in a message, a notification or a web page can tell the agent to send your data to other people.")
                }
                .settingsFooter()
            }
            .disabled(!settings.enabled)

            Section {
                Text("To add Phone Link to Claude Code, run this command in Terminal:")
                copyRow(addCommand)
                Text("For other agents, add an MCP server of the stdio type with this command:")
                copyRow(AgentServer.helperPath)
            } header: {
                Text("Set Up")
            } footer: {
                Text("The command starts Phone Link if it is not open. Only apps of your user account can connect.")
                    .settingsFooter()
            }

            Section {
                if server.log.isEmpty {
                    Text("No activity.").foregroundStyle(.secondary)
                } else {
                    ForEach(server.log.prefix(100)) { e in logRow(e) }
                }
            } header: {
                HStack {
                    Text("Activity")
                    Spacer()
                    if !server.log.isEmpty { Button("Clear") { server.clearLog() }.controlSize(.small) }
                }
            }
        }
        .formStyle(.grouped)
        .frame(height: 560)
    }

    private func label(for g: AgentGroup?) -> String {
        switch g {
        case .messagesSend: return "Send"
        case .notificationsAct, .media, .calls, .alerts, .screenControl: return "Control"
        case .intents: return "Open"
        case .shell: return "Run"
        default: return "Change"
        }
    }

    @ViewBuilder
    private func box(_ g: AgentGroup?, _ title: String) -> some View {
        Group {
            if let g {
                Toggle(title, isOn: Binding(get: { settings.isOn(g) }, set: { settings.set(g, $0) }))
                    .toggleStyle(.checkbox)
            } else {
                Color.clear.frame(height: 1)
            }
        }
        .frame(width: 74, alignment: .leading)
    }

    private func copyRow(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(text).font(.system(.caption, design: .monospaced)).textSelection(.enabled).lineLimit(3)
            Spacer(minLength: 8)
            Button(copied == text ? "Copied" : "Copy") {
                copyToPasteboard(text)
                copied = text
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { if copied == text { copied = nil } }
            }
            .controlSize(.small)
        }
    }

    private static let timeFormat: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .medium
        return f
    }()

    private func logRow(_ e: AgentServer.LogEntry) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Group {
                switch e.ok {
                case nil: ProgressView().controlSize(.mini)
                case true?: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                case false?: Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
                }
            }
            .frame(width: 14)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(e.tool).font(.system(.body, design: .monospaced))
                    Text(e.client).foregroundStyle(.secondary)
                    Spacer()
                    if let ms = e.ms { Text(ms < 1000 ? "\(ms) ms" : String(format: "%.1f s", Double(ms) / 1000)).foregroundStyle(.secondary) }
                    Text(Self.timeFormat.string(from: e.time)).foregroundStyle(.secondary)
                }
                if !e.args.isEmpty {
                    Text(e.args).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary).lineLimit(2).textSelection(.enabled)
                }
                if e.ok == false, let r = e.result {
                    Text(r).font(.caption).foregroundStyle(.red).lineLimit(3).textSelection(.enabled)
                }
            }
        }
        .help(e.result ?? "")
    }
}
