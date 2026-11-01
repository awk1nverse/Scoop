# Usage: scoop update <app> [options]
# Summary: Update apps, or Scoop itself
# Help: 'scoop update' updates Scoop to the latest version.
# 'scoop update <app>' installs a new version of that app, if there is one.
#
# You can use '*' in place of <app> to update all apps.
#
# Options:
#   -f, --force            Force update even when there isn't a newer version
#   -g, --global           Update a globally installed app
#   -i, --independent      Don't install dependencies automatically
#   -k, --no-cache         Don't use the download cache
#   -s, --skip-hash-check  Skip hash validation (use with caution!)
#   -q, --quiet            Hide extraneous messages
#   -a, --all              Update all apps (alternative to '*')
#   -p, --portable         Update portable installation (refreshes packaging)

. "$PSScriptRoot\..\lib\getopt.ps1"
. "$PSScriptRoot\..\lib\json.ps1" # 'save_install_info' in 'manifest.ps1' (indirectly)
. "$PSScriptRoot\..\lib\system.ps1"
. "$PSScriptRoot\..\lib\shortcuts.ps1"
. "$PSScriptRoot\..\lib\psmodules.ps1"
. "$PSScriptRoot\..\lib\decompress.ps1"
. "$PSScriptRoot\..\lib\manifest.ps1"
. "$PSScriptRoot\..\lib\versions.ps1"
. "$PSScriptRoot\..\lib\depends.ps1"
. "$PSScriptRoot\..\lib\install.ps1"
. "$PSScriptRoot\..\lib\download.ps1"
if (get_config USE_SQLITE_CACHE) {
    . "$PSScriptRoot\..\lib\database.ps1"
}

$opt, $apps, $err = getopt $args 'gfiksqap' 'global', 'force', 'independent', 'no-cache', 'skip-hash-check', 'quiet', 'all', 'portable'
if ($err) { error "scoop update: $err"; exit 1 }
$global = $opt.g -or $opt.global
$force = $opt.f -or $opt.force
$check_hash = !($opt.s -or $opt.'skip-hash-check')
$use_cache = !($opt.k -or $opt.'no-cache')
$quiet = $opt.q -or $opt.quiet
$independent = $opt.i -or $opt.independent
$all = $opt.a -or $opt.all
$portable = $opt.p -or $opt.portable

# load config
$configRepo = get_config SCOOP_REPO
if (!$configRepo) {
    $configRepo = 'https://github.com/ScoopInstaller/Scoop'
    set_config SCOOP_REPO $configRepo | Out-Null
}

# Find current update channel from config
$configBranch = get_config SCOOP_BRANCH
if (!$configBranch) {
    $configBranch = 'master'
    set_config SCOOP_BRANCH $configBranch | Out-Null
}

if (($PSVersionTable.PSVersion.Major) -lt 5) {
    # check powershell version
    Write-Output 'PowerShell 5 or later is required to run Scoop.'
    Write-Output 'Upgrade PowerShell: https://docs.microsoft.com/en-us/powershell/scripting/install/installing-powershell-core-on-windows'
    break
}
$show_update_log = get_config SHOW_UPDATE_LOG $true

