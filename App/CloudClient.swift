import Foundation

final class CloudClient: NSObject, URLSessionTaskDelegate {
    private var transport: URLSession?
    private func session() -> URLSession {
        if let transport {return transport}
        let c=URLSessionConfiguration.ephemeral; c.urlCache=nil; c.httpCookieStorage=nil
        c.requestCachePolicy = .reloadIgnoringLocalCacheData; c.timeoutIntervalForRequest=12; c.timeoutIntervalForResource=13
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
    struct Packet:Encodable { let context:CloudContext, image:String }
    func plan(endpoint:URL,context:CloudContext,jpeg:Data) async throws -> PlannerReply {
        guard !jpeg.isEmpty,jpeg.count<=360_000 else {throw SpatialError.invalid}
        var req=URLRequest(url:endpoint);req.httpMethod="POST";req.setValue("application/json",forHTTPHeaderField:"Content-Type")
        req.httpBody=try JSONEncoder().encode(Packet(context:context,image:jpeg.base64EncodedString()))
        let (data,response)=try await session().data(for:req)
        guard let response=response as? HTTPURLResponse,response.statusCode==200 else {throw SpatialError.invalid}
        return try PlannerReply.parse(data,for:context.capture.sample.id)
    }
}
