import Combine
import Foundation
import Security

@MainActor
final class CertificateInstaller: ObservableObject {
    @Published var needsInstall = false
    @Published var isInstalling = false
    @Published var installError: String? = nil
    @Published var installed = false

    private let certCN = "noSpeakerUI Root CA"

    func checkIfNeeded() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassCertificate,
            kSecMatchSubjectContains as String: certCN,
            kSecReturnRef as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        needsInstall = status == errSecItemNotFound
        installed = !needsInstall
    }

    func installCertificate() async {
        guard let certURL = Bundle.main.url(forResource: "nospeakerCA", withExtension: "crt") else {
            installError = "Certificate file not found in app bundle."
            return
        }
        isInstalling = true
        installError = nil
        defer { isInstalling = false }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        proc.arguments = [
            "add-trusted-cert",
            "-k", FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Keychains/login.keychain-db").path,
            "-r", "trustRoot",
            certURL.path
        ]
        let pipe = Pipe()
        proc.standardError = pipe
        do {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                proc.terminationHandler = { _ in continuation.resume() }
                do { try proc.run() }
                catch {
                    proc.terminationHandler = nil
                    installError = "Could not run security tool: \(error.localizedDescription)"
                    continuation.resume()
                }
            }
            guard proc.processIdentifier != 0 else { return }
            if proc.terminationStatus == 0 {
                needsInstall = false
                installed = true
            } else {
                let errData = pipe.fileHandleForReading.readDataToEndOfFile()
                let errMsg = String(data: errData, encoding: .utf8) ?? "Unknown error"
                installError = "Installation failed: \(errMsg)"
            }
        } catch {
            installError = "Could not run security tool: \(error.localizedDescription)"
        }
    }
}
