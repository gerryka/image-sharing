using System;
using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.ComponentModel;
using System.Linq;
using System.Runtime.InteropServices;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Data;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Shapes;
using System.Windows.Threading;
using ImgShare.Core;
using Microsoft.Win32;

namespace ImgShare.Ui;

public partial class ChatWindow : Window
{
    const int MaxTextLength = 20000;

    readonly ChatSession _s;
    readonly Action _saveConfig;
    readonly int _cascade;
    readonly ObservableCollection<MessageItem> _items = new();
    readonly ICollectionView _view;
    readonly Dictionary<long, MessageItem> _byId = new();
    readonly Dictionary<string, BitmapSource> _thumbs = new();
    PendingImage? _pending;
    bool _stick = true;
    bool _loadingOlder;
    double? _restoreFromBottom;
    bool _reallyClose;
    int _newWhileAway;
    ConnectionState _lastState;
    ImageViewerWindow? _viewer;

    public ChatSession Session => _s;
    public event Action? SettingsRequested;
    /// <summary>Fenster wurde in den Infobereich versteckt.</summary>
    public event Action? HiddenToTray;

    public ChatWindow(ChatSession session, int cascade, Action saveConfig)
    {
        InitializeComponent();
        _s = session;
        _cascade = cascade;
        _saveConfig = saveConfig;
        _lastState = session.State;
        _view = CollectionViewSource.GetDefaultView(_items);
        List.ItemsSource = _view;
        Icon = Tray.IconFactory.CreateImageSource(false);
        ApplyNames();

        _s.MessageAdded += OnMessageAdded;
        _s.HistoryChanged += Rebuild;
        _s.ReadStateChanged += UpdateReadTicks;
        _s.ConnectionChanged += UpdateStatus;

        SourceInitialized += (_, _) =>
        {
            WindowPlacement.FixMaximize(this);
            WindowPlacement.Restore(this, _s.Entry.WindowBounds, _cascade);
        };
        StateChanged += (_, _) => ApplyMaximizedFix();
        Activated += (_, _) => _ = _s.MarkReadAsync();
        Closing += OnClosing;
        PreviewKeyDown += Window_PreviewKeyDown;
        DragOver += Window_DragOver;
        DragLeave += (_, _) => DropOverlay.Visibility = Visibility.Collapsed;
        Drop += Window_Drop;

        Rebuild();
        UpdateStatus();
    }

    public void ApplyNames()
    {
        Title = $"Chat – {_s.Entry.ChatName}";
        ChatTitle.Text = _s.Entry.ChatName;
        var parts = _s.Entry.ChatName.Split(' ', StringSplitOptions.RemoveEmptyEntries);
        Initials.Text = parts.Length switch
        {
            0 => "?",
            1 => parts[0][..Math.Min(2, parts[0].Length)].ToUpperInvariant(),
            _ => $"{char.ToUpperInvariant(parts[0][0])}{char.ToUpperInvariant(parts[^1][0])}"
        };
    }

    public void ShowAndActivate()
    {
        if (!IsVisible) Show();
        if (WindowState == WindowState.Minimized) WindowState = WindowState.Normal;
        Activate();
        Input.Focus();
    }

    /// <summary>Fenster endgültig schließen (Chat entfernt oder App beendet).</summary>
    public void CloseForGood()
    {
        SaveBounds();
        _reallyClose = true;
        _s.MessageAdded -= OnMessageAdded;
        _s.HistoryChanged -= Rebuild;
        _s.ReadStateChanged -= UpdateReadTicks;
        _s.ConnectionChanged -= UpdateStatus;
        _viewer?.Close();
        Close();
    }

    void OnClosing(object? sender, CancelEventArgs e)
    {
        if (_reallyClose) return;
        e.Cancel = true; // Alt+F4 / X = in den Infobereich
        HideToTray();
    }

    void HideToTray()
    {
        SaveBounds();
        Hide();
        HiddenToTray?.Invoke();
    }

    void SaveBounds()
    {
        if (!IsLoaded) return;
        _s.Entry.WindowBounds = WindowPlacement.Capture(this);
        _saveConfig();
    }

    // Maximiert (Größe begrenzt per WindowPlacement.FixMaximize) ohne eigenen Rahmen.
    void ApplyMaximizedFix() =>
        BorderThickness = new Thickness(WindowState == WindowState.Maximized ? 0 : 1);

    // ------------------------------------------------------------------ Liste

