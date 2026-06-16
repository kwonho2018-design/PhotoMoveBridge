using System.Collections.ObjectModel;
using System.Diagnostics;
using System.IO;
using System.Windows;
using PhotoMoveBridge.Windows.Models;
using PhotoMoveBridge.Windows.Services;
using WinForms = System.Windows.Forms;

namespace PhotoMoveBridge.Windows;

public partial class MainWindow : Window
{
    private readonly StorageTargetService _storageService = new();
    private readonly TransferLogStore _logStore = new();
    private readonly ObservableCollection<DriveInfoSnapshot> _drives = new();
    private readonly ObservableCollection<ReceivedFileItem> _receivedFiles = new();
    private readonly UsbImportService _usbImportService;
    private StorageTarget? _selectedTarget;
    private bool _isImporting;

    public MainWindow()
    {
        InitializeComponent();
        _usbImportService = new UsbImportService(_storageService, _logStore);
        DriveGrid.ItemsSource = _drives;
        ReceivedGrid.ItemsSource = _receivedFiles;
        ResultGrid.ItemsSource = _receivedFiles;
        RefreshDrives();
        UpdateStatusPanels();
    }

    private void RefreshDrives_Click(object sender, RoutedEventArgs e)
    {
        RefreshDrives();
    }

    private void BrowseTargetRoot_Click(object sender, RoutedEventArgs e)
    {
        using var dialog = new WinForms.FolderBrowserDialog
        {
            Description = "컴퓨터 하드 또는 외장하드의 PhotoMove Bridge 저장 폴더를 선택하세요.",
            UseDescriptionForTitle = true,
            SelectedPath = Directory.Exists(TargetRootTextBox.Text) ? TargetRootTextBox.Text : ""
        };

        if (dialog.ShowDialog() == WinForms.DialogResult.OK)
        {
            TargetRootTextBox.Text = dialog.SelectedPath;
        }
    }

    private async void UseSelectedDrive_Click(object sender, RoutedEventArgs e)
    {
        if (DriveGrid.SelectedItem is not DriveInfoSnapshot snapshot)
        {
            MessageBox.Show("드라이브를 먼저 선택하세요.", "PhotoMove Bridge", MessageBoxButton.OK, MessageBoxImage.Information);
            return;
        }

        var target = _storageService.BuildTarget(snapshot, TargetRootTextBox.Text);
        TargetRootTextBox.Text = target.TargetRoot;
        await ConfirmTargetAsync(target);
    }

    private async void UseTypedTargetRoot_Click(object sender, RoutedEventArgs e)
    {
        var target = _storageService.BuildTargetFromPath(TargetRootTextBox.Text);
        TargetRootTextBox.Text = target.TargetRoot;
        await ConfirmTargetAsync(target);
    }

    private async void RetestTarget_Click(object sender, RoutedEventArgs e)
    {
        if (_selectedTarget is null)
        {
            MessageBox.Show("확정된 저장 대상이 없습니다.", "PhotoMove Bridge", MessageBoxButton.OK, MessageBoxImage.Information);
            return;
        }

        await ConfirmTargetAsync(_selectedTarget);
    }

    private void OpenTargetFolder_Click(object sender, RoutedEventArgs e)
    {
        if (_selectedTarget is null || !Directory.Exists(_selectedTarget.TargetRoot))
        {
            MessageBox.Show("열 수 있는 저장 폴더가 없습니다.", "PhotoMove Bridge", MessageBoxButton.OK, MessageBoxImage.Information);
            return;
        }

        Process.Start(new ProcessStartInfo(_selectedTarget.TargetRoot) { UseShellExecute = true });
    }

    private void OpenLog_Click(object sender, RoutedEventArgs e)
    {
        Process.Start(new ProcessStartInfo(_logStore.LogPath) { UseShellExecute = true });
    }

    private void BrowseUsbExportFolder_Click(object sender, RoutedEventArgs e)
    {
        using var dialog = new WinForms.FolderBrowserDialog
        {
            Description = "iPhone 앱 문서에서 복사한 PhotoMoveBridge USB 내보내기 세션 폴더를 선택하세요.",
            UseDescriptionForTitle = true,
            SelectedPath = Directory.Exists(UsbExportFolderTextBox.Text) ? UsbExportFolderTextBox.Text : ""
        };

        if (dialog.ShowDialog() == WinForms.DialogResult.OK)
        {
            UsbExportFolderTextBox.Text = dialog.SelectedPath;
        }
    }

