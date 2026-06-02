import AuthenticationServices
import Observation

@Observable
@MainActor
final class CredentialStore {
    var exportedData: ASExportedCredentialData?
    var statusMessage = "Waiting for incoming CXP transfer"

    func load(_ data: ASExportedCredentialData) {
        exportedData = data
        statusMessage = ""
    }
}