    void Rebuild()
    {
        var pending = _items.Where(i => i.IsPending || i.IsFailed).ToList();
        _items.Clear();
        _byId.Clear();
        foreach (var m in _s.Messages) AddMessage(m);
        foreach (var p in pending) _items.Add(p);
        UpdateReadTicks();
        _loadingOlder = false;
        UpdateEmptyHint();
        UpdateHistoryHead();
        Dispatcher.BeginInvoke(MaybeAutoLoadOlder, DispatcherPriority.Background);
    }

    void AddMessage(ChatMessage m)
    {
        if (_byId.ContainsKey(m.Id)) return;
        var item = MessageItem.From(m, _s.Entry.ChatName);
        int idx = _items.Count;
        while (idx > 0 && (_items[idx - 1].IsPending || _items[idx - 1].IsFailed)) idx--;
        var prev = idx > 0 ? _items[idx - 1] : null;
        var day = item.LocalTime.Date;
        var prevDay = prev is null ? (DateTime?)null : prev.IsSeparator ? prev.Day : prev.LocalTime.Date;
        if (prevDay != day) _items.Insert(idx++, MessageItem.Separator(day));
        _items.Insert(idx, item);
        _byId[m.Id] = item;
        item.IsRead = m.IsMine && m.Id <= _s.OtherReadUpTo;
        if (item.HasImage) _ = LoadThumbAsync(item);
    }

    void OnMessageAdded(ChatMessage m, bool live)
    {
        AddMessage(m);
        UpdateEmptyHint();
        UpdateHistoryHead();
        if (m.IsMine) _stick = true;
        else if (!_stick) { _newWhileAway++; UpdateJumpButton(); }
        if (IsActive && IsVisible) _ = _s.MarkReadAsync();
    }

    async Task LoadThumbAsync(MessageItem item)
    {
        var info = item.ImageInfo!;
        if (_thumbs.TryGetValue(info.BlobId, out var cached)) { item.Thumbnail = cached; return; }
        try
        {
            var bytes = await _s.GetImageBytesAsync(info);
            var thumb = await Task.Run(() => ImageHelper.Decode(bytes, 560));
            _thumbs[info.BlobId] = thumb;
            item.Thumbnail = thumb;
        }
        catch { item.ImageFailed = true; }
    }

    void UpdateReadTicks()
    {
        foreach (var item in _byId.Values)
            if (item.IsMine) item.IsRead = item.Id <= _s.OtherReadUpTo;
    }

    void UpdateEmptyHint()
    {
        string? text = null;
        var q = SearchBox.Text.Trim();
        if (q.Length > 0 && _view.IsEmpty)
            text = $"Keine Treffer für „{q}“.";
        else if (_items.Count == 0)
            text = _s.IsLoaded ? "Noch keine Nachrichten.\nSchreib etwas oder füge mit Strg+V ein Bild ein."
                : _s.State == ConnectionState.Offline
                    ? "Keine Verbindung zum Server.\nDer Verlauf wird geladen, sobald er erreichbar ist."
                    : "Verlauf wird geladen …";
        EmptyHint.Text = text ?? "";
        EmptyHint.Visibility = text is null ? Visibility.Collapsed : Visibility.Visible;
    }

    void UpdateHistoryHead()
    {
        bool searching = _view.Filter is not null;
        if (_items.Count == 0 || searching) { HistoryHead.Visibility = Visibility.Collapsed; return; }
        HistoryHead.Visibility = Visibility.Visible;
        if (_loadingOlder || _s.HasOlder && !_s.IsLoaded)
        {
            HistoryText.Text = "Ältere Nachrichten werden geladen …";
            HistoryText.Visibility = Visibility.Visible;
            LoadOlderButton.Visibility = Visibility.Collapsed;
        }
        else if (_s.HasOlder)
        {
            HistoryText.Visibility = Visibility.Collapsed;
            LoadOlderButton.Visibility = Visibility.Visible;
        }
        else
        {
            HistoryText.Text = "Beginn des Verlaufs";
            HistoryText.Visibility = Visibility.Visible;
            LoadOlderButton.Visibility = Visibility.Collapsed;
        }
        SearchHint.Visibility = _s.HasOlder ? Visibility.Visible : Visibility.Collapsed;
    }

