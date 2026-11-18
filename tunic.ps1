# Tunic Linux Installer for Windows
# Copyright (c) Michael Slattery under GPLv3 with NO warranty.
# For more info see  https://www.gnu.org/licenses/gpl-3.0.html#section15

# Automated/assisted install of a Linux ISO from Windows 10/11 (UEFI)

$global:NoReboot = $false
$global:CliIsoPath = $null
$global:ExeDir = $null
$op = $null

for ($i = 0; $i -lt $args.Count; $i++) {
    $arg = $args[$i]
    if ($arg -eq 'noop') { exit 0 }
    elseif ($arg -eq '-NoReboot' -or $arg -eq '--no-reboot') { $global:NoReboot = $true }
    elseif ($arg -eq '-ExeDir' -and ($i + 1) -lt $args.Count) {
        $i++
        $global:ExeDir = $args[$i]
    }
    elseif (-not $op -and $arg -match '\.iso$' -and (Test-Path -LiteralPath $arg)) {
        $global:CliIsoPath = (Resolve-Path -LiteralPath $arg).Path
    }
    elseif (-not $op) { $op = $arg }
    elseif ($op -eq 'inspect' -and -not $global:CliIsoPath) { $global:CliIsoPath = $arg }
}

$global:ProgressPreference = 'SilentlyContinue'

# Ensure modern TLS for HTTPS downloads on Windows 10/11 PowerShell 5.1
try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor 3072
} catch {
    try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}
}

$global:shim_url = 'https://github.com/pop-os/iso/blob/master/data/efi/shimx64.efi.signed?raw=true'

$global:letter = $env:HOMEDRIVE[0]
$global:root_dir = "${letter}:"
$global:tunic_dir = "${env:ALLUSERSPROFILE}\tunic"
$global:STAGING_LABEL = 'TUNIC_BOOT'
$global:STAGING_MARKER = '.tunic-fedora-boot'

$global:MIN_DISK_GB = 15

$DUALBOOT = 1
$FULLBOOT = 2
$CUSTOMBOOT = 3

$web = New-Object System.Net.WebClient
$global:isoMetaCache = @{}

