using System.IO;
using System.Security.Cryptography;
using PhotoMoveBridge.Windows.Models;

namespace PhotoMoveBridge.Windows.Services;

public sealed class StorageTargetService
{
    private static readonly char[] WindowsInvalidFileNameChars = Path.GetInvalidFileNameChars();

    public IReadOnlyList<DriveInfoSnapshot> GetDriveSnapshots()
    {
        return DriveInfo.GetDrives()
            .Select(ToSnapshot)
            .OrderBy(d => d.DriveLetter, StringComparer.OrdinalIgnoreCase)
            .ToList();
    }

    public StorageTarget BuildTarget(DriveInfoSnapshot snapshot, string? requestedTargetRoot)
    {
        var targetRoot = string.IsNullOrWhiteSpace(requestedTargetRoot)
            ? Path.Combine(snapshot.RootDirectory, "iPhone_Photo_Move")
            : requestedTargetRoot.Trim();

        if (!Path.EndsInDirectorySeparator(targetRoot))
        {
            targetRoot += Path.DirectorySeparatorChar;
        }

        return new StorageTarget(
            DriveLetter: snapshot.DriveLetter,
            VolumeLabel: snapshot.VolumeLabel,
            DriveType: snapshot.DriveType,
            FileSystem: snapshot.FileSystem,
            RootDirectory: snapshot.RootDirectory,
            TargetRoot: targetRoot,
            TotalSize: snapshot.TotalSize,
            FreeSpace: snapshot.FreeSpace,
            IsReady: snapshot.IsReady,
            CanWrite: false,
            LastCheckedAt: DateTimeOffset.Now
        );
    }

