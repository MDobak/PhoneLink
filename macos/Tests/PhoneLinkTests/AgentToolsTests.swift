import Foundation
import Testing
@testable import PhoneLink

/// Tests of the MCP tools for agents (AgentTools). They do not need a phone.
@Suite struct AgentToolsTests {
    private var tools: [AgentTool] { AgentTools.all }

    @Test func namesAreUniqueAndConsistent() {
        let names = tools.map(\.name)
        #expect(Set(names).count == names.count, "Two tools have the same name.")
        for n in names {
            #expect(n.range(of: "^[a-z]+_[a-z]+$", options: .regularExpression) != nil, "\(n) does not follow <area>_<verb>.")
        }
    }

    @Test func eachToolHasAGroupAndEachGroupHasATool() {
        for t in tools { #expect(!t.groups.isEmpty, "\(t.name) has no group.") }
        let used = Set(tools.flatMap(\.groups))
        for g in AgentGroup.allCases { #expect(used.contains(g), "No tool uses the group \(g).") }
    }

    @Test func eachSettingsRowHasItsGroups() {
        let inRows = Set(AgentRow.all.flatMap { [$0.read, $0.change].compactMap { $0 } })
        #expect(inRows == Set(AgentGroup.allCases), "Some groups have no checkbox in Settings > Agents.")
    }

    @Test func schemasAreValid() throws {
        for t in tools {
            #expect(t.input["type"] as? String == "object", "\(t.name): the input is not an object.")
            let props = t.input["properties"] as? [String: Any] ?? [:]
            for r in t.input["required"] as? [String] ?? [] {
                #expect(props[r] != nil, "\(t.name): the required argument \(r) is not a property.")
            }
            for (k, v) in props {
                let p = try #require(v as? [String: Any], "\(t.name).\(k) is not an object.")
                #expect(!(p["description"] as? String ?? "").isEmpty, "\(t.name).\(k) has no description.")
                if let e = p["enum"] as? [String] { #expect(!e.isEmpty, "\(t.name).\(k) has an empty enum.") }
            }
            #expect(!t.description.isEmpty && !t.title.isEmpty, "\(t.name) has no description or title.")
            #expect(JSONSerialization.isValidJSONObject(t.listing), "\(t.name): the listing is not valid JSON.")
        }
    }

    @Test func readOnlyToolsAreOnlyInReadGroups() {
        let changeGroups = Set(AgentRow.all.compactMap(\.change))
        for t in tools where t.readOnly {
            #expect(t.groups.allSatisfy { !changeGroups.contains($0) }, "\(t.name) is read-only but is in a change group.")
        }
    }

    // MARK: - tools/list filtering

    @Test func noGroupsShowNoTools() {
        #expect(AgentTools.visible { _ in false }.isEmpty)
    }

    @Test func allGroupsShowAllTools() {
        #expect(AgentTools.visible { _ in true }.count == tools.count)
    }

    @Test func screenReadShowsOnlyItsTools() {
        let names = Set(AgentTools.visible { $0 == .screenRead }.map(\.name))
        #expect(names == ["screen_capture", "screen_read", "windows_read"])
    }

    @Test func eachGroupShowsOnlyToolsOfThatGroup() {
        for g in AgentGroup.allCases {
            for t in AgentTools.visible(allows: { $0 == g }) {
                #expect(t.groups.contains(g), "\(t.name) shows with only \(g) on.")
            }
        }
    }

    @Test func filesTransferShowsWithReadOrWrite() {
        #expect(AgentTools.visible { $0 == .filesRead }.contains { $0.name == "files_transfer" })
        #expect(AgentTools.visible { $0 == .filesWrite }.contains { $0.name == "files_transfer" })
    }

    @Test func riskyMix() {
        #expect(!AgentSettings.riskyMix([]))
        #expect(!AgentSettings.riskyMix([.status, .messagesRead, .screenRead]))
        #expect(!AgentSettings.riskyMix([.messagesSend, .calls]))
        #expect(AgentSettings.riskyMix([.messagesRead, .messagesSend]))
        #expect(AgentSettings.riskyMix([.shell]))
    }

    // MARK: - Arguments

    @Test func argsReadValues() {
        let a = AgentArgs(["s": "x", "n": 5, "ns": "7", "b": true, "bs": "true", "null": NSNull()])
        #expect(a.str("s") == "x")
        #expect(a.int("n") == 5)
        #expect(a.int("ns") == 7)
        #expect(a.bool("b") && a.bool("bs") && !a.bool("missing"))
        #expect(a.has("s") && !a.has("null") && !a.has("missing"))
        #expect(a.pick(["s", "null", "missing"]).keys.sorted() == ["s"])
        #expect(a.all["null"] == nil)
    }

    @Test func argsNeedAndAction() throws {
        let a = AgentArgs(["action": "open"])
        #expect(try a.need("action") == "open")
        #expect(throws: AgentError.self) { try a.need("window") }
        #expect(try a.action(["open", "close"]) == "open")
        let e = #expect(throws: AgentError.self) { try AgentArgs(["action": "x"]).action(["open", "close", "focus"]) }
        #expect(e?.localizedDescription == "\"action\" must be open, close or focus.")
    }

    /// Calls a tool and returns the error text, or nil when the call succeeds.
    private func error(_ tool: String, _ args: [String: Any]) async throws -> String? {
        let t = try #require(tools.first { $0.name == tool })
        do { _ = try await t.run(AgentArgs(args)); return nil } catch { return error.localizedDescription }
    }

    @Test func toolsCheckArgumentsBeforeTheyUseThePhone() async throws {
        #expect(try await error("windows_control", [:])?.contains("\"action\" must be") == true)
        #expect(try await error("windows_control", ["action": "launch", "window": "desktop"])?.contains("\"action\" must be") == true)
        #expect(try await error("windows_control", ["action": "open"])?.contains("Give \"window\"") == true)
        #expect(try await error("windows_control", ["action": "open", "window": "not a package"])?.contains("must be a package name") == true)
        #expect(try await error("settings_write", ["name": "nope"])?.contains("cannot change") == true)
        #expect(try await error("settings_write", ["name": "screenTimeout", "timeout": 5])?.contains("10000 to 1800000") == true)
        #expect(try await error("settings_write", ["name": "airplane"])?.contains("Give \"on\"") == true)
        #expect(try await error("apps_start", [:])?.contains("Give \"package\"") == true)
        #expect(try await error("messages_read", ["action": "nope"])?.contains("\"action\" must be") == true)
    }

    // MARK: - Output

    @Test func outputToMCP() {
        let ok = AgentOutput.json(["a": 1]).mcp(error: false)
        #expect(ok["isError"] as? Bool == false)
        let c = ok["content"] as? [[String: Any]]
        #expect(c?.first?["type"] as? String == "text")
        #expect(c?.first?["text"] as? String == "{\"a\":1}")
        let img = AgentOutput.image(data: "AAAA", mime: "image/jpeg", meta: ["w": 1]).mcp(error: false)["content"] as? [[String: Any]]
        #expect(img?.map { $0["type"] as? String } == ["image", "text"])
        #expect(AgentOutput.text("no").mcp(error: true)["isError"] as? Bool == true)
    }

    @Test func activitySummaryIsShort() {
        #expect(AgentServer.summary([:]) == "")
        let s = AgentServer.summary(["text": String(repeating: "x", count: 1000)])
        #expect(s.count < 300 && s.contains("…"))
    }

    @Test func screenTextIsFlat() {
        let tree: [String: Any] = [
            "screen": [1080, 2400], "front": "com.example",
            "windows": [[
                "type": "app", "package": "com.example", "title": "Example", "active": true,
                "elements": [[
                    "id": 1, "class": "LinearLayout", "bounds": [0, 0, 100, 50], "flags": ["clickable"],
                    "children": [["id": 2, "class": "TextView", "bounds": [0, 0, 100, 50], "text": "Hello"]],
                ], ["id": 3, "class": "ImageButton", "bounds": [10, 10, 30, 30], "desc": "Send"],
                   ["id": 4, "class": "ImageView", "bounds": [0, 0, 2, 2], "res": "logo"]],
            ]],
        ]
        let s = AgentTools.screenText(tree)
        #expect(s == """
            screen 1080x2400, front app com.example
            # app com.example "Example" (active)
             [1] LinearLayout {clickable} @50,25
              [2] "Hello" @50,25
             [3] ImageButton desc="Send" @20,20
             [4] ImageView res=logo @1,1
            """)
    }

    @Test func screenTextHintsWhenNoElements() {
        let r: JSON = ["screen": [1088, 1920], "display": 29, "windows": [["type": "app", "package": "com.sec.android.app.launcher", "elements": [] as [JSON]]]]
        let t = AgentTools.screenText(r)
        #expect(t.contains("(no elements)"))
        #expect(t.contains("screen_capture"))
    }
}
