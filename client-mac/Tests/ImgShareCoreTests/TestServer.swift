import Foundation
@testable import ImgShareCore

/// Integrationstests laufen nur, wenn ein Dev-Server bereitsteht:
///   go run ./tools/devserver -addr 127.0.0.1:47001
///   go run ./tools/devserver -addr 127.0.0.1:47002 -drop-after 2s
///   IMGSHARE_TEST_SERVER=http://127.0.0.1:47001 IMGSHARE_TEST_SERVER_FLAKY=http://127.0.0.1:47002 swift test
enum TestServer {
    static let url: URL? = ProcessInfo.processInfo.environment["IMGSHARE_TEST_SERVER"].flatMap(URL.init(string:))
    static let flakyURL: URL? = ProcessInfo.processInfo.environment["IMGSHARE_TEST_SERVER_FLAKY"].flatMap(URL.init(string:))
    static let invite = "devinvite-0123456789"
}

/// Pollt eine Bedingung (MainActor) bis zum Timeout.
@MainActor
func eventually(timeout: Duration = .seconds(5), _ condition: @MainActor () -> Bool) async -> Bool {
    let end = ContinuousClock.now + timeout
    while ContinuousClock.now < end {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return condition()
}