    void UpdateStatus()
    {
        string text; string dot;
        switch (_s.State)
        {
            case ConnectionState.Online when _s.OtherOnline:
                text = "online · Ende-zu-Ende verschlüsselt"; dot = "Online"; break;
            case ConnectionState.Online:
                text = "offline · Ende-zu-Ende verschlüsselt"; dot = "Offline"; break;
            case ConnectionState.Connecting:
                text = "verbinde … · Ende-zu-Ende verschlüsselt"; dot = "Offline"; break;
            default:
                text = "keine Verbindung zum Server"; dot = "Offline"; break;
        }
        StatusLine.Text = text;
        StatusLine.ToolTip = _s.State == ConnectionState.Offline ? _s.LastError : null;
        PresenceDot.SetResourceReference(Shape.FillProperty, dot);

        // Verbindung wieder da: nicht gesendete Nachrichten automatisch nachschicken.
        if (_lastState != ConnectionState.Online && _s.State == ConnectionState.Online) RetryAllFailed();
        _lastState = _s.State;
        UpdateEmptyHint();
    }

    // ------------------------------------------------------------------ Scrollen

    void Scroller_ScrollChanged(object sender, ScrollChangedEventArgs e)
    {
        if (_restoreFromBottom is { } fromBottom && e.ExtentHeightChange != 0)
        {
            _restoreFromBottom = null;
            Scroller.ScrollToVerticalOffset(Scroller.ExtentHeight - fromBottom);
            return;
        }
        if (e.ExtentHeightChange == 0) _stick = Scroller.VerticalOffset >= Scroller.ScrollableHeight - 30;
        else if (_stick) Scroller.ScrollToEnd();
        if (_stick) _newWhileAway = 0;
        UpdateJumpButton();

        if (e.VerticalChange < 0 && Scroller.VerticalOffset < 60) _ = LoadOlderAsync();
    }

    void UpdateJumpButton()
    {
        bool far = Scroller.ScrollableHeight - Scroller.VerticalOffset > 150;
        JumpButton.Visibility = far ? Visibility.Visible : Visibility.Collapsed;
        JumpButton.Tag = _newWhileAway switch
        {
            0 => "Nach unten",
            1 => "1 neue Nachricht",
            var n => $"{n} neue Nachrichten"
        };
    }

    void JumpToEnd()
    {
        _stick = true;
        _newWhileAway = 0;
        Scroller.ScrollToEnd();
        UpdateJumpButton();
    }

    void Jump_Click(object sender, RoutedEventArgs e) { JumpToEnd(); Input.Focus(); }

    void LoadOlder_Click(object sender, RoutedEventArgs e) => _ = LoadOlderAsync();

    /// <summary>Füllt die erste Seite das Fenster nicht, gibt es nichts zu scrollen – dann selbst nachladen.</summary>
    void MaybeAutoLoadOlder()
    {
        if (_s.IsLoaded && _s.HasOlder && _view.Filter is null && Scroller.ScrollableHeight <= 0 && _items.Count > 0)
            _ = LoadOlderAsync();
    }

    async Task LoadOlderAsync()
    {
        if (_loadingOlder || !_s.HasOlder || !_s.IsLoaded || _view.Filter is not null) return;
        _loadingOlder = true;
        UpdateHistoryHead();
        _restoreFromBottom = Scroller.ExtentHeight - Scroller.VerticalOffset;
        try { await _s.LoadOlderAsync(); }
        catch { /* nächster Versuch per Button oder Scrollen */ }
        await Dispatcher.InvokeAsync(() => { }, DispatcherPriority.Background);
        _restoreFromBottom = null;
        _loadingOlder = false;
        UpdateHistoryHead();
    }

    // ------------------------------------------------------------------ Senden

    async void Send_Click(object sender, RoutedEventArgs e) => await SendAsync();

    async Task SendAsync()
    {
        HideNote();
        var text = Input.Text.Trim();
        var img = _pending;
        if (img is null && text.Length == 0) return;
        if (text.Length > MaxTextLength) { ShowError($"Der Text ist zu lang (max. {MaxTextLength} Zeichen)."); return; }

        Input.Clear();
        ClearPending();
        Input.Focus();
        if (img is not null) await SendImageAsync(img, null);
        if (text.Length > 0) await SendTextAsync(text, null);
    }

    void AddPending(MessageItem p)
    {
        _items.Add(p);
        UpdateEmptyHint();
        JumpToEnd();
    }

