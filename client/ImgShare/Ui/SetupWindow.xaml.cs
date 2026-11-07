using System;
using System.IO;
using System.Net.Http;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using ImgShare.Core;

namespace ImgShare.Ui;

public partial class SetupWindow : Window
{
    readonly ChatEntry? _existing;
    readonly Func<string, bool> _roomExists;
    byte[]? _key;
    bool _connectionFailed;

    /// <summary>Neuer oder geänderter Chat; null bei Abbruch.</summary>
    public ChatEntry? Result { get; private set; }
    public bool RemoveRequested { get; private set; }

    public SetupWindow(ChatEntry? existing, string defaultServer, string defaultName, Func<string, bool> roomExists)
    {
        InitializeComponent();
        _existing = existing;
        _roomExists = roomExists;
        Icon = Tray.IconFactory.CreateImageSource(false);
        // Nie höher als der Bildschirm (z. B. Laptop mit 125 %); der Mittelteil scrollt dann.
        MaxHeight = SystemParameters.WorkArea.Height - 24;
        SourceInitialized += (_, _) => MaxHeight = WindowPlacement.WorkAreaOf(this).Height - 24;

        if (existing is null)
        {
            Title = "Neuen Chat einrichten";
            ServerBox.Text = defaultServer;
            MyNameBox.Text = defaultName;
            GenerateButton.IsChecked = true;
            Generate_Click(this, new RoutedEventArgs());
        }
        else
        {
            Title = WindowTitle.Text = "Chat-Einstellungen";
            Heading.Text = $"Chat mit {existing.ChatName}";
            ServerBox.Text = existing.ServerUrl;
            MyNameBox.Text = existing.MyName;
            ChatNameBox.Text = existing.ChatName;
            InviteBox.Text = existing.GetInvite();
            KeyModes.Visibility = Visibility.Collapsed;
            KeyBox.IsReadOnly = true;
            KeyBox.Text = KeyFormat.Format(existing.GetRootKey());
            RemoveButton.Visibility = Visibility.Visible;
            OkButton.Content = "Speichern";
        }
        Loaded += (_, _) => (existing is null ? ChatNameBox : MyNameBox).Focus();
    }

    void Generate_Click(object sender, RoutedEventArgs e)
    {
        GenerateButton.IsChecked = true;
        KeyBox.Text = KeyFormat.Format(ChatKeys.GenerateRootKey());
    }

    void PasteKey_Click(object sender, RoutedEventArgs e)
    {
        PasteButton.IsChecked = true;
        try { KeyBox.Text = Clipboard.ContainsText() ? Clipboard.GetText().Trim() : ""; }
        catch { KeyBox.Text = ""; }
        if (KeyBox.Text.Length == 0) ShowError("In der Zwischenablage ist kein Schlüssel – bitte eintippen oder einfügen.");
        KeyBox.Focus();
        KeyBox.CaretIndex = KeyBox.Text.Length;
    }

    void KeyBox_TextChanged(object sender, TextChangedEventArgs e)
    {
        _connectionFailed = false;
        if (_existing is null) OkButton.Content = "Chat öffnen";
        QrPanel.Visibility = Visibility.Collapsed;
        QrButton.Content = "Als QR-Code zeigen";
        if (KeyFormat.TryParse(KeyBox.Text, out var key))
        {
            _key = key;
            SafetyCode.Text = ChatKeys.Derive(key).SafetyCode;
            SafetyPanel.Visibility = Visibility.Visible;
            HideError();
        }
        else
        {
            _key = null;
            SafetyPanel.Visibility = Visibility.Collapsed;
            if (KeyBox.Text.Trim().Length > 0) ShowError("Der Schlüssel ist unvollständig oder enthält Tippfehler.");
            else HideError();
        }
        CopyKeyButton.IsEnabled = _key is not null;
        QrButton.IsEnabled = _key is not null;
    }

    /// <summary>
    /// Schlüssel kopieren, ohne dass er im Zwischenablage-Verlauf (Win+V) oder im
    /// Cloud-Clipboard landet; nach 60 s wird er wieder entfernt.
    /// </summary>
    async void CopyKey_Click(object sender, RoutedEventArgs e)
    {
        if (_key is null) return;
        var text = KeyFormat.Format(_key);
        try
        {
            var data = new DataObject();
            data.SetText(text);
            data.SetData("ExcludeClipboardContentFromMonitorProcessing", new MemoryStream(new byte[4]));
            data.SetData("CanIncludeInClipboardHistory", new MemoryStream(BitConverter.GetBytes(0)));
            data.SetData("CanUploadToCloudClipboard", new MemoryStream(BitConverter.GetBytes(0)));
            Clipboard.SetDataObject(data, false);
            CopyKeyText.Text = "Kopiert – 60 s in der Zwischenablage";
            await Task.Delay(TimeSpan.FromSeconds(60));
            if (Clipboard.ContainsText() && Clipboard.GetText() == text) Clipboard.Clear();
        }
        catch { /* Zwischenablage belegt */ }
        finally { CopyKeyText.Text = "Kopieren"; }
    }

