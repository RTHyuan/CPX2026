import CryptoKit
import Foundation
import ImageIO
import Security

/// The paired developer can enroll this app instance once. The provider credential never travels with the bundle.
enum DeviceCloudCredential {
    private static let identity: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "org.crosspointx.pathsense.direct-cloud",
        kSecAttrAccount as String: "deepseek",
        kSecAttrSynchronizable as String: false
    ]

    static func read() throws -> String {
        var query = identity
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data, let token = String(data: data, encoding: .utf8), !token.isEmpty else { throw SpatialError.invalid }
        return token
    }

    static func importEnrollmentIfPresent() throws {
        let fm = FileManager.default
        let file = fm.temporaryDirectory.appendingPathComponent("PathSense-CloudEnrollment")
        guard fm.fileExists(atPath: file.path) else { return }
        try fm.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: file.path)
        let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true, (16...512).contains(values.fileSize ?? 0) else {
            try fm.removeItem(at: file); throw SpatialError.invalid
        }
        let data = try Data(contentsOf: file)
        guard data.allSatisfy({ (33...126).contains($0) }) else { try fm.removeItem(at: file); throw SpatialError.invalid }
        let fields: [String: Any] = [kSecValueData as String: data, kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        let status = SecItemUpdate(identity as CFDictionary, fields as CFDictionary)
        if status == errSecItemNotFound {
            let new = identity.merging(fields) { _, value in value }
            guard SecItemAdd(new as CFDictionary, nil) == errSecSuccess else { throw SpatialError.invalid }
        } else if status != errSecSuccess { throw SpatialError.invalid }
        try fm.removeItem(at: file)
    }
}


/// Pairing installs the relay address. Permission to send camera frames is specific to that address.
enum CloudPairing {
    private static var file: URL { URL.libraryDirectory.appendingPathComponent("PathSense-Relay.txt") }
    private static let consentKey = "cloudCameraConsentForEndpoint"
    private static func fingerprint(_ address: String) -> Data { Data(SHA256.hash(data: Data(address.utf8))) }

    static func load() -> (address: String, consent: Bool)? {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return nil }
        let address = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard CloudClient.endpoint(address) != nil else { return nil }
        return (address, UserDefaults.standard.data(forKey: consentKey) == fingerprint(address))
    }

    static func save(_ address: String, consent: Bool) throws {
        if !consent { UserDefaults.standard.removeObject(forKey: consentKey) }
        let address = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard CloudClient.endpoint(address) != nil else { throw SpatialError.invalid }
        try Data(address.utf8).write(to: file, options: [.atomic, .completeFileProtection])
        var url = file, values = URLResourceValues()
        values.isExcludedFromBackup = true
        try url.setResourceValues(values)
        if consent { UserDefaults.standard.set(fingerprint(address), forKey: consentKey) }
    }
}

struct CloudCheckReceipt: Encodable {
    let run = UUID().uuidString
    let start = Date()
    let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
    let source = "bundled CC0 route-door.jpg"
    let pose = "injected for public test image"
    let wireVersion = 2
    var transport = "paired-relay", providerHost: String?, model: String?
    var status = "checking", outcome: String?, frame: FrameID?, observations: [String]?, seconds: Double?

    func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(self) {
            try? data.write(to: URL.cachesDirectory.appendingPathComponent("PathSense-CloudCheck.json"), options: .atomic)
        }
    }
}

extension CloudClient {
    /// This check exercises the production v2 request, parser and frame binding without opening the camera.
    func checkWithPublicPhoto(endpoint: URL) async throws -> PlannerReply {
        guard let photo = Bundle.main.url(forResource: "route-door", withExtension: "jpg"),
              let jpg = try? Data(contentsOf: photo), let image = CGImageSourceCreateWithData(jpg as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(image, 0, nil) as? [CFString: Any],
              let width = props[kCGImagePropertyPixelWidth] as? Int, let height = props[kCGImagePropertyPixelHeight] as? Int else { throw SpatialError.invalid }
        let session = UUID(), focal = 0.55 * Double(width)
        let capture = FramePose(id: .init(session: session, world: 1, frame: 1), time: 1,
            transform: [1,0,0,0, 0,1,0,0, 0,0,1,0, 0,1.4,0,1], intrinsics: [focal,0,0, 0,focal,0, Double(width)/2,Double(height)/2,1],
            width: width, height: height, exif: 1, tracking: "normal")
        var request = capture
        request.id.frame += 1
        request.time += 0.1
        let goal = Destination.facility(.restroom)
        let context = CloudContext(utterance: "带我去厕所", destination: goal.text, stage: "环顾四周", trigger: "first_observation",
            capture: PosePacket(capture), request: PosePacket(request), history: [], image_width: width, image_height: height,
            features: [], scanned_bins: [], known: [], recent_hazards: [], last_instruction: "", turned_since_instruction: 0, moved_since_instruction: 0, sign_history: [])
        return try await plan(endpoint: endpoint, context: context, jpeg: jpg, history: [],
                              planning: PlanningSnapshot(WayfindingJourney(target: goal)), executionState: "observing")
    }
}