function Sync-Scoop {
    [CmdletBinding()]
    Param (
        [Switch]$Log
    )
    # Test if Scoop Core is hold
    if (Test-ScoopCoreOnHold) {
        return
    }

    # check for git
    if (!(Test-GitAvailable)) { abort "Scoop uses Git to update itself. Run 'scoop install git' and try again." }

    Write-Host 'Updating Scoop...'
    $currentdir = versiondir 'scoop' 'current'
    if (!(Test-Path "$currentdir\.git")) {
        $newdir = "$currentdir\..\new"
        $olddir = "$currentdir\..\old"

        # get git scoop
        Invoke-Git -ArgumentList @('clone', '-q', $configRepo, '--branch', $configBranch, '--single-branch', $newdir)

        # check if scoop was successful downloaded
        if (!(Test-Path "$newdir\bin\scoop.ps1")) {
            Remove-Item $newdir -Force -Recurse
            abort "Scoop download failed. If this appears several times, try removing SCOOP_REPO by 'scoop config rm SCOOP_REPO'"
        } else {
            # replace non-git scoop with the git version
            try {
                Rename-Item $currentdir 'old' -ErrorAction Stop
                Rename-Item $newdir 'current' -ErrorAction Stop
            } catch {
                Write-Warning $_
                abort "Scoop update failed. Folder in use. Please rename folders $currentdir to ``old`` and $newdir to ``current``."
            }
        }
    } else {
        if (Test-Path "$currentdir\..\old") {
            Remove-Item "$currentdir\..\old" -Recurse -Force -ErrorAction SilentlyContinue
        }

        $previousCommit = Invoke-Git -Path $currentdir -ArgumentList @('rev-parse', 'HEAD')
        $currentRepo = Invoke-Git -Path $currentdir -ArgumentList @('config', 'remote.origin.url')
        $currentBranch = Invoke-Git -Path $currentdir -ArgumentList @('branch')

        $isRepoChanged = !($currentRepo -match $configRepo)
        $isBranchChanged = !($currentBranch -match "\*\s+$configBranch")

        # Stash uncommitted changes
        if (Invoke-Git -Path $currentdir -ArgumentList @('diff', 'HEAD', '--name-only')) {
            if (get_config AUTOSTASH_ON_CONFLICT) {
                warn 'Uncommitted changes detected. Stashing...'
                Invoke-Git -Path $currentdir -ArgumentList @('stash', 'push', '-m', "WIP at $([System.DateTime]::Now.ToString('o'))", '-u', '-q')
            } else {
                warn 'Uncommitted changes detected. Update aborted.'
                return
            }
        }

        # Change remote url if the repo is changed
        if ($isRepoChanged) {
            Invoke-Git -Path $currentdir -ArgumentList @('config', 'remote.origin.url', $configRepo)
        }

        # Fetch and reset local repo if the repo or the branch is changed
        if ($isRepoChanged -or $isBranchChanged) {
            # Reset git fetch refs, so that it can fetch all branches (GH-3368)
            Invoke-Git -Path $currentdir -ArgumentList @('config', 'remote.origin.fetch', '+refs/heads/*:refs/remotes/origin/*')
            # fetch remote branch
            Invoke-Git -Path $currentdir -ArgumentList @('fetch', '--force', 'origin', "refs/heads/$configBranch`:refs/remotes/origin/$configBranch", '-q')
            # checkout and track the branch
            Invoke-Git -Path $currentdir -ArgumentList @('checkout', '-B', $configBranch, '-t', "origin/$configBranch", '-q')
            # reset branch HEAD
            Invoke-Git -Path $currentdir -ArgumentList @('reset', '--hard', "origin/$configBranch", '-q')
        } else {
            Invoke-Git -Path $currentdir -ArgumentList @('pull', '--tags', '--force', '-q')
        }

        $res = $lastexitcode
        if ($Log) {
            Invoke-GitLog -Path $currentdir -CommitHash $previousCommit
        }

        if ($res -ne 0) {
            abort 'Update failed.'
        }
    }

    shim "$currentdir\bin\scoop.ps1" $false
}

