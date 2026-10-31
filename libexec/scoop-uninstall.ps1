# Usage: scoop uninstall <app> [options]
# Summary: Uninstall an app
# Help: e.g. scoop uninstall git
#
# To uninstall a portable installation:
#      scoop uninstall --portable 7zip@26.05
#
# Options:
#   -g, --global              Uninstall a globally installed app
#   -p, --purge               Remove all persistent data
#   --portable <app@version>  Uninstall a specific portable installation (requires app@version format)

. "$PSScriptRoot\..\lib\getopt.ps1"
. "$PSScriptRoot\..\lib\manifest.ps1" # 'Get-Manifest' 'Select-CurrentVersion' (indirectly)
. "$PSScriptRoot\..\lib\system.ps1"
. "$PSScriptRoot\..\lib\install.ps1"
. "$PSScriptRoot\..\lib\download.ps1" # url_filename
. "$PSScriptRoot\..\lib\shortcuts.ps1"
. "$PSScriptRoot\..\lib\psmodules.ps1"
. "$PSScriptRoot\..\lib\versions.ps1" # 'Select-CurrentVersion'

# options
$opt, $apps, $err = getopt $args 'gp' 'global', 'purge', 'portable='

if ($err) {
    error "scoop uninstall: $err"
    exit 1
}

$global = $opt.g -or $opt.global
$purge = $opt.p -or $opt.purge
$portableSpec = $opt.portable

# Handle portable uninstall first (doesn't need app in normal Scoop)
if ($portableSpec) {
    $portableApp, $null, $portableVersion = parse_app $portableSpec
    if (!$portableVersion) {
        error "Portable uninstall requires app@version format (e.g., 7zip@26.05)"
        exit 1
    }

    if (!$portabledir) {
        error "Portable directory not configured. Set SCOOP_PORTABLE environment variable or run 'scoop config PORTABLE_PATH <path>'"
        exit 1
    }

    $portableRoot = portableappdir $portableApp $portableVersion
    if (!(Test-Path $portableRoot)) {
        error "'$portableApp' ($portableVersion) is not installed in portable mode."
        exit 1
    }

    Write-Host "Uninstalling portable '$portableApp' ($portableVersion)."

    $dir = portableappsubdir $portableApp $portableVersion
    $scoopMetadataDir = portablescoopdir $portableApp $portableVersion

    # Load manifest and install info from portable metadata location
    $manifest = installed_manifest $portableApp $portableVersion $false $true
    $install = install_info $portableApp $portableVersion $false $true
    $architecture = $install.architecture

    Invoke-HookScript -HookType 'pre_uninstall' -Manifest $manifest -Arch $architecture

    # Check for running processes in the portable app directory
    $running_processes = Get-Process | Where-Object { $_.Path -like "$portableRoot\*" } | Out-String
    if ($running_processes) {
        if (get_config IGNORE_RUNNING_PROCESSES) {
            warn "The following instances of `"$portableApp`" are still running. Scoop is configured to ignore this condition."
            Write-Host $running_processes
        } else {
            error "The following instances of `"$portableApp`" are still running. Close them and try again."
            Write-Host $running_processes
            exit 1
        }
    }

    # Run uninstaller if present
    Invoke-Installer -Path $dir -Manifest $manifest -ProcessorArchitecture $architecture -Global:$false -Uninstall

    # Portable installations have no system integration to clean up (no shims, shortcuts, env vars)

    # Remove the entire portable app directory
    # Try multiple approaches as files may be locked temporarily
    $removed = $false
    $maxAttempts = 3

    for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
        try {
            # First try to remove read-only attributes that might block deletion
            Get-ChildItem $portableRoot -Recurse -Force -ErrorAction SilentlyContinue | ForEach-Object {
                if ($_.Attributes -band [System.IO.FileAttributes]::ReadOnly) {
                    $_.Attributes = $_.Attributes -bxor [System.IO.FileAttributes]::ReadOnly
                }
            }

            Remove-Item $portableRoot -Recurse -Force -ErrorAction Stop
            $removed = $true
            break
        } catch {
            if ($attempt -lt $maxAttempts) {
                warn "Removal attempt $attempt failed, retrying..."
                Start-Sleep -Milliseconds 500
            } else {
                error "Couldn't remove '$(friendly_path $portableRoot)' after $maxAttempts attempts."
                error "Error: $($_.Exception.Message)"
                error "Try closing any programs that might be using files in this directory."
                exit 1
            }
        }
    }

    if ($removed) {
        success "'$portableApp' ($portableVersion) was uninstalled."
    }

    Invoke-HookScript -HookType 'post_uninstall' -Manifest $manifest -Arch $architecture
    exit 0
}

