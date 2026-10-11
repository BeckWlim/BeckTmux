# Windows 10 1809+ clipboard history bridge for the WSL tmux picker.
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)

try {
    Add-Type -AssemblyName System.Runtime.WindowsRuntime
    $null = [Windows.ApplicationModel.DataTransfer.Clipboard, Windows.ApplicationModel.DataTransfer, ContentType=WindowsRuntime]
    $null = [Windows.ApplicationModel.DataTransfer.ClipboardHistoryItemsResult, Windows.ApplicationModel.DataTransfer, ContentType=WindowsRuntime]
    $asTask = [System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object {
        $_.Name -eq 'AsTask' -and $_.IsGenericMethodDefinition -and
        $_.GetParameters().Count -eq 1 -and
        $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1'
    } | Select-Object -First 1

    function Wait-WinRT($Operation, [Type]$ResultType) {
        $task = $asTask.MakeGenericMethod($ResultType).Invoke($null, @($Operation))
        $task.GetAwaiter().GetResult()
    }

    $history = Wait-WinRT ([Windows.ApplicationModel.DataTransfer.Clipboard]::GetHistoryItemsAsync()) `
        ([Windows.ApplicationModel.DataTransfer.ClipboardHistoryItemsResult])
    if ($history.Status.ToString() -ne 'Success') {
        throw "Windows clipboard history is unavailable ($($history.Status)). Enable it in Settings > System > Clipboard."
    }
    foreach ($item in $history.Items) {
        if (-not $item.Content.Contains('Text')) { continue }
        $text = Wait-WinRT ($item.Content.GetTextAsync()) ([string])
        if ($text.Length -eq 0) { continue }
        # Match terminal text conventions while retaining all trailing newlines.
        $text = $text.Replace("`r`n", "`n")
        $encoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($text))
        $preview = [regex]::Replace($text, '[\x00-\x1f\x7f-\x9f]', ' ')
        if ($preview.Length -gt 200) { $preview = $preview.Substring(0, 200) }
        [Console]::Write($encoded + "`t" + $preview + "`n")
    }
} catch {
    [Console]::Error.WriteLine('[clipboard-history] ' + $_.Exception.Message)
    exit 1
}
