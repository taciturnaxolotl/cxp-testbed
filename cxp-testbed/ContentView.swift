import SwiftUI
import AuthenticationServices
import UniformTypeIdentifiers

struct ContentView: View {
    @State private var showFilePicker = false
    @State private var statusMessage = "Load a CXF JSON file to begin"
    @State private var cxfData: CxfHeader?
    @State private var isExporting = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Image(systemName: "key.fill")
                    .font(.system(size: 60))
                    .foregroundStyle(.blue)

                Text("CXP Passkey Exporter")
                    .font(.title2.bold())

                if let data = cxfData {
                    VStack(spacing: 8) {
                        Text("\(data.accounts.first?.items.count ?? 0) passkeys loaded")
                            .font(.headline)
                            .foregroundStyle(.green)

                        Text("From: \(data.exporterDisplayName)")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }

                Button {
                    showFilePicker = true
                } label: {
                    Label("Load CXF JSON", systemImage: "doc.badge.plus")
                        .frame(maxWidth: .infinity)
                        .padding()
                }
                .buttonStyle(.borderedProminent)

                if cxfData != nil {
                    Button {
                        startExport()
                    } label: {
                        Label("Export to Another App", systemImage: "square.and.arrow.up")
                            .frame(maxWidth: .infinity)
                            .padding()
                    }
                    .buttonStyle(.bordered)
                    .disabled(isExporting)
                }

                Text(statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)

                Spacer()
            }
            .padding()
            .navigationTitle("CXP Testbed")
            .fileImporter(
                isPresented: $showFilePicker,
                allowedContentTypes: [.json],
                allowsMultipleSelection: false
            ) { result in
                handleFileImport(result)
            }
        }
    }

    private func handleFileImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }

            let accessing = url.startAccessingSecurityScopedResource()
            defer {
                if accessing { url.stopAccessingSecurityScopedResource() }
            }

            do {
                let data = try Data(contentsOf: url)
                let header = try JSONDecoder().decode(CxfHeader.self, from: data)

                guard !header.accounts.isEmpty,
                      !(header.accounts.first?.items.isEmpty ?? true) else {
                    statusMessage = "Error: No items found in CXF file"
                    return
                }

                cxfData = header
                statusMessage = "Ready to export"
            } catch {
                statusMessage = "Error parsing CXF: \(error.localizedDescription)"
            }

        case .failure(let error):
            statusMessage = "File error: \(error.localizedDescription)"
        }
    }

    private func decodeBase64url(_ string: String) -> Data? {
        var s = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let pad = s.count % 4
        if pad != 0 { s += String(repeating: "=", count: 4 - pad) }
        return Data(base64Encoded: s)
    }

    private func startExport() {
        guard let cxfData else { return }
        isExporting = true
        statusMessage = "Preparing export..."

        guard let windowScene = UIApplication.shared.connectedScenes
            .first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene,
              let window = windowScene.keyWindow else {
            statusMessage = "Error: Could not get presentation anchor"
            isExporting = false
            return
        }

        Task { @MainActor in
            do {
                let exportManager = ASCredentialExportManager(presentationAnchor: window)
                let options = try await exportManager.requestExport(for: nil)
                let exportedData = try convertToExportedData(cxfData, formatVersion: options.formatVersion)
                try await exportManager.exportCredentials(exportedData)

                statusMessage = "Export complete!"
                isExporting = false
            } catch {
                let ns = error as NSError
                statusMessage = "Export failed [\(ns.domain) \(ns.code)]: \(error.localizedDescription)"
                isExporting = false
            }
        }
    }

    private func convertToExportedData(
        _ header: CxfHeader,
        formatVersion: ASExportedCredentialData.FormatVersion
    ) throws -> ASExportedCredentialData {
        var accounts: [ASImportableAccount] = []

        for account in header.accounts {
            var items: [ASImportableItem] = []

            for item in account.items {
                var credentials: [ASImportableCredential] = []

                for cred in item.credentials {
                    switch cred {
                    case .passkey(let pk):
                        guard let keyData = decodeBase64url(pk.key),
                              let credIdData = decodeBase64url(pk.credentialId),
                              let userHandleData = decodeBase64url(pk.userHandle) else {
                            continue
                        }

                        let passkey = ASImportableCredential.Passkey(
                            credentialID: credIdData,
                            relyingPartyIdentifier: pk.rpId,
                            userName: pk.username,
                            userDisplayName: pk.userDisplayName,
                            userHandle: userHandleData,
                            key: keyData
                        )
                        credentials.append(.passkey(passkey))

                    case .basicAuth(let ba):
                        let basicAuth = ASImportableCredential.BasicAuthentication(
                            userName: ba.username.map {
                                ASImportableEditableField(
                                    id: nil,
                                    fieldType: .string,
                                    value: $0
                                )
                            },
                            password: ba.password.map {
                                ASImportableEditableField(
                                    id: nil,
                                    fieldType: .concealedString,
                                    value: $0
                                )
                            }
                        )
                        credentials.append(.basicAuthentication(basicAuth))

                    case .unknown:
                        break
                    }
                }

                guard !credentials.isEmpty else { continue }

                let itemId = item.id.data(using: .utf8) ?? Data()

                let created = item.creationAt.map { Date(timeIntervalSince1970: TimeInterval($0)) }
                let lastModified = item.modifiedAt.map { Date(timeIntervalSince1970: TimeInterval($0)) } ?? created

                let importableItem: ASImportableItem
                if let created, let lastModified {
                    importableItem = ASImportableItem(
                        id: itemId,
                        created: created,
                        lastModified: lastModified,
                        title: item.title,
                        credentials: credentials
                    )
                } else {
                    importableItem = ASImportableItem(
                        id: itemId,
                        title: item.title,
                        credentials: credentials
                    )
                }
                items.append(importableItem)
            }

            let accountId = account.id.data(using: .utf8) ?? Data()

            let importableAccount = ASImportableAccount(
                id: accountId,
                userName: account.username,
                email: account.email,
                fullName: nil,
                collections: [],
                items: items
            )
            accounts.append(importableAccount)
        }

        return ASExportedCredentialData(
            accounts: accounts,
            formatVersion: formatVersion,
            exporterRelyingPartyIdentifier: header.exporterRpId,
            exporterDisplayName: header.exporterDisplayName,
            timestamp: Date(timeIntervalSince1970: TimeInterval(header.timestamp))
        )
    }
}
