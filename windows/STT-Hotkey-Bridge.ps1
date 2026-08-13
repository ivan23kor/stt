# Persistent Windows global-hotkey bridge and status overlay for
# Ivan Korostelev <ivan23kor@gmail.com>.

$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$source = @'
using System;
using System.Diagnostics;
using System.Drawing;
using System.Globalization;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using System.Windows.Forms;

public sealed class STTHotkeyOverlay : Form
{
    private const int WM_HOTKEY = 0x0312;
    private const int HOTKEY_S_ID = 0x5354;
    private const int HOTKEY_P_ID = 0x5054;
    private const int HOTKEY_X_ID = 0x5854;
    private const uint MOD_ALT = 0x0001;
    private const uint MOD_CONTROL = 0x0002;
    private const uint MOD_NOREPEAT = 0x4000;
    private const int VK_CONTROL = 0x11;
    private const int VK_MENU = 0x12;
    private const int VK_S = 0x53;
    private const int VK_P = 0x50;
    private const int VK_X = 0x58;
    private const int WS_EX_TOOLWINDOW = 0x00000080;
    private const int WS_EX_NOACTIVATE = 0x08000000;

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool RegisterHotKey(IntPtr hWnd, int id, uint modifiers, uint key);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool UnregisterHotKey(IntPtr hWnd, int id);

    [DllImport("user32.dll")]
    private static extern uint GetClipboardSequenceNumber();

    [DllImport("user32.dll")]
    private static extern short GetAsyncKeyState(int key);

    private readonly string logPath;
    private readonly Label titleLabel;
    private readonly Label detailLabel;
    private readonly ProgressBar progress;
    private readonly Panel accent;
    private readonly System.Windows.Forms.Timer modifierTimer;
    private readonly System.Windows.Forms.Timer clipboardTimer;
    private readonly System.Windows.Forms.Timer hideTimer;
    private readonly System.Windows.Forms.Timer progressTimer;
    private readonly Stopwatch requestStopwatch = new Stopwatch();
    private readonly Stopwatch playbackStopwatch = new Stopwatch();
    private int modifierAttempts;
    private int clipboardAttempts;
    private uint clipboardSequence;
    private bool busy;
    private bool stopRequested;
    private bool playbackStarted;
    private double estimatedSpeechSeconds = 5.0;
    private double preparationSeconds;
    private double playbackSeconds;
    private Process speechProcess;

    public STTHotkeyOverlay()
    {
        string directory = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "IvanKorostelev", "STT");
        Directory.CreateDirectory(directory);
        logPath = Path.Combine(directory, "hotkey-bridge.log");

        Text = "STT status";
        FormBorderStyle = FormBorderStyle.None;
        StartPosition = FormStartPosition.Manual;
        ClientSize = new Size(390, 108);
        BackColor = Color.FromArgb(27, 29, 34);
        TopMost = true;
        ShowInTaskbar = false;
        Opacity = 0.96;
        Padding = new Padding(22, 14, 18, 12);

        accent = new Panel();
        accent.Dock = DockStyle.Left;
        accent.Width = 6;
        accent.BackColor = Color.FromArgb(74, 144, 245);
        Controls.Add(accent);

        titleLabel = new Label();
        titleLabel.AutoSize = false;
        titleLabel.Location = new Point(25, 15);
        titleLabel.Size = new Size(345, 29);
        titleLabel.ForeColor = Color.White;
        titleLabel.Font = new Font("Segoe UI Semibold", 13.0f, FontStyle.Bold);
        titleLabel.Text = "STT ready";
        Controls.Add(titleLabel);

        detailLabel = new Label();
        detailLabel.AutoSize = false;
        detailLabel.Location = new Point(27, 47);
        detailLabel.Size = new Size(342, 22);
        detailLabel.ForeColor = Color.FromArgb(196, 201, 210);
        detailLabel.Font = new Font("Segoe UI", 9.5f, FontStyle.Regular);
        detailLabel.Text = "Select text and press Ctrl+Alt+S";
        Controls.Add(detailLabel);