function Test-IsAdmin() {
    return ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-FreeDriveLetter() {
    $used = @((Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue).Name)
    foreach ($code in 90..68) {
        # Z down to D
        $c = [char]$code
        if ($used -notcontains "$c" -and -not (Test-Path "${c}:\")) {
            return "${c}:"
        }
    }
    throw "No free drive letters available."
}

function Format-BytesGB([long]$bytes) {
    return [math]::Round($bytes / 1GB, 2)
}

function Get-LocalIsoSearchDirs() {
    $dirs = @()
    if ($global:ExeDir) {
        $dirs += $global:ExeDir
        $dirs += (Join-Path $global:ExeDir 'iso')
    }
    if ($PSScriptRoot) {
        $dirs += $PSScriptRoot
        $dirs += (Join-Path $PSScriptRoot 'iso')
        $parent = Split-Path $PSScriptRoot -Parent
        if ($parent) {
            $dirs += $parent
            $dirs += (Join-Path $parent 'iso')
        }
    }
    $cwd = (Get-Location).Path
    if ($cwd) {
        $dirs += $cwd
        $dirs += (Join-Path $cwd 'iso')
    }
    if ($HOME) {
        $dirs += (Join-Path $HOME 'Downloads')
    }

    $unique = @()
    $seen = @{}
    foreach ($d in $dirs) {
        if ($d -and (Test-Path -LiteralPath $d)) {
            $resolved = (Resolve-Path -LiteralPath $d).Path
            $key = $resolved.ToLowerInvariant()
            if (-not $seen.ContainsKey($key)) {
                $seen[$key] = $true
                $unique += $resolved
            }
        }
    }
    return $unique
}

function Get-LocalIsoEntries() {
    $entries = @()
    $seenFiles = @{}
    $files = @()

    foreach ($dir in (Get-LocalIsoSearchDirs)) {
        $found = Get-ChildItem -LiteralPath $dir -Filter '*.iso' -File -ErrorAction SilentlyContinue
        foreach ($f in $found) {
            $key = $f.FullName.ToLowerInvariant()
            if (-not $seenFiles.ContainsKey($key)) {
                $seenFiles[$key] = $true
                $files += $f
            }
        }
    }

    # Prioritize Fedora ISOs first, then newest files
    $files = $files | Sort-Object `
        @{ Expression = { if ($_.Name -match 'fedora') { 0 } else { 1 } } }, `
        @{ Expression = { $_.LastWriteTime }; Descending = $true }

    foreach ($f in $files) {
        $gb = Format-BytesGB $f.Length
        $entries += @{
            name      = "[Local] $($f.Name) ($gb GB)"
            url       = $f.FullName
            path      = $f.FullName
            local     = $true
            sizeBytes = [long]$f.Length
        }
    }
    return $entries
}

function Add-OrSelectLocalIso([string]$isoPath) {
    if (-not (Test-Path -LiteralPath $isoPath)) { return $false }
    $resolved = (Resolve-Path -LiteralPath $isoPath).Path
    $item = Get-Item -LiteralPath $resolved
    $gb = Format-BytesGB $item.Length

    for ($i = 0; $i -lt $global:distros.Count; $i++) {
        if ($global:distros[$i].url -eq $resolved) {
            if ($global:distroName) { $global:distroName.SelectedIndex = $i }
            return $true
        }
    }

    $newEntry = @{
        name      = "[Local] $($item.Name) ($gb GB)"
        url       = $resolved
        path      = $resolved
        local     = $true
        sizeBytes = [long]$item.Length
    }
    $global:distros = @($newEntry) + @($global:distros)
    if ($global:distroName) {
        $global:distroName.Items.Clear()
        $global:distroName.Items.AddRange(($global:distros | ForEach-Object { $_.name }))
        $global:distroName.SelectedIndex = 0
    }
    return $true
}

function Inspect-LinuxIso([string]$isoPath) {
    if ($global:isoMetaCache.ContainsKey($isoPath)) {
        return $global:isoMetaCache[$isoPath]
    }
    if (-not (Test-Path -LiteralPath $isoPath)) {
        throw "ISO file not found: $isoPath"
    }

    $isoFile = Get-Item -LiteralPath $isoPath
    $alreadyMounted = $false
    $existingImg = Get-DiskImage -ImagePath $isoPath -ErrorAction SilentlyContinue
    if ($existingImg -and $existingImg.Attached) {
        $alreadyMounted = $true
        $img = $existingImg
    } else {
        $img = Mount-DiskImage -ImagePath $isoPath -StorageType ISO -PassThru -ErrorAction Stop
    }

    try {
        # Wait briefly for volume letter assignment if Windows just mounted it
        $vol = $null
        for ($attempt = 0; $attempt -lt 10; $attempt++) {
            $vol = $img | Get-Volume -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($vol -and $vol.DriveLetter) { break }
            Start-Sleep -Milliseconds 250
        }
        if (-not $vol -or -not $vol.DriveLetter) {
            throw "Unable to resolve drive letter for mounted ISO: $isoPath"
        }

        $drive = "$($vol.DriveLetter):"
        $hasLiveSquash = (Test-Path -LiteralPath "$drive\LiveOS\squashfs.img") -or
                         (Test-Path -LiteralPath "$drive\LiveOS\rootfs.img") -or
                         [bool](Get-ChildItem -LiteralPath "$drive\" -Recurse -File -Filter '*.squashfs' -ErrorAction SilentlyContinue | Select-Object -First 1)
        $hasInstallImg = (Test-Path -LiteralPath "$drive\images\install.img") -or
                         (Test-Path -LiteralPath "$drive\LiveOS\install.img")
        $hasCasper = Test-Path -LiteralPath "$drive\casper\vmlinuz"
        $hasBootx64 = Test-Path -LiteralPath "$drive\EFI\BOOT\BOOTX64.EFI"
        $hasGrubx64 = (Test-Path -LiteralPath "$drive\EFI\BOOT\grubx64.efi") -or (Test-Path -LiteralPath "$drive\EFI\fedora\grubx64.efi")
        $hasRepo = (Test-Path -LiteralPath "$drive\repodata") -or (Test-Path -LiteralPath "$drive\Packages")

        $linuxCmd = 'linux'
        $initrdCmd = 'initrd'
        $kernelPath = $null
        $initrdPath = $null
        $grubBootArgs = ''

        # Parse ISO's own GRUB config(s) to discover exact kernel/initrd paths & boot style (supports Kiwi + Lorax layouts)
        $cfgCandidates = @(
            "$drive\boot\grub2\grub.cfg",
            "$drive\EFI\BOOT\grub.cfg",
            "$drive\EFI\fedora\grub.cfg",
            "$drive\boot\grub\grub.cfg"
        )
        foreach ($cfgPath in $cfgCandidates) {
            if (-not (Test-Path -LiteralPath $cfgPath)) { continue }
            $cfgText = Get-Content -LiteralPath $cfgPath -Raw -ErrorAction SilentlyContinue
            if (-not $cfgText) { continue }
            if ($cfgText -match '(?m)^\s*(linuxefi|linux)\s+(\S+)(.*)$') {
                $linuxCmd = $matches[1]
                $candKernel = $matches[2].Trim()
                $grubBootArgs = $matches[3].Trim()
                $candKernelWin = Join-Path "$drive\" ($candKernel.TrimStart('/').Replace('/', '\'))
                if (Test-Path -LiteralPath $candKernelWin) {
                    $kernelPath = $candKernel
                }
            }
            if ($cfgText -match '(?m)^\s*(initrdefi|initrd)\s+(\S+)') {
                $initrdCmd = $matches[1]
                $candInitrd = $matches[2].Trim()
                $candInitrdWin = Join-Path "$drive\" ($candInitrd.TrimStart('/').Replace('/', '\'))
                if (Test-Path -LiteralPath $candInitrdWin) {
                    $initrdPath = $candInitrd
                }
            }
            if ($kernelPath -and $initrdPath) { break }
        }

        # Fallback: probe known paths or search the mounted ISO for kernel & initrd
        if (-not $kernelPath) {
            foreach ($rel in @('\images\pxeboot\vmlinuz', '\boot\x86_64\loader\linux', '\isolinux\vmlinuz', '\boot\vmlinuz', '\vmlinuz')) {
                if (Test-Path -LiteralPath "$drive$rel") {
                    $kernelPath = $rel.Replace('\', '/')
                    break
                }
            }
            if (-not $kernelPath) {
                $kFile = Get-ChildItem -LiteralPath "$drive\" -Recurse -File -Include 'vmlinuz*','linux' -ErrorAction SilentlyContinue |
                    Where-Object { $_.FullName -notmatch '\\casper\\' } | Select-Object -First 1
                if ($kFile) {
                    $kernelPath = '/' + $kFile.FullName.Substring($drive.Length).TrimStart('\').Replace('\', '/')
                }
            }
        }

        if (-not $initrdPath) {
            foreach ($rel in @('\images\pxeboot\initrd.img', '\boot\x86_64\loader\initrd', '\isolinux\initrd.img', '\boot\initrd.img', '\initrd.img', '\boot\initramfs.img')) {
                if (Test-Path -LiteralPath "$drive$rel") {
                    $initrdPath = $rel.Replace('\', '/')
                    break
                }
            }
            if (-not $initrdPath) {
                $iFile = Get-ChildItem -LiteralPath "$drive\" -Recurse -File -Include 'initrd*','initramfs*' -ErrorAction SilentlyContinue |
                    Where-Object { $_.FullName -notmatch '\\casper\\' } | Select-Object -First 1
                if ($iFile) {
                    $initrdPath = '/' + $iFile.FullName.Substring($drive.Length).TrimStart('\').Replace('\', '/')
                }
            }
        }

        $family = 'unknown'
        if ($hasCasper) {
            $family = 'casper'
            $kernelPath = '/casper/vmlinuz'
            if (Test-Path -LiteralPath "$drive\casper\initrd.lz") {
                $initrdPath = '/casper/initrd.lz'
            } else {
                $initrdPath = '/casper/initrd'
            }
        } elseif ($kernelPath -and $initrdPath) {
            $isLiveIso = $hasLiveSquash -or ($grubBootArgs -match 'rd\.live\.image|root=live:') -or ($vol.FileSystemLabel -match 'Live|WS-Live|KDE')
            if ($isLiveIso) {
                $family = 'fedora-live'
            } elseif ($hasInstallImg -or ($grubBootArgs -match 'inst\.stage2') -or ($vol.FileSystemLabel -match 'Fedora') -or (Test-Path -LiteralPath "$drive\.discinfo") -or (Test-Path -LiteralPath "$drive\.treeinfo")) {
                $family = 'fedora-installer'
            }
        }

        $topDirs = @((Get-ChildItem -LiteralPath "$drive\" -Force -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name)) -join ', '

        $meta = @{
            isoPath    = $isoPath
            label      = $vol.FileSystemLabel
            sizeBytes  = [long]$isoFile.Length
            family     = $family
            kernelPath = $kernelPath
            initrdPath = $initrdPath
            linuxCmd   = $linuxCmd
            initrdCmd  = $initrdCmd
            hasEfiShim = ($hasBootx64 -and $hasGrubx64)
            hasRepo    = $hasRepo
            topDirs    = $topDirs
        }
        $global:isoMetaCache[$isoPath] = $meta
        return $meta
    } finally {
        if (-not $alreadyMounted) {
            Dismount-DiskImage -ImagePath $isoPath -ErrorAction SilentlyContinue | Out-Null
        }
    }
}

function Get-StagingBytesForIso([long]$isoSizeBytes) {
    # ISO contents + 512 MB buffer for FAT32 overhead & config files, aligned to 1 MB
    $raw = $isoSizeBytes + 512MB
    $mb = [math]::Ceiling($raw / 1MB)
    return [long]$mb * 1MB
}

function Get-MinLinuxGBForSelectedDistro() {
    $selected = Get-SelectedDistro
    if (-not $selected) { return 20 }
    if ($selected.local -and (Test-Path -LiteralPath $selected.url)) {
        $stagingGB = [math]::Ceiling((Get-StagingBytesForIso $selected.sizeBytes) / 1GB)
        try {
            $meta = Inspect-LinuxIso $selected.url
            if ($meta.family -like 'fedora*') {
                return [math]::Max(20, $stagingGB + 15)
            }
        } catch {}
    } elseif ($selected.name -match 'Fedora') {
        return 20
    }
    return 15
}

function Get-SelectedDistro() {
    if ($global:distroName -and $global:distroName.SelectedIndex -ge 0 -and $global:distroName.SelectedIndex -lt $global:distros.Count) {
        return $global:distros[$global:distroName.SelectedIndex]
    }
    if ($global:distros -and $global:distros.Count -gt 0) {
        return $global:distros[0]
    }
    return $null
}

function Refresh-DistroList() {
    $localIsos = @(Get-LocalIsoEntries)
    $configured = @(. "$PSScriptRoot\files\distros.ps1")
    $global:distros = @($localIsos) + @($configured)

    if ($global:CliIsoPath) {
        Add-OrSelectLocalIso $global:CliIsoPath | Out-Null
    }

    if ($global:distroName) {
        $global:distroName.Items.Clear()
        $global:distroName.Items.AddRange(($global:distros | ForEach-Object { $_.name }))
        if ($global:distroName.Items.Count -gt 0) {
            $global:distroName.SelectedIndex = 0
        }
        Update-DistroSelectionUi
    }
}

function Update-DistroSelectionUi() {
    $selected = Get-SelectedDistro
    if (-not $selected) { return }

    $isFedoraLive = $false
    $infoText = ""

    if ($selected.local -and (Test-Path -LiteralPath $selected.url)) {
        try {
            $meta = Inspect-LinuxIso $selected.url
            $gb = Format-BytesGB $meta.sizeBytes
            $stagingGB = Format-BytesGB (Get-StagingBytesForIso $meta.sizeBytes)
            $shimMsg = if ($meta.hasEfiShim) { "Secure Boot shim found" } else { "No EFI shim in ISO" }

            switch ($meta.family) {
                'fedora-live' {
                    $isFedoraLive = $true
                    $infoText = "Detected: Fedora Live ISO ($gb GB, label '$($meta.label)') | $shimMsg | Staging: ~$stagingGB GB FAT32"
                }
                'fedora-installer' {
                    $infoText = "Detected: Fedora Installer/Netinst ISO ($gb GB, label '$($meta.label)') | $shimMsg | Staging: ~$stagingGB GB FAT32"
                }
                'casper' {
                    $infoText = "Detected: Ubuntu/Mint Casper ISO ($gb GB)"
                }
                default {
                    $infoText = "Warning: Unrecognized ISO layout ($gb GB). Fedora Live/Server or Ubuntu/Mint expected."
                }
            }
        } catch {
            $infoText = "Selected local ISO: $($selected.url) (inspect failed: $($_.Exception.Message))"
        }
    } else {
        if ($selected.name -match 'Fedora') {
            $isFedoraLive = $true
            $infoText = "Will download $($selected.name) to Downloads and stage to FAT32."
        } else {
            $infoText = "Will download $($selected.name) to Downloads."
        }
    }

    if ($global:isoInfoLabel) {
        $global:isoInfoLabel.Text = $infoText
    }

    # Fedora Live ISOs reject inst.ks and create user accounts interactively inside Fedora
    if ($global:idGroup -and $global:idNoteLabel) {
        $needCredentials = -not $isFedoraLive
        $global:username.Enabled = $needCredentials
        $global:password.Enabled = $needCredentials
        $global:password2.Enabled = $needCredentials
        $global:fullName.Enabled = $needCredentials
        $global:hostname.Enabled = $needCredentials
        if ($isFedoraLive) {
            $global:idNoteLabel.Text = "Fedora Live ISOs create your user account inside Fedora after reboot (fields disabled)."
            $global:idNoteLabel.Visible = $true
        } else {
            $global:idNoteLabel.Text = ""
            $global:idNoteLabel.Visible = $false
        }
    }
}

# Do very basic initialization
function initData() {
    if ($PSScriptRoot) {
        Set-Location -Path $PSScriptRoot
    }

    if (-not (Test-Path -LiteralPath "$global:tunic_dir")) {
        New-Item -ItemType Directory -Path "$global:tunic_dir" -Force | Out-Null
    }

    Refresh-DistroList

    # Safe Windows 10/11 user account detection (supports Local, Microsoft Account, and Entra ID)
    $rawUser = $env:USERNAME
    $fullName = $rawUser
    try {
        $cimUser = Get-CimInstance -ClassName Win32_UserAccount -Filter "LocalAccount=True" -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -eq $rawUser } | Select-Object -First 1
        if ($cimUser -and $cimUser.FullName) {
            $fullName = $cimUser.FullName
        }
    } catch {}

    $safeUnixUser = ($rawUser.ToLowerInvariant() -replace '[^a-z0-9_-]', '')
    if (-not $safeUnixUser -or $safeUnixUser -match '^[0-9-]') {
        $safeUnixUser = 'user'
    }

    $selected = Get-SelectedDistro
    $global:data = @{
        installType = $DUALBOOT
        fullname    = $fullName
        username    = $safeUnixUser
        hostname    = $env:COMPUTERNAME.ToLowerInvariant()
        iso_url     = if ($selected) { $selected.url } else { '' }
    }
}

# Get the name part of an URL or path
function getUrlFile($url) {
    if ($url -and (Test-Path -LiteralPath $url)) {
        return [System.IO.Path]::GetFileName($url)
    }
    return $url -replace '^.*/', '' -replace '[?#].*$', ''
}

# Get the path on the disk to the file
function getUrlFilepath($url) {
    if ($url -and (Test-Path -LiteralPath $url)) {
        return (Resolve-Path -LiteralPath $url).Path
    }
    $file = getUrlFile $url
    $dir = Join-Path $HOME 'Downloads'
    if (-not (Test-Path -LiteralPath "$dir")) {
        New-Item -ItemType Directory -Path "$dir" -Force | Out-Null
    }
    return (Join-Path $dir $file)
}

# Convert Windows path to grub path.
function getGrubPath($filename) {
    $filename -replace '^.*:', '' -replace '\\', '/'
}

# Disable swap, hibernate, restore, error reports
function disableSwap() {
    Write-Host "Disabling swap..."

    powercfg.exe /h off | Out-Null
    REG ADD "HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\Power" /V HiberbootEnabled /T REG_DWORD /D 0 /F | Out-Null

    try {
        $computersys = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop
        if ($computersys.AutomaticManagedPagefile) {
            Set-CimInstance -InputObject $computersys -Property @{ AutomaticManagedPagefile = $false } -ErrorAction Stop
        }
        $pagefiles = Get-CimInstance -ClassName Win32_PageFileSetting -ErrorAction SilentlyContinue
        if ($pagefiles) {
            $pagefiles | Remove-CimInstance -ErrorAction SilentlyContinue
        }
        Set-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management' -Name 'PagingFiles' -Value ([string[]]@()) -Type MultiString -ErrorAction Stop
    } catch {
        Write-Host "Pagefile update note: $($_.Exception.Message)"
    }

    try { Disable-WindowsErrorReporting -ErrorAction SilentlyContinue | Out-Null } catch {}
    try { Disable-ComputerRestore -Drive "${global:root_dir}" -ErrorAction SilentlyContinue } catch {}

    Write-Host "Swap disabled."
}

function enableSwap() {
    Write-Host "Re-enabling Swap"

    try { Enable-ComputerRestore -Drive "${global:root_dir}" -ErrorAction SilentlyContinue } catch {}
    try { Enable-WindowsErrorReporting -ErrorAction SilentlyContinue | Out-Null } catch {}

    try {
        Set-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management' -Name 'PagingFiles' -Value ([string[]]@('?:\pagefile.sys')) -Type MultiString -ErrorAction SilentlyContinue
        $computersys = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop
        Set-CimInstance -InputObject $computersys -Property @{ AutomaticManagedPagefile = $true } -ErrorAction Stop
    } catch {
        Write-Host "Re-enable pagefile warning: $($_.Exception.Message)"
    }

    powercfg.exe /h on | Out-Null
}

function clean() {
    $regkey = 'registry::HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\VolumeCaches'
    Get-ChildItem -Path $regkey | New-ItemProperty -Name 'StateFlags0112' -PropertyType DWORD -Value 2 -Force | Out-Null
    Start-Process cleanmgr -ArgumentList '/sagerun:112' -Wait
}

function Invoke-DisableHibernation() {
    powercfg.exe /h off | Out-Null
    REG ADD "HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\Power" /V HiberbootEnabled /T REG_DWORD /D 0 /F | Out-Null
}

function Invoke-AsyncVolumeOptimize([string]$driveLetter) {
    $origTitle = if ($global:Form) { $global:Form.Text } else { "Tunic" }
    $job = Start-Job -ScriptBlock {
        param($dl)
        & defrag.exe "${dl}:" /X | Out-Null
        Optimize-Volume -DriveLetter $dl -Defrag -ErrorAction SilentlyContinue
    } -ArgumentList $driveLetter

    try {
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        while ($job.State -eq 'Running' -or $job.State -eq 'NotStarted') {
            $secs = [int]$sw.Elapsed.TotalSeconds
            if ($global:Form) {
                $global:Form.Text = "Tunic - Optimizing ${driveLetter}:... (${secs}s)"
                if ($global:isoInfoLabel -and $global:main.Visible) {
                    $global:isoInfoLabel.Text = "Optimizing ${driveLetter}: to free shrinkable space (${secs}s)..."
                }
                [System.Windows.Forms.Application]::DoEvents()
            }
            Start-Sleep -Milliseconds 200
        }
        Receive-Job -Job $job -ErrorAction SilentlyContinue | Out-Null
    } finally {
        Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
        if ($global:Form) {
            $global:Form.Text = $origTitle
            [System.Windows.Forms.Application]::DoEvents()
        }
    }
}

function defrag() {
    Invoke-DisableHibernation
    try {
        Invoke-AsyncVolumeOptimize $global:letter
    } catch {
        Write-Host "Optimize-Volume note: $($_.Exception.Message)"
    }
}

function Try-ReclaimShrinkSpace([long]$neededBytes) {
    # Step 1: Turning off hibernation deletes hiberfil.sys immediately without a slow defrag
    Invoke-DisableHibernation
    calcPartition
    if ($global:maxAvailable -ge $neededBytes) { return $true }

    # Step 2: Run non-blocking volume defrag/optimize
    Invoke-AsyncVolumeOptimize $global:letter
    calcPartition
    if ($global:maxAvailable -ge $neededBytes) { return $true }

    if (yes("Hibernation was disabled and ${global:letter}: was optimized, but Windows still reports only $([math]::Floor($global:maxAvailable / 1GB)) GB shrinkable.`n`nThis is usually caused by System Restore shadow copies or the Windows pagefile (pagefile.sys) near the end of ${global:letter}:.`n`nWould you like Tunic to delete Windows restore shadow copies on ${global:letter}: now?")) {
        & vssadmin.exe delete shadows /for="${global:letter}:" /all /quiet | Out-Null
        calcPartition
        if ($global:maxAvailable -ge $neededBytes) { return $true }
        Invoke-AsyncVolumeOptimize $global:letter
        calcPartition
        if ($global:maxAvailable -ge $neededBytes) { return $true }
    }

    if (yes("Still only $([math]::Floor($global:maxAvailable / 1GB)) GB shrinkable on ${global:letter}:.`n`nDisable Windows Swap (pagefile.sys) and reboot so Windows releases locked space at the end of ${global:letter}:?")) {
        disableSwap
        Restart-Computer -Force
    }
    return $false
}

function ternary($expr, $ontrue, $onfalse) {
    if ($expr) { return $ontrue } else { return $onfalse }
}

function die($msg) {
    Write-Host $msg
    [System.Windows.Forms.MessageBox]::Show($msg, "Tunic") | Out-Null
    if ($global:form) { $global:form.Close() }
}

function say($msg) {
    Write-Host $msg
    [System.Windows.Forms.MessageBox]::Show($msg, "Tunic") | Out-Null
}

function yes($q) {
    $buttons = [System.Windows.Forms.MessageBoxButtons]::YesNo
    return [System.Windows.Forms.MessageBox]::Show($q, "Tunic", $buttons) -eq "Yes"
}

function openUrl($url) {
    Start-Process $url
}

function Test-PendingRebootNative() {
    if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') {
        return $true
    }
    if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired') {
        return $true
    }
    $compNameActive = (Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\ComputerName\ActiveComputerName' -ErrorAction SilentlyContinue).ComputerName
    $compNamePending = (Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\ComputerName\ComputerName' -ErrorAction SilentlyContinue).ComputerName
    if ($compNameActive -and $compNamePending -and ($compNameActive -ne $compNamePending)) {
        return $true
    }
    return $false
}

function Get-BitLockerStatus([string]$driveLetter) {
    $result = @{ Enabled = $false; RecoveryPassword = $null }
    try {
        $blInfo = Get-BitLockerVolume -MountPoint "${driveLetter}:" -ErrorAction Stop
        if ($blInfo -and $blInfo.ProtectionStatus -eq 'On') {
            $result.Enabled = $true
            $rp = $blInfo.KeyProtector | Where-Object { $_.KeyProtectorType -eq 'RecoveryPassword' } | Select-Object -First 1
            if ($rp) { $result.RecoveryPassword = $rp.RecoveryPassword }
        }
    } catch {
        # Fallback for environments without BitLocker PS module
        try {
            $bdeOut = (& manage-bde.exe -status "${driveLetter}:" 2>$null) -join "`n"
            if ($bdeOut -match 'Protection Status:\s*Protection On') {
                $result.Enabled = $true
            }
        } catch {}
    }
    return $result
}

function Suspend-BitLockerIfNeeded([string]$driveLetter) {
    $bl = Get-BitLockerStatus $driveLetter
    if ($bl.Enabled) {
        if ($bl.RecoveryPassword) {
            Set-Content -Path "${global:tunic_dir}\bitlocker-recovery.txt" -Value "Drive ${driveLetter}: Recovery Password: $($bl.RecoveryPassword)"
        }
        try {
            Suspend-BitLocker -MountPoint "${driveLetter}:" -RebootCount 1 -ErrorAction Stop | Out-Null
        } catch {
            & manage-bde.exe -protectors -disable "${driveLetter}:" -RebootCount 1 | Out-Null
        }
    }
}

# Returns if Linux can be installed, or closes form on fatal failure.
function checks() {
    if (-not (Test-IsAdmin)) {
        if (yes('Tunic requires Administrator privileges. Relaunch as Administrator now?')) {
            $scriptPath = $PSCommandPath
            if (-not $scriptPath) { $scriptPath = Join-Path (Get-Location).Path 'tunic.ps1' }
            $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$scriptPath`"")
            if ($global:NoReboot) { $argList += '-NoReboot' }
            if ($global:ExeDir) { $argList += @('-ExeDir', "`"$($global:ExeDir)`"") }
            if ($global:CliIsoPath) { $argList += "`"$global:CliIsoPath`"" }
            Start-Process powershell.exe -ArgumentList $argList -Verb RunAs
        }
        if ($global:form) { $global:form.Close() }
        return
    }

    if (-not [System.Environment]::Is64BitOperatingSystem) {
        die('Only 64 bit systems supported')
        return
    }

    $cs = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction SilentlyContinue
    if ($cs -and $cs.TotalPhysicalMemory -lt 3.5GB) {
        die('4GB or more RAM required.')
        return
    }

    if ([IntPtr]::Size -eq 4) {
        die('Tunic cannot be run from 32 bit PowerShell')
        return
    }

    $osversion = [System.Environment]::OSVersion.Version
    if ($osversion.Major -lt 10) {
        die('Windows 10 or Windows 11 required')
        return
    }

    if ($PSVersionTable.PSVersion.Major -lt 3) {
        die('PowerShell 3 or above required')
        return
    }

    $bat = Get-CimInstance -ClassName Win32_Battery -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($bat -and $bat.BatteryStatus -eq 1) {
        say('Warning: Your laptop appears to be running on battery. Plug in AC power before partitioning and rebooting.')
    }

    if (Test-PendingRebootNative) {
        if (yes('A Windows reboot is pending (e.g. Windows Update). You should reboot before running Tunic. Reboot now?')) {
            Restart-Computer
            return
        }
    }

    try {
        if ((New-Object -ComObject 'Microsoft.Update.Installer').IsBusy) {
            say('A Windows Update is currently in progress. You should quit and try again after it finishes.')
        }
    } catch {}

    $bl = Get-BitLockerStatus $global:letter
    if ($bl.Enabled) {
        $msg = "BitLocker / Device Encryption is ON for ${global:letter}:.`n`nTunic can temporarily suspend BitLocker for 1 reboot while resizing and booting Linux (it auto-resumes when Windows boots next)."
        if ($bl.RecoveryPassword) {
            Set-Content -Path "${global:tunic_dir}\bitlocker-recovery.txt" -Value "Drive ${global:letter}: Recovery Password: $($bl.RecoveryPassword)"
            $msg += "`n`nYour BitLocker Recovery Key (also saved to ${global:tunic_dir}\bitlocker-recovery.txt):`n$($bl.RecoveryPassword)"
        }
        say($msg)
    }

    $partc = Get-Partition -DriveLetter $global:letter
    if ((Get-Disk -Number $partc.DiskNumber).PartitionStyle -eq 'MBR') {
        mbr2gpt /validate /allowfullos > $null 2> $null
        if ($?) {
            if (yes('UEFI/GPT is required, but this disk is MBR. Open guide on how to convert MBR to GPT without data loss?')) {
                openUrl('https://learn.microsoft.com/en-us/windows/deployment/mbr-to-gpt')
            }
            $global:form.Close()
        } else {
            die('UEFI/GPT is required, and MBR2GPT validation failed on this system.')
        }
        return
    }
}

function downloadIso() {
    $iso_path = getUrlFilepath $global:data.iso_url
    $iso_file = getUrlFile $global:data.iso_url
    if (-not (Test-Path -LiteralPath "$iso_path")) {
        $ciso = "Z:\Downloads\$iso_file"
        if (Test-Path -LiteralPath "$ciso") {
            Write-Host 'Cached.'
            Copy-Item "$ciso" "$iso_path"
        } else {
            try {
                $web.DownloadFile($global:data.iso_url, "$iso_path")
            } catch {
                Write-Host "Error downloading $($global:data.iso_url) to $iso_path"
                Write-Host $_
                Remove-Item "$iso_path" -ErrorAction SilentlyContinue
                throw "Download failed"
            }
        }
    }
    return $iso_path
}

function guiDownloadIso() {
    $iso_path = getUrlFilepath $global:data.iso_url
    $iso_file = getUrlFile $global:data.iso_url
    if (Test-Path -LiteralPath "$iso_path") {
        $global:dlStatus.Text = "Using local ISO: $iso_file"
        [System.Windows.Forms.Application]::DoEvents()
        return $iso_path
    }

    $ciso = "Z:\Downloads\$iso_file"
    if (Test-Path -LiteralPath "$ciso") {
        Copy-Item "$ciso" "$iso_path"
        return $iso_path
    }

    Import-Module BitsTransfer
    $url = $global:data.iso_url
    $tempPath = "${iso_path}.part"
    Remove-Item -LiteralPath $tempPath -ErrorAction SilentlyContinue

    $bits = Start-BitsTransfer -DisplayName $iso_file -Source $url -Destination $tempPath -Asynchronous
    try {
        $global:dlStatus.Text = 'Connecting...'
        while ($bits.JobState -eq "Connecting") {
            Start-Sleep -Seconds 1
            [System.Windows.Forms.Application]::DoEvents()
        }
        while ($bits.JobState -eq "Transferring" -or $bits.JobState -eq "TransientError") {
            if ($bits.JobState -eq "TransientError") {
                Resume-BitsTransfer -BitsJob $bits -Asynchronous | Out-Null
            }
            if ($bits.BytesTotal -gt 0) {
                $pct = [int](($bits.BytesTransferred * 100) / $bits.BytesTotal)
                $global:dlStatus.Text = "Downloading $pct% complete"
            } else {
                $global:dlStatus.Text = 'Transferring...'
            }
            Start-Sleep -Seconds 1
            [System.Windows.Forms.Application]::DoEvents()
        }
        if ($bits.JobState -eq "Error") {
            throw "BITS transfer failed: $($bits.ErrorDescription)"
        }
        Complete-BitsTransfer -BitsJob $bits
        Move-Item -LiteralPath $tempPath -Destination $iso_path -Force
    } catch {
        Write-Host "Error downloading $url to $iso_path"
        Write-Host $_
        if ($bits) { Remove-BitsTransfer -BitsJob $bits -ErrorAction SilentlyContinue }
        Remove-Item -LiteralPath $tempPath -ErrorAction SilentlyContinue
        throw "Download failed: $($_.Exception.Message)"
    }
    return $iso_path
}

# Returns the Linux timezone converted from Windows.
function getLinuxTimeZone() {
    $wtz = Get-TimeZone
    $tzName = $wtz.Id
    $ltz = $null

    try {
        $url = 'https://raw.githubusercontent.com/unicode-org/cldr/master/common/supplemental/windowsZones.xml'
        $file = Join-Path $env:TEMP 'windowsZones.xml'
        if (-not (Test-Path -LiteralPath $file -ErrorAction SilentlyContinue)) {
            $web.DownloadFile($url, $file)
        }
        [xml]$xml = Get-Content -LiteralPath $file
        $nodes = $xml.supplementalData.windowsZones.mapTimezones.childNodes
        $territory = (New-Object System.Globalization.RegionInfo (Get-Culture).Name).TwoLetterISORegionName

        $zones = @($nodes | Where-Object { $_.other -eq $tzName })
        if ($zones.Count -eq 1) {
            $ltz = $zones[0].type
        } elseif ($zones.Count -gt 1) {
            $ltz = ($zones | Where-Object { $_.territory -eq $territory } | Select-Object -First 1).type
            if (-not $ltz) {
                $ltz = ($zones | Where-Object { $_.territory -eq '001' } | Select-Object -First 1).type
            }
            if (-not $ltz) {
                $ltz = $zones[0].type
            }
        }
    } catch {
        Write-Host "Offline/timezone lookup fallback: $($_.Exception.Message)"
    }

    if (-not $ltz) {
        $offset = - [int][math]::Round($wtz.BaseUtcOffset.TotalHours)
        if (-12 -le $offset -and $offset -le 12 -and $offset -ne 0) {
            if ($offset -gt 0) {
                $ltz = "Etc/GMT+$offset"
            } else {
                $ltz = "Etc/GMT$offset"
            }
        } else {
            $ltz = "UTC"
        }
    }

    return ($ltz -split '\s+')[0]
}

function expandTemplate($filename) {
    $str = Get-Content -LiteralPath "$filename"
    $str = $str -join "`n"
    return $ExecutionContext.InvokeCommand.ExpandString($str)
}

function Expand-Placeholders([string]$templatePath, [hashtable]$map) {
    $content = Get-Content -LiteralPath $templatePath -Raw
    foreach ($k in $map.Keys) {
        $content = $content.Replace("{{$k}}", [string]$map[$k])
    }
    return $content
}

function Copy-FileWithProgress([string]$src, [string]$dst, [ref]$copiedBytes, [long]$totalBytes) {
    $parent = Split-Path $dst -Parent
    if (-not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    if (Test-Path -LiteralPath $dst) {
        $existing = Get-Item -LiteralPath $dst -Force
        if ($existing.IsReadOnly) { $existing.IsReadOnly = $false }
    }

    $bufSize = 8MB
    $buffer = New-Object byte[] $bufSize
    $inStream = [System.IO.File]::OpenRead($src)
    try {
        $outStream = [System.IO.File]::Create($dst)
        try {
            while (($read = $inStream.Read($buffer, 0, $bufSize)) -gt 0) {
                $outStream.Write($buffer, 0, $read)
                $copiedBytes.Value += $read
                if ($totalBytes -gt 0 -and $global:dlStatus) {
                    $pct = [math]::Min(100, [int](($copiedBytes.Value * 100) / $totalBytes))
                    $global:dlStatus.Text = "Staging ISO to FAT32... $pct%"
                    [System.Windows.Forms.Application]::DoEvents()
                }
            }
        } finally {
            $outStream.Dispose()
        }
    } finally {
        $inStream.Dispose()
    }
}

function New-FedoraStagingPartition([long]$stagingBytes) {
    calcPartition
    $diskNumber = $global:partc.DiskNumber

    # Remove any stale TUNIC_BOOT partition from an aborted previous run
    $stale = Get-Volume -FileSystemLabel $global:STAGING_LABEL -ErrorAction SilentlyContinue | Get-Partition -ErrorAction SilentlyContinue
    if ($stale) {
        foreach ($p in $stale) {
            if ($p.DiskNumber -eq $diskNumber) {
                Remove-Partition -DiskNumber $p.DiskNumber -PartitionNumber $p.PartitionNumber -Confirm:$false
            }
        }
        calcPartition
    }

    # Shrink C: if unallocated gap isn't already large enough (e.g. Full Disk or Custom mode)
    if ($global:gap -lt $stagingBytes) {
        $shrinkBy = $stagingBytes - $global:gap + 16MB
        $newSize = [long]([math]::Floor(($global:partc.Size - $shrinkBy) / 1MB) * 1MB)
        $minSize = (Get-PartitionSupportedSize -DriveLetter $global:letter).SizeMin
        if ($newSize -lt $minSize) {
            throw "Not enough free space on ${global:letter}: to create $(Format-BytesGB $stagingBytes) GB staging partition."
        }
        Suspend-BitLockerIfNeeded $global:letter
        Resize-Partition -DriveLetter $global:letter -Size $newSize -ErrorAction Stop
    }

    $driveLetterStr = (Get-FreeDriveLetter).TrimEnd(':')
    $part = New-Partition -DiskNumber $diskNumber -Size $stagingBytes -DriveLetter $driveLetterStr -ErrorAction Stop
    Format-Volume -Partition $part -FileSystem FAT32 -NewFileSystemLabel $global:STAGING_LABEL -Confirm:$false -ErrorAction Stop | Out-Null

    return "${driveLetterStr}:"
}

function Copy-IsoToStaging([string]$isoPath, [string]$stagingDrive, [hashtable]$meta) {
    $alreadyMounted = $false
    $existingImg = Get-DiskImage -ImagePath $isoPath -ErrorAction SilentlyContinue
    if ($existingImg -and $existingImg.Attached) {
        $alreadyMounted = $true
        $img = $existingImg
    } else {
        $img = Mount-DiskImage -ImagePath $isoPath -StorageType ISO -PassThru -ErrorAction Stop
    }

    try {
        $vol = $img | Get-Volume | Select-Object -First 1
        $isoDrive = "$($vol.DriveLetter):"

        $allFiles = @(Get-ChildItem -LiteralPath "$isoDrive\" -Recurse -File -Force -ErrorAction Stop)
        $totalBytes = ($allFiles | Measure-Object -Property Length -Sum).Sum
        if (-not $totalBytes) { $totalBytes = 1 }
        [long]$copied = 0

        foreach ($f in $allFiles) {
            $rel = $f.FullName.Substring($isoDrive.Length).TrimStart('\')
            $dst = Join-Path "$stagingDrive\" $rel
            Copy-FileWithProgress $f.FullName $dst ([ref]$copied) $totalBytes
        }

        # Marker file for GRUB search
        Set-Content -Path (Join-Path "$stagingDrive\" $global:STAGING_MARKER) -Value "Tunic Fedora Boot Partition`n$($meta.label)`n" -Encoding ASCII

        # Generate Kickstart file if using Server / Everything / Netinstall ISO
        if ($meta.family -eq 'fedora-installer') {
            $ksContent = Build-FedoraKickstart
            Set-Content -Path (Join-Path "$stagingDrive\" 'ks.cfg') -Value $ksContent -Encoding ASCII
        }

        # Verify kernel & initrd exist on staging partition
        $kWin = Join-Path "$stagingDrive\" ($meta.kernelPath.TrimStart('/').Replace('/', '\'))
        $iWin = Join-Path "$stagingDrive\" ($meta.initrdPath.TrimStart('/').Replace('/', '\'))
        if (-not (Test-Path -LiteralPath $kWin) -or -not (Test-Path -LiteralPath $iWin)) {
            throw "Expected kernel/initrd missing after copying to ${stagingDrive}: ($kWin, $iWin)"
        }
    } finally {
        if (-not $alreadyMounted) {
            Dismount-DiskImage -ImagePath $isoPath -ErrorAction SilentlyContinue | Out-Null
        }
    }
}

function Build-FedoraKickstart() {
    $disk = Get-Disk -Number (Get-Partition -DriveLetter $global:letter).DiskNumber
    $ondisk = if ($disk.BusType -eq 'NVMe') { "nvme0n1" } else { "sd$([char]($disk.Number + 97))" }

    if ($global:data.installType -eq $FULLBOOT) {
        $partCmds = @"
clearpart --all --initlabel
autopart --type=btrfs
"@
    } elseif ($global:data.installType -eq $DUALBOOT) {
        $partCmds = @"
clearpart --none
part /boot --fstype="ext4" --size=1024 --ondisk=$ondisk
part btrfs.1 --fstype="btrfs" --size=1 --grow --ondisk=$ondisk
btrfs none --label=fedora btrfs.1
btrfs /     --subvol --name=root  fedora
btrfs /home --subvol --name=home  fedora
"@
    } else {
        $partCmds = "# Interactive partitioning in Anaconda"
    }

    $utcFlag = if ($global:data.installType -ne $DUALBOOT) { "--utc" } else { "" }
    $lang = "$((Get-Culture).IetfLanguageTag.Replace('-', '_')).UTF-8"
    $tz = getLinuxTimeZone

    return Expand-Placeholders (Join-Path $PSScriptRoot 'files\ks.cfg') @{
        LANG           = $lang
        TIMEZONE       = $tz
        UTC_FLAG       = $utcFlag
        HOSTNAME       = $global:data.hostname
        USERNAME       = $global:data.username
        PASSWORD       = $global:data.password
        FULLNAME       = $global:data.fullname
        PARTITION_CMDS = $partCmds
    }
}

function Build-FedoraGrubCfg([hashtable]$meta) {
    $isFull = ($global:data.installType -eq $FULLBOOT)
    $ramBytes = (Get-CimInstance -ClassName Win32_ComputerSystem).TotalPhysicalMemory
    $enoughRamForCopy = ($ramBytes -ge 5.5GB)

    if ($meta.family -eq 'fedora-live') {
        $primaryArgs = "root=live:LABEL=$($global:STAGING_LABEL) rd.live.image quiet rhgb"
        $primaryTitle = "Start Fedora Live Installer (Tunic)"
        if ($isFull -and $enoughRamForCopy) {
            $primaryArgs = "root=live:LABEL=$($global:STAGING_LABEL) rd.live.image rd.live.ram=1 quiet rhgb"
            $primaryTitle = "Start Fedora Live Installer (Loaded to RAM)"
        }
        $altTitle = "Start Fedora Live (Load to RAM - rd.live.ram=1)"
        $altArgs = "root=live:LABEL=$($global:STAGING_LABEL) rd.live.image rd.live.ram=1 quiet"
        $nomodesetTitle = "Start Fedora Live (Basic Graphics / nomodeset)"
        $nomodesetArgs = "root=live:LABEL=$($global:STAGING_LABEL) rd.live.image nomodeset"
    } else {
        $repoArg = if ($meta.hasRepo) { " inst.repo=hd:LABEL=$($global:STAGING_LABEL)" } else { "" }
        $primaryTitle = "Start Fedora Installer (Interactive)"
        $primaryArgs = "inst.stage2=hd:LABEL=$($global:STAGING_LABEL)$repoArg quiet"
        $altTitle = "Start Fedora Installer (Automated Kickstart)"
        $altArgs = "inst.stage2=hd:LABEL=$($global:STAGING_LABEL)$repoArg inst.ks=hd:LABEL=$($global:STAGING_LABEL):/ks.cfg quiet"
        $nomodesetTitle = "Start Fedora Installer (Basic Graphics / nomodeset)"
        $nomodesetArgs = "inst.stage2=hd:LABEL=$($global:STAGING_LABEL)$repoArg inst.xdriver=vesa nomodeset"
    }

    return Expand-Placeholders (Join-Path $PSScriptRoot 'files\grub.fedora.cfg') @{
        PRIMARY_TITLE   = $primaryTitle
        PRIMARY_ARGS    = $primaryArgs
        ALT_TITLE       = $altTitle
        ALT_ARGS        = $altArgs
        NOMODESET_TITLE = $nomodesetTitle
        NOMODESET_ARGS  = $nomodesetArgs
        LINUX_CMD       = $meta.linuxCmd
        INITRD_CMD      = $meta.initrdCmd
        KERNEL_PATH     = $meta.kernelPath
        INITRD_PATH     = $meta.initrdPath
    }
}

function Set-TunicBcdEntry([string]$efiDrive, [string]$efiRelPath, [string]$description) {
    if (-not (Test-Path -LiteralPath "${global:tunic_dir}\bcd-before.bak")) {
        bcdedit /export "${global:tunic_dir}\bcd-before.bak" | Out-Null
    }

    if (Test-Path -LiteralPath "${global:tunic_dir}\bcd.id") {
        $oldLoader = (Get-Content -LiteralPath "${global:tunic_dir}\bcd.id" -ErrorAction SilentlyContinue | Select-Object -First 1).Trim()
        if ($oldLoader) {
            bcdedit /delete "$oldLoader" /cleanup /f | Out-Null
        }
    }

    $copyOut = (bcdedit /copy '{bootmgr}' /d "$description") -join ' '
    if ($LASTEXITCODE -ne 0 -or $copyOut -notmatch '(\{[0-9a-fA-F-]+\})') {
        throw "Failed to create BCD boot entry: $copyOut"
    }
    $osloader = $matches[1]

    bcdedit /set "$osloader" device "partition=$efiDrive" | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "bcdedit failed setting device partition=$efiDrive" }

    bcdedit /set "$osloader" path "$efiRelPath" | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "bcdedit failed setting path $efiRelPath" }

    bcdedit /set "$osloader" description "$description" | Out-Null

    @('locale', 'inherit', 'default', 'resumeobject', 'displayorder', 'toolsdisplayorder', 'timeout') | ForEach-Object {
        bcdedit /deletevalue "$osloader" $_ 2>$null | Out-Null
    }

    bcdedit /set '{fwbootmgr}' displayorder "$osloader" /addfirst | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "bcdedit failed updating {fwbootmgr} displayorder" }

    Set-Content -Path "${global:tunic_dir}\bcd.id" -Value "$osloader"
    bcdedit /export "${global:tunic_dir}\bcd-grub.bak" | Out-Null
}

function Install-FedoraBootloader([string]$stagingDrive, [hashtable]$meta) {
    $efi = Get-FreeDriveLetter
    mountvol $efi /s
    if ($LASTEXITCODE -ne 0) { throw "Failed to mount EFI System Partition to $efi" }

    try {
        $tunicEfiDir = "${efi}\EFI\tunic"
        $bootEfiDir = "${efi}\EFI\BOOT"
        if (-not (Test-Path -LiteralPath $tunicEfiDir)) {
            New-Item -ItemType Directory -Path $tunicEfiDir -Force | Out-Null
        }
        if (-not (Test-Path -LiteralPath $bootEfiDir)) {
            New-Item -ItemType Directory -Path $bootEfiDir -Force | Out-Null
        }

        $stagingEfiBoot = "${stagingDrive}\EFI\BOOT"
        $stagingEfiFedora = "${stagingDrive}\EFI\fedora"
        $copiedShim = $false
        foreach ($bin in @('BOOTX64.EFI', 'grubx64.efi', 'mmx64.efi')) {
            $srcBin = Join-Path $stagingEfiBoot $bin
            if (-not (Test-Path -LiteralPath $srcBin) -and (Test-Path -LiteralPath (Join-Path $stagingEfiFedora $bin))) {
                $srcBin = Join-Path $stagingEfiFedora $bin
            }
            if (Test-Path -LiteralPath $srcBin) {
                $dstBin = Join-Path $tunicEfiDir $bin
                Copy-Item -LiteralPath $srcBin -Destination $dstBin -Force
                if (Test-Path -LiteralPath $dstBin) {
                    $fi = Get-Item -LiteralPath $dstBin -Force
                    if ($fi.IsReadOnly) { $fi.IsReadOnly = $false }
                }
                if ($bin -eq 'BOOTX64.EFI') { $copiedShim = $true }
            }
        }

        if (-not $copiedShim) {
            throw "ISO does not contain \EFI\BOOT\BOOTX64.EFI required for Secure Boot."
        }

        $grubCfgText = Build-FedoraGrubCfg $meta

        # Write to EFI\tunic\grub.cfg
        Set-Content -Path (Join-Path $tunicEfiDir 'grub.cfg') -Value $grubCfgText -Encoding ASCII

        # Also write to EFI\BOOT\grub.cfg (Fedora gcdx64.efi default prefix), backing up any pre-existing non-Tunic grub.cfg
        $espBootGrubCfg = Join-Path $bootEfiDir 'grub.cfg'
        $espBootBackup = Join-Path $bootEfiDir 'grub.tunic.bak'
        if ((Test-Path -LiteralPath $espBootGrubCfg) -and -not (Test-Path -LiteralPath $espBootBackup)) {
            $existingCfg = Get-Content -LiteralPath $espBootGrubCfg -Raw -ErrorAction SilentlyContinue
            if ($existingCfg -notmatch '^# Tunic Linux Installer') {
                Copy-Item -LiteralPath $espBootGrubCfg -Destination $espBootBackup -Force
            }
        }
        Set-Content -Path $espBootGrubCfg -Value $grubCfgText -Encoding ASCII

        # Also update the staging partition's EFI\BOOT\grub.cfg
        $stagingGrubCfg = Join-Path $stagingEfiBoot 'grub.cfg'
        if (Test-Path -LiteralPath $stagingGrubCfg) {
            $sfi = Get-Item -LiteralPath $stagingGrubCfg -Force
            if ($sfi.IsReadOnly) { $sfi.IsReadOnly = $false }
        }
        Set-Content -Path $stagingGrubCfg -Value $grubCfgText -Encoding ASCII

        Set-TunicBcdEntry $efi "\EFI\tunic\BOOTX64.EFI" "Tunic Fedora Installer"
    } finally {
        mountvol $efi /d | Out-Null
    }
}

function installGrub([string]$iso_path) {
    $efi = Get-FreeDriveLetter
    mountvol $efi /s
    if ($LASTEXITCODE -ne 0) { throw "Failed to mount EFI System Partition to $efi" }

    try {
        $secureBootEnabled = $false
        try {
            $secureBootEnabled = Confirm-SecureBootUEFI
        } catch {}

        $grub_dir = "\boot\grub"
        $grub_path = "${efi}${grub_dir}"

        if (-not $iso_path) {
            $iso_path = getUrlFilepath $global:data.iso_url
        }
        $iso_grub_path = getGrubPath $iso_path

        $grub_version = 'grub-2.04-for-windows'
        $grub_local_dir = "${global:tunic_dir}\${grub_version}"
        if (-not (Test-Path -LiteralPath $grub_local_dir)) {
            $web.DownloadFile("https://ftp.gnu.org/gnu/grub/${grub_version}.zip", "${grub_local_dir}.zip")
            Expand-Archive "${grub_local_dir}.zip" -DestinationPath "${global:tunic_dir}"
            Remove-Item "${grub_local_dir}.zip"
        }
        & "${global:tunic_dir}\${grub_version}\grub-install.exe" --no-nvram --boot-directory="${efi}\boot" --efi-directory="${efi}\" --target=x86_64-efi > $null

        if ($secureBootEnabled) {
            $web.DownloadFile($shim_url, "${efi}\EFI\grub\shimx64.efi")
            $efiPath = "\EFI\grub\shimx64.efi"
        } else {
            $efiPath = "\EFI\grub\grubx64.efi"
        }

        Move-Item "$grub_path\grub.cfg" "$grub_path\grub.orig.cfg" -ErrorAction SilentlyContinue
        Copy-Item "files\grub.cfg" "$grub_path\."
        Set-Content -Path "$grub_path\grub.var.cfg" -Value "set iso_path='$iso_grub_path'"

        Set-TunicBcdEntry $efi $efiPath "Tunic Linux Installer"

        Set-Content -Value (expandTemplate "files\preseed.cfg") -Path "${global:tunic_dir}\preseed.cfg"
    } finally {
        mountvol $efi /d | Out-Null
    }
}

# Calculates globals gap and maxAvailable
function calcPartition() {
    $letter = $global:letter
    $global:partc = Get-Partition -DriveLetter $letter
    $disk = Get-Disk -Number $global:partc.DiskNumber

    # Find next partition on the disk by byte offset (safer than partitionNumber + 1)
    $partcEnd = [long]$global:partc.Offset + [long]$global:partc.Size
    $partnext = Get-Partition -DiskNumber $global:partc.DiskNumber |
        Where-Object { $_.Offset -ge $partcEnd } |
        Sort-Object Offset |
        Select-Object -First 1

    if (-not $partnext) {
        $global:gap = [math]::Max(0, [long]$disk.Size - $partcEnd - 1MB)
    } else {
        $global:gap = [math]::Max(0, [long]$partnext.Offset - $partcEnd)
    }

    $supported = Get-PartitionSupportedSize -DriveLetter "$letter"
    $global:maxAvailable = [math]::Max(0, ([long]$global:partc.Size - [long]$supported.SizeMin + [long]$global:gap - 16MB))
}

function repartition() {
    $letter = $global:letter
    $global:partc = Get-Partition -DriveLetter $letter

    $linuxSizeBytes = [long]([double]$global:data.linuxSize * 1GB)
    $shrinkBy = $linuxSizeBytes - [long]$global:gap

    if ($shrinkBy -gt 0) {
        $newSize = [long]([math]::Floor(([long]$global:partc.Size - $shrinkBy) / 1MB) * 1MB)
        Suspend-BitLockerIfNeeded $letter
        Resize-Partition -DriveLetter $letter -Size $newSize -ErrorAction Stop
    }
}

function calcGui() {
    $global:form.Activate()
    [System.Windows.Forms.Application]::DoEvents()

    calcPartition

    $letter = $global:letter
    $volume = Get-Volume -DriveLetter $letter

    $total = [math]::Round($volume.Size / 1GB)
    $free = [math]::Round($volume.SizeRemaining / 1GB)
    $used = [math]::Round(($volume.Size - $volume.SizeRemaining) / 1GB)
    $avail = [math]::Floor($global:maxAvailable / 1GB)

    $global:sizeGroup.Text = "${letter}: Drive"
    $global:totalValue.Text = "$total GB"
    $global:freeValue.Text = "$free GB"
    $global:usedValue.Text = "$used GB"
    $global:availValue.Text = "$avail GB"

    $minGB = Get-MinLinuxGBForSelectedDistro
    if (-not $global:linuxSize.Text) {
        $global:linuxSize.Text = "$([math]::Max($minGB, [math]::Min([math]::Floor($total / 2), $avail)))"
    }

    if ($global:dualNoteLabel) {
        $selected = Get-SelectedDistro
        if ($selected -and $selected.local -and (Test-Path -LiteralPath $selected.url)) {
            $stgGB = Format-BytesGB (Get-StagingBytesForIso $selected.sizeBytes)
            $global:dualNoteLabel.Text = "Minimum ${minGB} GB (includes ~${stgGB} GB temporary FAT32 boot partition TUNIC_BOOT + free space for Fedora)."
        } else {
            $global:dualNoteLabel.Text = "Minimum ${minGB} GB required for Linux."
        }
    }
}

function treeMap() {
    $tree_dl = 'https://windirstat.mirror.wearetriple.com//wds_current_setup.exe'
    $tree_setup = "$($global:tunic_dir)\windirstat-setup.exe"
    $tree_exe = "C:\Program Files (x86)\WinDirStat\windirstat.exe"
    if (-not (Test-Path -LiteralPath "$tree_exe")) {
        $web.DownloadFile($tree_dl, $tree_setup)
        Start-Process $tree_setup -ArgumentList '/S' -Wait
    }
    Start-Process "$tree_exe" -Wait
}

function initFields() {
    checks
    if ($global:form.IsDisposed) { return }
    initData

    $global:fullName.Text = $global:data.fullname
    $global:username.Text = $global:data.username
    $global:hostname.Text = $global:data.hostname

    Update-DistroSelectionUi
}

function checkFields() {
    $global:outer.Enabled = $false

    $selected = Get-SelectedDistro
    if (-not $selected) {
        [Void][System.Windows.Forms.MessageBox]::Show("Please select or browse for a Linux ISO.", "Tunic")
        $global:outer.Enabled = $true
        return $false
    }

    $requireCreds = $true
    $isFedora = ($selected.name -match 'Fedora')
    if ($selected.local -and (Test-Path -LiteralPath $selected.url)) {
        try {
            $meta = Inspect-LinuxIso $selected.url
            if ($meta.family -eq 'unknown') {
                [Void][System.Windows.Forms.MessageBox]::Show("Unrecognized ISO layout in $($selected.url). Expected Fedora Live/Installer or Ubuntu/Mint ISO.`n`nDetected root entries: $($meta.topDirs)`nKernel: $($meta.kernelPath) | Initrd: $($meta.initrdPath)", "Tunic")
                $global:outer.Enabled = $true
                return $false
            }
            if ($meta.family -eq 'fedora-live') { $requireCreds = $false }
            if ($meta.family -like 'fedora*') { $isFedora = $true }
        } catch {
            [Void][System.Windows.Forms.MessageBox]::Show("Could not inspect ISO: $($_.Exception.Message)", "Tunic")
            $global:outer.Enabled = $true
            return $false
        }
    } elseif ($isFedora) {
        $requireCreds = $false
    }

    if ($requireCreds) {
        if ($global:password.Text.Length -eq 0) {
            [Void][System.Windows.Forms.MessageBox]::Show("Password required.", "Tunic")
            $global:outer.Enabled = $true
            [Void]$global:password.Focus()
            return $false
        }

        if ($global:password.Text -ne $global:password2.Text) {
            [Void][System.Windows.Forms.MessageBox]::Show("Passwords don't match.", "Tunic")
            $global:outer.Enabled = $true
            [Void]$global:password.Focus()
            return $false
        }
    }

    if (-not $global:agreeBox.Checked) {
        [Void][System.Windows.Forms.MessageBox]::Show("You must agree to the disclaimer to continue.", "Tunic")
        $global:outer.Enabled = $true
        [Void]$global:agreeBox.Focus()
        return $false
    }

    $minDiskGB = Get-MinLinuxGBForSelectedDistro

    if ($global:dualBootRadio.Checked -and $global:dual.Visible) {
        $parsedSize = 0.0
        if (-not [double]::TryParse($global:linuxSize.Text, [ref]$parsedSize)) {
            [Void][System.Windows.Forms.MessageBox]::Show("Enter a valid numeric Linux Size in GB.", "Tunic")
            $global:outer.Enabled = $true
            [Void]$global:linuxSize.Focus()
            return $false
        }
        $linuxSizeNum = $parsedSize * 1GB
        if ($linuxSizeNum -lt ($minDiskGB * 1GB)) {
            [Void][System.Windows.Forms.MessageBox]::Show("Selected Linux configuration requires at least ${minDiskGB} GB.", "Tunic")
            $global:outer.Enabled = $true
            [Void]$global:linuxSize.Focus()
            return $false
        }

        if ($linuxSizeNum -gt $global:maxAvailable) {
            [Void][System.Windows.Forms.MessageBox]::Show("Not enough available space on ${global:letter}:.", "Tunic")
            $global:outer.Enabled = $true
            [Void]$global:linuxSize.Focus()
            return $false
        }
    } elseif (-not $global:dualBootRadio.Checked -and $isFedora) {
        # Full Disk / Custom for Fedora still needs temporary FAT32 staging space
        calcPartition
        $neededBytes = if ($selected.sizeBytes) { Get-StagingBytesForIso $selected.sizeBytes } else { 4GB }
        if ($global:maxAvailable -lt $neededBytes) {
            $neededGB = [math]::Ceiling($neededBytes / 1GB)
            $availGB = [math]::Round($global:maxAvailable / 1GB, 1)
            $freeGB = [math]::Round((Get-Volume -DriveLetter $global:letter).SizeRemaining / 1GB, 1)
            $ask = "Fedora needs ~${neededGB} GB of shrinkable space on ${global:letter}: for the temporary FAT32 boot partition.`n`n${global:letter}: has ${freeGB} GB free, but Windows currently only allows shrinking ${availGB} GB (usually because hiberfil.sys, pagefile.sys, or shadow copies sit at the end of the drive).`n`nHave Tunic try reclaiming shrinkable space now (disables Hibernation/Fast Startup and consolidates)? "
            if (yes($ask)) {
                if (Try-ReclaimShrinkSpace $neededBytes) {
                    $global:outer.Enabled = $true
                    return $true
                }
            }
            $global:outer.Enabled = $true
            return $false
        }
    }

    $global:outer.Enabled = $true
    return $true
}

function installTypeCheck() {
    if ($global:dualBootRadio.Checked) {
        $global:installButton.Text = 'Continue'
    } else {
        $global:installButton.Text = 'Install Now'
    }
}

function gui() {
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    [System.Windows.Forms.Application]::EnableVisualStyles()

    $global:Form = New-Object System.Windows.Forms.Form
    $Form.Text = "Tunic Linux Installer (Windows 10/11 + Fedora)"
    $Form.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::Font
    $Form.AutoSize = $true
    $Form.MinimumSize = New-Object System.Drawing.Size(540, 500)
    $Form.AllowDrop = $true
    $icoPath = Join-Path $PSScriptRoot 'files\tunic-logo.ico'
    if (Test-Path -LiteralPath $icoPath) {
        $Form.Icon = New-Object System.Drawing.Icon($icoPath)
    }

    $Form.Add_DragEnter({
        if ($_.Data.GetDataPresent([System.Windows.Forms.DataFormats]::FileDrop)) {
            $files = $_.Data.GetData([System.Windows.Forms.DataFormats]::FileDrop)
            if ($files -and $files[0] -match '\.iso$') {
                $_.Effect = [System.Windows.Forms.DragDropEffects]::Copy
                return
            }
        }
        $_.Effect = [System.Windows.Forms.DragDropEffects]::None
    })

    $Form.Add_DragDrop({
        $files = $_.Data.GetData([System.Windows.Forms.DataFormats]::FileDrop)
        if ($files -and $files[0] -match '\.iso$') {
            if (Add-OrSelectLocalIso $files[0]) {
                Update-DistroSelectionUi
            }
        }
    })

    # Outer layout
    $global:outer = New-Object System.Windows.Forms.TableLayoutPanel
    $outer.AutoSize = $true
    $outer.Dock = [System.Windows.Forms.DockStyle]::Fill
    $outer.ColumnCount = 1

    # Main Input Panel
    $global:main = New-Object System.Windows.Forms.TableLayoutPanel
    $main.AutoSize = $true
    $main.Dock = [System.Windows.Forms.DockStyle]::Fill
    $main.Padding = 10
    $main.ColumnCount = 1

    $bootGroup = New-Object System.Windows.Forms.GroupBox
    $bootGroup.Text = "Installation Type"
    $bootGroup.AutoSize = $true
    $bootGroup.Dock = [System.Windows.Forms.DockStyle]::Fill

    $bootPanel = New-Object System.Windows.Forms.TableLayoutPanel
    $bootPanel.AutoSize = $true
    $bootPanel.Dock = [System.Windows.Forms.DockStyle]::Fill
    $bootPanel.Padding = 5
    $bootPanel.ColumnCount = 1

    $global:dualBootRadio = New-Object System.Windows.Forms.RadioButton
    $dualBootRadio.Text = "Install Linux alongside Windows (Dual Boot)"
    $dualBootRadio.AutoSize = $true
    $dualBootRadio.Checked = $true
    $bootPanel.Controls.Add($dualBootRadio)

    $global:fullBootRadio = New-Object System.Windows.Forms.RadioButton
    $fullBootRadio.Text = "Erase entire disk and install Linux"
    $fullBootRadio.AutoSize = $true
    $bootPanel.Controls.Add($fullBootRadio)

    $global:customBootRadio = New-Object System.Windows.Forms.RadioButton
    $customBootRadio.Text = "Custom/Advanced (Boot ISO Installer)"
    $customBootRadio.AutoSize = $true
    $bootPanel.Controls.Add($customBootRadio)

    $bootGroup.Controls.Add($bootPanel)
    $main.Controls.Add($bootGroup)

    # Distro / ISO Selection
    $distroGroup = New-Object System.Windows.Forms.GroupBox
    $distroGroup.Text = "Linux ISO (Drop .iso here, in project folder, or Downloads)"
    $distroGroup.AutoSize = $true
    $distroGroup.Dock = [System.Windows.Forms.DockStyle]::Fill

    $distroPanel = New-Object System.Windows.Forms.TableLayoutPanel
    $distroPanel.AutoSize = $true
    $distroPanel.Dock = [System.Windows.Forms.DockStyle]::Fill
    $distroPanel.Padding = 5
    $distroPanel.ColumnCount = 3

    $global:distroName = New-Object System.Windows.Forms.ComboBox
    $distroName.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
    $distroName.Width = 340

    $browseIsoButton = New-Object System.Windows.Forms.Button
    $browseIsoButton.Text = "Browse ISO..."
    $browseIsoButton.AutoSize = $true

    $refreshIsoButton = New-Object System.Windows.Forms.Button
    $refreshIsoButton.Text = "Refresh"
    $refreshIsoButton.AutoSize = $true

    $distroPanel.Controls.Add($distroName, 0, 0)
    $distroPanel.Controls.Add($browseIsoButton, 1, 0)
    $distroPanel.Controls.Add($refreshIsoButton, 2, 0)

    $global:isoInfoLabel = New-Object System.Windows.Forms.Label
    $isoInfoLabel.AutoSize = $true
    $isoInfoLabel.MaximumSize = New-Object System.Drawing.Size(500, 0)
    $isoInfoLabel.ForeColor = [System.Drawing.SystemColors]::ControlDarkDark
    $distroPanel.Controls.Add($isoInfoLabel, 0, 1)
    $distroPanel.SetColumnSpan($isoInfoLabel, 3)

    $distroGroup.Controls.Add($distroPanel)
    $main.Controls.Add($distroGroup)

    # Identification Group
    $global:idGroup = New-Object System.Windows.Forms.GroupBox
    $idGroup.Text = "Identification"
    $idGroup.AutoSize = $true
    $idGroup.Dock = [System.Windows.Forms.DockStyle]::Fill

    $idPanel = New-Object System.Windows.Forms.TableLayoutPanel
    $idPanel.AutoSize = $true
    $idPanel.Dock = [System.Windows.Forms.DockStyle]::Fill
    $idPanel.Padding = 5
    $idPanel.ColumnCount = 2
    $row = 0

    $global:idNoteLabel = New-Object System.Windows.Forms.Label
    $idNoteLabel.AutoSize = $true
    $idNoteLabel.MaximumSize = New-Object System.Drawing.Size(480, 0)
    $idNoteLabel.ForeColor = [System.Drawing.Color]::DarkBlue
    $idNoteLabel.Visible = $false
    $idPanel.Controls.Add($idNoteLabel, 0, $row)
    $idPanel.SetColumnSpan($idNoteLabel, 2)
    $row++

    $usernameLabel = New-Object System.Windows.Forms.Label
    $usernameLabel.Text = "User Name"
    $usernameLabel.AutoSize = $true
    $global:username = New-Object System.Windows.Forms.TextBox
    $username.Width = 220
    $idPanel.Controls.Add($usernameLabel, 0, $row)
    $idPanel.Controls.Add($username, 1, $row)
    $row++

    $passwordLabel = New-Object System.Windows.Forms.Label
    $passwordLabel.Text = "Password"
    $passwordLabel.AutoSize = $true
    $global:password = New-Object System.Windows.Forms.TextBox
    $password.PasswordChar = '*'
    $password.Width = 220
    $idPanel.Controls.Add($passwordLabel, 0, $row)
    $idPanel.Controls.Add($password, 1, $row)
    $row++

    $password2Label = New-Object System.Windows.Forms.Label
    $password2Label.Text = "Password, again"
    $password2Label.AutoSize = $true
    $global:password2 = New-Object System.Windows.Forms.TextBox
    $password2.PasswordChar = '*'
    $password2.Width = 220
    $idPanel.Controls.Add($password2Label, 0, $row)
    $idPanel.Controls.Add($password2, 1, $row)
    $row++

    $fullNameLabel = New-Object System.Windows.Forms.Label
    $fullNameLabel.Text = "Full Name"
    $fullNameLabel.AutoSize = $true
    $global:fullName = New-Object System.Windows.Forms.TextBox
    $fullName.Width = 220
    $idPanel.Controls.Add($fullNameLabel, 0, $row)
    $idPanel.Controls.Add($fullName, 1, $row)
    $row++

    $hostnameLabel = New-Object System.Windows.Forms.Label
    $hostnameLabel.Text = "Computer Name"
    $hostnameLabel.AutoSize = $true
    $global:hostname = New-Object System.Windows.Forms.TextBox
    $hostname.Width = 220
    $idPanel.Controls.Add($hostnameLabel, 0, $row)
    $idPanel.Controls.Add($hostname, 1, $row)
    $row++

    $idGroup.Controls.Add($idPanel)
    $main.Controls.Add($idGroup)

    $global:agreeBox = New-Object System.Windows.Forms.CheckBox
    $agreeBox.AutoSize = $true
    $agreeBox.MaximumSize = New-Object System.Drawing.Size(500, 0)
    $agreeBox.Padding = New-Object System.Windows.Forms.Padding(0, 6, 0, 4)
    $agreeBox.Text = "I understand this software modifies partitions and bootloaders, could cause data loss, and is provided as-is without warranty."
    $main.Controls.Add($agreeBox)

    $outer.Controls.Add($main)

    # Dual boot Input Panel
    $global:dual = New-Object System.Windows.Forms.TableLayoutPanel
    $dual.AutoSize = $true
    $dual.Dock = [System.Windows.Forms.DockStyle]::Fill
    $dual.Padding = 10
    $dual.ColumnCount = 1
    $dual.Visible = $false

    $global:sizeGroup = New-Object System.Windows.Forms.GroupBox
    $sizeGroup.Text = "C: Drive"
    $sizeGroup.AutoSize = $true
    $sizeGroup.Dock = [System.Windows.Forms.DockStyle]::Fill

    $sizePanel = New-Object System.Windows.Forms.TableLayoutPanel
    $sizePanel.AutoSize = $true
    $sizePanel.Dock = [System.Windows.Forms.DockStyle]::Fill
    $sizePanel.Padding = 5
    $sizePanel.ColumnCount = 2
    $row = 0

    $totalLabel = New-Object System.Windows.Forms.Label
    $totalLabel.Text = "Total Size"
    $totalLabel.AutoSize = $true
    $global:totalValue = New-Object System.Windows.Forms.Label
    $totalValue.Text = "0 GB"
    $totalValue.AutoSize = $true
    $sizePanel.Controls.Add($totalLabel, 0, $row)
    $sizePanel.Controls.Add($totalValue, 1, $row)
    $row++

    $usedLabel = New-Object System.Windows.Forms.Label
    $usedLabel.Text = "Used by Windows"
    $usedLabel.AutoSize = $true
    $global:usedValue = New-Object System.Windows.Forms.Label
    $usedValue.Text = "0 GB"
    $usedValue.AutoSize = $true
    $sizePanel.Controls.Add($usedLabel, 0, $row)
    $sizePanel.Controls.Add($usedValue, 1, $row)
    $row++

    $freeLabel = New-Object System.Windows.Forms.Label
    $freeLabel.Text = "Free"
    $freeLabel.AutoSize = $true
    $global:freeValue = New-Object System.Windows.Forms.Label
    $freeValue.Text = "0 GB"
    $freeValue.AutoSize = $true
    $sizePanel.Controls.Add($freeLabel, 0, $row)
    $sizePanel.Controls.Add($freeValue, 1, $row)
    $row++

    $availLabel = New-Object System.Windows.Forms.Label
    $availLabel.Text = "Available to Shrink"
    $availLabel.AutoSize = $true
    $global:availValue = New-Object System.Windows.Forms.Label
    $availValue.Text = "0 GB"
    $availValue.AutoSize = $true
    $sizePanel.Controls.Add($availLabel, 0, $row)
    $sizePanel.Controls.Add($availValue, 1, $row)
    $row++

    $linuxLabel = New-Object System.Windows.Forms.Label
    $linuxLabel.Text = "Linux Size (GB)"
    $linuxLabel.AutoSize = $true
    $global:linuxSize = New-Object System.Windows.Forms.TextBox
    $linuxSize.Width = 60
    $sizePanel.Controls.Add($linuxLabel, 0, $row)
    $sizePanel.Controls.Add($linuxSize, 1, $row)
    $row++

    $global:dualNoteLabel = New-Object System.Windows.Forms.Label
    $dualNoteLabel.AutoSize = $true
    $dualNoteLabel.MaximumSize = New-Object System.Drawing.Size(480, 0)
    $dualNoteLabel.ForeColor = [System.Drawing.SystemColors]::ControlDarkDark
    $sizePanel.Controls.Add($dualNoteLabel, 0, $row)
    $sizePanel.SetColumnSpan($dualNoteLabel, 2)

    $sizeGroup.Controls.Add($sizePanel)
    $dual.Controls.Add($sizeGroup)

    $cleanNotice = New-Object System.Windows.Forms.Label
    $cleanNotice.Text = 'These tools may help free up more shrinkable space:'
    $cleanNotice.AutoSize = $true
    $dual.Controls.Add($cleanNotice)

    $cleanPanel = New-Object System.Windows.Forms.FlowLayoutPanel
    $cleanPanel.Padding = 5
    $cleanPanel.AutoSize = $true

    $cleanButton = New-Object System.Windows.Forms.Button
    $cleanButton.Text = "Clean"
    $cleanButton.AutoSize = $true
    $cleanPanel.Controls.Add($cleanButton)

    $defragButton = New-Object System.Windows.Forms.Button
    $defragButton.Text = "Defrag"
    $defragButton.AutoSize = $true
    $cleanPanel.Controls.Add($defragButton)

    $parterButton = New-Object System.Windows.Forms.Button
    $parterButton.Text = "Partitions"
    $parterButton.AutoSize = $true
    $cleanPanel.Controls.Add($parterButton)

    $swapButton = New-Object System.Windows.Forms.Button
    $swapButton.Text = "Disable Swap"
    $swapButton.AutoSize = $true
    $cleanPanel.Controls.Add($swapButton)

    $treeButton = New-Object System.Windows.Forms.Button
    $treeButton.Text = "Disk Use"
    $treeButton.AutoSize = $true
    $cleanPanel.Controls.Add($treeButton)

    $dual.Controls.Add($cleanPanel)
    $outer.Controls.Add($dual)

    # Progress Panel
    $global:progress = New-Object System.Windows.Forms.TableLayoutPanel
    $progress.AutoSize = $true
    $progress.Dock = [System.Windows.Forms.DockStyle]::Fill
    $progress.Padding = 10
    $progress.ColumnCount = 1
    $progress.Visible = $false

    $statusPanel = New-Object System.Windows.Forms.TableLayoutPanel
    $statusPanel.AutoSize = $true
    $statusPanel.Dock = [System.Windows.Forms.DockStyle]::Fill
    $statusPanel.Padding = 5
    $statusPanel.ColumnCount = 2
    $row = 0

    $defragLabel = New-Object System.Windows.Forms.Label
    $defragLabel.Text = "Prepare / Defrag"
    $defragLabel.AutoSize = $true
    $global:defragStatus = New-Object System.Windows.Forms.Label
    $defragStatus.Text = "To Do"
    $defragStatus.AutoSize = $true
    $statusPanel.Controls.Add($defragLabel, 0, $row)
    $statusPanel.Controls.Add($defragStatus, 1, $row)
    $row++

    $partLabel = New-Object System.Windows.Forms.Label
    $partLabel.Text = "Re-Partition"
    $partLabel.AutoSize = $true
    $global:partStatus = New-Object System.Windows.Forms.Label
    $partStatus.Text = "To Do"
    $partStatus.AutoSize = $true
    $statusPanel.Controls.Add($partLabel, 0, $row)
    $statusPanel.Controls.Add($partStatus, 1, $row)
    $row++

    $dlLabel = New-Object System.Windows.Forms.Label
    $dlLabel.Text = "ISO / Staging"
    $dlLabel.AutoSize = $true
    $global:dlStatus = New-Object System.Windows.Forms.Label
    $dlStatus.Text = "To Do"
    $dlStatus.AutoSize = $true
    $statusPanel.Controls.Add($dlLabel, 0, $row)
    $statusPanel.Controls.Add($dlStatus, 1, $row)
    $row++

    $grubLabel = New-Object System.Windows.Forms.Label
    $grubLabel.Text = "Install Bootloader"
    $grubLabel.AutoSize = $true
    $global:grubStatus = New-Object System.Windows.Forms.Label
    $grubStatus.Text = "To Do"
    $grubStatus.AutoSize = $true
    $statusPanel.Controls.Add($grubLabel, 0, $row)
    $statusPanel.Controls.Add($grubStatus, 1, $row)
    $row++

    $rebootLabel = New-Object System.Windows.Forms.Label
    $rebootLabel.Text = "Reboot"
    $rebootLabel.AutoSize = $true
    $global:rebootStatus = New-Object System.Windows.Forms.Label
    $rebootStatus.Text = "To Do"
    $rebootStatus.AutoSize = $true
    $statusPanel.Controls.Add($rebootLabel, 0, $row)
    $statusPanel.Controls.Add($rebootStatus, 1, $row)
    $row++

    $progress.Controls.Add($statusPanel)
    $outer.Controls.Add($progress)

    # Button Panel
    $buttonPanel = New-Object System.Windows.Forms.FlowLayoutPanel
    $buttonPanel.Padding = 5
    $buttonPanel.AutoSize = $true

    $global:abortButton = New-Object System.Windows.Forms.Button
    $abortButton.Text = "Quit"
    $abortButton.AutoSize = $true
    $abortButton.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $buttonPanel.Controls.Add($abortButton)

    $global:uninstallButton = New-Object System.Windows.Forms.Button
    $uninstallButton.Text = "Cleanup / Uninstall"
    $uninstallButton.AutoSize = $true
    $buttonPanel.Controls.Add($uninstallButton)

    $global:installButton = New-Object System.Windows.Forms.Button
    $installButton.Text = "Continue"
    $installButton.AutoSize = $true
    $installButton.Enabled = $false
    $buttonPanel.Controls.Add($installButton)

    $outer.Controls.Add($buttonPanel)
    $Form.Controls.Add($outer)

    # Actions
    $Form.Add_Shown({
        $global:outer.Enabled = $false
        try {
            initFields
        } finally {
            if (-not $global:Form.IsDisposed) {
                $global:outer.Enabled = $true
                $global:Form.Activate()
                $dualBootRadio.Focus()
            }
        }
    })

    $distroName.Add_SelectedIndexChanged({
        Update-DistroSelectionUi
    })

    $browseIsoButton.Add_Click({
        $ofd = New-Object System.Windows.Forms.OpenFileDialog
        $ofd.Title = "Select Fedora or Linux ISO"
        $ofd.Filter = "ISO Images (*.iso)|*.iso|All Files (*.*)|*.*"
        if ($ofd.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
            Add-OrSelectLocalIso $ofd.FileName | Out-Null
            Update-DistroSelectionUi
        }
    })

    $refreshIsoButton.Add_Click({
        Refresh-DistroList
    })

    $agreeBox.Add_Click({
        $installButton.Enabled = $agreeBox.Checked
    })

    $uninstallButton.Add_Click({
        if (yes("Remove Tunic's EFI bootloader files, BCD entry, and any temporary TUNIC_BOOT partition?")) {
            $global:outer.Enabled = $false
            try {
                uninstall
                say("Tunic bootloader and temporary staging files cleaned up.")
            } catch {
                say("Cleanup encountered an error: $($_.Exception.Message)")
            } finally {
                $global:outer.Enabled = $true
            }
        }
    })

    $cleanButton.Add_Click({
        $global:outer.Enabled = $false
        try { clean; calcGui } finally { $global:outer.Enabled = $true }
    })

    $defragButton.Add_Click({
        $global:outer.Enabled = $false
        try {
            $minBytes = [long](Get-MinLinuxGBForSelectedDistro) * 1GB
            Try-ReclaimShrinkSpace $minBytes | Out-Null
            calcGui
        } finally { $global:outer.Enabled = $true }
    })

    $parterButton.Add_Click({
        $global:outer.Enabled = $false
        try { Start-Process diskmgmt.msc -Wait; calcGui } finally { $global:outer.Enabled = $true }
    })

    $swapButton.Add_Click({
        $global:outer.Enabled = $false
        try {
            disableSwap
            if (yes('Swap will be disabled on reboot. Reboot now?')) {
                Restart-Computer -Force
            }
        } finally {
            $global:outer.Enabled = $true
        }
    })

    $treeButton.Add_Click({
        $global:outer.Enabled = $false
        try { treeMap; calcGui } finally { $global:outer.Enabled = $true }
    })

    $dualBootRadio.Add_Click({ installTypeCheck })
    $fullBootRadio.Add_Click({ installTypeCheck })
    $customBootRadio.Add_Click({ installTypeCheck })

    $installButton.Add_Click({
        $global:data.username = $username.Text
        $global:data.fullname = $fullName.Text
        $global:data.hostname = $hostname.Text
        $global:data.password = $password.Text
        if ($dualBootRadio.Checked) {
            $global:data.installType = $DUALBOOT
        } elseif ($fullBootRadio.Checked) {
            $global:data.installType = $FULLBOOT
        } else {
            $global:data.installType = $CUSTOMBOOT
        }

        $selected = Get-SelectedDistro
        $global:data.iso_url = if ($selected) { $selected.url } else { '' }

        if (-not (checkFields)) { return }

        if ($main.Visible -and $dualBootRadio.Checked) {
            $main.Visible = $false
            $dual.Visible = $true
            $outer.Enabled = $false
            try {
                $global:installButton.Text = 'Install'
                [System.Windows.Forms.Application]::DoEvents()
                calcGui
            } finally {
                $outer.Enabled = $true
            }
            $linuxSize.Focus()
        } else {
            if ($global:data.installType -eq $FULLBOOT -and $selected.name -match 'Fedora') {
                $warnMsg = "Erase Entire Disk mode will create a temporary FAT32 boot partition (TUNIC_BOOT) and boot Fedora into RAM.`n`nNote: If Fedora's installer reports the target disk is busy, open a Terminal inside Fedora Live and run:`n  sudo umount /run/initramfs/live`n`nContinue?"
                if (-not (yes($warnMsg))) { return }
            }
            $global:main.Visible = $false
            $global:dual.Visible = $false
            $global:installButton.Visible = $false
            $global:uninstallButton.Visible = $false
            $global:progress.Visible = $true
            $global:abortButton.Visible = $false

            try {
                $global:dlStatus.Text = 'Preparing ISO...'
                [System.Windows.Forms.Application]::DoEvents()
                $isoPath = guiDownloadIso
                $meta = Inspect-LinuxIso $isoPath

                if ($meta.family -like 'fedora*') {
                    $stagingBytes = Get-StagingBytesForIso $meta.sizeBytes

                    if ($global:data.installType -eq $DUALBOOT) {
                        $global:data.linuxSize = [double]::Parse($global:linuxSize.Text)
                        $global:defragStatus.Text = 'In Progress'
                        [System.Windows.Forms.Application]::DoEvents()
                        defrag
                        $global:defragStatus.Text = 'Done'

                        $global:partStatus.Text = 'Shrinking C: & Creating TUNIC_BOOT'
                        [System.Windows.Forms.Application]::DoEvents()
                        repartition
                        $stagingDrive = New-FedoraStagingPartition $stagingBytes
                        $global:partStatus.Text = "Done ($stagingDrive)"
                    } else {
                        $global:defragStatus.Text = 'In Progress'
                        [System.Windows.Forms.Application]::DoEvents()
                        defrag
                        $global:defragStatus.Text = 'Done'

                        $global:partStatus.Text = 'Creating TUNIC_BOOT'
                        [System.Windows.Forms.Application]::DoEvents()
                        $stagingDrive = New-FedoraStagingPartition $stagingBytes
                        $global:partStatus.Text = "Done ($stagingDrive)"
                    }

                    $global:dlStatus.Text = 'Copying ISO to TUNIC_BOOT...'
                    [System.Windows.Forms.Application]::DoEvents()
                    Copy-IsoToStaging $isoPath $stagingDrive $meta
                    $global:dlStatus.Text = 'Done'

                    $global:grubStatus.Text = 'Installing Fedora Secure Boot EFI...'
                    [System.Windows.Forms.Application]::DoEvents()
                    Install-FedoraBootloader $stagingDrive $meta
                    $global:grubStatus.Text = 'Done'
                } elseif ($meta.family -eq 'casper') {
                    if ($global:data.installType -eq $DUALBOOT) {
                        $global:data.linuxSize = [double]::Parse($global:linuxSize.Text)
                        $global:defragStatus.Text = 'In Progress'
                        [System.Windows.Forms.Application]::DoEvents()
                        defrag
                        $global:defragStatus.Text = 'Done'

                        $global:partStatus.Text = 'In Progress'
                        [System.Windows.Forms.Application]::DoEvents()
                        repartition
                        $global:partStatus.Text = 'Done'
                    } else {
                        $global:defragStatus.Text = 'Skipped'
                        $global:partStatus.Text = 'Skipped'
                    }

                    $global:dlStatus.Text = 'Done'
                    $global:grubStatus.Text = 'In Progress'
                    [System.Windows.Forms.Application]::DoEvents()
                    installGrub $isoPath
                    $global:grubStatus.Text = 'Done'
                } else {
                    throw "Unsupported ISO format in $isoPath"
                }

                if ($global:NoReboot) {
                    $global:rebootStatus.Text = 'Skipped (-NoReboot)'
                    $global:abortButton.Text = 'Close'
                    $global:abortButton.Visible = $true
                    say("Staging complete! Reboot skipped because -NoReboot was specified.")
                } else {
                    $global:rebootStatus.Text = 'Rebooting...'
                    [System.Windows.Forms.Application]::DoEvents()
                    Restart-Computer -Force
                }
            } catch {
                $global:abortButton.Text = 'Close'
                $global:abortButton.Visible = $true
                say("Installation failed: $($_.Exception.Message)")
            }
        }
    })

    return $Form
}

function hideConsole() {
    Add-Type -Name Window -Namespace Console -MemberDefinition '
        [DllImport("Kernel32.dll")]
        public static extern IntPtr GetConsoleWindow();

        [DllImport("user32.dll")]
        public static extern bool ShowWindow(IntPtr hWnd, Int32 nCmdShow);
    '
    $consoleWin = [Console.Window]::GetConsoleWindow()
    [void][Console.Window]::ShowWindow($consoleWin, 6)
}

function uninstall() {
    if (-not (Test-IsAdmin)) {
        Write-Host 'Must be an Administrator'
        exit 1
    }

    if (Test-Path -LiteralPath "${global:tunic_dir}\bcd.id") {
        $osloader = (Get-Content -LiteralPath "${global:tunic_dir}\bcd.id" | Select-Object -First 1).Trim()
        if ($osloader) {
            bcdedit /delete "$osloader" /cleanup /f | Out-Null
        }
    }

    $efi = Get-FreeDriveLetter
    mountvol $efi /s
    try {
        if (Test-Path -LiteralPath "${efi}\EFI\tunic") {
            Remove-Item -LiteralPath "${efi}\EFI\tunic" -Recurse -Force
        }
        $espBootGrubCfg = "${efi}\EFI\BOOT\grub.cfg"
        $espBootBackup = "${efi}\EFI\BOOT\grub.tunic.bak"
        if (Test-Path -LiteralPath $espBootBackup) {
            Move-Item -LiteralPath $espBootBackup -Destination $espBootGrubCfg -Force
        } elseif (Test-Path -LiteralPath $espBootGrubCfg) {
            $cfg = Get-Content -LiteralPath $espBootGrubCfg -Raw -ErrorAction SilentlyContinue
            if ($cfg -match '^# Tunic Linux Installer') {
                Remove-Item -LiteralPath $espBootGrubCfg -Force
            }
        }
        if (Test-Path -LiteralPath "${efi}\boot") {
            Remove-Item -LiteralPath "${efi}\boot" -Recurse -Force -ErrorAction SilentlyContinue
        }
    } finally {
        mountvol $efi /d | Out-Null
    }

    # Remove temporary TUNIC_BOOT partition if present
    $stagingParts = Get-Volume -FileSystemLabel $global:STAGING_LABEL -ErrorAction SilentlyContinue | Get-Partition -ErrorAction SilentlyContinue
    if ($stagingParts) {
        foreach ($p in $stagingParts) {
            Remove-Partition -DiskNumber $p.DiskNumber -PartitionNumber $p.PartitionNumber -Confirm:$false
        }
    }

    if (Test-Path -LiteralPath "${global:tunic_dir}") {
        Remove-Item -LiteralPath "${global:tunic_dir}" -Recurse -Force
    }
}

# Installs full disk install (CLI test helper)
function fullDisk() {
    initData
    $global:data.installType = $FULLBOOT
    $global:data.password = 'tunic'
    $iso_path = downloadIso
    $meta = Inspect-LinuxIso $iso_path
    if ($meta.family -like 'fedora*') {
        $stagingBytes = Get-StagingBytesForIso $meta.sizeBytes
        $stagingDrive = New-FedoraStagingPartition $stagingBytes
        Copy-IsoToStaging $iso_path $stagingDrive $meta
        Install-FedoraBootloader $stagingDrive $meta
    } else {
        installGrub $iso_path
    }
    if (-not $global:NoReboot) {
        Write-Host 'Restarting...'
        Restart-Computer -Force
    }
}

switch ($op) {
    "download-iso" {
        initData
        downloadIso | Out-Null
    }
    "enable-swap" {
        enableSwap
    }
    "disable-swap" {
        disableSwap
    }
    "install-grub" {
        initData
        $iso = downloadIso
        installGrub $iso
    }
    "tz" {
        getLinuxTimeZone
    }
    "full-disk" {
        fullDisk
    }
    "defrag" {
        defrag
    }
    "inspect" {
        if (-not $global:CliIsoPath) {
            Write-Error "Usage: tunic.ps1 inspect <path-to-iso>"
            exit 1
        }
        $meta = Inspect-LinuxIso $global:CliIsoPath
        $meta | Format-Table -AutoSize
    }
    "preseed" {
        initData
        Set-Content -Value (expandTemplate "files\preseed.cfg") -Path "preseed.tmp.cfg"
        Get-Content -Path 'preseed.tmp.cfg'
        Remove-Item 'preseed.tmp.cfg'
    }
    "hidden" {
        hideConsole
        $global:form = gui
        [void]$global:form.ShowDialog()
    }
    "uninstall" {
        uninstall
    }
    default {
        $global:form = gui
        [void]$global:form.ShowDialog()
    }
}
