using System;
using System.ComponentModel;
using System.Globalization;
using System.Runtime.CompilerServices;
using System.Windows;
using System.Windows.Media.Imaging;
using ImgShare.Core;

namespace ImgShare.Ui;

/// <summary>Eine Zeile in der Chatliste: Datumstrenner, Nachricht oder lokal ausstehende Nachricht.</summary>
public sealed class MessageItem : INotifyPropertyChanged
{
    static readonly CultureInfo De = new("de-AT");
    const double MaxImageW = 280, MaxImageH = 320;

    public event PropertyChangedEventHandler? PropertyChanged;
    void Set<T>(ref T field, T value, [CallerMemberName] string? name = null)
    {
        if (Equals(field, value)) return;
        field = value;
        Changed(name!);
        Changed(nameof(AccessibleText));
    }
    void Changed(string name) => PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(name));

    // ---- Datumstrenner
    public bool IsSeparator { get; private init; }
    public string? SeparatorText { get; private init; }
    public DateTime Day { get; private init; }

    public static MessageItem Separator(DateTime day)
    {
        var today = DateTime.Today;
        string text = day == today ? "Heute"
            : day == today.AddDays(-1) ? "Gestern"
            : day.Year == today.Year ? day.ToString("dddd, d. MMMM", De)
            : day.ToString("d. MMMM yyyy", De);
        return new MessageItem { IsSeparator = true, SeparatorText = text, Day = day };
    }

    // ---- Nachricht
    public ChatMessage? Message { get; private init; }
    public long Id => Message?.Id ?? long.MaxValue;
    public bool IsMine { get; private init; }
    public string PeerName { get; private init; } = "";
    public string? Text { get; private init; }
    public bool HasText => !string.IsNullOrEmpty(Text);
    public bool HasImage { get; private init; }
    public ImageInfo? ImageInfo => Message?.Image;
    public string FileName { get; private init; } = "bild.png";
    public string? ImageCaption { get; private init; }
    public double ImageWidth { get; private init; }
    public double ImageHeight { get; private init; }
    public string TimeText { get; private init; } = "";
    public DateTime LocalTime { get; private init; }

    public HorizontalAlignment Align => IsMine ? HorizontalAlignment.Right : HorizontalAlignment.Left;
    public CornerRadius BubbleRadius => IsMine ? new CornerRadius(12, 4, 12, 12) : new CornerRadius(4, 12, 12, 12);
    public Thickness BubblePadding => HasImage ? new Thickness(4) : new Thickness(12, 8, 12, 8);

    BitmapSource? _thumbnail;
    public BitmapSource? Thumbnail { get => _thumbnail; set { Set(ref _thumbnail, value); Changed(nameof(IsLoadingImage)); } }
    public bool IsLoadingImage => HasImage && _thumbnail is null && !_imageFailed;

    bool _imageFailed;
    public bool ImageFailed { get => _imageFailed; set { Set(ref _imageFailed, value); Changed(nameof(IsLoadingImage)); } }

    bool _isRead;
    public bool IsRead { get => _isRead; set { Set(ref _isRead, value); Changed(nameof(IsDelivered)); } }
    public bool IsDelivered => IsMine && !IsPending && !IsFailed && !_isRead;

    bool _isPending;
    public bool IsPending { get => _isPending; set { Set(ref _isPending, value); Changed(nameof(IsDelivered)); } }

    string? _status;
    public string? StatusText { get => _status; set { Set(ref _status, value); Changed(nameof(HasStatus)); } }
    public bool HasStatus => !string.IsNullOrEmpty(_status);

    bool _failed;
    public bool IsFailed { get => _failed; set { Set(ref _failed, value); Changed(nameof(IsDelivered)); } }

    /// <summary>Lokale Daten für erneutes Senden.</summary>
    public string? RetryText { get; private init; }
    public PendingImage? RetryImage { get; private init; }

    /// <summary>Vorlesetext für Screenreader.</summary>
    public string AccessibleText
    {
        get
        {
            if (IsSeparator) return SeparatorText ?? "";
            var who = IsMine ? "Ich" : PeerName;
            var what = HasImage ? $"Bild {ImageCaption}" : Text;
            var state = IsFailed ? ", nicht gesendet" : IsPending ? ", wird gesendet"
                : IsMine && _isRead ? ", gelesen" : IsMine ? ", zugestellt" : "";
            return $"{who}, {TimeText}: {what}{state}";
        }
    }

    static (double w, double h) Fit(int w, int h)
    {
        if (w <= 0 || h <= 0) return (MaxImageW, 160);
        double scale = Math.Min(1, Math.Min(MaxImageW / w, MaxImageH / h));
        return (Math.Max(48, w * scale), Math.Max(48, h * scale));
    }

    public static MessageItem From(ChatMessage m, string peerName)
    {
        var local = m.ServerTs.ToLocalTime().DateTime;
        var time = local.ToString("HH:mm", De);
        if (m.Image is not { } img)
            return new MessageItem { Message = m, IsMine = m.IsMine, PeerName = peerName, Text = m.Text, LocalTime = local, TimeText = time };

        var (w, h) = Fit(img.Width, img.Height);
        var name = ImageFormat.SafeFileName(img.FileName, img.Mime);
        return new MessageItem
        {
            Message = m, IsMine = m.IsMine, PeerName = peerName, HasImage = true, LocalTime = local, TimeText = time,
            ImageWidth = w, ImageHeight = h, FileName = name,
            ImageCaption = $"{name} · {ImageFormat.FormatSize(img.Size)}",
        };
    }

    public static MessageItem PendingText(string text) => new()
    {
        IsMine = true, Text = text, RetryText = text, LocalTime = DateTime.Now,
        TimeText = DateTime.Now.ToString("HH:mm", De), IsPending = true, StatusText = "Wird gesendet …"
    };

    public static MessageItem PendingImg(PendingImage img)
    {
        var (w, h) = Fit(img.Width, img.Height);
        return new MessageItem
        {
            IsMine = true, HasImage = true, RetryImage = img, LocalTime = DateTime.Now, FileName = img.FileName,
            TimeText = DateTime.Now.ToString("HH:mm", De), ImageWidth = w, ImageHeight = h,
            ImageCaption = $"{img.FileName} · {ImageFormat.FormatSize(img.Bytes.Length)}",
            Thumbnail = img.Preview, IsPending = true, StatusText = "Wird verschlüsselt hochgeladen …"
        };
    }
}
