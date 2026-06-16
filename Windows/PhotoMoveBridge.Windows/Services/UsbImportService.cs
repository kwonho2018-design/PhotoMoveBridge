using System.IO;
using System.Text.Json;
using PhotoMoveBridge.Windows.Models;

namespace PhotoMoveBridge.Windows.Services;

public sealed class UsbImportService
{
    private readonly StorageTargetService _storageService;
    private readonly TransferLogStore _logStore;
    private readonly JsonSerializerOptions _jsonOptions = new(JsonSerializerDefaults.Web)
    {
        PropertyNameCaseInsensitive = true
    };

    public UsbImportService(StorageTargetService storageService, TransferLogStore logStore)
    {
        _storageService = storageService;
        _logStore = logStore;
    }

    public async Task ImportAsync(
        string exportFolder,
        StorageTarget target,
        Action<ReceivedFileItem> onItemChanged,
        CancellationToken cancellationToken = default)
    {
        if (string.IsNullOrWhiteSpace(exportFolder) || !Directory.Exists(exportFolder))
        {
            throw new UploadFailureException("USB_EXPORT_FOLDER_NOT_FOUND", "USB export folder does not exist.");
        }

        var manifestPath = Path.Combine(exportFolder, "manifest.json");
        if (!File.Exists(manifestPath))
        {
            throw new UploadFailureException("USB_MANIFEST_NOT_FOUND", "manifest.json was not found in the selected USB export folder.");
        }

        var manifest = JsonSerializer.Deserialize<UsbExportManifest>(
            await File.ReadAllTextAsync(manifestPath, cancellationToken),
            _jsonOptions);
        if (manifest?.Files is null || manifest.Files.Count == 0)
        {
            throw new UploadFailureException("USB_MANIFEST_EMPTY", "USB export manifest has no files.");
        }

        var expectedTotalBytes = manifest.Files.Sum(file => Math.Max(file.FileSize, 0));
        _storageService.EnsureUsableForUpload(target, expectedTotalBytes);
        target = await _storageService.RefreshAndTestAsync(target, cancellationToken);
        _storageService.EnsureUsableForUpload(target, expectedTotalBytes);

        foreach (var file in manifest.Files)
        {
            cancellationToken.ThrowIfCancellationRequested();
            await ImportFileAsync(exportFolder, target, manifest.SessionId, file, onItemChanged, cancellationToken);
        }
    }

    private async Task ImportFileAsync(
        string exportFolder,
        StorageTarget target,
        string sessionId,
        UsbExportFile file,
        Action<ReceivedFileItem> onItemChanged,
        CancellationToken cancellationToken)
    {
        var received = new ReceivedFileItem
        {
            AssetId = file.AssetId,
            OriginalFilename = file.OriginalFilename,
            Status = "receiving",
            FileSize = file.FileSize,
            Progress = 0
        };
        onItemChanged(received);

        string? partialPath = null;
        string? finalPath = null;

        try
        {
            var sourcePath = ResolveSourcePath(exportFolder, file.RelativePath);
            if (!File.Exists(sourcePath))
            {
                throw new UploadFailureException("USB_SOURCE_FILE_NOT_FOUND", $"Source file was not found: {file.RelativePath}");
            }

            var sourceSize = new FileInfo(sourcePath).Length;
            if (sourceSize != file.FileSize)
            {
                throw new UploadFailureException("USB_SOURCE_SIZE_MISMATCH", $"Manifest expected {file.FileSize} bytes but source has {sourceSize} bytes.");
            }

            _storageService.EnsureUsableForUpload(target, file.FileSize);
            finalPath = _storageService.CreateFinalPath(target, file.CreatedAt, file.OriginalFilename);
            partialPath = _storageService.CreatePartialPath(finalPath);

            await CopyWithProgressAsync(sourcePath, partialPath, file.FileSize, received, onItemChanged, cancellationToken);
            _storageService.EnsureUsableForUpload(target, 0);

            var actualSize = new FileInfo(partialPath).Length;
            if (actualSize != file.FileSize)
            {
                throw new UploadFailureException("FILE_SIZE_MISMATCH", $"Expected {file.FileSize} bytes but copied {actualSize} bytes.");
            }

            var actualHash = await _storageService.ComputeSha256Async(partialPath, cancellationToken);
            if (!actualHash.Equals(file.Sha256, StringComparison.OrdinalIgnoreCase))
            {
                throw new UploadFailureException("SHA256_MISMATCH", "SHA256 hash does not match the USB export manifest.");
            }

            if (!_storageService.IsPathUnderRoot(finalPath, target.TargetRoot))
            {
                throw new UploadFailureException("SAVED_PATH_INVALID", "Final save path is outside of the selected target root.");
            }

            File.Move(partialPath, finalPath, overwrite: false);
            received.Status = "verified";
            received.Progress = 1;
            received.SavedPath = finalPath;
            received.CompletedAt = DateTimeOffset.Now;
            onItemChanged(received);

            _logStore.Add(new TransferLog(
                Id: Guid.NewGuid(),
                SessionId: sessionId,
                AssetId: file.AssetId,
                ResourceId: file.ResourceId,
                OriginalFilename: file.OriginalFilename,
                Status: "verified",
                LocalFileSize: file.FileSize,
                RemoteFileSize: actualSize,
                LocalSha256: file.Sha256,
                RemoteSha256: actualHash,
                SavedPath: finalPath,
                ErrorCode: null,
                ErrorMessage: null,
                Timestamp: DateTimeOffset.Now
            ));
        }
        catch (UploadFailureException ex)
        {
            FailImport(file, sessionId, partialPath ?? finalPath, ex.ErrorCode, ex.Message, received, onItemChanged);
        }
        catch (IOException ex)
        {
            FailImport(file, sessionId, partialPath ?? finalPath, "IO_ERROR", ex.Message, received, onItemChanged);
        }
        catch (Exception ex)
        {
            FailImport(file, sessionId, partialPath ?? finalPath, "USB_IMPORT_FAILED", ex.Message, received, onItemChanged);
        }
    }

