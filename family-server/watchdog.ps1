# Nivvi family-server watchdog: restart Docker + Cloudflare if the PC comes back online.
# Install: PowerShell as Administrator, then:
#   powershell -ExecutionPolicy Bypass -File .\watchdog.ps1 -Install
param(
    [switch]$Install
)

$health = "http://127.0.0.1:8000/health"
$log = Join-Path $env:LOCALAPPDATA "Nivvi-watchdog.log"

function Write-Log($message) {
    $line = "{0} {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $message
    Add-Content -Path $log -Value $line
}

if ($Install) {
    $here = $PSCommandPath
    $action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$here`""
    $trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) -RepetitionInterval (New-TimeSpan -Minutes 2) -RepetitionDuration (New-TimeSpan -Days 365)
    Register-ScheduledTask -TaskName "NivviFamilyWatchdog" -Action $action -Trigger $trigger -RunLevel Highest -Force | Out-Null
    Write-Host "Installed. Checks every 2 minutes. Log: $log"
    exit 0
}

try {
    $ok = $false
    try {
        $body = (Invoke-WebRequest -Uri $health -UseBasicParsing -TimeoutSec 8).Content
        if ($body -match '"status"\s*:\s*"ok"') { $ok = $true }
    } catch { $ok = $false }

    if ($ok) { exit 0 }

    Write-Log "Health failed — restarting Docker family container and Cloudflare"
    docker start nivvi-family 2>$null
    docker compose -f (Join-Path $PSScriptRoot "docker-compose.yml") up -d 2>$null
    Restart-Service Cloudflared -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 8
    try {
        $body = (Invoke-WebRequest -Uri $health -UseBasicParsing -TimeoutSec 8).Content
        Write-Log "After restart: $body"
    } catch {
        Write-Log "Still down after restart"
    }
} catch {
    Write-Log $_.Exception.Message
}