    void MarkFailed(MessageItem p, Exception ex)
    {
        p.IsPending = false;
        p.IsFailed = true;
        p.StatusText = "Nicht gesendet";
        ShowError(ErrorText.Describe(ex) + (_s.State == ConnectionState.Online
            ? ""
            : " Wird automatisch erneut gesendet, sobald die Verbindung steht."));
    }

    async Task SendTextAsync(string text, MessageItem? retry)
    {
        var p = retry ?? MessageItem.PendingText(text);
        if (retry is null) AddPending(p);
        p.IsFailed = false; p.IsPending = true; p.StatusText = "Wird gesendet …";
        try
        {
            await _s.SendTextAsync(text);
            _items.Remove(p);
        }
        catch (Exception ex) { MarkFailed(p, ex); }
    }

    async Task SendImageAsync(PendingImage img, MessageItem? retry)
    {
        var p = retry ?? MessageItem.PendingImg(img);
        if (retry is null) AddPending(p);
        p.IsFailed = false; p.IsPending = true; p.StatusText = "Wird verschlüsselt hochgeladen …";
        var progress = new Progress<double>(v => { if (p.IsPending) p.StatusText = $"Wird verschlüsselt hochgeladen … {v * 100:0} %"; });
        try
        {
            var id = await _s.SendImageAsync(img.Bytes, img.FileName, img.Width, img.Height, progress);
            if (_byId.TryGetValue(id, out var real) && real.Thumbnail is null) real.Thumbnail = img.Preview;
            _items.Remove(p);
        }
        catch (Exception ex) { MarkFailed(p, ex); }
    }

    void Retry(MessageItem item)
    {
        if (!item.IsFailed) return;
        HideNote();
        if (item.RetryImage is { } img) _ = SendImageAsync(img, item);
        else if (item.RetryText is { } t) _ = SendTextAsync(t, item);
    }

    void RetryAllFailed()
    {
        foreach (var item in _items.Where(i => i.IsFailed).ToList()) Retry(item);
    }

    void SetPending(PendingImage img)
    {
        _pending = img;
        PastePreview.ImageSource = img.Preview;
        PasteTitle.Text = img.FromClipboard ? "Bild aus Zwischenablage" : img.FileName;
        PasteInfo.Text = $"{ImageFormat.ShortType(img.Mime)} · {img.Width}×{img.Height} · wird verschlüsselt gesendet";
        PastePanel.Visibility = Visibility.Visible;
        HideNote();
        Input.Focus();
    }

    void ClearPending()
    {
        _pending = null;
        PastePreview.ImageSource = null;
        PastePanel.Visibility = Visibility.Collapsed;
    }

    void RemovePaste_Click(object sender, RoutedEventArgs e) { ClearPending(); Input.Focus(); }

    void ShowError(string msg)
    {
        ComposerNote.Text = msg;
        ComposerNote.SetResourceReference(TextBlock.ForegroundProperty, "Danger");
        ComposerNote.Visibility = Visibility.Visible;
    }

    void ShowInfo(string msg)
    {
        ComposerNote.Text = msg;
        ComposerNote.SetResourceReference(TextBlock.ForegroundProperty, "TextMuted");
        ComposerNote.Visibility = Visibility.Visible;
    }

    void HideNote() => ComposerNote.Visibility = Visibility.Collapsed;

    bool TryPasteImage()
    {
        try
        {
            var img = ImageHelper.TryReadClipboard();
            if (img is null) return false;
            SetPending(img);
            return true;
        }
        catch (COMException) { ShowError("Die Zwischenablage ist gerade belegt, bitte nochmal versuchen."); return true; }
        catch (Exception ex) { ShowError(ErrorText.Describe(ex)); return true; }
    }

    // ------------------------------------------------------------------ Tastatur

    void Input_PreviewKeyDown(object sender, KeyEventArgs e)
    {
        var mods = Keyboard.Modifiers;
        switch (e.Key)
        {
            case Key.Enter when (mods & ModifierKeys.Shift) == 0:
                e.Handled = true;
                _ = SendAsync();
                break;
            case Key.V when mods == ModifierKeys.Control:
            case Key.Insert when mods == ModifierKeys.Shift:
                if (TryPasteImage()) e.Handled = true;
                break;
            case Key.PageUp:
                Scroller.PageUp(); e.Handled = true;
                break;
            case Key.PageDown:
                Scroller.PageDown(); e.Handled = true;
                break;
            case Key.Home when mods == ModifierKeys.Control && Input.Text.Length == 0:
                Scroller.ScrollToTop(); e.Handled = true;
                break;
            case Key.End when mods == ModifierKeys.Control && Input.Text.Length == 0:
                JumpToEnd(); e.Handled = true;
                break;
            case Key.Up when mods == ModifierKeys.None && Input.Text.Length == 0:
                FocusLastMessage(); e.Handled = true;
                break;
        }
    }

