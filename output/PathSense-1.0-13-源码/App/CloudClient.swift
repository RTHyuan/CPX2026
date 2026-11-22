import Foundation

/// Full, upright JPEG from one selected observation. Retained only by the active session.
struct CloudKeyframe {
    let pose: FramePose, jpeg: Data, width: Int, height: Int
}

struct CloudHTTPError: Error { let status: Int, reason: String? }

final class CloudClient: NSObject, URLSessionTaskDelegate {
    static let imageLimit = 8 * 1024 * 1024
    static let directEndpoint = URL(string: "https://api.deepseek.com/chat/completions")!
    static let model = "deepseek-flash"

    private var transport: URLSession?
    private func session() -> URLSession {
        if let transport {return transport}
        let c=URLSessionConfiguration.ephemeral; c.urlCache=nil; c.httpCookieStorage=nil
        c.requestCachePolicy = .reloadIgnoringLocalCacheData; c.timeoutIntervalForRequest=24; c.timeoutIntervalForResource=30
        let result=URLSession(configuration:c,delegate:self,delegateQueue:nil); transport=result; return result
    }
    func close() { transport?.invalidateAndCancel(); transport=nil }
    func urlSession(_ session:URLSession, task:URLSessionTask, willPerformHTTPRedirection response:HTTPURLResponse, newRequest request:URLRequest, completionHandler:@escaping(URLRequest?)->Void) { completionHandler(nil) }
    static func endpoint(_ input:String) -> URL? {
        guard let u=URLComponents(string:input.trimmingCharacters(in:.whitespacesAndNewlines)), let host=u.host,
              u.user==nil,u.password==nil,u.query==nil,u.fragment==nil, u.path.range(of:#"^/[A-Za-z0-9_-]{16,80}/?$"#,options:.regularExpression) != nil else { return nil }
        let labels=host.split(separator:".",omittingEmptySubsequences:false)
        let parts=labels.compactMap { UInt8($0) }
        let local=host.hasSuffix(".local") || host=="localhost" || (labels.count==4 && parts.count==4 && (parts[0]==10 || (parts[0]==192 && parts[1]==168) || (parts[0]==172 && (16...31).contains(parts[1])) || parts[0]==127))
        guard u.scheme=="https" || (u.scheme=="http" && local) else {return nil}; return u.url?.appendingPathComponent("next")
    }
    private struct Packet: Encodable {
        var context: CloudContext, image: String
        var version: Int? = nil, historical_frames: [HistoryImage]? = nil
        var planning: PlanningSnapshot? = nil, execution_state: String? = nil
    }
    private struct HistoryImage: Encodable {
        let pose: PosePacket, width: Int, height: Int, image: String
    }
    func plan(endpoint: URL, context: CloudContext, jpeg: Data) async throws -> PlannerReply {
        guard !jpeg.isEmpty, jpeg.count <= 360_000 else { throw SpatialError.invalid }
        return try await send(Packet(context: context, image: jpeg.base64EncodedString()), to: endpoint, sources: nil)
    }
    func plan(endpoint: URL, context: CloudContext, jpeg: Data, history: [CloudKeyframe],
              planning: PlanningSnapshot, executionState: String) async throws -> PlannerReply {
        let capture = context.capture.sample
        guard !jpeg.isEmpty, jpeg.count <= Self.imageLimit, history.count <= 2, (1...16384).contains(context.image_width),
              (1...16384).contains(context.image_height), !executionState.isEmpty, executionState.count <= 80,
              context.request.sample.id.sameWorld(capture.id), context.request.sample.time >= capture.time else { throw SpatialError.invalid }
        var stamps: Set<FrameID> = [capture.id]
        let images = try history.map { frame -> HistoryImage in
            guard !frame.jpeg.isEmpty, frame.jpeg.count <= Self.imageLimit, frame.pose.id.sameWorld(capture.id),
                  frame.pose.id.frame < capture.id.frame, frame.pose.time < capture.time, stamps.insert(frame.pose.id).inserted,
                  (1...16384).contains(frame.width), (1...16384).contains(frame.height) else { throw SpatialError.invalid }
            return HistoryImage(pose: PosePacket(frame.pose), width: frame.width, height: frame.height, image: frame.jpeg.base64EncodedString())
        }
        return try await send(Packet(context: context, image: jpeg.base64EncodedString(), version: 2, historical_frames: images,
                                     planning: planning, execution_state: executionState), to: endpoint, sources: stamps)
    }
    private struct ProviderEnvelope: Decodable {
        struct Choice: Decodable {
            struct Message: Decodable { let role: String, content: String }
            let finish_reason: String, message: Message
        }
        let choices: [Choice]
    }

    // Keep the large image strings outside the text context. Each image immediately follows the metadata of the matching capture.
    private static func providerBody(_ packet: Packet) throws -> Data {
        guard packet.version == 2, let planning = packet.planning, let execution = packet.execution_state,
              let frames = packet.historical_frames,
              let resource = Bundle.main.url(forResource: "deepseek-planner-v2", withExtension: "txt") else { throw SpatialError.invalid }
        let template = try String(contentsOf: resource, encoding: .utf8)
        let placeholder = "__PATHSENSE_CAPTURE_ID__"
        guard template.components(separatedBy: placeholder).count == 2 else { throw SpatialError.invalid }
        let enc = JSONEncoder()
        enc.outputFormatting = [.withoutEscapingSlashes]
        struct CurrentContext: Encodable { let context: CloudContext, planning: PlanningSnapshot, execution_state: String }
        struct ImageHeader: Encodable { let role: String, frame_id: FrameID; var pose: PosePacket?, width: Int?, height: Int? }
        func text<T: Encodable>(_ value: T) throws -> [String: Any] {
            ["type": "text", "text": String(decoding: try enc.encode(value), as: UTF8.self)]
        }
        func photo(_ base64: String) -> [String: Any] {
            ["type": "image_url", "image_url": ["url": "data:image/jpeg;base64," + base64]]
        }
        let stamp = packet.context.capture.sample.id
        let prompt = template.replacingOccurrences(of: placeholder, with: String(decoding: try enc.encode(stamp), as: UTF8.self))
        var content: [[String: Any]] = [try text(CurrentContext(context: packet.context, planning: planning, execution_state: execution)),
            try text(ImageHeader(role: "current", frame_id: stamp)), photo(packet.image)]
        for history in frames {
            content.append(try text(ImageHeader(role: "historical", frame_id: history.pose.sample.id, pose: history.pose,
                                                width: history.width, height: history.height)))
            content.append(photo(history.image))
        }
        let messages: [[String: Any]] = [["role": "system", "content": prompt], ["role": "user", "content": content]]
        let body: [String: Any] = ["model": model, "thinking": ["type": "disabled"], "response_format": ["type": "json_object"],
                                   "stream": false, "max_tokens": 1500, "messages": messages]
        return try JSONSerialization.data(withJSONObject: body, options: [.withoutEscapingSlashes])
    }

    private func send(_ packet: Packet, to endpoint: URL, sources: Set<FrameID>?) async throws -> PlannerReply {
        // Only this exact HTTPS endpoint may receive the device's bearer credential. All redirected requests are refused by the delegate.
        let direct = endpoint.absoluteString == Self.directEndpoint.absoluteString
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if direct {
            guard sources != nil else { throw SpatialError.invalid }
            request.httpBody = try Self.providerBody(packet)
            let token = try DeviceCloudCredential.read()
            guard !token.isEmpty, !token.contains(where: { $0.isWhitespace || $0.isNewline }) else {
                throw CloudHTTPError(status: 401, reason: "upstream_auth")
            }
            request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        } else {
            request.timeoutInterval = 12
            request.httpBody = try JSONEncoder().encode(packet)
        }
        let (data, response) = try await session().data(for: request)
        guard let http = response as? HTTPURLResponse, data.count <= (direct ? 131_072 : 24_576) else { throw SpatialError.invalid }
        guard http.statusCode == 200 else {
            if direct {
                let reasons = [401: "upstream_auth", 403: "upstream_auth", 402: "upstream_quota", 408: "upstream_timeout", 429: "upstream_rate_limit", 504: "upstream_timeout"]
                throw CloudHTTPError(status: http.statusCode, reason: reasons[http.statusCode] ?? "upstream_http")
            }
            let known = ["busy", "invalid_request", "upstream_auth", "upstream_quota", "upstream_rate_limit", "upstream_timeout", "upstream_transport", "upstream_schema", "upstream_tls"]
            let value = (try? JSONDecoder().decode([String: String].self, from: data))?["error"]
            throw CloudHTTPError(status: http.statusCode, reason: value.flatMap { known.contains($0) ? $0 : nil })
        }
        if direct {
            let envelope = try JSONDecoder().decode(ProviderEnvelope.self, from: data)
            guard envelope.choices.count == 1, let choice = envelope.choices.first, choice.finish_reason == "stop",
                  choice.message.role == "assistant" else { throw SpatialError.invalid }
            return try PlannerReply.parse(Data(choice.message.content.utf8), for: packet.context.capture.sample.id, sources: sources)
        }
        return try PlannerReply.parse(data, for: packet.context.capture.sample.id, sources: sources)
    }
}
