using System.Text.Json.Serialization;

namespace PhotoMoveBridge.Windows.Models;

public sealed record StorageTarget(
    string DriveLetter,
    string VolumeLabel,
    string DriveType,
    string FileSystem,
    string RootDirectory,
    string TargetRoot,
    long TotalSize,
    long FreeSpace,
    bool IsReady,
    bool CanWrite,
    DateTimeOffset LastCheckedAt
);

public sealed record DriveInfoSnapshot(
    string DriveLetter,
    string VolumeLabel,
    string DriveType,
    long TotalSize,
    long FreeSpace,
    string FileSystem,
    bool IsReady,
    string RootDirectory
);

public sealed record TransferLog(
    Guid Id,
    string SessionId,
    string AssetId,
    string? ResourceId,
    string OriginalFilename,
    string Status,
    long? LocalFileSize,
    long? RemoteFileSize,
    string? LocalSha256,
    string? RemoteSha256,
    string? SavedPath,
    string? ErrorCode,
    string? ErrorMessage,
    DateTimeOffset Timestamp
);

public sealed record UsbExportManifest(
    string AppName,
    string ExportVersion,
    string SessionId,
    DateTimeOffset CreatedAt,
    int FileCount,
    long TotalBytes,
    List<UsbExportFile> Files
);

public sealed record UsbExportFile(
    string AssetId,
    string ResourceId,
    string OriginalFilename,
    string RelativePath,
    DateTimeOffset? CreatedAt,
    string MediaType,
    long FileSize,
    string Sha256
);

public sealed class ReceivedFileItem
{
    public string OriginalFilename { get; set; } = "";
    public string AssetId { get; set; } = "";
    public string Status { get; set; } = "pending";
    public string? SavedPath { get; set; }
    public string? ErrorCode { get; set; }
    public string? ErrorMessage { get; set; }
    public long FileSize { get; set; }
    public double Progress { get; set; }
    public DateTimeOffset StartedAt { get; set; } = DateTimeOffset.Now;
    public DateTimeOffset? CompletedAt { get; set; }

    [JsonIgnore]
    public bool IsSuccess => Status.Equals("verified", StringComparison.OrdinalIgnoreCase);
}
