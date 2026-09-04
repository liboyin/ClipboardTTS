import Foundation

/// Builds a successful metadata response carrying `json`, shared by the metadata test files.
///
/// Model discovery is the only metadata request the app issues, so both the publication tests
/// and the request-lifecycle tests drive it through this one response shape.
func metadataResponse(for request: URLRequest, json: String) -> (HTTPURLResponse, Data?) {
    guard let url = request.url,
          let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil) else {
        return (HTTPURLResponse(), Data())
    }
    return (response, Data(json.utf8))
}
