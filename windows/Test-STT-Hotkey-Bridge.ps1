# End-to-end verifier: focuses selected Windows text and presses Ctrl+Alt+S.

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$form = New-Object System.Windows.Forms.Form
$form.Text = 'STT hotkey bridge verification'
$form.Width = 520
$form.Height = 140
$form.StartPosition = 'CenterScreen'
$form.TopMost = $true

$textBox = New-Object System.Windows.Forms.TextBox
$textBox.Dock = 'Fill'
$textBox.Multiline = $true
$superscriptT = [char]::ConvertFromUtf32(0x1D40)
$timesSign = [char] 0x00D7
$curlyApostrophe = [char] 0x2019
$textBox.Text = "Unicode bridge test: QK${superscriptT} ${timesSign} P, GPT-2${curlyApostrophe}s tensors, and nonnegative probabilities."
$form.Controls.Add($textBox)

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 700
$timer.Add_Tick({
    $timer.Stop()
    $textBox.Focus()
    $textBox.SelectAll()
    [System.Windows.Forms.SendKeys]::SendWait('^%s')
    $closeTimer.Start()
})

$closeTimer = New-Object System.Windows.Forms.Timer
$closeTimer.Interval = 5000
$closeTimer.Add_Tick({
    $closeTimer.Stop()
    $form.Close()
})

$form.Add_Shown({
    $textBox.Focus()
    $textBox.SelectAll()
    $timer.Start()
})

[void] $form.ShowDialog()
