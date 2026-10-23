import Foundation

/// Share / deep-link formats (brief 003, REC-01):
/// - custom scheme `souslens://recipe/{recipe_id}`
/// - universal link `https://souslens.app/r/{recipe_id}` (association is a stub in this slice;
///   the domain is not live, but the path is handled when iOS hands it to the app).
enum ShareLinks {
    static let scheme = "souslens"
    static let universalHost = "souslens.app"

    static func universal(recipeId: UUID) -> URL {
        URL(string: "https://\(universalHost)/r/\(recipeId.uuidString.lowercased())")!
    }

    static func custom(recipeId: UUID) -> URL {
        URL(string: "\(scheme)://recipe/\(recipeId.uuidString.lowercased())")!
    }
}

enum DeepLink: Equatable, Sendable {
    case recipe(UUID)

    /// Returns nil for anything that is not one of the two recipe link forms. Trailing slashes and
    /// upper-case UUIDs are tolerated; extra path components, other hosts and other schemes are not.
    static func parse(_ url: URL) -> DeepLink? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased()
        else { return nil }
        let host = components.host?.lowercased() ?? ""
        let segments = components.path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)

        switch scheme {
        case ShareLinks.scheme:
            // souslens://recipe/{id} → host "recipe", path "/{id}"
            guard host == "recipe", segments.count == 1 else { return nil }
            return UUID(uuidString: segments[0]).map(DeepLink.recipe)
        case "https":
            // Only the exact host in the associated-domains entitlement (`applinks:souslens.app`).
            guard host == ShareLinks.universalHost,
                  segments.count == 2, segments[0] == "r"
            else { return nil }
            return UUID(uuidString: segments[1]).map(DeepLink.recipe)
        default:
            return nil
        }
    }
}
