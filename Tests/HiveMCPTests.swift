import XCTest
@testable import Hive

final class HiveMCPTests: XCTestCase {
    func testJSONRPCRequestEncodesEnvelope() throws {
        let request = JSONRPCRequest(
            id: 3,
            method: "tools/call",
            params: ["name": "fetch", "arguments": ["url": "https://example.com"]]
        )
        let data = try JSONEncoder().encode(request)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        XCTAssertEqual(object?["jsonrpc"] as? String, "2.0")
        XCTAssertEqual(object?["id"] as? Int, 3)
        XCTAssertEqual(object?["method"] as? String, "tools/call")

        let params = object?["params"] as? [String: Any]
        XCTAssertEqual(params?["name"] as? String, "fetch")

        let arguments = params?["arguments"] as? [String: Any]
        XCTAssertEqual(arguments?["url"] as? String, "https://example.com")
    }

    func testJSONRPCNotificationOmitsID() throws {
        let request = JSONRPCRequest(id: nil, method: "notifications/initialized", params: [:])
        let data = try JSONEncoder().encode(request)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        XCTAssertNil(object?["id"])
        XCTAssertEqual(object?["method"] as? String, "notifications/initialized")
    }

    func testAnyCodableRoundTripsNestedJSON() throws {
        let value: [String: Any] = [
            "text": "hi",
            "number": 42,
            "flag": true,
            "list": [1, 2]
        ]
        let data = try JSONEncoder().encode(AnyCodable(value))
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        XCTAssertEqual(object?["text"] as? String, "hi")
        XCTAssertEqual(object?["number"] as? Double, 42)
        XCTAssertEqual(object?["flag"] as? Bool, true)
        XCTAssertEqual((object?["list"] as? [Any])?.count, 2)
    }

    func testMCPToolNameIsSanitisedAndCapped() {
        let server = MCPServerConfig(name: "My Server 1", url: "http://localhost/mcp")
        let name = ToolRegistry.mcpToolName(server: server, tool: "search/things")

        // Only [A-Za-z0-9_-] may reach a provider.
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-"))
        XCTAssertTrue(name.unicodeScalars.allSatisfy { allowed.contains($0) })
        XCTAssertLessThanOrEqual(name.count, 64)
        XCTAssertTrue(name.hasPrefix("mcp_"))
    }
}