function Sync-Bucket {
    Param (
        [Switch]$Log
    )
    Write-Host 'Updating Buckets...'

    if (!(Test-Path (Join-Path (Find-BucketDirectory 'main' -Root) '.git'))) {
        info "Converting 'main' bucket to git repo..."
        $status = rm_bucket 'main'
        if ($status -ne 0) {
            abort "Failed to remove local 'main' bucket."
        }
        $status = add_bucket 'main' (known_bucket_repo 'main')
        if ($status -ne 0) {
            abort "Failed to add remote 'main' bucket."
        }
    }


    $buckets = Get-LocalBucket | ForEach-Object {
        $path = Find-BucketDirectory $_ -Root
        return @{
            name  = $_
            valid = Test-Path (Join-Path $path '.git')
            path  = $path
        }
    }

    $buckets | Where-Object { !$_.valid } | ForEach-Object { Write-Host "'$($_.name)' is not a git repository. Skipped." }

    $updatedFiles = [System.Collections.ArrayList]::Synchronized([System.Collections.ArrayList]::new())
    $removedFiles = [System.Collections.ArrayList]::Synchronized([System.Collections.ArrayList]::new())
    if ($PSVersionTable.PSVersion.Major -ge 7) {
        # Parallel parameter is available since PowerShell 7
        $buckets | Where-Object { $_.valid } | ForEach-Object -ThrottleLimit 5 -Parallel {
            . "$using:PSScriptRoot\..\lib\core.ps1"
            . "$using:PSScriptRoot\..\lib\buckets.ps1"

            $name = $_.name
            $bucketLoc = $_.path
            $innerBucketLoc = Find-BucketDirectory $name

            $previousCommit = Invoke-Git -Path $bucketLoc -ArgumentList @('rev-parse', 'HEAD')
            Invoke-Git -Path $bucketLoc -ArgumentList @('pull', '-q')
            if ($using:Log) {
                Invoke-GitLog -Path $bucketLoc -Name $name -CommitHash $previousCommit
            }
            if (get_config USE_SQLITE_CACHE) {
                Invoke-Git -Path $bucketLoc -ArgumentList @('diff', '--name-status', $previousCommit) | ForEach-Object {
                    $status, $file = $_ -split '\s+', 2
                    $filePath = Join-Path $bucketLoc $file
                    if ($filePath -match "^$([regex]::Escape($innerBucketLoc)).*\.json$") {
                        switch ($status) {
                            { $_ -in 'A', 'M', 'R' } {
                                [void]($using:updatedFiles).Add($filePath)
                            }
                            'D' {
                                [void]($using:removedFiles).Add([pscustomobject]@{
                                        Name   = ([System.IO.FileInfo]$file).BaseName
                                        Bucket = $name
                                    })
                            }
                        }
                    }
                }
            }
        }
    } else {
        $buckets | Where-Object { $_.valid } | ForEach-Object {
            $name = $_.name
            $bucketLoc = $_.path
            $innerBucketLoc = Find-BucketDirectory $name

            $previousCommit = Invoke-Git -Path $bucketLoc -ArgumentList @('rev-parse', 'HEAD')
            Invoke-Git -Path $bucketLoc -ArgumentList @('pull', '-q')
            if ($Log) {
                Invoke-GitLog -Path $bucketLoc -Name $name -CommitHash $previousCommit
            }
            if (get_config USE_SQLITE_CACHE) {
                Invoke-Git -Path $bucketLoc -ArgumentList @('diff', '--name-status', $previousCommit) | ForEach-Object {
                    $status, $file = $_ -split '\s+', 2
                    $filePath = Join-Path $bucketLoc $file
                    if ($filePath -match "^$([regex]::Escape($innerBucketLoc)).*\.json$") {
                        switch ($status) {
                            { $_ -in 'A', 'M', 'R' } {
                                [void]($updatedFiles).Add($filePath)
                            }
                            'D' {
                                [void]($removedFiles).Add([pscustomobject]@{
                                        Name   = ([System.IO.FileInfo]$file).BaseName
                                        Bucket = $name
                                    })
                            }
                        }
                    }
                }
            }
        }
    }
    if ((get_config USE_SQLITE_CACHE) -and ($updatedFiles.Count -gt 0 -or $removedFiles.Count -gt 0)) {
        info 'Updating cache...'
        Set-ScoopDB -Path $updatedFiles
        $removedFiles | Remove-ScoopDBItem
    }
}

