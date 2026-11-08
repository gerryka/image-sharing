import Foundation

/// Fehler mit fertigem deutschem Text für die Oberfläche.
public protocol UserFacingError: Error {
    var message: String { get }
}

/// Übersetzt technische Fehler in kurze deutsche Meldungen (wie ErrorText.cs).
public enum ErrorText {
    public static func describe(_ error: Error) -> String {
        if let e = error as? UserFacingError { return e.message }
        if let e = error as? CryptoError {
            switch e {
            case .invalidKeyLength: return "Der Schlüssel ist ungültig."
            case .dataTooShort, .authenticationFailed: return "Daten konnten nicht entschlüsselt werden."
            }
        }
        if let e = error as? URLError {
            switch e.code {
            case .serverCertificateUntrusted, .serverCertificateHasBadDate, .serverCertificateNotYetValid,
                 .serverCertificateHasUnknownRoot, .clientCertificateRejected, .secureConnectionFailed:
                return "Das Zertifikat des Servers ist ungültig."
            case .timedOut: return "Der Server antwortet nicht."
            case .networkConnectionLost: return "Die Verbindung zum Server wurde unterbrochen."
            case .cancelled: return "Der Server antwortet nicht."
            default: return "Server nicht erreichbar."
            }
        }
        if error is CancellationError { return "Der Server antwortet nicht." }
        if let e = error as? CocoaError, e.isFileError {
            return e.code == .fileReadNoPermission || e.code == .fileWriteNoPermission
                ? "Kein Zugriff auf die Datei." : "Die Datei konnte nicht gelesen oder geschrieben werden."
        }
        return "Unerwarteter Fehler: " + error.localizedDescription
    }
}
