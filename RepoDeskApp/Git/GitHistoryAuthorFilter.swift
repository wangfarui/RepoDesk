import Foundation

enum GitHistoryAuthorFilter: Equatable, Hashable, Sendable, Codable {
    case all
    case me
    case author(String)

    private enum CodingKeys: String, CodingKey {
        case kind
        case author
    }

    private enum Kind: String, Codable {
        case all
        case me
        case author
    }

    init(from decoder: Decoder) throws {
        if let legacyAuthor = try? decoder.singleValueContainer().decode(String.self) {
            self = .author(legacyAuthor)
            return
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .all:
            self = .all
        case .me:
            self = .me
        case .author:
            self = .author(try container.decode(String.self, forKey: .author))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .all:
            try container.encode(Kind.all, forKey: .kind)
        case .me:
            try container.encode(Kind.me, forKey: .kind)
        case .author(let author):
            try container.encode(Kind.author, forKey: .kind)
            try container.encode(author, forKey: .author)
        }
    }
}
