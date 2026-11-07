using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.Text.RegularExpressions;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Documents;
using System.Windows.Input;
using System.Windows.Media;

namespace ImgShare.Ui;

/// <summary>
/// Nachrichtentext in einer Sprechblase: auswählbar (Teilauswahl + Strg+C),
/// mit anklickbaren http/https-Links, und so breit wie der Text selbst –
/// ein normales RichTextBox würde immer die volle Breite einnehmen.
/// </summary>
public sealed class MessageText : RichTextBox
{
    static readonly Regex Url = new(@"\b(?:https?://|www\.)[^\s<>""]+", RegexOptions.IgnoreCase | RegexOptions.Compiled);

    public static readonly DependencyProperty TextProperty = DependencyProperty.Register(
        nameof(Text), typeof(string), typeof(MessageText),
        new FrameworkPropertyMetadata("", FrameworkPropertyMetadataOptions.AffectsMeasure, (d, _) => ((MessageText)d).Rebuild()));

    public static readonly DependencyProperty LinkBrushProperty = DependencyProperty.Register(
        nameof(LinkBrush), typeof(Brush), typeof(MessageText),
        new PropertyMetadata(null, (d, _) => ((MessageText)d).Rebuild()));

    public string Text { get => (string)GetValue(TextProperty); set => SetValue(TextProperty, value); }
    public Brush? LinkBrush { get => (Brush?)GetValue(LinkBrushProperty); set => SetValue(LinkBrushProperty, value); }

    public MessageText()
    {
        IsReadOnly = true;
        IsDocumentEnabled = true;   // Links klickbar trotz IsReadOnly
        IsUndoEnabled = false;
        IsTabStop = false;          // Tab springt zwischen Nachrichten, nicht in jeden Text
        AcceptsReturn = false;
        BorderThickness = new Thickness(0);
        Padding = new Thickness(0);
        Background = Brushes.Transparent;
        VerticalScrollBarVisibility = ScrollBarVisibility.Disabled;
        HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled;
        FocusVisualStyle = null;
        Rebuild();
    }

    /// <summary>Zerlegt Text in (Teilstück, Link-URI oder null).</summary>
    public static IEnumerable<(string text, Uri? link)> Split(string text)
    {
        int pos = 0;
        foreach (Match m in Url.Matches(text))
        {
            var raw = m.Value.TrimEnd('.', ',', ';', ':', '!', '?', ')');
            if (m.Index > pos) yield return (text[pos..m.Index], null);
            var target = raw.StartsWith("www.", StringComparison.OrdinalIgnoreCase) ? "https://" + raw : raw;
            if (Uri.TryCreate(target, UriKind.Absolute, out var uri) &&
                (uri.Scheme == Uri.UriSchemeHttp || uri.Scheme == Uri.UriSchemeHttps))
                yield return (raw, uri);
            else
                yield return (raw, null);
            pos = m.Index + raw.Length;
        }
        if (pos < text.Length) yield return (text[pos..], null);
    }

    void Rebuild()
    {
        var p = new Paragraph { Margin = new Thickness(0) };
        foreach (var (part, uri) in Split(Text ?? ""))
        {
            if (uri is null) { p.Inlines.Add(new Run(part)); continue; }
            var link = new Hyperlink(new Run(part)) { NavigateUri = uri, ToolTip = uri.AbsoluteUri, Cursor = Cursors.Hand };
            if (LinkBrush is { } b) link.Foreground = b;
            link.Click += (_, _) => Process.Start(new ProcessStartInfo(uri.AbsoluteUri) { UseShellExecute = true });
            p.Inlines.Add(link);
        }
        Document = new FlowDocument(p) { PagePadding = new Thickness(0) };
    }

    // Breite am Inhalt ausrichten (max. verfügbare Breite).
    protected override Size MeasureOverride(Size constraint)
    {
        const double extra = 8; // interne Ränder des Editors + Cursor
        var max = double.IsInfinity(constraint.Width) ? 4000 : constraint.Width;
        var ft = new FormattedText(Text ?? "", CultureInfo.CurrentUICulture, FlowDirection,
            new Typeface(FontFamily, FontStyle, FontWeight, FontStretch), FontSize, Brushes.Black,
            VisualTreeHelper.GetDpi(this).PixelsPerDip)
        { MaxTextWidth = Math.Max(1, max - extra) };
        var width = Math.Min(max, Math.Ceiling(ft.WidthIncludingTrailingWhitespace) + extra);
        Document.PageWidth = width;
        var size = base.MeasureOverride(new Size(width, constraint.Height));
        return new Size(width, size.Height);
    }

    // Mausrad an die Chatliste weitergeben, statt es im Text zu verschlucken.
    protected override void OnPreviewMouseWheel(MouseWheelEventArgs e)
    {
        e.Handled = true;
        var args = new MouseWheelEventArgs(e.MouseDevice, e.Timestamp, e.Delta) { RoutedEvent = MouseWheelEvent, Source = this };
        (Parent as UIElement ?? VisualTreeHelper.GetParent(this) as UIElement)?.RaiseEvent(args);
    }

    // Rechtsklick: das Menü der Nachricht statt des Editor-Menüs zeigen.
    protected override void OnContextMenuOpening(ContextMenuEventArgs e)
    {
        e.Handled = true;
        DependencyObject? d = this;
        while (d is not null and not ListBoxItem) d = VisualTreeHelper.GetParent(d);
        if (d is ListBoxItem { ContextMenu: { } menu } item)
        {
            menu.PlacementTarget = item;
            menu.IsOpen = true;
        }
    }

    public string? SelectedText => Selection.IsEmpty ? null : Selection.Text;
}
