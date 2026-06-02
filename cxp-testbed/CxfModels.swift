import Foundation

// MARK: - CXF Header (top-level)

struct CxfHeader: Codable {
    let version: CxfVersion
    let exporterRpId: String
    let exporterDisplayName: String
    let timestamp: UInt64
    let accounts: [CxfAccount]
}

struct CxfVersion: Codable {
    let major: UInt8
    let minor: UInt8
}

// MARK: - Account

struct CxfAccount: Codable {
    let id: String
    let username: String
    let email: String
    let collections: [CxfCollection]?
    let items: [CxfItem]
}

struct CxfCollection: Codable {
    let id: String
    let title: String
    let items: [CxfLinkedItem]?
}

struct CxfLinkedItem: Codable {
    let item: String
    let account: String?
}

// MARK: - Item

struct CxfItem: Codable {
    let id: String
    let title: String
    let credentials: [CxfCredential]
    let scope: CxfScope?
    let creationAt: UInt64?
    let modifiedAt: UInt64?
    let favorite: Bool?
    let tags: [String]?
}

struct CxfScope: Codable {
    let urls: [String]?
}

// MARK: - Credentials (tagged union)

enum CxfCredential: Codable {
    case passkey(CxfPasskey)
    case basicAuth(CxfBasicAuth)
    case unknown(String)

    enum CodingKeys: String, CodingKey {
        case type
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)

        switch type {
        case "passkey":
            self = .passkey(try CxfPasskey(from: decoder))
        case "basic-auth":
            self = .basicAuth(try CxfBasicAuth(from: decoder))
        default:
            self = .unknown(type)
        }
    }

    func encode(to encoder: Encoder) throws {
        switch self {
        case .passkey(let pk):
            try pk.encode(to: encoder)
        case .basicAuth(let ba):
            try ba.encode(to: encoder)
        case .unknown:
            break
        }
    }
}

// MARK: - Passkey

struct CxfPasskey: Codable {
    let credentialId: String
    let rpId: String
    let username: String
    let userDisplayName: String
    let userHandle: String
    let key: String
}

// MARK: - Basic Auth

struct CxfBasicAuth: Codable {
    let username: String?
    let password: String?
    let uris: [String]?
}