    void Window_PreviewKeyDown(object sender, KeyEventArgs e)
    {
        if (e.Key == Key.Escape)
        {
            // Der Reihe nach: Suche → Bildvorschau → Fenster
            if (SearchBar.Visibility == Visibility.Visible) CloseSearch();
            else if (_pending is not null) { ClearPending(); Input.Focus(); }
            else HideToTray();
            e.Handled = true;
        }
        else if (e.Key == Key.F && Keyboard.Modifiers == ModifierKeys.Control)
        {
            OpenSearch();
            e.Handled = true;
        }
        else if (e.Key == Key.V && Keyboard.Modifiers == ModifierKeys.Control && !Input.IsKeyboardFocused && !SearchBox.IsKeyboardFocused)
        {
            if (TryPasteImage()) e.Handled = true;
        }
    }

    void FocusLastMessage()
    {
        var last = _view.Cast<MessageItem>().LastOrDefault(i => !i.IsSeparator);
        if (last is null) return;
        List.ScrollIntoView(last);
        List.UpdateLayout();
        (List.ItemContainerGenerator.ContainerFromItem(last) as ListBoxItem)?.Focus();
    }

    void Item_KeyDown(object sender, KeyEventArgs e)
    {
        if (sender is not ListBoxItem { DataContext: MessageItem item } container) return;
        switch (e.Key)
        {
            case Key.Enter when item.IsFailed:
                Retry(item); e.Handled = true; break;
            case Key.Enter when item.HasImage:
                ShowImage(item); e.Handled = true; break;
            case Key.C when Keyboard.Modifiers == ModifierKeys.Control:
                _ = CopyAsync(item, container); e.Handled = true; break;
            case Key.Escape:
            case Key.Tab when Keyboard.Modifiers == ModifierKeys.None:
                Input.Focus(); e.Handled = true; break;
        }
    }

    void Attach_Click(object sender, RoutedEventArgs e)
    {
        var dlg = new OpenFileDialog { Filter = "Bilder (*.png;*.jpg;*.jpeg)|*.png;*.jpg;*.jpeg", Title = "Bild auswählen" };
        if (dlg.ShowDialog(this) != true) return;
        try { SetPending(ImageHelper.FromFile(dlg.FileName)); }
        catch (Exception ex) { ShowError(ErrorText.Describe(ex)); }
    }

    // ------------------------------------------------------------------ Drag & Drop

    static string[] DroppedFiles(DragEventArgs e) =>
        e.Data.GetDataPresent(DataFormats.FileDrop) && e.Data.GetData(DataFormats.FileDrop) is string[] f ? f : Array.Empty<string>();

    void Window_DragOver(object sender, DragEventArgs e)
    {
        var files = DroppedFiles(e);
        e.Handled = true;
        if (files.Length == 0) { e.Effects = DragDropEffects.None; DropOverlay.Visibility = Visibility.Collapsed; return; }
        bool ok = files.Any(ImageHelper.IsImageFile);
        e.Effects = ok ? DragDropEffects.Copy : DragDropEffects.None;
        DropText.Text = ok ? "Loslassen zum Anhängen" : "Nur PNG- und JPG-Bilder";
        var brush = ok ? "Accent" : "Danger";
        DropText.SetResourceReference(TextBlock.ForegroundProperty, brush);
        DropFrame.SetResourceReference(Border.BorderBrushProperty, brush);
        DropOverlay.Visibility = Visibility.Visible;
    }

    void Window_Drop(object sender, DragEventArgs e)
    {
        DropOverlay.Visibility = Visibility.Collapsed;
        var files = DroppedFiles(e);
        var images = files.Where(ImageHelper.IsImageFile).ToList();
        if (images.Count == 0) { if (files.Length > 0) ShowError("Nur PNG- und JPG-Bilder können geteilt werden."); return; }
        try
        {
            SetPending(ImageHelper.FromFile(images[0]));
            if (files.Length > 1) ShowInfo("Nur das erste Bild wurde übernommen.");
        }
        catch (Exception ex) { ShowError(ErrorText.Describe(ex)); }
    }

