import CryptoKit
import Darwin
import Foundation
import Security

// On the wire: Security.framework's authenticated ECIES ciphertext for the app's X9.63 public key.
private let algorithm = SecKeyAlgorithm.eciesEncryptionCofactorVariableIVX963SHA256AESGCM
private enum EnrollmentError: Error { case input, recipient, seal, selfTest }

private func importKey(_ bytes: Data, keyClass: CFString) throws -> SecKey {
    let attributes: [CFString: Any] = [kSecAttrKeyType: kSecAttrKeyTypeECSECPrimeRandom,
                                       kSecAttrKeySizeInBits: 256, kSecAttrKeyClass: keyClass]
    guard let key = SecKeyCreateWithData(bytes as CFData, attributes as CFDictionary, nil) else {
        throw EnrollmentError.recipient
    }
    return key
}

private func publicKey(_ bytes: Data) throws -> SecKey {
    guard bytes.count == 65, bytes.first == 4,
          (try? P256.KeyAgreement.PublicKey(x963Representation: bytes)) != nil else { throw EnrollmentError.recipient }
    let key = try importKey(bytes, keyClass: kSecAttrKeyClassPublic)
    guard SecKeyIsAlgorithmSupported(key, .encrypt, algorithm) else { throw EnrollmentError.recipient }
    return key
}

private func seal(_ plaintext: Data, to recipient: SecKey) throws -> Data {
    guard (16...512).contains(plaintext.count), plaintext.allSatisfy({ (33...126).contains($0) }) else {
        throw EnrollmentError.input
    }
    guard let ciphertext = SecKeyCreateEncryptedData(recipient, algorithm, plaintext as CFData, nil) as Data?,
          ciphertext.count > plaintext.count else { throw EnrollmentError.seal }
    return ciphertext
}

private func readPipe() throws -> Data {
    var info = stat()
    guard fstat(STDIN_FILENO, &info) == 0, info.st_mode & S_IFMT == S_IFIFO, isatty(STDOUT_FILENO) == 0 else {
        throw EnrollmentError.input
    }
    var result = Data()
    while result.count <= 512 {
        guard let chunk = try FileHandle.standardInput.read(upToCount: 513 - result.count), !chunk.isEmpty else { return result }
        result.append(chunk)
    }
    throw EnrollmentError.input
}

private func sealViaCLI(_ sample: Data, rawPublic: Data) throws -> Data {
    let files = FileManager.default
    let directory = files.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try files.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    defer { try? files.removeItem(at: directory) }
    let publicFile = directory.appendingPathComponent("public.bin")
    try rawPublic.write(to: publicFile)
    let child = Process(), input = Pipe(), output = Pipe()
    child.executableURL = Bundle.main.executableURL
    child.arguments = ["--seal", publicFile.path]
    child.environment = [:]
    child.standardInput = input
    child.standardOutput = output
    child.standardError = FileHandle.nullDevice
    try child.run()
    try input.fileHandleForWriting.write(contentsOf: sample)
    try input.fileHandleForWriting.close()
    let result = try output.fileHandleForReading.readToEnd() ?? Data()
    child.waitUntilExit()
    guard child.terminationStatus == 0 else { throw EnrollmentError.selfTest }
    return result
}

private func selfTest() throws {
    // Import ephemeral software keys directly into SecKey. This test never accesses the keychain or Secure Enclave.
    let first = P256.KeyAgreement.PrivateKey(), other = P256.KeyAgreement.PrivateKey()
    let receiver = try importKey(first.x963Representation, keyClass: kSecAttrKeyClassPrivate)
    let wrongReceiver = try importKey(other.x963Representation, keyClass: kSecAttrKeyClassPrivate)
    guard let exportedKey = SecKeyCopyPublicKey(receiver),
          let raw = SecKeyCopyExternalRepresentation(exportedKey, nil) as Data?,
          raw == first.publicKey.x963Representation else { throw EnrollmentError.selfTest }
    let recipient = try publicKey(raw)
    let sample = Data(UUID().uuidString.utf8)
    let box = try sealViaCLI(sample, rawPublic: raw)
    let secondBox = try seal(sample, to: recipient)
    var tampered = box
    tampered[tampered.index(before: tampered.endIndex)] ^= 1
    let recovered = SecKeyCreateDecryptedData(receiver, algorithm, box as CFData, nil) as Data?
    guard recovered == sample, box != secondBox,
          SecKeyCreateDecryptedData(wrongReceiver, algorithm, box as CFData, nil) == nil,
          SecKeyCreateDecryptedData(receiver, algorithm, tampered as CFData, nil) == nil,
          (try? publicKey(Data(raw.dropLast()))) == nil else { throw EnrollmentError.selfTest }
}

do {
    let args = Array(CommandLine.arguments.dropFirst())
    switch args.first {
    case "--self-test" where args.count == 1:
        try selfTest()
    case "--check-public-key", "--seal":
        guard args.count == 2 else { throw EnrollmentError.input }
        let recipient = try publicKey(Data(contentsOf: URL(fileURLWithPath: args[1])))
        if args[0] == "--seal" {
            var plaintext = try readPipe()
            defer { plaintext.resetBytes(in: plaintext.startIndex..<plaintext.endIndex) }
            try FileHandle.standardOutput.write(contentsOf: seal(plaintext, to: recipient))
        }
    default:
        throw EnrollmentError.input
    }
} catch {
    // In particular, never print payloads or Security.framework error descriptions.
    FileHandle.standardError.write(Data("Enrollment operation failed.\n".utf8))
    exit(1)
}
