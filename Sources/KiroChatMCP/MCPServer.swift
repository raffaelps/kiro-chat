import Foundation

/// Servidor MCP mínimo (JSON-RPC 2.0 sobre stdio, uma mensagem JSON por linha).
final class MCPServer: @unchecked Sendable {
    typealias JSON = [String: Any]

    let tools: ChatTools
    private let outQueue = DispatchQueue(label: "kiro-chat.mcp.out")
    private let workQueue = DispatchQueue(label: "kiro-chat.mcp.work")
    private let waitQueue = DispatchQueue(label: "kiro-chat.mcp.wait", attributes: .concurrent)
    private let supportedVersions = ["2025-06-18", "2025-03-26", "2024-11-05"]

    init(tools: ChatTools) { self.tools = tools }

    func run() -> Never {
        let group = DispatchGroup()
        while let line = readLine(strippingNewline: true) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            guard let data = trimmed.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) else {
                send(["jsonrpc": "2.0", "id": NSNull(),
                      "error": ["code": -32700, "message": "Parse error"]])
                continue
            }
            let batch = (obj as? [JSON]) ?? [(obj as? JSON) ?? [:]]
            for message in batch {
                group.enter()
                // Requisições são processadas em ordem; só a espera longa roda em paralelo
                // para não travar ping/cancelamentos.
                let isWait = (message["params"] as? JSON)?["name"] as? String == "wait_for_mentions"
                (isWait ? waitQueue : workQueue).async {
                    defer { group.leave() }
                    self.handle(message)
                }
            }
        }
        // stdin fechado: espera as requisições pendentes e encerra.
        _ = group.wait(timeout: .now() + 5)
        exit(0)
    }

    private func handle(_ msg: JSON) {
        let method = msg["method"] as? String
        let id = msg["id"]
        let params = msg["params"] as? JSON ?? [:]

        guard let method else { return } // respostas a requisições nossas: ignorar
        let isNotification = id == nil

        do {
            let result: JSON
            switch method {
            case "initialize":
                let requested = params["protocolVersion"] as? String ?? supportedVersions[0]
                result = [
                    "protocolVersion": supportedVersions.contains(requested) ? requested : supportedVersions[0],
                    "capabilities": ["tools": ["listChanged": false]],
                    "serverInfo": ["name": "kiro-chat", "version": "1.0.0"],
                    "instructions": ChatTools.serverInstructions,
                ]
            case "ping":
                result = [:]
            case "tools/list":
                result = ["tools": ChatTools.definitions]
            case "tools/call":
                guard let name = params["name"] as? String else {
                    throw RPCError(code: -32602, message: "Parâmetro 'name' ausente")
                }
                let args = params["arguments"] as? JSON ?? [:]
                result = tools.call(name: name, arguments: args)
            case "resources/list":
                result = ["resources": []]
            case "prompts/list":
                result = ["prompts": []]
            default:
                if isNotification { return } // notifications/initialized, notifications/cancelled...
                throw RPCError(code: -32601, message: "Método não suportado: \(method)")
            }
            if !isNotification { send(["jsonrpc": "2.0", "id": id!, "result": result]) }
        } catch let e as RPCError {
            if !isNotification {
                send(["jsonrpc": "2.0", "id": id!, "error": ["code": e.code, "message": e.message]])
            }
        } catch {
            if !isNotification {
                send(["jsonrpc": "2.0", "id": id!, "error": ["code": -32603, "message": "\(error)"]])
            }
        }
    }

    private func send(_ obj: JSON) {
        outQueue.sync {
            guard var data = try? JSONSerialization.data(withJSONObject: obj, options: [.withoutEscapingSlashes]) else { return }
            data.append(0x0A)
            FileHandle.standardOutput.write(data)
        }
    }
}

struct RPCError: Error {
    let code: Int
    let message: String
}

func log(_ s: String) {
    FileHandle.standardError.write(("[kiro-chat] " + s + "\n").data(using: .utf8)!)
}
