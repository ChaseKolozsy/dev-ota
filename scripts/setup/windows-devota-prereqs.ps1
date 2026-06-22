param(
    [switch]$SkipWsl,
    [switch]$ConfigureWslPortProxy,
    [int[]]$ForwardPorts = @(8082, 8083),
    [string]$WslDistro = "Ubuntu"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Step {
    param([string]$Message)
    Write-Host ""
    Write-Host "==> $Message"
}

function Test-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-CapabilityByPrefix {
    param([string]$Prefix)
    return Get-WindowsCapability -Online |
        Where-Object { $_.Name -like "$Prefix*" } |
        Select-Object -First 1
}

function Ensure-WindowsCapability {
    param([string]$Prefix)

    $capability = Get-CapabilityByPrefix -Prefix $Prefix
    if (-not $capability) {
        throw "Windows capability not found: $Prefix"
    }

    if ($capability.State -eq "Installed") {
        Write-Host "$($capability.Name) is already installed."
        return
    }

    Write-Host "Installing $($capability.Name)..."
    Add-WindowsCapability -Online -Name $capability.Name | Out-Host
}

function Get-LanIPv4Addresses {
    Get-NetIPAddress -AddressFamily IPv4 |
        Where-Object {
            $_.IPAddress -notlike "127.*" -and
            $_.IPAddress -notlike "169.254.*" -and
            $_.PrefixOrigin -ne "WellKnown"
        } |
        Sort-Object InterfaceAlias, IPAddress
}

function Ensure-FirewallRule {
    param(
        [string]$Name,
        [string]$DisplayName,
        [int]$Port
    )

    $rule = Get-NetFirewallRule -Name $Name -ErrorAction SilentlyContinue
    if ($rule) {
        Write-Host "Firewall rule exists: $DisplayName"
        return
    }

    New-NetFirewallRule `
        -Name $Name `
        -DisplayName $DisplayName `
        -Enabled True `
        -Direction Inbound `
        -Protocol TCP `
        -Action Allow `
        -LocalPort $Port | Out-Host
}

function Ensure-OpenSsh {
    Write-Step "Installing and enabling OpenSSH"
    Ensure-WindowsCapability -Prefix "OpenSSH.Client"
    Ensure-WindowsCapability -Prefix "OpenSSH.Server"

    $service = Get-Service -Name sshd -ErrorAction SilentlyContinue
    if (-not $service) {
        throw "sshd service was not found after OpenSSH Server installation."
    }

    Set-Service -Name sshd -StartupType Automatic
    if ($service.Status -ne "Running") {
        Start-Service sshd
    }

    Ensure-FirewallRule `
        -Name "OpenSSH-Server-In-TCP" `
        -DisplayName "OpenSSH Server (sshd)" `
        -Port 22

    $sshCheck = Test-NetConnection -ComputerName 127.0.0.1 -Port 22 -InformationLevel Quiet
    if (-not $sshCheck) {
        Write-Warning "OpenSSH was configured, but localhost port 22 did not respond yet."
    } else {
        Write-Host "OpenSSH is listening on localhost:22."
    }
}

function Get-WslDistros {
    if (-not (Get-Command wsl.exe -ErrorAction SilentlyContinue)) {
        return @()
    }

    $raw = & wsl.exe -l -q 2>$null
    if ($LASTEXITCODE -ne 0) {
        return @()
    }

    return @($raw | ForEach-Object { ($_ -replace "`0", "").Trim() } | Where-Object { $_ })
}

function Ensure-WslUbuntu {
    if ($SkipWsl) {
        Write-Host "Skipping WSL setup."
        return
    }

    Write-Step "Checking WSL Ubuntu"
    if (-not (Get-Command wsl.exe -ErrorAction SilentlyContinue)) {
        throw "wsl.exe was not found. Install the Windows Subsystem for Linux feature first."
    }

    $distros = Get-WslDistros
    if ($distros -contains $WslDistro) {
        Write-Host "$WslDistro is already installed."
        return
    }

    Write-Host "$WslDistro is not installed. Starting WSL installation..."
    Write-Host "Windows may request a reboot and Ubuntu may ask for a UNIX username on first launch."
    & wsl.exe --install -d $WslDistro
}

function Get-WslIPv4 {
    param([string]$Distro)

    $raw = & wsl.exe -d $Distro -- sh -lc "hostname -I | awk '{print `$1}'" 2>$null
    if ($LASTEXITCODE -ne 0) {
        throw "Could not read WSL IP from distro: $Distro"
    }

    $ip = ($raw | Select-Object -First 1).Trim()
    if (-not $ip) {
        throw "WSL distro did not report an IPv4 address."
    }

    return $ip
}

function Ensure-WslPortProxy {
    if (-not $ConfigureWslPortProxy) {
        return
    }

    Write-Step "Configuring Windows port proxy to WSL"
    $wslIp = Get-WslIPv4 -Distro $WslDistro
    Write-Host "WSL $WslDistro IPv4: $wslIp"

    foreach ($port in $ForwardPorts) {
        Write-Host "Mapping Windows 0.0.0.0:$port to WSL ${wslIp}:$port"
        & netsh interface portproxy delete v4tov4 listenaddress=0.0.0.0 listenport=$port 2>$null | Out-Null
        & netsh interface portproxy add v4tov4 listenaddress=0.0.0.0 listenport=$port connectaddress=$wslIp connectport=$port | Out-Host
        Ensure-FirewallRule `
            -Name "DevOTA-Port-$port" `
            -DisplayName "DevOTA port $port" `
            -Port $port
    }
}

if (-not (Test-Administrator)) {
    throw "Run this script from an Administrator PowerShell session."
}

Write-Step "DevOTA Windows prerequisite setup"
Ensure-OpenSsh
Ensure-WslUbuntu
Ensure-WslPortProxy

Write-Step "Reachable addresses"
$addresses = @(Get-LanIPv4Addresses)
if ($addresses.Count -eq 0) {
    Write-Warning "No LAN IPv4 addresses found."
} else {
    foreach ($address in $addresses) {
        Write-Host "$($address.InterfaceAlias): $($address.IPAddress)"
    }
}

$username = [Environment]::UserName
Write-Host ""
Write-Host "Phone SSH target: $username@<one-of-the-addresses-above>:22"
Write-Host "DevOTA build URL: http://<one-of-the-addresses-above>:8082"
Write-Host "DevOTA Agent URL: ws://<one-of-the-addresses-above>:8083/phone"
Write-Host ""
Write-Host "If you build inside WSL, SSH into Windows first, then run: wsl.exe -d $WslDistro"
