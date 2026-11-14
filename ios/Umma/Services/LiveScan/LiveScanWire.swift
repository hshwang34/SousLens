import Foundation

/// Gemini Live wire format, mirrored from google-genai's `live.py` (the path the brief 016 spike
/// ran against the real API): snake_case client envelopes, camelCase server messages,
/// URL-safe base64 media, `Authorization: Token <auth_tokens/...>` on the constrained endpoint.
enum LiveScanWire {
    static let endpoint = URL(string: "wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1alpha.GenerativeService.BidiGenerateContentConstrained")!

    /// 1 s of silent 16 kHz mono 16-bit PCM. Video alone closes for client inactivity.
    static let silentSecond = Data(count: 32_000)

    static func request(token: LiveScanToken) -> URLRequest {
        var request = URLRequest(url: endpoint)
        request.timeoutInterval = 15
        request.setValue("Token \(token.token)", forHTTPHeaderField: "Authorization")
        return request
    }

    static func modelPath(_ model: String) -> String? {
        let trimmed = model.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        return trimmed.hasPrefix("models/") ? trimmed : "models/\(trimmed)"
    }

    /// Model only: instructions, tool and modalities are locked into the token.
    static func setup(modelPath: String) -> String {
        json(["setup": ["model": modelPath]])
    }

    static func video(jpeg: Data) -> String {
        json(["realtime_input": ["video": ["data": base64URL(jpeg), "mime_type": "image/jpeg"]]])
    }

    static func audio(pcm: Data) -> String {
        json(["realtime_input": ["audio": ["data": base64URL(pcm), "mime_type": "audio/pcm;rate=16000"]]])
    }

    static func text(_ text: String) -> String {
        json(["realtime_input": ["text": text]])
    }

    /// `SILENT`: the answer updates the model's context without starting a spoken turn.
    static func toolResponse(callID: String, name: String, status: String, canonical: String?) -> String {
        var response: [String: Any] = ["status": status]
        if let canonical { response["canonical_name"] = canonical }
        let call: [String: Any] = ["id": callID, "name": name, "response": response, "scheduling": "SILENT"]
        return json(["tool_response": ["functionResponses": [call]]])
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
    }

    private static func json(_ object: [String: Any]) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: - Server messages

    /// Only the fields we act on. `serverContent` (model audio, transcripts) is never decoded.
    /// Every field decodes leniently: one wrongly typed value must not hide the call ids, because
    /// every function call needs an answer.
    struct ServerMessage: Decodable {
        struct Empty: Decodable {}
        struct ToolCall: Decodable {
            let functionCalls: [FunctionCall]?
        }
        struct FunctionCall: Decodable {
            let id: String?
            let name: String?
            let args: Args?

            enum CodingKeys: String, CodingKey { case id, name, args }

            init(from decoder: Decoder) throws {
                let container = try? decoder.container(keyedBy: CodingKeys.self)
                id = try? container?.decodeIfPresent(String.self, forKey: .id)
                name = try? container?.decodeIfPresent(String.self, forKey: .name)
                args = try? container?.decodeIfPresent(Args.self, forKey: .args)
            }
        }
        struct Args: Decodable {
            let name: String?
            let kind: String?
            let confidence: String?

            enum CodingKeys: String, CodingKey { case name, kind, confidence }

            init(from decoder: Decoder) throws {
                let container = try? decoder.container(keyedBy: CodingKeys.self)
                name = try? container?.decodeIfPresent(String.self, forKey: .name)
                kind = try? container?.decodeIfPresent(String.self, forKey: .kind)
                confidence = try? container?.decodeIfPresent(String.self, forKey: .confidence)
            }
        }

        let setupComplete: Empty?
        let toolCall: ToolCall?
        let goAway: Empty?

        enum CodingKeys: String, CodingKey { case setupComplete, toolCall, goAway }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            setupComplete = try? container.decodeIfPresent(Empty.self, forKey: .setupComplete)
            toolCall = try? container.decodeIfPresent(ToolCall.self, forKey: .toolCall)
            goAway = try? container.decodeIfPresent(Empty.self, forKey: .goAway)
        }
    }

    static func decode(_ data: Data) -> ServerMessage? {
        try? JSONDecoder().decode(ServerMessage.self, from: data)
    }
}
