function Write-SqlCpyStep {
<#
.SYNOPSIS
    Writes a numbered, timestamped step header to the screen.

.DESCRIPTION
    Used by orchestration and TUI flow to make progress visible. Output goes to the
    host with a coloured prefix, not to the pipeline.
#>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$Message,
        [int]$StepNumber
    )
    $ts = (Get-Date).ToString('HH:mm:ss')
    $prefix = if ($PSBoundParameters.ContainsKey('StepNumber')) {
        "[{0}] STEP {1:d2} " -f $ts, $StepNumber
    } else {
        "[{0}] STEP     " -f $ts
    }
    Write-Host $prefix -NoNewline -ForegroundColor Cyan
    Write-Host $Message -ForegroundColor White
}

function Write-SqlCpyInfo {
<#
.SYNOPSIS
    Writes an informational line to the screen.
#>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string]$Message)
    $ts = (Get-Date).ToString('HH:mm:ss')
    Write-Host ("[{0}] INFO     {1}" -f $ts, $Message) -ForegroundColor Gray
}

function Write-SqlCpyWarning {
<#
.SYNOPSIS
    Writes a warning line to the screen without raising an error.
#>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string]$Message)
    $ts = (Get-Date).ToString('HH:mm:ss')
    Write-Host ("[{0}] WARN     {1}" -f $ts, $Message) -ForegroundColor Yellow
}

function Write-SqlCpyError {
<#
.SYNOPSIS
    Writes an error line to the screen without throwing.

.DESCRIPTION
    Use this for non-fatal errors that should not end the run. For a fatal error,
    let the exception bubble up to Start-SqlCpyInteractive which will show the
    end-of-run error screen via Show-SqlCpyErrorScreen.
#>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string]$Message)
    $ts = (Get-Date).ToString('HH:mm:ss')
    Write-Host ("[{0}] ERROR    {1}" -f $ts, $Message) -ForegroundColor Red
}

function Show-SqlCpyErrorScreen {
<#
.SYNOPSIS
    Displays an end-of-run error screen for an uncaught exception and offers to copy
    or save the full error.

.DESCRIPTION
    Pretty-prints the exception summary and prompts the user:
      [C] copy the full error text to the clipboard (best-effort via Set-Clipboard)
      [F] write the full error text to a timestamped file in the current directory
      [N] do nothing

    The clipboard path is best-effort: on hosts where Set-Clipboard is not available
    (some remote sessions, non-Windows hosts), it automatically falls back to writing
    a file and reports the path.

.PARAMETER ErrorRecord
    The ErrorRecord from a caught exception (typically $_ from a trap / catch block).

.EXAMPLE
    try { Start-SqlCpyInteractive } catch { Show-SqlCpyErrorScreen -ErrorRecord $_ }
#>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Management.Automation.ErrorRecord]$ErrorRecord
    )

    $fullText = @()
    $fullText += '=== sqlserver-cpy: run ended with an error ==='
    $fullText += "Time       : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
    $fullText += "Message    : $($ErrorRecord.Exception.Message)"
    $fullText += "Category   : $($ErrorRecord.CategoryInfo)"
    $fullText += "Target     : $($ErrorRecord.TargetObject)"
    $fullText += "ScriptLine : $($ErrorRecord.InvocationInfo.PositionMessage)"
    $fullText += ''
    $fullText += '--- Exception chain ---'
    $ex = $ErrorRecord.Exception
    while ($ex) {
        $fullText += "$($ex.GetType().FullName): $($ex.Message)"
        $ex = $ex.InnerException
    }
    $fullText += ''
    $fullText += '--- Script stack trace ---'
    $fullText += ($ErrorRecord.ScriptStackTrace)
    $fullText += ''
    $fullText += '--- .NET stack trace ---'
    $fullText += ($ErrorRecord.Exception.StackTrace)

    $joined = $fullText -join [Environment]::NewLine

    Write-Host ''
    Write-Host ('=' * 72) -ForegroundColor Red
    Write-Host '  sqlserver-cpy: an error ended the run' -ForegroundColor Red
    Write-Host ('=' * 72) -ForegroundColor Red
    Write-Host ''
    Write-Host $ErrorRecord.Exception.Message -ForegroundColor Yellow
    Write-Host ''
    Write-Host 'Do you want to copy the full error message?' -ForegroundColor White
    Write-Host '  [C] Copy to clipboard (falls back to file if unavailable)'
    Write-Host '  [F] Write to a timestamped file in the current directory'
    Write-Host '  [N] No, just exit'
    $choice = Read-Host 'Choice'

    switch -Regex ($choice) {
        '^(?i)c$' {
            if (Get-Command -Name Set-Clipboard -ErrorAction SilentlyContinue) {
                try {
                    Set-Clipboard -Value $joined -ErrorAction Stop
                    Write-Host 'Full error copied to clipboard.' -ForegroundColor Green
                    return
                } catch {
                    Write-Host "Clipboard copy failed: $($_.Exception.Message). Falling back to file." -ForegroundColor Yellow
                }
            } else {
                Write-Host 'Set-Clipboard not available. Falling back to file.' -ForegroundColor Yellow
            }
            $path = Join-Path -Path (Get-Location) -ChildPath ("error_{0}.txt" -f (Get-Date -Format 'yyyyMMdd_HHmmss'))
            Set-Content -LiteralPath $path -Value $joined -Encoding UTF8
            Write-Host "Full error written to: $path" -ForegroundColor Green
        }
        '^(?i)f$' {
            $path = Join-Path -Path (Get-Location) -ChildPath ("error_{0}.txt" -f (Get-Date -Format 'yyyyMMdd_HHmmss'))
            Set-Content -LiteralPath $path -Value $joined -Encoding UTF8
            Write-Host "Full error written to: $path" -ForegroundColor Green
        }
        default {
            Write-Host 'No error text saved.' -ForegroundColor Gray
        }
    }
}