# Portable-Launcher: Update portable installation with revision tracking
function update_portable($app, $version, $force = $false, $quiet = $false, $use_cache = $true, $check_hash = $true) {
    if (!$portabledir) {
        error "Portable directory not configured. Set SCOOP_PORTABLE environment variable or run 'scoop config PORTABLE_PATH <path>'"
        return
    }

    $portableRoot = portableappdir $app $version
    if (!(Test-Path $portableRoot)) {
        error "'$app' ($version) is not installed in portable mode at '$(friendly_path $portableRoot)'."
        return
    }

    # Load old installation info
    $install = install_info $app $version $false $true
    $old_manifest = installed_manifest $app $version $false $true

    # Get installed revision (default to 1 for backward compatibility)
    $old_revision = if ($install.portable_revision) { $install.portable_revision } else { 1 }

    # Re-use architecture, bucket and url from original install
    $architecture = Format-ArchitectureString $install.architecture
    $bucket = $install.bucket
    $url = $install.url

    if ($null -eq $bucket -and !$url) { $bucket = 'main' }
    $manifest = manifest $app $bucket $url

    if (!$manifest) {
        error "No manifest available for '$app'."
        return
    }

    # Get new revision from manifest
    $new_revision = Get-PortableRevision $manifest
    $manifest_version = $manifest.version

    # Check if update is needed
    if (!$force -and ($manifest_version -eq $version) -and ($new_revision -le $old_revision)) {
        if (!$quiet) {
            warn "The latest version of '$app' ($version rev $old_revision) is already installed."
        }
        return
    }

    if ($manifest_version -ne $version) {
        error "Cannot update portable installation: version mismatch. Installed: $version, Available: $manifest_version"
        error "Portable revision updates work only when the app version stays the same."
        error "To install a different version, use: scoop install $app@$manifest_version -p"
        return
    }

    Write-Host "Updating '$app' (portable) ($version rev $old_revision -> rev $new_revision)"

    # Check for running processes
    $running_processes = Get-Process | Where-Object { $_.Path -like "$portableRoot\*" } | Out-String
    if ($running_processes) {
        if (get_config IGNORE_RUNNING_PROCESSES) {
            warn "The following instances of `"$app`" are still running. Scoop is configured to ignore this condition."
            Write-Host $running_processes
        } else {
            error "The following instances of `"$app`" are still running. Close them and try again."
            Write-Host $running_processes
            return
        }
    }

    $dir = portableappsubdir $app $version
    $persist_dir = portabledatadir $app $version

    Invoke-HookScript -HookType 'pre_uninstall' -Manifest $old_manifest -Arch $architecture

    Write-Host "Uninstalling old portable version ($version rev $old_revision)"
    Invoke-Installer -Path $dir -Manifest $old_manifest -ProcessorArchitecture $architecture -Global:$false -Uninstall

    # Remove App directory contents but keep Data and Other\Scoop
    Write-Host "Removing old app files"
    if (Test-Path $dir) {
        Remove-Item $dir -Recurse -Force -ErrorAction SilentlyContinue
    }

    Invoke-HookScript -HookType 'post_uninstall' -Manifest $old_manifest -Arch $architecture

    # Reinstall with new revision
    Write-Host "Installing new portable version ($version rev $new_revision)"

    # Ensure App directory exists
    ensure $dir | Out-Null

    # Download and extract
    $fname = Invoke-ScoopDownload $app $version $manifest $bucket $architecture $dir $use_cache $check_hash
    Invoke-Extraction -Path $dir -Name $fname -Manifest $manifest -ProcessorArchitecture $architecture
    Invoke-HookScript -HookType 'pre_install' -Manifest $manifest -ProcessorArchitecture $architecture
    Invoke-Installer -Path $dir -Name $fname -Manifest $manifest -ProcessorArchitecture $architecture -AppName $app -Global:$false

    # Restore persist data (Data directory already exists with user data)
    $original_dir = $dir
    persist_data $manifest $original_dir $persist_dir

    Invoke-HookScript -HookType 'post_install' -Manifest $manifest -ProcessorArchitecture $architecture

    # Update metadata with new revision
    save_installed_manifest $app $bucket $portableRoot $url $true
    save_install_info @{
        'architecture' = $architecture
        'url' = $url
        'bucket' = $bucket
        'portable' = $true
        'portable_revision' = $new_revision
    } $portableRoot $true

    success "'$app' ($version) was updated successfully to revision $new_revision!"
}