    public StorageTarget BuildTargetFromPath(string? requestedTargetRoot)
    {
        var targetRoot = string.IsNullOrWhiteSpace(requestedTargetRoot)
            ? Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.MyPictures), "iPhone_Photo_Move")
            : requestedTargetRoot.Trim();
        targetRoot = Path.GetFullPath(targetRoot);

        if (!Path.EndsInDirectorySeparator(targetRoot))
        {
            targetRoot += Path.DirectorySeparatorChar;
        }

        var root = Path.GetPathRoot(targetRoot) ?? targetRoot;
        var drive = DriveInfo.GetDrives()
            .FirstOrDefault(d => d.Name.Equals(root, StringComparison.OrdinalIgnoreCase));

        if (drive is null || !drive.IsReady)
        {
            return new StorageTarget(
                DriveLetter: root.TrimEnd('\\', '/'),
                VolumeLabel: "",
                DriveType: "Unknown",
                FileSystem: "",
                RootDirectory: root,
                TargetRoot: targetRoot,
                TotalSize: 0,
                FreeSpace: 0,
                IsReady: false,
                CanWrite: false,
                LastCheckedAt: DateTimeOffset.Now
            );
        }

        return BuildTarget(ToSnapshot(drive), targetRoot);
    }

    public async Task<StorageTarget> RefreshAndTestAsync(StorageTarget target, CancellationToken cancellationToken = default)
    {
        var drive = GetDriveInfo(target.DriveLetter);
        if (drive is null || !drive.IsReady)
        {
            return target with
            {
                IsReady = false,
                CanWrite = false,
                FreeSpace = 0,
                LastCheckedAt = DateTimeOffset.Now
            };
        }

        var refreshed = target with
        {
            VolumeLabel = drive.VolumeLabel,
            DriveType = drive.DriveType.ToString(),
            FileSystem = drive.DriveFormat,
            RootDirectory = drive.RootDirectory.FullName,
            TotalSize = drive.TotalSize,
            FreeSpace = drive.AvailableFreeSpace,
            IsReady = drive.IsReady,
            LastCheckedAt = DateTimeOffset.Now
        };

        var canWrite = await TestWriteAsync(refreshed, cancellationToken);
        return refreshed with { CanWrite = canWrite };
    }

    public async Task<bool> TestWriteAsync(StorageTarget target, CancellationToken cancellationToken = default)
    {
        try
        {
            Directory.CreateDirectory(target.TargetRoot);
            var testPath = Path.Combine(target.TargetRoot, $".photomove-write-test-{Guid.NewGuid():N}.tmp");
            await File.WriteAllTextAsync(testPath, "PhotoMove Bridge write test", cancellationToken);
            File.Delete(testPath);
            return true;
        }
        catch
        {
            return false;
        }
    }

    public void EnsureUsableForUpload(StorageTarget? target, long requiredBytes)
    {
        if (target is null)
        {
            throw new UploadFailureException("STORAGE_TARGET_NOT_SELECTED", "Storage target has not been selected.");
        }

        var drive = GetDriveInfo(target.DriveLetter);
        if (drive is null || !drive.IsReady)
        {
            throw new UploadFailureException("STORAGE_TARGET_NOT_READY", "Storage target drive is not connected or not ready.");
        }

        if (!IsPathUnderRoot(target.TargetRoot, drive.RootDirectory.FullName))
        {
            throw new UploadFailureException("TARGET_ROOT_NOT_ON_SELECTED_DRIVE", "Target root is not on the selected drive.");
        }

        if (drive.AvailableFreeSpace < requiredBytes)
        {
            throw new UploadFailureException("INSUFFICIENT_FREE_SPACE", "Storage target does not have enough free space.");
        }
    }

    public string CreateFinalPath(StorageTarget target, DateTimeOffset? createdAt, string originalFilename)
    {
        var safeName = SanitizeWindowsFilename(originalFilename);
        var directory = createdAt is null
            ? Path.Combine(target.TargetRoot, "Unknown-Date")
            : Path.Combine(
                target.TargetRoot,
                createdAt.Value.ToString("yyyy-MM"),
                createdAt.Value.ToString("yyyy-MM-dd"));

        Directory.CreateDirectory(directory);
        var candidate = Path.Combine(directory, safeName);

        if (!IsPathUnderRoot(candidate, target.TargetRoot))
        {
            throw new UploadFailureException("SAVED_PATH_INVALID", "Resolved path is outside of the selected target root.");
        }

        if (!File.Exists(candidate))
        {
            return candidate;
        }

        var name = Path.GetFileNameWithoutExtension(safeName);
        var extension = Path.GetExtension(safeName);
        for (var i = 1; i < 10_000; i++)
        {
            var deduped = Path.Combine(directory, $"{name}_{i:000}{extension}");
            if (!File.Exists(deduped))
            {
                return deduped;
            }
        }

        throw new UploadFailureException("FILENAME_COLLISION_LIMIT", "Too many duplicate filenames exist in the target folder.");
    }

    public string CreatePartialPath(string finalPath)
    {
        var partial = finalPath + ".partial";
        if (!File.Exists(partial))
        {
            return partial;
        }

        return finalPath + $".{Guid.NewGuid():N}.partial";
    }

    public bool IsPathUnderRoot(string path, string root)
    {
        var fullPath = Path.GetFullPath(path).TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
        var fullRoot = Path.GetFullPath(root).TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
        if (fullPath.Equals(fullRoot, StringComparison.OrdinalIgnoreCase))
        {
            return true;
        }

        var rootWithSeparator = fullRoot + Path.DirectorySeparatorChar;
        return fullPath.StartsWith(rootWithSeparator, StringComparison.OrdinalIgnoreCase);
    }

    public string SanitizeWindowsFilename(string filename)
    {
        var decoded = Uri.UnescapeDataString(filename);
        var cleaned = new string(decoded.Select(ch => WindowsInvalidFileNameChars.Contains(ch) ? '_' : ch).ToArray()).Trim();
        if (string.IsNullOrWhiteSpace(cleaned))
        {
            cleaned = "asset.bin";
        }

        var reserved = new HashSet<string>(StringComparer.OrdinalIgnoreCase)
        {
            "CON", "PRN", "AUX", "NUL",
            "COM1", "COM2", "COM3", "COM4", "COM5", "COM6", "COM7", "COM8", "COM9",
            "LPT1", "LPT2", "LPT3", "LPT4", "LPT5", "LPT6", "LPT7", "LPT8", "LPT9"
        };
        var stem = Path.GetFileNameWithoutExtension(cleaned);
        if (reserved.Contains(stem))
        {
            cleaned = "_" + cleaned;
        }

        return cleaned;
    }

    public async Task<string> ComputeSha256Async(string path, CancellationToken cancellationToken = default)
    {
        await using var stream = File.OpenRead(path);
        var hash = await SHA256.HashDataAsync(stream, cancellationToken);
        return Convert.ToHexString(hash).ToLowerInvariant();
    }

    private static DriveInfoSnapshot ToSnapshot(DriveInfo drive)
    {
        if (!drive.IsReady)
        {
            return new DriveInfoSnapshot(
                DriveLetter: drive.Name.TrimEnd('\\'),
                VolumeLabel: "",
                DriveType: drive.DriveType.ToString(),
                TotalSize: 0,
                FreeSpace: 0,
                FileSystem: "",
                IsReady: false,
                RootDirectory: drive.RootDirectory.FullName
            );
        }

        return new DriveInfoSnapshot(
            DriveLetter: drive.Name.TrimEnd('\\'),
            VolumeLabel: drive.VolumeLabel,
            DriveType: drive.DriveType.ToString(),
            TotalSize: drive.TotalSize,
            FreeSpace: drive.AvailableFreeSpace,
            FileSystem: drive.DriveFormat,
            IsReady: drive.IsReady,
            RootDirectory: drive.RootDirectory.FullName
        );
    }

    private static DriveInfo? GetDriveInfo(string driveLetter)
    {
        var normalized = driveLetter.TrimEnd('\\') + "\\";
        return DriveInfo.GetDrives()
            .FirstOrDefault(d => d.Name.Equals(normalized, StringComparison.OrdinalIgnoreCase));
    }
}

public sealed class UploadFailureException : Exception
{
    public string ErrorCode { get; }

    public UploadFailureException(string errorCode, string message) : base(message)
    {
        ErrorCode = errorCode;
    }
}
