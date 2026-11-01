# Usage: scoop status
# Summary: Show status and check for new app versions
# Help: Options:
#   -l, --local         Checks the status for only the locally installed apps,
#                       and disables remote fetching/checking for Scoop and buckets

. "$PSScriptRoot\..\lib\manifest.ps1" # 'manifest' 'parse_json' "install_info"
. "$PSScriptRoot\..\lib\versions.ps1" # 'Select-CurrentVersion'
. "$PSScriptRoot\..\lib\download.ps1" # 'Get-UserAgent'

# check if scoop needs updating
$currentdir = versiondir 'scoop' 'current'
$needs_update = $false
$bucket_needs_update = $false
$script:network_failure = $false
$no_remotes = $args[0] -eq '-l' -or $args[0] -eq '--local'
if (!(Get-Command git -ErrorAction SilentlyContinue)) { $no_remotes = $true }
$list = @()
if (!(Get-FormatData ScoopStatus)) {
    Update-FormatData "$PSScriptRoot\..\supporting\formats\ScoopTypes.Format.ps1xml"
}

function Test-UpdateStatus($repopath) {
    if (Test-Path "$repopath\.git") {
        Invoke-Git -Path $repopath -ArgumentList @('fetch', '-q', 'origin')
        $script:network_failure = 128 -eq $LASTEXITCODE
        $branch  = Invoke-Git -Path $repopath -ArgumentList @('branch', '--show-current')
        $commits = Invoke-Git -Path $repopath -ArgumentList @('log', "HEAD..origin/$branch", '--oneline')
        if ($commits) { return $true }
        else { return $false }
    } else {
        return $true
    }
}

if (!$no_remotes) {
    $needs_update = Test-UpdateStatus $currentdir
    foreach ($bucket in Get-LocalBucket) {
        if (Test-UpdateStatus (Find-BucketDirectory $bucket -Root)) {
            $bucket_needs_update = $true
            break
        }
    }
}

if ($needs_update) {
    warn "Scoop out of date. Run 'scoop update' to get the latest changes."
} elseif ($bucket_needs_update) {
    warn "Scoop bucket(s) out of date. Run 'scoop update' to get the latest changes."
} elseif (!$script:network_failure -and !$no_remotes) {
    success 'Scoop is up to date.'
}

$true, $false | ForEach-Object { # local and global apps
    $global = $_
    $dir = appsdir $global
    if (!(Test-Path $dir)) { return }

    Get-ChildItem $dir | Where-Object name -NE 'scoop' | ForEach-Object {
        $app = $_.name
        $status = app_status $app $global
        if (!$status.outdated -and !$status.failed -and !$status.deprecated -and !$status.removed -and !$status.missing_deps) { return }

        $item = [ordered]@{}
        $item.Name = $app
        $item.'Installed Version' = $status.version
        $item.'Latest Version' = if ($status.outdated) { $status.latest_version } else { "" }
        $item.'Missing Dependencies' = $status.missing_deps -Split ' ' -Join ' | '
        $info = @()
        if ($status.failed)     { $info += 'Install failed' }
        if ($status.hold)       { $info += 'Held package' }
        if ($status.deprecated) { $info += 'Deprecated' }
        if ($status.removed)    { $info += 'Manifest removed' }
        $item.Info = $info -join ', '
        $list += [PSCustomObject]$item
    }
}

# Portable-Launcher: Check portable installations for revision updates
if ($portabledir -and (Test-Path $portabledir)) {
    Get-ChildItem $portabledir -Directory | ForEach-Object {
        # Parse app name and version from directory name: AppName_vVersion
        if ($_.Name -match '^(.+)_v(.+)$') {
            $app = $matches[1]
            $version = $matches[2]

            # Check if this is a valid portable installation
            $installInfoPath = "$($_.FullName)\Other\Scoop\scoop-install.json"
            if (!(Test-Path $installInfoPath)) { return }

            $install_info = parse_json $installInfoPath
            if (!$install_info -or !$install_info.portable) { return }

            # Get installed revision (default to 1 for backward compatibility)
            $installedRevision = if ($install_info.portable_revision) { $install_info.portable_revision } else { 1 }

            # Get version-specific manifest for this installation
            # Use the bucket and URL from the installation metadata
            $bucket = $install_info.bucket
            $url = $install_info.url

            # Try to get the manifest for the installed version
            $manifest = $null
            try {
                if ($url) {
                    # Installation from URL - try that first
                    $manifest = url_manifest $url
                } elseif ($bucket) {
                    # Try current bucket manifest first
                    $current_manifest = manifest $app $bucket $null
                    if ($current_manifest -and $current_manifest.version -eq $version) {
                        $manifest = $current_manifest
                    } else {
                        # Need historical manifest for this version
                        $manifest_path = generate_user_manifest $app $bucket $version
                        if ($manifest_path -and (Test-Path $manifest_path)) {
                            $manifest = parse_json $manifest_path
                        }
                    }
                }
            } catch {
                # Manifest lookup failed - skip this installation
                return
            }

            if (!$manifest) { return }

            # Verify manifest version matches installed version
            if ($manifest.version -ne $version) {
                # Version mismatch - skip this installation
                return
            }

            # Get available revision from version-specific manifest
            $availableRevision = Get-PortableRevision $manifest

            # Check if revision is outdated
            if ($availableRevision -gt $installedRevision) {
                $item = [ordered]@{}
                $item.Name = "$app (portable)"
                $item.'Installed Version' = "$version (rev $installedRevision)"
                $item.'Latest Version' = "$version (rev $availableRevision)"
                $item.'Missing Dependencies' = ""
                $item.Info = "Portable packaging updated"
                $list += [PSCustomObject]$item
            }
        }
    }
}

if ($list.Length -eq 0 -and !$needs_update -and !$bucket_needs_update -and !$script:network_failure) {
    success 'Everything is ok!'
}

$list | Add-Member -TypeName ScoopStatus -PassThru

exit 0
