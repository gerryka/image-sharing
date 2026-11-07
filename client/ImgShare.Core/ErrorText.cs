using System.Net.Http;
using System.Net.WebSockets;
using System.Security.Cryptography;

namespace ImgShare.Core;

/// <summary>Übersetzt technische Ausnahmen in kurze deutsche Meldungen für die Oberfläche.</summary>
public static class ErrorText
{
    public static string Describe(Exception ex) => ex switch
    {
        ApiException a => a.Message,
        HttpRequestException { InnerException: System.Security.Authentication.AuthenticationException } =>
            "Das Zertifikat des Servers ist ungültig.",
        HttpRequestException => "Server nicht erreichbar.",
        TaskCanceledException or TimeoutException or OperationCanceledException => "Der Server antwortet nicht.",
        WebSocketException => "Die Verbindung zum Server wurde unterbrochen.",
        CryptographicException => "Daten konnten nicht entschlüsselt werden.",
        InvalidDataException => ex.Message,
        UnauthorizedAccessException => "Kein Zugriff auf die Datei.",
        IOException => "Die Datei konnte nicht gelesen oder geschrieben werden.",
        _ => "Unerwarteter Fehler: " + ex.Message
    };
}
