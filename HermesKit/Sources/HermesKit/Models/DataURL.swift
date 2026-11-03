import Foundation

/// Pure parser for the `data:` URLs `/api/fs/read-data-url` answers with
/// (`data:<mime>;base64,<payload>`). Base64 ONLY — the server never emits the percent-encoded
/// form, so a URL without `;base64` is treated as malformed rather than decoded leniently.
public enum DataURL {
  /// The media type and decoded bytes of a base64 data URL, or nil when the string is not one:
  /// a different scheme, no `,` separator, no `;base64` immediately before the separator, or
  /// a payload that is not valid (padded) base64. The media type is the token before the first
  /// `;` (parameters such as `;charset=` are dropped); an empty media type is nil.
  ///
  /// An EMPTY payload is well-formed and yields empty `Data` — a 0-byte file on the agent is a
  /// real file, and `.decoding` ("is this a Hermes server?") would misdescribe it; the preview
  /// falls back to the generic card when the bytes don't decode as an image.
  public static func parse(_ string: String) -> (mimeType: String?, data: Data)? {
    let prefix = "data:"
    guard string.prefix(prefix.count).lowercased() == prefix else { return nil }
    let body = string.dropFirst(prefix.count)
    guard let comma = body.firstIndex(of: ",") else { return nil }

    let header = body[..<comma]
    let parameters = header.split(separator: ";", omittingEmptySubsequences: false)
    // `;base64` must be the LAST header parameter (`data:image/png;base64,`); anywhere else
    // (`data:;base64;charset=x,`) is not a shape the server produces.
    guard parameters.count >= 2, parameters.last?.lowercased() == "base64" else { return nil }

    let payload = String(body[body.index(after: comma)...])
    guard let data = Data(base64Encoded: payload) else { return nil }

    let mime = parameters[0].trimmingCharacters(in: .whitespaces)
    return (mimeType: mime.isEmpty ? nil : mime, data: data)
  }
}
