using System.Security.Cryptography;
using System.Text;

namespace ImgShare.Core;

/// <summary>
/// Alle aus dem preshared Root-Key abgeleiteten Werte (siehe docs/PROTOCOL.md, Abschnitt 2).
/// </summary>
public sealed class ChatKeys
{
    static readonly byte[] Salt = Encoding.ASCII.GetBytes("imgshare-v1");
    public const int RootKeyLength = 32;

    public byte[] EncKey { get; }
    public string RoomId { get; }
    public byte[] Token { get; }
    public string SafetyCode { get; }

    ChatKeys(byte[] encKey, string roomId, byte[] token, string safetyCode)
    {
        EncKey = encKey; RoomId = roomId; Token = token; SafetyCode = safetyCode;
    }

    public static ChatKeys Derive(byte[] rootKey)
    {
        if (rootKey.Length != RootKeyLength)
            throw new ArgumentException("Root-Key muss 32 Bytes lang sein.");

        byte[] Kdf(string info, int len) =>
            HKDF.DeriveKey(HashAlgorithmName.SHA256, rootKey, len, Salt, Encoding.ASCII.GetBytes(info));

        var enc = Kdf("enc", 32);
        var room = Convert.ToHexString(Kdf("room", 16)).ToLowerInvariant();
        var token = Kdf("auth", 32);
        var safetyBytes = Kdf("safety", 8);
        ulong n = BitConverter.ToUInt64(safetyBytes, 0) % 1_000_000_000_000UL;
        var s = n.ToString("D12");
        var safety = $"{s[..3]} {s[3..6]} · {s[6..9]} {s[9..]}";
        return new ChatKeys(enc, room, token, safety);
    }

    public static byte[] GenerateRootKey() => RandomNumberGenerator.GetBytes(RootKeyLength);

    public string TokenBase64Url =>
        Convert.ToBase64String(Token).TrimEnd('=').Replace('+', '-').Replace('/', '_');

    /// <summary>AES-256-GCM: Ausgabe = nonce(12) || ciphertext || tag(16). AAD = room_id.</summary>
    public byte[] Encrypt(ReadOnlySpan<byte> plaintext)
    {
        var output = new byte[12 + plaintext.Length + 16];
        var nonce = output.AsSpan(0, 12);
        RandomNumberGenerator.Fill(nonce);
        using var aes = new AesGcm(EncKey, 16);
        aes.Encrypt(nonce, plaintext, output.AsSpan(12, plaintext.Length),
            output.AsSpan(12 + plaintext.Length, 16), Encoding.ASCII.GetBytes(RoomId));
        return output;
    }

    public byte[] Decrypt(ReadOnlySpan<byte> data)
    {
        if (data.Length < 28) throw new CryptographicException("Daten zu kurz.");
        var plain = new byte[data.Length - 28];
        using var aes = new AesGcm(EncKey, 16);
        aes.Decrypt(data[..12], data.Slice(12, plain.Length), data[^16..], plain,
            Encoding.ASCII.GetBytes(RoomId));
        return plain;
    }
}

/// <summary>Darstellung des Root-Keys als Base32 (RFC 4648) in 4er-Gruppen.</summary>
public static class KeyFormat
{
    const string Alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567";

    public static string Format(byte[] key)
    {
        var sb = new StringBuilder();
        int buffer = 0, bits = 0;
        foreach (var b in key)
        {
            buffer = (buffer << 8) | b; bits += 8;
            while (bits >= 5) { sb.Append(Alphabet[(buffer >> (bits - 5)) & 31]); bits -= 5; }
        }
        if (bits > 0) sb.Append(Alphabet[(buffer << (5 - bits)) & 31]);
        var raw = sb.ToString();
        return string.Join("-", Enumerable.Range(0, (raw.Length + 3) / 4)
            .Select(i => raw.Substring(i * 4, Math.Min(4, raw.Length - i * 4))));
    }

    public static bool TryParse(string? text, out byte[] key)
    {
        key = Array.Empty<byte>();
        if (string.IsNullOrWhiteSpace(text)) return false;
        var clean = new StringBuilder();
        foreach (var ch in text.ToUpperInvariant())
        {
            var c = ch switch { '0' => 'O', '1' => 'I', _ => ch };
            if (Alphabet.Contains(c)) clean.Append(c);
            else if (char.IsLetterOrDigit(c)) return false;
        }
        var bytes = new List<byte>();
        int buffer = 0, bits = 0;
        foreach (var c in clean.ToString())
        {
            buffer = (buffer << 5) | Alphabet.IndexOf(c); bits += 5;
            if (bits >= 8) { bytes.Add((byte)(buffer >> (bits - 8))); bits -= 8; }
            buffer &= (1 << bits) - 1;
        }
        if (bytes.Count != ChatKeys.RootKeyLength) return false;
        // Rest-Bits müssen 0 sein, sonst Tippfehler im letzten Zeichen
        if (buffer != 0) return false;
        key = bytes.ToArray();
        return true;
    }
}