    private async Task CopyWithProgressAsync(
        string sourcePath,
        string partialPath,
        long expectedSize,
        ReceivedFileItem received,
        Action<ReceivedFileItem> onItemChanged,
        CancellationToken cancellationToken)
    {
        await using var input = new FileStream(sourcePath, FileMode.Open, FileAccess.Read, FileShare.Read, 1024 * 1024, useAsync: true);
        await using var output = new FileStream(partialPath, FileMode.CreateNew, FileAccess.Write, FileShare.None, 1024 * 1024, useAsync: true);
        var buffer = new byte[1024 * 1024];
        long totalRead = 0;

        while (true)
        {
            var read = await input.ReadAsync(buffer.AsMemory(0, buffer.Length), cancellationToken);
            if (read == 0)
            {
                break;
            }

            await output.WriteAsync(buffer.AsMemory(0, read), cancellationToken);
            totalRead += read;
            received.Progress = expectedSize > 0 ? Math.Min(1.0, (double)totalRead / expectedSize) : 0;
            onItemChanged(received);
        }

        await output.FlushAsync(cancellationToken);
    }

    private void FailImport(
        UsbExportFile file,
        string sessionId,
        string? savedPath,
        string errorCode,
        string message,
        ReceivedFileItem received,
        Action<ReceivedFileItem> onItemChanged)
    {
        received.Status = "failed";
        received.ErrorCode = errorCode;
        received.ErrorMessage = message;
        received.SavedPath = savedPath;
        received.CompletedAt = DateTimeOffset.Now;
        onItemChanged(received);

        _logStore.Add(new TransferLog(
            Id: Guid.NewGuid(),
            SessionId: sessionId,
            AssetId: file.AssetId,
            ResourceId: file.ResourceId,
            OriginalFilename: file.OriginalFilename,
            Status: "failed",
            LocalFileSize: file.FileSize,
            RemoteFileSize: savedPath is not null && File.Exists(savedPath) ? new FileInfo(savedPath).Length : null,
            LocalSha256: file.Sha256,
            RemoteSha256: null,
            SavedPath: savedPath,
            ErrorCode: errorCode,
            ErrorMessage: message,
            Timestamp: DateTimeOffset.Now
        ));
    }

    private string ResolveSourcePath(string exportFolder, string relativePath)
    {
        var normalizedRelativePath = relativePath
            .Replace('/', Path.DirectorySeparatorChar)
            .Replace('\\', Path.DirectorySeparatorChar);
        var sourcePath = Path.GetFullPath(Path.Combine(exportFolder, normalizedRelativePath));
        if (!_storageService.IsPathUnderRoot(sourcePath, exportFolder))
        {
            throw new UploadFailureException("USB_SOURCE_PATH_INVALID", "Manifest source path escapes the selected USB export folder.");
        }

        return sourcePath;
    }
}
