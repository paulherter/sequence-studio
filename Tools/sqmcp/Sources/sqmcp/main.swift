import Foundation

// MCP server over stdio (newline-delimited JSON-RPC 2.0) that forwards to Sequence Studio's local edit API.
// The app writes port + per-launch token to ~/Library/Application Support/Sequence Studio/edit-api.json while the API
// is enabled (Settings > Advanced); this shim reads it on every call, so it survives app restarts.

typealias JSON = [String: Any]

let discoveryURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    .appendingPathComponent("Sequence Studio/edit-api.json")

let timeSchema: JSON = ["type": "object", "properties": ["value": ["type": "integer"], "timescale": ["type": "integer", "minimum": 1]],
                        "required": ["value", "timescale"], "description": "Rational time value/timescale seconds"]

let tools: [JSON] = [
    ["name": "sq_get_state",
     "description": "Read the open Sequence Studio project: sequences, tracks, clips (stable ids), markers, effects. Times are {value,timescale}.",
     "inputSchema": ["type": "object", "properties": [String: Any]()]],
    ["name": "sq_commit",
     "description": """
     Apply a batch of edit operations to one sequence as ONE undo step ("Agent: <name>"). All-or-nothing: if any \
     operation fails nothing changes and the failing operationIndex is returned. dryRun=true returns the diff only. \
     Ops: razor{at,tracks?} rippleDelete{clips} lift{clips} extract{range,tracks?} liftRange{range,tracks?} \
     trim{clip,edge:head|tail,by} rippleTrim{clip,edge,by} move{clip,to,track?} slip{clip,by} slide{clip,by} \
     roll{clip,by} toggleEnabled{clips} addMarker{at,name?}. range = {start: time, duration: time}.
     """,
     "inputSchema": ["type": "object", "properties": [
        "operations": ["type": "array", "items": ["type": "object", "properties": ["op": ["type": "string"], "at": timeSchema],
                                                  "required": ["op"]]],
        "name": ["type": "string", "description": "Undo name suffix"],
        "dryRun": ["type": "boolean"],
        "sequence": ["type": "string", "description": "activeSequence id from sq_get_state; refused (409) if the user switched sequence since"],
     ], "required": ["operations", "sequence"]]],
    ["name": "sq_undo", "description": "Undo the last step, only if it is an agent step (\"Agent: ...\"); expectedName pins the exact step.", "inputSchema": ["type": "object", "properties": ["expectedName": ["type": "string"]]]],
]

@MainActor func send(_ obj: JSON) {
    guard let d = try? JSONSerialization.data(withJSONObject: obj), var s = String(data: d, encoding: .utf8) else { return }
    s += "\n"
    FileHandle.standardOutput.write(Data(s.utf8))
}

@MainActor func callAPI(_ method: String, _ path: String, body: JSON?) async -> (text: String, isError: Bool) {
    guard let d = try? Data(contentsOf: discoveryURL),
          let info = try? JSONSerialization.jsonObject(with: d) as? JSON,
          let port = info["port"] as? Int, let token = info["token"] as? String else {
        return ("Sequence Studio's edit API is not running. Turn it on in Settings > Advanced.", true)
    }
    var r = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(path)")!)
    r.httpMethod = method
    r.timeoutInterval = 30
    r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    if let body {
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.httpBody = try? JSONSerialization.data(withJSONObject: body)
    }
    do {
        let (data, resp) = try await URLSession.shared.data(for: r)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        return (String(decoding: data, as: UTF8.self), status != 200)
    } catch {
        return ("Could not reach Sequence Studio: \(error.localizedDescription)", true)
    }
}

@MainActor func handle(_ msg: JSON) async {
    let id = msg["id"]
    let method = msg["method"] as? String ?? ""
    func reply(_ result: JSON) { if let id { send(["jsonrpc": "2.0", "id": id, "result": result]) } }
    switch method {
    case "initialize":
        let params = msg["params"] as? JSON
        reply(["protocolVersion": params?["protocolVersion"] as? String ?? "2025-06-18",
               "capabilities": ["tools": [String: Any]()],
               "serverInfo": ["name": "sequence-studio", "version": "1.0"]])
    case "ping": reply([:])
    case "tools/list": reply(["tools": tools])
    case "tools/call":
        let params = msg["params"] as? JSON ?? [:]
        let args = params["arguments"] as? JSON ?? [:]
        let out: (text: String, isError: Bool)
        switch params["name"] as? String {
        case "sq_get_state": out = await callAPI("GET", "/v1/state", body: nil)
        case "sq_commit": out = await callAPI("POST", "/v1/commit", body: args)
        case "sq_undo": out = await callAPI("POST", "/v1/undo", body: args)
        default: out = ("unknown tool", true)
        }
        reply(["content": [["type": "text", "text": out.text]], "isError": out.isError])
    default:
        if let id, !method.hasPrefix("notifications/") {
            send(["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": "method not found: \(method)"]])
        }
    }
}

while let line = readLine(strippingNewline: true) {
    guard !line.isEmpty, let d = line.data(using: .utf8), let msg = try? JSONSerialization.jsonObject(with: d) as? JSON else {
        if !line.isEmpty { send(["jsonrpc": "2.0", "id": NSNull(), "error": ["code": -32700, "message": "parse error"]]) }
        continue
    }
    await handle(msg)
}
