using System.IO;
using System.Text.Json;
using PhotoMoveBridge.Windows.Models;

namespace PhotoMoveBridge.Windows.Services;

public sealed class TransferLogStore
{
    private readonly object _gate = new();
    private readonly List<TransferLog> _logs = new();
    private readonly JsonSerializerOptions _jsonOptions = new(JsonSerializerDefaults.Web)
    {
        WriteIndented = true
    };

    public string LogDirectory { get; }
    public string LogPath => Path.Combine(LogDirectory, "transfer-log.json");

    public TransferLogStore()
    {
        LogDirectory = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "PhotoMoveBridge");
        Directory.CreateDirectory(LogDirectory);
        Load();
    }

    public IReadOnlyList<TransferLog> Logs
    {
        get
        {
            lock (_gate)
            {
                return _logs.ToList();
            }
        }
    }

    public void Add(TransferLog log)
    {
        lock (_gate)
        {
            _logs.Insert(0, log);
            File.WriteAllText(LogPath, JsonSerializer.Serialize(_logs, _jsonOptions));
        }
    }

    private void Load()
    {
        if (!File.Exists(LogPath))
        {
            return;
        }

        try
        {
            var loaded = JsonSerializer.Deserialize<List<TransferLog>>(File.ReadAllText(LogPath), _jsonOptions);
            if (loaded is null)
            {
                return;
            }

            _logs.Clear();
            _logs.AddRange(loaded);
        }
        catch
        {
            // A corrupt log file must not prevent receiving new transfers.
        }
    }
}