    void Qr_Click(object sender, RoutedEventArgs e)
    {
        if (_key is null) return;
        if (QrPanel.Visibility == Visibility.Visible)
        {
            QrPanel.Visibility = Visibility.Collapsed;
            QrButton.Content = "Als QR-Code zeigen";
            return;
        }
        try
        {
            using var gen = new QRCoder.QRCodeGenerator();
            using var data = gen.CreateQrCode(KeyFormat.Format(_key), QRCoder.QRCodeGenerator.ECCLevel.M);
            var png = new QRCoder.PngByteQRCode(data).GetGraphic(8);
            QrImage.Source = ImageHelper.Decode(png, 2000);
            QrPanel.Visibility = Visibility.Visible;
            QrButton.Content = "QR-Code ausblenden";
        }
        catch (Exception ex) { ShowError("QR-Code konnte nicht erzeugt werden: " + ex.Message); }
    }

    void ShowError(string msg) { ErrorLine.Text = msg; ErrorLine.Visibility = Visibility.Visible; }
    void HideError() => ErrorLine.Visibility = Visibility.Collapsed;

    async void Ok_Click(object sender, RoutedEventArgs e)
    {
        var server = ServerBox.Text.Trim().TrimEnd('/');
        var myName = MyNameBox.Text.Trim();
        var chatName = ChatNameBox.Text.Trim();
        var invite = InviteBox.Text.Trim();

        if (!ApiClient.IsAllowedServerUrl(server, out var urlError)) { ShowError(urlError!); return; }
        if (myName.Length == 0 || chatName.Length == 0) { ShowError("Bitte deinen Namen und einen Chat-Namen angeben."); return; }
        if (_key is null) { ShowError("Bitte einen gültigen Schlüssel erzeugen oder einfügen."); return; }
        if (_existing is null && _roomExists(ChatKeys.Derive(_key).RoomId))
        {
            ShowError("Ein Chat mit diesem Schlüssel ist bereits eingerichtet.");
            return;
        }

        bool needsTest = _existing is null || _existing.ServerUrl != server;
        if (needsTest && !_connectionFailed)
        {
            OkButton.IsEnabled = false;
            OkButton.Content = "Verbinde …";
            try
            {
                await ChatSession.TestConnectionAsync(server, _key, invite);
            }
            catch (ApiException ex) when (ex.Code == "invite_required")
            {
                // Speichern ergibt hier keinen Sinn: ohne Code entsteht der Chat nie.
                OkButton.IsEnabled = true;
                OkButton.Content = _existing is null ? "Chat öffnen" : "Speichern";
                ShowError(invite.Length == 0
                    ? "Dieser Chat existiert auf dem Server noch nicht. Zum Anlegen bitte den Server-Zugangscode eintragen – oder warten, bis dein Kollege den Chat angelegt hat."
                    : "Der Server-Zugangscode ist falsch.");
                InviteBox.Focus();
                InviteBox.SelectAll();
                return;
            }
            catch (Exception ex)
            {
                _connectionFailed = true;
                OkButton.IsEnabled = true;
                OkButton.Content = "Trotzdem speichern";
                ShowError(ex switch
                {
                    ApiException { Status: System.Net.HttpStatusCode.Unauthorized } =>
                        "Der Server kennt diesen Chat mit einem anderen Schlüssel und lehnt den Zugriff ab.",
                    ApiException a => a.Message,
                    HttpRequestException h => "Server nicht erreichbar: " + h.Message,
                    TaskCanceledException => "Server antwortet nicht (Zeitüberschreitung).",
                    _ => ex.Message
                });
                return;
            }
        }

        var entry = _existing ?? new ChatEntry();
        entry.ServerUrl = server;
        entry.MyName = myName;
        entry.ChatName = chatName;
        entry.SetInvite(invite);
        if (_existing is null) entry.SetRootKey(_key);
        Result = entry;
        DialogResult = true;
    }

    void Remove_Click(object sender, RoutedEventArgs e)
    {
        var answer = MessageBox.Show(this,
            "Chat auf diesem Rechner entfernen?\n\nDer verschlüsselte Verlauf bleibt am Server. Mit dem Schlüssel kannst du den Chat später wieder einrichten – ohne Schlüssel ist er verloren.",
            "Chat entfernen", MessageBoxButton.YesNo, MessageBoxImage.Warning, MessageBoxResult.No);
        if (answer != MessageBoxResult.Yes) return;
        RemoveRequested = true;
        Result = _existing;
        DialogResult = true;
    }

    void Cancel_Click(object sender, RoutedEventArgs e) => DialogResult = false;
}
