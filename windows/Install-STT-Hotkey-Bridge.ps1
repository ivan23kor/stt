# Installs Ivan Korostelev's STT Windows hotkey bridge for the current user.

$ErrorActionPreference = 'Stop'

$source = Join-Path $PSScriptRoot 'STT-Hotkey-Bridge.ps1'
if (-not (Test-Path -LiteralPath $source -PathType Leaf)) {
    throw "Bridge source not found: $source"
}

$tokens = $null
$parseErrors = $null
[System.Management.Automation.Language.Parser]::ParseFile(
    $source,
    [ref] $tokens,
    [ref] $parseErrors
) | Out-Null
if ($parseErrors.Count -gt 0) {
    throw ($parseErrors | ForEach-Object Message | Out-String)
}

$installDirectory = Join-Path $env:LOCALAPPDATA 'IvanKorostelev\STT'
New-Item -ItemType Directory -Path $installDirectory -Force | Out-Null
$installedScript = Join-Path $installDirectory 'STT-Hotkey-Bridge.ps1'

# Stop only the previously installed bridge instance before replacing it.
$installedPattern = [Regex]::Escape($installedScript)
$existingBridges = Get-CimInstance Win32_Process | Where-Object {
    $_.Name -eq 'powershell.exe' -and
    $_.ProcessId -ne $PID -and
    $_.CommandLine -match $installedPattern
}
foreach ($bridge in $existingBridges) {
    Stop-Process -Id $bridge.ProcessId -Force -ErrorAction Stop
}
if ($existingBridges) {
    Start-Sleep -Milliseconds 500
}

Copy-Item -LiteralPath $source -Destination $installedScript -Force

$startupDirectory = [Environment]::GetFolderPath('Startup')
$shortcutPath = Join-Path $startupDirectory 'STT Hotkey Bridge.lnk'
$shell = New-Object -ComObject WScript.Shell
$shortcut = $shell.CreateShortcut($shortcutPath)
$shortcut.TargetPath = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
$shortcut.Arguments = "-NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$installedScript`""
$shortcut.WorkingDirectory = $installDirectory
$shortcut.Description = 'Ivan Korostelev STT global hotkey bridge'
$shortcut.Save()

$powershell = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
Start-Process -FilePath $powershell -ArgumentList @(
    '-NoProfile',
    '-STA',
    '-ExecutionPolicy', 'Bypass',
    '-WindowStyle', 'Hidden',
    '-File', "`"$installedScript`""
) -WindowStyle Hidden

Write-Output "Installed script: $installedScript"
Write-Output "Startup shortcut: $shortcutPath"