function update($app, $global, $force = $false, $quiet = $false, $independent, $suggested, $use_cache = $true, $check_hash = $true) {
    $old_version = Select-CurrentVersion -AppName $app -Global:$global
    $old_manifest = installed_manifest $app $old_version $global
    $install = install_info $app $old_version $global

    # re-use architecture, bucket and url from first install
    $architecture = Format-ArchitectureString $install.architecture
    $bucket = $install.bucket
    $url = $install.url

    # -f on an @version pin re-resolves against the bucket HEAD
    $pin_broken = $force -and $null -eq $bucket -and ($url -eq (usermanifest $app))
    if ($pin_broken) {
        $scanned, $bucket = Find-AppBucket $app
        if ($scanned) {
            $manifest = $scanned
            $url = $null
        } else {
            $manifest = manifest $app $null $url
        }
    } else {
        if ($null -eq $bucket -and !$url) { $bucket = 'main' }
        $manifest = manifest $app $bucket $url
    }
    $version = $manifest.version
    $is_nightly = $version -eq 'nightly'
    if ($is_nightly) {
        $version = nightly_version $quiet
        $check_hash = $false
    }

    if (!$force -and ($old_version -eq $version)) {
        if (!$quiet) {
            warn "The latest version of '$app' ($version) is already installed."
        }
        return
    }
    if (!$version) {
        # installed from a custom bucket/no longer supported
        error "No manifest available for '$app'."
        return
    }

    Write-Host "Updating '$app' ($old_version -> $version)"

    #region Workaround for #2952
    if (test_running_process $app $global) {
        Write-Host 'Running process detected, skip updating.'
        return
    }
    #endregion Workaround for #2952

    # region Workaround
    # Workaround for https://github.com/ScoopInstaller/Scoop/issues/2220 until install is refactored
    # Remove and replace whole region after proper fix
    Write-Host 'Downloading new version'
    if (Test-Aria2Enabled) {
        Invoke-CachedAria2Download $app $version $manifest $architecture $cachedir $manifest.cookie $true $check_hash
    } else {
        $urls = script:url $manifest $architecture

        foreach ($url in $urls) {
            Invoke-CachedDownload $app $version $url $null $manifest.cookie $true

            if ($check_hash) {
                $manifest_hash = hash_for_url $manifest $url $architecture
                $source = cache_path $app $version $url
                $ok, $err = check_hash $source $manifest_hash $(show_app $app $bucket)

                if (!$ok) {
                    error $err
                    if (Test-Path $source) {
                        # rm cached file
                        Remove-Item -Force $source
                    }
                    if ($url.Contains('sourceforge.net')) {
                        Write-Host -f yellow 'SourceForge.net is known for causing hash validation fails. Please try again before opening a ticket.'
                    }
                    abort $(new_issue_msg $app $bucket 'hash check failed')
                }
            }
        }
    }
    # There is no need to check hash again while installing
    $check_hash = $false
    # endregion Workaround

    $dir = versiondir $app $old_version $global
    $persist_dir = persistdir $app $global

    Invoke-HookScript -HookType 'pre_uninstall' -Manifest $old_manifest -Arch $architecture

    Write-Host "Uninstalling '$app' ($old_version)"
    Invoke-Installer -Path $dir -Manifest $old_manifest -ProcessorArchitecture $architecture -Global:$global -Uninstall
    rm_shims $app $old_manifest $global $architecture

    # If a junction was used during install, that will have been used
    # as the reference directory. Otherwise it will just be the version
    # directory.
    $refdir = unlink_current $dir
    uninstall_psmodule $old_manifest $refdir $global
    env_rm_path $old_manifest $refdir $global $architecture
    env_rm $old_manifest $global $architecture

    if ($force -and ($old_version -eq $version)) {
        if (!(Test-Path "$dir/../_$version.old")) {
            Move-Item "$dir" "$dir/../_$version.old"
        } else {
            $i = 1
            While (Test-Path "$dir/../_$version.old($i)") {
                $i++
            }
            Move-Item "$dir" "$dir/../_$version.old($i)"
        }
    }

    Invoke-HookScript -HookType 'post_uninstall' -Manifest $old_manifest -Arch $architecture

    if ($bucket) {
        # add bucket name it was installed from
        $app = "$bucket/$app"
    }
    if ($install.url -and (!$pin_broken -or !$bucket)) {
        # use the url of the install json if the application was installed through url
        $app = $install.url
    }

    if ($independent) {
        install_app $app $architecture $global $suggested $use_cache $check_hash
    } else {
        # Also add missing dependencies
        $apps = @(Get-Dependency $app $architecture) -ne $app
        $apps.Where({ !(installed $_) }) + $app | ForEach-Object { install_app $_ $architecture $global $suggested $use_cache $check_hash }
    }
}

