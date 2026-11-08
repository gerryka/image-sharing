import Foundation
import Testing
@testable import ImgShareCore

struct ErrorTextTests {
    func http(_ s: Int, _ c: String? = nil) -> String { ErrorText.describe(ApiError.http(status: s, code: c)) }

    @Test func apiErrors() {
        #expect(http(401) == "Zugriff verweigert – passt der Schlüssel?")
        #expect(http(403, "invite_required") == "Der Chat existiert auf dem Server noch nicht. Zum Anlegen braucht es den Server-Zugangscode.")
        #expect(http(413) == "Datei ist zu groß für den Server.")
        #expect(http(429) == "Zu viele Anfragen, bitte kurz warten.")
        #expect(http(507, "quota_exceeded") == "Der Speicher für diesen Chat am Server ist voll.")
        #expect(http(507, "room_limit") == "Auf dem Server können keine weiteren Chats angelegt werden.")
        #expect(http(507) == "Der Server hat keinen freien Speicher mehr.")
        #expect(http(500, "x") == "Serverfehler 500 (x)")
        #expect(http(502) == "Serverfehler 502")
    }

    @Test func urlErrors() {
        #expect(ErrorText.describe(URLError(.cannotConnectToHost)) == "Server nicht erreichbar.")
        #expect(ErrorText.describe(URLError(.serverCertificateUntrusted)) == "Das Zertifikat des Servers ist ungültig.")
        #expect(ErrorText.describe(URLError(.timedOut)) == "Der Server antwortet nicht.")
        #expect(ErrorText.describe(URLError(.networkConnectionLost)) == "Die Verbindung zum Server wurde unterbrochen.")
    }

    @Test func cryptoAndUrlValidation() {
        #expect(ErrorText.describe(CryptoError.authenticationFailed) == "Daten konnten nicht entschlüsselt werden.")
        #expect(ErrorText.describe(ApiError.httpsRequired) == "Die Server-Adresse muss mit https:// beginnen.")
        #expect(ErrorText.describe(ApiError.invalidServerURL) == "Ungültige Server-Adresse.")
    }
}