        progress = new ProgressBar();
        progress.Location = new Point(27, 79);
        progress.Size = new Size(342, 7);
        progress.Minimum = 0;
        progress.Maximum = 1000;
        progress.Value = 0;
        progress.Style = ProgressBarStyle.Continuous;
        progress.MarqueeAnimationSpeed = 0;
        Controls.Add(progress);

        modifierTimer = new System.Windows.Forms.Timer();
        modifierTimer.Interval = 50;
        modifierTimer.Tick += ModifierTimerTick;

        clipboardTimer = new System.Windows.Forms.Timer();
        clipboardTimer.Interval = 75;
        clipboardTimer.Tick += ClipboardTimerTick;

        hideTimer = new System.Windows.Forms.Timer();
        hideTimer.Interval = 1800;
        hideTimer.Tick += delegate {
            hideTimer.Stop();
            Hide();
        };

        progressTimer = new System.Windows.Forms.Timer();
        progressTimer.Interval = 100;
        progressTimer.Tick += ProgressTimerTick;

        Shown += delegate {
            PositionOverlay();
            Hide();
        };
        FormClosing += delegate(object sender, FormClosingEventArgs args) {
            if (args.CloseReason == CloseReason.UserClosing) {
                args.Cancel = true;
                Hide();
            }
        };
    }

    protected override bool ShowWithoutActivation { get { return true; } }

    protected override CreateParams CreateParams
    {
        get
        {
            CreateParams parameters = base.CreateParams;
            parameters.ExStyle |= WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE;
            return parameters;
        }
    }

    protected override void OnHandleCreated(EventArgs args)
    {
        base.OnHandleCreated(args);
        uint modifiers = MOD_CONTROL | MOD_ALT | MOD_NOREPEAT;
        if (!RegisterHotKey(Handle, HOTKEY_S_ID, modifiers, VK_S)) {
            int error = Marshal.GetLastWin32Error();
            Log("ERROR Could not register Ctrl+Alt+S (Win32 " + error + ").");
            throw new InvalidOperationException("Could not register Ctrl+Alt+S (Win32 " + error + ").");
        }
        if (!RegisterHotKey(Handle, HOTKEY_P_ID, modifiers, VK_P)) {
            int error = Marshal.GetLastWin32Error();
            UnregisterHotKey(Handle, HOTKEY_S_ID);
            Log("ERROR Could not register Ctrl+Alt+P (Win32 " + error + ").");
            throw new InvalidOperationException("Could not register Ctrl+Alt+P (Win32 " + error + ").");
        }
        if (!RegisterHotKey(Handle, HOTKEY_X_ID, modifiers, VK_X)) {
            int error = Marshal.GetLastWin32Error();
            UnregisterHotKey(Handle, HOTKEY_S_ID);
            UnregisterHotKey(Handle, HOTKEY_P_ID);
            Log("ERROR Could not register Ctrl+Alt+X (Win32 " + error + ").");
            throw new InvalidOperationException("Could not register Ctrl+Alt+X (Win32 " + error + ").");
        }
        Log("READY Ctrl+Alt+S/P/X registered globally with persistent overlay host.");
    }

    protected override void OnHandleDestroyed(EventArgs args)
    {
        UnregisterHotKey(Handle, HOTKEY_S_ID);
        UnregisterHotKey(Handle, HOTKEY_P_ID);
        UnregisterHotKey(Handle, HOTKEY_X_ID);
        Log("STOP Overlay host handle destroyed.");
        base.OnHandleDestroyed(args);
    }

    protected override void WndProc(ref Message message)
    {
        if (message.Msg == WM_HOTKEY) {
            int hotkey = message.WParam.ToInt32();
            if (hotkey == HOTKEY_S_ID) {
                BeginSelectionCopy();
            } else if (hotkey == HOTKEY_P_ID) {
                Log("HOTKEY Ctrl+Alt+P received.");
                RunPlaybackControl("toggle");
            } else if (hotkey == HOTKEY_X_ID) {
                Log("HOTKEY Ctrl+Alt+X received.");
                stopRequested = true;
                RunPlaybackControl("stop");
            }
        }
        base.WndProc(ref message);
    }

    private void BeginSelectionCopy()
    {
        Log("HOTKEY Ctrl+Alt+S received.");
        if (busy) {
            Log("BUSY Ignored duplicate shortcut while speech is in progress.");
            ShowOverlay();
            return;
        }

        busy = true;
        stopRequested = false;
        StartRequestProgress();
        hideTimer.Stop();
        SetStatus("Copying selected text", "Usually less than one second", Color.FromArgb(74, 144, 245), true);
        ShowOverlay();
        modifierAttempts = 0;
        modifierTimer.Start();
    }

    private void StartRequestProgress()
    {
        requestStopwatch.Restart();
        playbackStopwatch.Reset();
        playbackStarted = false;
        estimatedSpeechSeconds = 5.0;
        preparationSeconds = 0.0;
        playbackSeconds = 0.0;
        progress.Value = 0;
        progressTimer.Start();
    }

    private void ProgressTimerTick(object sender, EventArgs args)
    {
        if (!busy) return;

        if (!playbackStarted) {
            double elapsed = requestStopwatch.Elapsed.TotalSeconds;
            double estimatedTotal = Math.Max(elapsed + 0.5, 1.5 + estimatedSpeechSeconds);
            SetProgressFraction(Math.Min(0.35, elapsed / estimatedTotal));
            if (titleLabel.Text != "Copying selected text") {
                detailLabel.Text = String.Format("Preparing audio - {0:0.0}s elapsed", elapsed);
            }
            return;
        }

        double played = Math.Min(playbackSeconds, playbackStopwatch.Elapsed.TotalSeconds);
        double total = Math.Max(0.1, preparationSeconds + playbackSeconds);
        SetProgressFraction((preparationSeconds + played) / total);
        double remaining = Math.Max(0.0, playbackSeconds - played);
        detailLabel.Text = String.Format(
            "Reading selected text - {0} second{1} remaining",
            Math.Ceiling(remaining),
            Math.Ceiling(remaining) == 1 ? "" : "s");
    }

    private void SetProgressFraction(double fraction)
    {
        int target = Math.Max(0, Math.Min(progress.Maximum, (int)Math.Round(fraction * progress.Maximum)));
        progress.Value = Math.Max(progress.Value, target);
    }

    private void StopProgress(bool completed)
    {
        progressTimer.Stop();
        requestStopwatch.Stop();
        playbackStopwatch.Stop();
        if (completed) progress.Value = progress.Maximum;
    }

    private void ModifierTimerTick(object sender, EventArgs args)
    {
        modifierAttempts++;
        bool controlDown = (GetAsyncKeyState(VK_CONTROL) & 0x8000) != 0;
        bool altDown = (GetAsyncKeyState(VK_MENU) & 0x8000) != 0;
        if ((controlDown || altDown) && modifierAttempts < 30) {
            return;
        }

        modifierTimer.Stop();
        clipboardSequence = GetClipboardSequenceNumber();
        clipboardAttempts = 0;
        detailLabel.Text = "Reading selection from the active app...";
        try
        {
            SendKeys.SendWait("^c");
            clipboardTimer.Start();
        }
        catch (Exception exception)
        {
            Fail("Could not copy the selection", exception.Message);
        }
    }

    private void ClipboardTimerTick(object sender, EventArgs args)
    {
        clipboardAttempts++;
        if (GetClipboardSequenceNumber() == clipboardSequence && clipboardAttempts < 16) {
            return;
        }

        clipboardTimer.Stop();
        string selection = null;
        try {
            if (Clipboard.ContainsText()) {
                selection = Clipboard.GetText();
            }
        }
        catch (Exception exception) {
            Fail("Clipboard is unavailable", exception.Message);
            return;
        }

        if (GetClipboardSequenceNumber() == clipboardSequence || String.IsNullOrWhiteSpace(selection)) {
            Fail("No selected text found", "Highlight text, keep that app focused, then press Ctrl+Alt+S");
            return;
        }

        StartSpeech(selection);
    }

    private void StartSpeech(string selection)
    {
        int wordCount = selection.Split(
            new char[] { ' ', '\t', '\r', '\n' },
            StringSplitOptions.RemoveEmptyEntries).Length;
        estimatedSpeechSeconds = Math.Max(3.0, wordCount / (2.4 * 1.2));
        SetStatus(
            "Preparing audio",
            String.Format("Sending {0:N0} selected characters to Piper...", selection.Length),
            Color.FromArgb(74, 144, 245),
            true);
        Log(String.Format("SENT {0} selected characters to WSL.", selection.Length));

        try {
            ProcessStartInfo start = new ProcessStartInfo();
            start.FileName = "wsl.exe";
            start.Arguments = "-d Ubuntu -- /home/aivan/.personal/stt/scripts/speak-stdin.sh";
            start.UseShellExecute = false;
            start.CreateNoWindow = true;
            start.RedirectStandardInput = true;
            start.RedirectStandardOutput = true;
            start.RedirectStandardError = true;

            speechProcess = new Process();
            speechProcess.StartInfo = start;
            speechProcess.EnableRaisingEvents = true;
            speechProcess.ErrorDataReceived += SpeechErrorDataReceived;
            speechProcess.OutputDataReceived += SpeechOutputDataReceived;
            speechProcess.Exited += SpeechProcessExited;
            speechProcess.Start();
            speechProcess.BeginErrorReadLine();
            speechProcess.BeginOutputReadLine();
            string encodedSelection = Convert.ToBase64String(Encoding.UTF8.GetBytes(selection));
            speechProcess.StandardInput.Write(encodedSelection);
            speechProcess.StandardInput.Close();
        }
        catch (Exception exception) {
            Fail("Could not start WSL", exception.Message);
        }
    }

    private void RunPlaybackControl(string action)
    {
        hideTimer.Stop();
        string title = action == "stop" ? "Stopping playback" : "Changing playback";
        SetStatus(title, "Sending the command to WSL...", Color.FromArgb(245, 166, 35), true);
        ShowOverlay();

        ThreadPool.QueueUserWorkItem(delegate {
            try {
                ProcessStartInfo start = new ProcessStartInfo();
                start.FileName = "wsl.exe";
                start.Arguments = "-d Ubuntu -- /home/aivan/.personal/stt/scripts/control-playback.sh " + action;
                start.UseShellExecute = false;
                start.CreateNoWindow = true;
                start.RedirectStandardOutput = true;
                start.RedirectStandardError = true;

                using (Process control = Process.Start(start)) {
                    string output = control.StandardOutput.ReadToEnd().Trim();
                    string error = control.StandardError.ReadToEnd().Trim();
                    control.WaitForExit();
                    Log("CONTROL " + action + " returned " + output + " (exit " + control.ExitCode + ").");
                    if (control.ExitCode != 0) {
                        string problem = String.IsNullOrWhiteSpace(error) ? "Playback control failed" : error;
                        Ui(delegate { stopRequested = false; Fail("Playback control failed", problem); });
                    } else {
                        Ui(delegate { ApplyPlaybackControl(output); });
                    }
                }
            }
            catch (Exception exception) {
                Log("ERROR Playback control: " + exception);
                Ui(delegate { stopRequested = false; Fail("Playback control failed", exception.Message); });
            }
        });
    }

    private void ApplyPlaybackControl(string result)
    {
        if (result == "paused") {
            playbackStopwatch.Stop();
            progressTimer.Stop();
            double remaining = Math.Max(0.0, playbackSeconds - playbackStopwatch.Elapsed.TotalSeconds);
            SetStatus(
                "Paused",
                String.Format("{0}s remaining; Ctrl+Alt+P resumes", Math.Ceiling(remaining)),
                Color.FromArgb(245, 166, 35),
                false);
            ShowOverlay();
        } else if (result == "resumed") {
            if (playbackStarted) playbackStopwatch.Start();
            progressTimer.Start();
            SetStatus("Speaking", "Playback resumed", Color.FromArgb(42, 190, 125), true);
            ShowOverlay();
        } else if (result == "stopped") {
            busy = false;
            StopProgress(false);
            SetStatus("Stopped", "Playback ended", Color.FromArgb(230, 79, 79), false);
            ShowFor(2200);
        } else {
            stopRequested = false;
            bool requestActive = speechProcess != null && !speechProcess.HasExited;
            if (requestActive) {
                SetStatus("Not speaking yet", "The audio is still being prepared", Color.FromArgb(143, 103, 246), true);
                ShowOverlay();
            } else {
                busy = false;
                StopProgress(false);
                progress.Value = 0;
                SetStatus("Nothing is playing", "Start speech with Ctrl+Alt+S", Color.FromArgb(245, 166, 35), false);
                ShowFor(2500);
            }
        }
    }

    private void SpeechErrorDataReceived(object sender, DataReceivedEventArgs args)
    {
        if (String.IsNullOrEmpty(args.Data)) return;
        Log("WSL " + args.Data);
        if (!args.Data.StartsWith("STT_STATUS\t")) return;

        string[] fields = args.Data.Split(new char[] { '\t' }, 3);
        string state = fields.Length > 1 ? fields[1] : "";
        string detail = fields.Length > 2 ? fields[2] : "";
        Ui(delegate { ApplyBridgeStatus(state, detail); });
    }

    private void SpeechOutputDataReceived(object sender, DataReceivedEventArgs args)
    {
        if (!String.IsNullOrEmpty(args.Data)) Log("WSL " + args.Data);
    }

    private void SpeechProcessExited(object sender, EventArgs args)
    {
        Process completed = (Process)sender;
        int exitCode = completed.ExitCode;
        Log("WSL process exited with code " + exitCode + ".");
        Ui(delegate {
            if (busy) {
                if (stopRequested) {
                    busy = false;
                    StopProgress(false);
                    SetStatus("Stopped", "Playback ended", Color.FromArgb(230, 79, 79), false);
                    ShowFor(2200);
                } else if (exitCode == 0) {
                    Complete("Finished", "Ready for another selection");
                } else {
                    Fail("STT failed", "See hotkey-bridge.log for details");
                }
            }
            completed.Dispose();
            if (Object.ReferenceEquals(speechProcess, completed)) speechProcess = null;
        });
    }

    private void ApplyBridgeStatus(string state, string detail)
    {
        if (stopRequested) return;

        double seconds;
        if (state == "preparing") {
            if (Double.TryParse(detail, NumberStyles.Float, CultureInfo.InvariantCulture, out seconds)) {
                estimatedSpeechSeconds = Math.Max(0.1, seconds);
            }
            SetStatus(
                "Preparing audio",
                String.Format("Waiting for Piper - {0:0.0}s elapsed", requestStopwatch.Elapsed.TotalSeconds),
                Color.FromArgb(143, 103, 246),
                true);
        } else if (state == "speaking") {
            if (!Double.TryParse(detail, NumberStyles.Float, CultureInfo.InvariantCulture, out seconds)) {
                Fail("STT failed", "Invalid playback duration received from WSL");
                return;
            }
            requestStopwatch.Stop();
            preparationSeconds = requestStopwatch.Elapsed.TotalSeconds;
            playbackSeconds = Math.Max(0.1, seconds);
            playbackStarted = true;
            playbackStopwatch.Restart();
            progressTimer.Start();
            Log(String.Format(
                CultureInfo.InvariantCulture,
                "PLAYBACK started after {0:0.000}s preparation; audio is {1:0.000}s.",
                preparationSeconds,
                playbackSeconds));
            SetStatus(
                "Speaking",
                String.Format("Reading selected text - {0}s remaining", Math.Ceiling(playbackSeconds)),
                Color.FromArgb(42, 190, 125),
                true);
            ProgressTimerTick(null, EventArgs.Empty);
        } else if (state == "done") {
            if (stopRequested) {
                busy = false;
                StopProgress(false);
                SetStatus("Stopped", "Playback ended", Color.FromArgb(230, 79, 79), false);
                ShowFor(2200);
            } else {
                Complete("Finished", detail);
            }
        } else if (state == "error") {
            Fail("STT failed", detail);
        }
    }

    private void Complete(string title, string detail)
    {
        busy = false;
        StopProgress(true);
        SetStatus(title, detail, Color.FromArgb(42, 190, 125), false);
        ShowFor(1800);
    }

    private void Fail(string title, string detail)
    {
        busy = false;
        StopProgress(false);
        Log("ERROR " + title + ": " + detail);
        SetStatus(title, detail, Color.FromArgb(230, 79, 79), false);
        System.Media.SystemSounds.Exclamation.Play();
        ShowFor(4500);
    }

    private void SetStatus(string title, string detail, Color color, bool working)
    {
        titleLabel.Text = title;
        detailLabel.Text = detail;
        accent.BackColor = color;
        progress.Style = ProgressBarStyle.Continuous;
        progress.MarqueeAnimationSpeed = 0;
    }

    private void PositionOverlay()
    {
        Screen screen = Screen.FromPoint(Cursor.Position);
        Rectangle area = screen.WorkingArea;
        Location = new Point(area.Right - Width - 24, area.Bottom - Height - 24);
    }

    private void ShowOverlay()
    {
        PositionOverlay();
        if (!Visible) Show();
        BringToFront();
    }

    private void ShowFor(int milliseconds)
    {
        ShowOverlay();
        hideTimer.Stop();
        hideTimer.Interval = milliseconds;
        hideTimer.Start();
    }

    private void Ui(MethodInvoker action)
    {
        if (IsDisposed) return;
        BeginInvoke(action);
    }

    private void Log(string message)
    {
        try {
            File.AppendAllText(
                logPath,
                DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss.fff") + " " + message + Environment.NewLine);
        } catch { }
    }

    public static void Run()
    {
        bool created;
        using (Mutex mutex = new Mutex(true, "IvanKorostelev.STT.HotkeyBridge", out created)) {
            if (!created) return;
            Application.EnableVisualStyles();
            Application.SetCompatibleTextRenderingDefault(false);
            Application.ThreadException += delegate(object sender, ThreadExceptionEventArgs args) {
                string directory = Path.Combine(
                    Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                    "IvanKorostelev", "STT");
                Directory.CreateDirectory(directory);
                File.AppendAllText(Path.Combine(directory, "hotkey-bridge.log"),
                    DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss.fff") + " FATAL " + args.Exception + Environment.NewLine);
            };
            Application.Run(new STTHotkeyOverlay());
        }
    }
}
'@

try {
    Add-Type -TypeDefinition $source -ReferencedAssemblies @(
        'System.dll',
        'System.Drawing.dll',
        'System.Windows.Forms.dll'
    )
    [STTHotkeyOverlay]::Run()
}
catch {
    $directory = Join-Path $env:LOCALAPPDATA 'IvanKorostelev\STT'
    New-Item -ItemType Directory -Path $directory -Force | Out-Null
    $log = Join-Path $directory 'hotkey-bridge.log'
    Add-Content -LiteralPath $log -Encoding UTF8 -Value (
        '{0:yyyy-MM-dd HH:mm:ss.fff} FATAL {1}' -f (Get-Date), $_.Exception
    )
    throw
}
