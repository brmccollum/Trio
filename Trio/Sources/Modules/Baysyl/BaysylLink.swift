import Foundation

/// The optional build-time link to the Baysyl page. Display only: the app only ever opens it in the browser.
///
/// The address is never in the source. A private build passes it as the build setting `BRYAN_BASAL_URL`,
/// which lands in Info.plist under `BryanBasalURL`; in a normal build the value is empty and every
/// Baysyl entry point stays hidden.
enum BaysylLink {
    static let infoKey = "BryanBasalURL"

    /// The link, or nil unless the build set a valid https address.
    static var url: URL? {
        validatedHTTPSURL(from: (Bundle.main.object(forInfoDictionaryKey: infoKey) as? String) ?? "")
    }

    /// Trims the text and accepts only absolute https URLs with a host.
    static func validatedHTTPSURL(from text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let url = URL(string: trimmed),
              url.scheme?.lowercased() == "https",
              let host = url.host, !host.isEmpty
        else { return nil }
        return url
    }
}