    private async void StartUsbImport_Click(object sender, RoutedEventArgs e)
    {
        if (_isImporting)
        {
            return;
        }

        if (_selectedTarget is null)
        {
            MessageBox.Show("저장 대상 폴더를 먼저 확정하세요.", "PhotoMove Bridge", MessageBoxButton.OK, MessageBoxImage.Information);
            return;
        }

        if (string.IsNullOrWhiteSpace(UsbExportFolderTextBox.Text) || !Directory.Exists(UsbExportFolderTextBox.Text))
        {
            MessageBox.Show("USB 내보내기 폴더를 먼저 선택하세요.", "PhotoMove Bridge", MessageBoxButton.OK, MessageBoxImage.Information);
            return;
        }

        _isImporting = true;
        StartUsbImportButton.IsEnabled = false;
        AppStatusText.Text = "USB 가져오기 중";
        UsbImportStatusText.Text = "USB 내보내기 폴더를 가져오는 중입니다...";

        try
        {
            await ConfirmTargetAsync(_selectedTarget);
            if (_selectedTarget is null)
            {
                UsbImportStatusText.Text = "저장 대상이 준비되지 않아 가져오기를 시작하지 않았습니다.";
                return;
            }

            await _usbImportService.ImportAsync(UsbExportFolderTextBox.Text, _selectedTarget, UpsertReceivedFile);
            AppStatusText.Text = "USB 가져오기 완료";
            UsbImportStatusText.Text = "USB 가져오기 완료: 파일 크기와 SHA256 검증 결과를 진행/결과 탭에서 확인하세요.";
            await ConfirmTargetAsync(_selectedTarget);
        }
        catch (Exception ex)
        {
            AppStatusText.Text = "USB 가져오기 실패";
            UsbImportStatusText.Text = $"USB 가져오기 실패: {ex.Message}";
            MessageBox.Show(ex.Message, "USB 가져오기 실패", MessageBoxButton.OK, MessageBoxImage.Error);
        }
        finally
        {
            _isImporting = false;
            StartUsbImportButton.IsEnabled = true;
            UpdateCounters();
        }
    }

    private async Task ConfirmTargetAsync(StorageTarget target)
    {
        StorageStatusText.Text = "저장 대상 상태와 쓰기 권한을 확인하는 중입니다...";
        var refreshed = await _storageService.RefreshAndTestAsync(target);
        if (!refreshed.IsReady)
        {
            _selectedTarget = null;
            StorageStatusText.Text = "드라이브가 준비되지 않았습니다. 저장 장치 연결 상태를 확인하세요.";
            UpdateStatusPanels();
            return;
        }

        if (!refreshed.CanWrite)
        {
            _selectedTarget = null;
            StorageStatusText.Text = "쓰기 테스트 실패: 저장 대상으로 확정하지 않았습니다.";
            UpdateStatusPanels();
            return;
        }

        _selectedTarget = refreshed;
        StorageStatusText.Text = $"저장 대상 확정: {refreshed.TargetRoot} / 남은 용량 {FormatBytes(refreshed.FreeSpace)} / 파일 시스템 {refreshed.FileSystem}";
        UsbTargetSummaryText.Text = $"{refreshed.TargetRoot}\n{refreshed.DriveLetter} / {refreshed.VolumeLabel} / 남은 용량 {FormatBytes(refreshed.FreeSpace)}";
        UpdateStatusPanels();
    }

    private void RefreshDrives()
    {
        _drives.Clear();
        foreach (var drive in _storageService.GetDriveSnapshots())
        {
            _drives.Add(drive);
        }

        StorageStatusText.Text = "드라이브 목록을 갱신했습니다. 컴퓨터 하드 또는 외장하드의 저장 루트를 확정하세요.";
    }

    private void UpsertReceivedFile(ReceivedFileItem item)
    {
        Dispatcher.Invoke(() =>
        {
            var existing = _receivedFiles
                .Select((value, index) => new { value, index })
                .FirstOrDefault(x => x.value.AssetId == item.AssetId && x.value.OriginalFilename == item.OriginalFilename);

            if (existing is null)
            {
                _receivedFiles.Insert(0, item);
            }
            else
            {
                _receivedFiles[existing.index] = item;
            }

            CurrentFileText.Text = item.OriginalFilename;
            CurrentProgressBar.Value = item.Progress * 100;
            UpdateCounters();
        });
    }

    private void UpdateCounters()
    {
        TotalCountText.Text = _receivedFiles.Count.ToString();
        SuccessCountText.Text = _receivedFiles.Count(x => x.Status.Equals("verified", StringComparison.OrdinalIgnoreCase)).ToString();
        FailedCountText.Text = _receivedFiles.Count(x => x.Status.Equals("failed", StringComparison.OrdinalIgnoreCase)).ToString();
        PendingCountText.Text = _receivedFiles.Count(x => x.Status.Equals("receiving", StringComparison.OrdinalIgnoreCase)).ToString();
    }

    private void UpdateStatusPanels()
    {
        WorkflowSummaryText.Text = "USB 내보내기 세션 폴더를 선택한 저장 대상 폴더로 복사하고 검증합니다.";
        SelectedTargetText.Text = _selectedTarget is null
            ? "저장 대상 폴더가 아직 확정되지 않았습니다."
            : $"{_selectedTarget.TargetRoot}\n{_selectedTarget.DriveLetter} / {_selectedTarget.VolumeLabel} / 남은 용량 {FormatBytes(_selectedTarget.FreeSpace)}";
        UsbTargetSummaryText.Text = _selectedTarget is null
            ? "저장 대상 폴더가 아직 확정되지 않았습니다."
            : $"{_selectedTarget.TargetRoot}\n{_selectedTarget.DriveLetter} / {_selectedTarget.VolumeLabel} / 남은 용량 {FormatBytes(_selectedTarget.FreeSpace)}";
    }

    private static string FormatBytes(long bytes)
    {
        string[] suffixes = ["B", "KB", "MB", "GB", "TB"];
        var value = (double)Math.Max(bytes, 0);
        var index = 0;
        while (value >= 1024 && index < suffixes.Length - 1)
        {
            value /= 1024;
            index++;
        }

        return $"{value:0.##} {suffixes[index]}";
    }
}