if (-not ($apps -or $all)) {
    if ($global) {
        error 'scoop update: --global is invalid when <app> is not specified.'
        exit 1
    }
    if (!$use_cache) {
        error 'scoop update: --no-cache is invalid when <app> is not specified.'
        exit 1
    }
    Sync-Scoop -Log:$show_update_log
    Sync-Bucket -Log:$show_update_log
    set_config LAST_UPDATE ([System.DateTime]::Now.ToString('o')) | Out-Null
    success 'Scoop was updated successfully!'
} else {
    if ($global -and !(is_admin)) {
        error 'You need admin rights to update global apps.'; exit 1
    }

    # Portable-Launcher: Handle portable updates separately
    if ($portable) {
        if (!$apps) {
            error 'scoop update: <app> required when using --portable'
            exit 1
        }

        if ($apps -eq '*' -or $all) {
            error 'scoop update: wildcard updates not supported for portable installations'
            exit 1
        }

        # Parse app and optional version
        $apps | ForEach-Object {
            $app, $null, $version = parse_app $_

            # Find all installed versions of this app in portable mode
            if (!$portabledir -or !(Test-Path $portabledir)) {
                error "Portable directory not configured or doesn't exist."
                exit 1
            }

            $sanitizedApp = sanitary_path $app
            $pattern = "${sanitizedApp}_v*"
            $found = $false

            Get-ChildItem "$portabledir\$pattern" -Directory -ErrorAction SilentlyContinue | ForEach-Object {
                if ($_.Name -match "^${sanitizedApp}_v(.+)$") {
                    $installedVersion = $matches[1]

                    # If version specified, only update that version
                    if ($version -and $installedVersion -ne $version) {
                        return
                    }

                    $found = $true
                    update_portable $app $installedVersion $force $quiet $use_cache $check_hash
                }
            }

            if (!$found) {
                if ($version) {
                    error "'$app' ($version) is not installed in portable mode."
                } else {
                    error "'$app' is not installed in portable mode."
                }
            }
        }

        exit 0
    }

    # Normal (non-portable) update flow
    $outdated = @()
    $updateScoop = $null -ne ($apps | Where-Object { $_ -eq 'scoop' }) -or (is_scoop_outdated)
    $apps = $apps | Where-Object { $_ -ne 'scoop' }
    $apps_param = $apps

    if ($updateScoop) {
        Sync-Scoop -Log:$show_update_log
        Sync-Bucket -Log:$show_update_log
        set_config LAST_UPDATE ([System.DateTime]::Now.ToString('o')) | Out-Null
        success 'Scoop was updated successfully!'
    }

    if ($apps_param -eq '*' -or $all) {
        $apps = applist (installed_apps $false) $false
        if ($global) {
            $apps += applist (installed_apps $true) $true
        }
    } else {
        if ($apps_param) {
            $apps = Confirm-InstallationStatus $apps_param -Global:$global
        }
    }
    if ($apps) {
        $apps | ForEach-Object {
            ($app, $global) = $_
            $status = app_status $app $global
            # -f on an @version pin upgrades to the bucket HEAD; the target
            # version is resolved (and warned) by update(), not guessed here
            $ver = Select-CurrentVersion -AppName $app -Global:$global
            $pin = install_info $app $ver $global
            $is_pin = $force -and !$pin.bucket -and ($pin.url -eq (usermanifest $app))
            if ($status.installed -and ($force -or $status.outdated)) {
                if (!$status.hold) {
                    $outdated += applist $app $global
                    $latest = if ($is_pin) { 'HEAD (forced)' } else { $status.latest_version }
                    Write-Host -f yellow ("$app`: $($status.version) -> $latest{0}" -f ('', ' (global)')[$global])
                } else {
                    warn "'$app' is held to version $($status.version)"
                }
            } elseif ($apps_param -ne '*' -and !$all) {
                if ($status.installed) {
                    ensure_none_failed $app
                    Write-Host "$app`: $($status.version) (latest version)" -ForegroundColor Green
                } else {
                    info 'Please reinstall it or fix the manifest.'
                }
            }
        }

        if ($outdated -and ((Test-Aria2Enabled) -and (get_config 'aria2-warning-enabled' $true))) {
            warn "Scoop uses 'aria2c' for multi-connection downloads."
            warn "Should it cause issues, run 'scoop config aria2-enabled false' to disable it."
            warn "To disable this warning, run 'scoop config aria2-warning-enabled false'."
        }
        if ($outdated.Length -gt 1) {
            Write-Host -f DarkCyan "Updating $($outdated.Length) outdated apps:"
        } elseif ($outdated.Length -eq 0) {
            Write-Host -f Green "Latest versions for all apps are installed! For more information try 'scoop status'"
        } else {
            Write-Host -f DarkCyan 'Updating one outdated app:'
        }
    }

    $suggested = @{}
    # $outdated is a list of ($app, $global) tuples
    $outdated | ForEach-Object { update @_ $force $quiet $independent $suggested $use_cache $check_hash }
}

exit 0
