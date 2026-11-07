using System.Text.Json.Serialization;

namespace ImgShare.Core;

// ---------- Wire-Format des Servers ----------

public sealed class EncryptedMessage
{
    [JsonPropertyName("id")] public long Id { get; set; }
    [JsonPropertyName("server_ts")] public DateTimeOffset ServerTs { get; set; }
    [JsonPropertyName("ciphertext")] public string Ciphertext { get; set; } = "";
}

public sealed class MessagesPage
{
    [JsonPropertyName("messages")] public List<EncryptedMessage> Messages { get; set; } = new();
    [JsonPropertyName("has_more")] public bool HasMore { get; set; }
}

public sealed class PostMessageResult
{
    [JsonPropertyName("id")] public long Id { get; set; }
    [JsonPropertyName("server_ts")] public DateTimeOffset ServerTs { get; set; }
}

public sealed class BlobResult
{
    [JsonPropertyName("blob_id")] public string BlobId { get; set; } = "";
    [JsonPropertyName("size")] public long Size { get; set; }
}

// ---------- Verschlüsselter Klartext (nur Clients sehen das) ----------

public static class MessageKind
{
    public const string Text = "text";
    public const string Image = "image";
    public const string Read = "read";
}

public sealed class Payload
{
    [JsonPropertyName("v")] public int Version { get; set; } = 1;
    [JsonPropertyName("kind")] public string Kind { get; set; } = MessageKind.Text;
    [JsonPropertyName("sender")] public string Sender { get; set; } = "";
    [JsonPropertyName("sender_name")] public string SenderName { get; set; } = "";
    [JsonPropertyName("sent_at")] public DateTimeOffset SentAt { get; set; }
    [JsonPropertyName("text")] public string? Text { get; set; }
    [JsonPropertyName("image")] public ImageInfo? Image { get; set; }
    [JsonPropertyName("read_up_to")] public long? ReadUpTo { get; set; }
}

public sealed class ImageInfo
{
    [JsonPropertyName("blob_id")] public string BlobId { get; set; } = "";
    [JsonPropertyName("mime")] public string Mime { get; set; } = "";
    [JsonPropertyName("filename")] public string FileName { get; set; } = "";
    [JsonPropertyName("size")] public long Size { get; set; }
    [JsonPropertyName("width")] public int Width { get; set; }
    [JsonPropertyName("height")] public int Height { get; set; }
}

/// <summary>Entschlüsselte, anzeigbare Nachricht.</summary>
public sealed class ChatMessage
{
    public long Id { get; init; }
    public DateTimeOffset ServerTs { get; init; }
    public required Payload Payload { get; init; }
    public bool IsMine { get; init; }

    public string Kind => Payload.Kind;
    public string? Text => Payload.Text;
    public ImageInfo? Image => Payload.Image;
}

public enum ConnectionState { Connecting, Online, Offline }