# For normal uninstall, require app argument
if (!$apps) {
    error '<app> missing'
    my_usage
    exit 1
}

if ($global -and !(is_admin)) {
    error 'You need admin rights to uninstall global apps.'
    exit 1
}

if ($apps -eq 'scoop') {
    & "$PSScriptRoot\..\bin\uninstall.ps1" $global $purge
    exit
}

$apps = Confirm-InstallationStatus $apps -Global:$global
if (!$apps) { exit 0 }

:app_loop foreach ($_ in $apps) {
    ($app, $global) = $_

    $version = Select-CurrentVersion -AppName $app -Global:$global
    $appDir = appdir $app $global
    if ($version) {
        Write-Host "Uninstalling '$app' ($version)."

        $dir = versiondir $app $version $global
        $persist_dir = persistdir $app $global

        $manifest = installed_manifest $app $version $global
        $install = install_info $app $version $global
        $architecture = $install.architecture
        $bucket = $install.bucket

        Invoke-HookScript -HookType 'pre_uninstall' -Manifest $manifest -Arch $architecture

        #region Workaround for #2952
        if (test_running_process $app $global) {
            continue
        }
        #endregion Workaround for #2952

        try {
            Test-Path $dir -ErrorAction Stop | Out-Null
        } catch [UnauthorizedAccessException] {
            error "Access denied: $dir. You might need to restart."
            continue
        }

        Invoke-Installer -Path $dir -Manifest $manifest -ProcessorArchitecture $architecture -Global:$global -Uninstall
        rm_shims $app $manifest $global $architecture
        rm_startmenu_shortcuts $manifest $global $architecture

        # If a junction was used during install, that will have been used
        # as the reference directory. Otherwise it will just be the version
        # directory.
        $refdir = unlink_current $dir

        uninstall_psmodule $manifest $refdir $global

        env_rm_path $manifest $refdir $global $architecture
        env_rm $manifest $global $architecture

        try {
            # unlink all potential old link before doing recursive Remove-Item
            unlink_persist_data $manifest $dir
            Remove-Item $dir -Recurse -Force -ErrorAction Stop
        } catch {
            if (Test-Path $dir) {
                error "Couldn't remove '$(friendly_path $dir)'; it may be in use."
                continue
            }
        }

        Invoke-HookScript -HookType 'post_uninstall' -Manifest $manifest -Arch $architecture
    }
    # Remove older versions only for normal installations
    # Portable installations are version-specific - don't remove other versions
    if (!$portableSpec) {
        $oldVersions = @(Get-ChildItem $appDir -Name -Exclude 'current')
        foreach ($version in $oldVersions) {
            Write-Host "Removing older version ($version)."
            $dir = versiondir $app $version $global
            try {
                # unlink all potential old link before doing recursive Remove-Item
                unlink_persist_data $manifest $dir
                Remove-Item $dir -Recurse -Force -ErrorAction Stop
            } catch {
                error "Couldn't remove '$(friendly_path $dir)'; it may be in use."
                continue app_loop
            }
        }
    }
    if (Test-Path ($currentDir = Join-Path $appDir 'current')) {
        attrib $currentDir -R /L
        Remove-Item $currentDir -ErrorAction Stop -Force
    }
    if (!(Get-ChildItem $appDir)) {
        try {
            # if last install failed, the directory seems to be locked and this
            # will throw an error about the directory not existing
            Remove-Item $appdir -Recurse -Force -ErrorAction Stop
        } catch {
            if ((Test-Path $appdir)) { throw } # only throw if the dir still exists
        }
    }

    # purge persistent data
    if ($purge) {
        Write-Host 'Removing persisted data.'
        $persist_dir = persistdir $app $global

        if (Test-Path $persist_dir) {
            try {
                Remove-Item $persist_dir -Recurse -Force -ErrorAction Stop
            } catch {
                error "Couldn't remove '$(friendly_path $persist_dir)'; it may be in use."
                continue
            }
        }
    }

    success "'$app' was uninstalled."
}

exit 0