    // ------------------------------------------------------------------ Kontextmenü & Bildansicht

    static MessageItem? ItemOf(object sender) => (sender as FrameworkElement)?.DataContext as MessageItem;

    Task<byte[]> ImageBytesAsync(MessageItem item) =>
        item.RetryImage is { } local ? Task.FromResult(local.Bytes) : _s.GetImageBytesAsync(item.ImageInfo!);

    void ShowImage(MessageItem item)
    {
        if (!item.HasImage || item.ImageFailed) return;
        if (_viewer is { IsLoaded: true })
        {
            _viewer.ShowImage(() => ImageBytesAsync(item), item.FileName);
            if (_viewer.WindowState == WindowState.Minimized) _viewer.WindowState = WindowState.Normal;
            _viewer.Activate();
            return;
        }
        _viewer = new ImageViewerWindow(() => ImageBytesAsync(item), item.FileName) { Owner = this };
        _viewer.Closed += (_, _) => _viewer = null;
        _viewer.Show();
    }

    void Image_Click(object sender, MouseButtonEventArgs e)
    {
        if (ItemOf(sender) is { } item) ShowImage(item);
    }

    void Open_Click(object sender, RoutedEventArgs e)
    {
        if (ItemOf(sender) is { } item) ShowImage(item);
    }

    static T? FindChild<T>(DependencyObject root) where T : DependencyObject
    {
        for (int i = 0; i < VisualTreeHelper.GetChildrenCount(root); i++)
        {
            var c = VisualTreeHelper.GetChild(root, i);
            if (c is T t) return t;
            if (FindChild<T>(c) is { } found) return found;
        }
        return null;
    }

    async Task CopyAsync(MessageItem item, DependencyObject? container)
    {
        try
        {
            if (item.HasImage) ImageHelper.CopyToClipboard(await ImageBytesAsync(item));
            else
            {
                container ??= List.ItemContainerGenerator.ContainerFromItem(item);
                var selected = container is null ? null : FindChild<MessageText>(container)?.SelectedText;
                Clipboard.SetText(string.IsNullOrEmpty(selected) ? item.Text ?? "" : selected);
            }
        }
        catch (Exception ex) { ShowError(ErrorText.Describe(ex)); }
    }

    void Copy_Click(object sender, RoutedEventArgs e)
    {
        if (ItemOf(sender) is { } item) _ = CopyAsync(item, null);
    }

    async void Save_Click(object sender, RoutedEventArgs e)
    {
        if (ItemOf(sender) is not { HasImage: true } item) return;
        await ImageViewerWindow.SaveAsAsync(this, () => ImageBytesAsync(item), item.FileName);
    }

    void Retry_Click(object sender, RoutedEventArgs e)
    {
        if (ItemOf(sender) is { } item) Retry(item);
    }

    // ------------------------------------------------------------------ Kopfzeile & Suche

    void Close_Click(object sender, RoutedEventArgs e) => HideToTray();
    void Settings_Click(object sender, RoutedEventArgs e) => SettingsRequested?.Invoke();

    void Search_Click(object sender, RoutedEventArgs e)
    {
        if (SearchBar.Visibility == Visibility.Visible) CloseSearch(); else OpenSearch();
    }

    void OpenSearch()
    {
        SearchBar.Visibility = Visibility.Visible;
        UpdateHistoryHead();
        SearchBox.Focus();
        SearchBox.SelectAll();
    }

    void CloseSearch()
    {
        SearchBox.Clear();
        SearchBar.Visibility = Visibility.Collapsed;
        Input.Focus();
    }

    void SearchBox_TextChanged(object sender, TextChangedEventArgs e)
    {
        var q = SearchBox.Text.Trim();
        _view.Filter = q.Length == 0 ? null : o => o is MessageItem i && !i.IsSeparator &&
            ((i.Text?.Contains(q, StringComparison.CurrentCultureIgnoreCase) ?? false) ||
             (i.ImageCaption?.Contains(q, StringComparison.CurrentCultureIgnoreCase) ?? false));
        UpdateEmptyHint();
        UpdateHistoryHead();
        if (q.Length == 0) JumpToEnd();
    }

    void SearchBox_PreviewKeyDown(object sender, KeyEventArgs e)
    {
        if (e.Key == Key.Escape) { CloseSearch(); e.Handled = true; }
        else if (e.Key == Key.Down) { FocusLastMessage(); e.Handled = true; }
    }
}
