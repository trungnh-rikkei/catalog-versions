@set "__SELF=%~f0" & powershell -NoProfile -ExecutionPolicy Bypass -Command "& { $c=[IO.File]::ReadAllText($env:__SELF); & ([scriptblock]::Create($c.Substring($c.LastIndexOf('#!PS1')+5))) $args }" -- %* & exit /b %ERRORLEVEL%
#!PS1
<#
  catalog.bat
  Usage:
    catalog.bat          # Sync with default catalog
    catalog.bat compose  # Sync with Compose catalog

  Requires: Windows PowerShell 5+ or PowerShell 7+, internet access.
#>

$URL_DEFAULT = "https://raw.githubusercontent.com/trungnh-rikkei/catalog-versions/main/gradle/libs.versions.toml"
$URL_COMPOSE = "https://raw.githubusercontent.com/trungnh-rikkei/catalog-versions/main/gradle/libs-compose.versions.toml"

$ConnectTimeout = 10000
$ReadTimeout    = 30000
$LocalPath      = "gradle/libs.versions.toml"

# Strip leading "--" sentinel injected by the batch wrapper
$cleanArgs = $args | Where-Object { $_ -ne "--" }

$Url = if ($cleanArgs.Count -gt 0 -and $cleanArgs[0] -eq "compose") {
    $URL_COMPOSE
} elseif ($cleanArgs.Count -eq 0) {
    $URL_DEFAULT
} else {
    Write-Host "Usage: catalog.bat [compose]"
    exit 1
}

# ──────────────────────────────────────────────────────────────────────────────
# Get-RemoteCatalog: Downloads URL to a temp file.
# Returns $true on success, $false on network/HTTP error.
# ──────────────────────────────────────────────────────────────────────────────
function Get-RemoteCatalog {
    param(
        [string]$CatalogUrl,
        [string]$OutFile,
        [int]$ConnTimeout,
        [int]$ReadTimeout
    )
    try {
        $req = [System.Net.HttpWebRequest]::Create($CatalogUrl)
        $req.Method         = "GET"
        $req.Timeout        = $ConnTimeout
        $req.ReadWriteTimeout = $ReadTimeout
        $req.Headers["Cache-Control"] = "no-cache"
        $req.Headers["Pragma"]        = "no-cache"
        $req.Accept = "text/plain, */*"

        $resp = $req.GetResponse()
        $code = [int]$resp.StatusCode
        if ($code -eq 401 -or $code -eq 403) {
            throw "HTTP $code – access denied."
        }
        if ($code -ne 200) {
            throw "HTTP $code from $CatalogUrl"
        }

        $stream = $resp.GetResponseStream()
        $fs     = [System.IO.File]::Open($OutFile, [System.IO.FileMode]::Create)
        $stream.CopyTo($fs)
        $fs.Dispose()
        $stream.Dispose()
        $resp.Dispose()
        return $true
    }
    catch [System.Net.WebException] {
        Write-Host "[CatalogSync] [WARN] Network error: $($_.Exception.Message)"
        return $false
    }
    catch {
        Write-Host "[CatalogSync] [WARN] Fetch error: $($_.Exception.Message)"
        return $false
    }
}

# ──────────────────────────────────────────────────────────────────────────────
# Parse-TomlEntries: Parses a TOML file into sections.
# Returns a hashtable: sectionName → OrderedDictionary(key → fullRawLine)
# ──────────────────────────────────────────────────────────────────────────────
function Parse-TomlEntries {
    param([string]$Path)
    $sections = @{}
    $currentSection = ""
    foreach ($rawLine in [System.IO.File]::ReadAllLines($Path)) {
        $trimmed = $rawLine.Trim()
        if ($trimmed -match '^\[([^\]]+)\]\s*$') {
            $currentSection = $Matches[1].Trim()
            if (-not $sections.ContainsKey($currentSection)) {
                $sections[$currentSection] = [ordered]@{}
            }
            continue
        }
        if ($currentSection -and $trimmed -and -not $trimmed.StartsWith("#")) {
            $eqIdx = $trimmed.IndexOf("=")
            if ($eqIdx -gt 0) {
                $key = $trimmed.Substring(0, $eqIdx).Trim()
                if ($key) { $sections[$currentSection][$key] = $rawLine }
            }
        }
    }
    return $sections
}

# ──────────────────────────────────────────────────────────────────────────────
# Show-CatalogDiff: Prints [ADDED] / [CHANGED] for remote entries vs local.
# Local-only entries are NOT shown (they are expected and OK).
# Returns $true when there are actual changes.
# ──────────────────────────────────────────────────────────────────────────────
function Show-CatalogDiff {
    param([string]$LocalFile, [string]$RemoteFile)
    $localSections  = Parse-TomlEntries $LocalFile
    $remoteSections = Parse-TomlEntries $RemoteFile
    $hasChange = $false

    foreach ($section in $remoteSections.Keys) {
        $remoteEntries = $remoteSections[$section]
        $localEntries  = if ($localSections.ContainsKey($section)) { $localSections[$section] } else { [ordered]@{} }
        foreach ($key in $remoteEntries.Keys) {
            $rLine = $remoteEntries[$key].Trim()
            $rVal  = if ($rLine.IndexOf("=") -gt 0) { $rLine.Substring($rLine.IndexOf("=") + 1).Trim() } else { $rLine }
            if (-not $localEntries.Contains($key)) {
                Write-Host "  [ADDED]   [$section] ${key}: $rVal"
                $hasChange = $true
            } else {
                $lLine = $localEntries[$key].Trim()
                $lVal  = if ($lLine.IndexOf("=") -gt 0) { $lLine.Substring($lLine.IndexOf("=") + 1).Trim() } else { $lLine }
                if ($lVal -ne $rVal) {
                    Write-Host "  [CHANGED] [$section] ${key}: $lVal -> $rVal"
                    $hasChange = $true
                }
            }
        }
    }
    return $hasChange
}

# ──────────────────────────────────────────────────────────────────────────────
# Test-CatalogInSync: Checks if all remote entries exist in local with same value.
# Returns $true when in sync, $false otherwise.
# ──────────────────────────────────────────────────────────────────────────────
function Test-CatalogInSync {
    param([string]$LocalFile, [string]$RemoteFile)
    $localSections  = Parse-TomlEntries $LocalFile
    $remoteSections = Parse-TomlEntries $RemoteFile

    foreach ($section in $remoteSections.Keys) {
        $remoteEntries = $remoteSections[$section]
        $localEntries  = if ($localSections.ContainsKey($section)) { $localSections[$section] } else { [ordered]@{} }
        foreach ($key in $remoteEntries.Keys) {
            if (-not $localEntries.Contains($key)) { return $false }
            if ($localEntries[$key].Trim() -ne $remoteEntries[$key].Trim()) { return $false }
        }
    }
    return $true
}

# ──────────────────────────────────────────────────────────────────────────────
# Extract-Module: Extracts the module coordinate from a TOML library line.
# Returns the module string (e.g. "com.google.ads.mediation:applovin") or "".
# Handles both { module = "..." } and { group = "...", name = "..." } syntax.
# ──────────────────────────────────────────────────────────────────────────────
function Extract-Module {
    param([string]$Line)
    $t = $Line.Trim()
    # { module = "group:artifact", ... }
    if ($t -match 'module\s*=\s*"([^"]+)"') { return $Matches[1] }
    # { group = "...", name = "..." }
    $g = ""; $n = ""
    if ($t -match 'group\s*=\s*"([^"]+)"') { $g = $Matches[1] }
    if ($t -match 'name\s*=\s*"([^"]+)"')  { $n = $Matches[1] }
    if ($g -and $n) { return "${g}:${n}" }
    return ""
}

# ──────────────────────────────────────────────────────────────────────────────
# Build-RemoteModuleSet: Builds a HashSet of all module coordinates from the
# remote catalog's [libraries] section.
# ──────────────────────────────────────────────────────────────────────────────
function Build-RemoteModuleSet {
    param([hashtable]$RemoteSections)
    $set = @{}
    if ($RemoteSections.ContainsKey("libraries")) {
        foreach ($rKey in $RemoteSections["libraries"].Keys) {
            $mod = Extract-Module $RemoteSections["libraries"][$rKey]
            if ($mod) { $set[$mod] = $true }
        }
    }
    return $set
}

# ──────────────────────────────────────────────────────────────────────────────
# Merge-CatalogContent: Merges remote entries into local file content.
# Remote entries override matching local keys; new remote entries are appended.
# Local-only entries are preserved as-is.
# Entries whose module coordinate already exists in remote are removed
# (even if the key name differs), preventing duplicates.
# Returns the merged content as a single string.
# ──────────────────────────────────────────────────────────────────────────────
function Merge-CatalogContent {
    param([string]$LocalFile, [string]$RemoteFile)

    $remoteSections   = Parse-TomlEntries $RemoteFile
    $remoteModuleSet  = Build-RemoteModuleSet $remoteSections
    $localLines       = [System.IO.File]::ReadAllLines($LocalFile)

    # Track version keys used by skipped local entries so we can remove orphans
    $skippedVersionRefs = @{}

    $result      = [System.Collections.ArrayList]@()
    $tailBuffer  = [System.Collections.ArrayList]@()   # trailing non-entry lines in section
    $currentSection = ""
    $writtenKeys    = @{}

    foreach ($line in $localLines) {
        $trimmed = $line.Trim()

        # ── Section header: flush pending entries + tail buffer ────────────
        if ($trimmed -match '^\[([^\]]+)\]\s*$') {
            # Append unwritten remote entries for previous section
            if ($currentSection -and $remoteSections.ContainsKey($currentSection)) {
                $headerEmitted = $false
                foreach ($rKey in $remoteSections[$currentSection].Keys) {
                    if (-not $writtenKeys.ContainsKey($rKey)) {
                        if (-not $headerEmitted) {
                            [void]$result.Add("")
                            [void]$result.Add("# ── Managed by catalog (do not edit below) ──")
                            $headerEmitted = $true
                        }
                        [void]$result.Add($remoteSections[$currentSection][$rKey])
                        $writtenKeys[$rKey] = $true
                    }
                }
            }
            # Flush tail buffer (blank/comment lines after last entry)
            foreach ($bl in $tailBuffer) { [void]$result.Add($bl) }
            $tailBuffer.Clear()

            $currentSection = $Matches[1].Trim()
            $writtenKeys    = @{}
            [void]$result.Add($line)
            continue
        }

        # ── Key-value entry inside a section ──────────────────────────────
        if ($currentSection -and $trimmed -and -not $trimmed.StartsWith("#")) {
            $eqIdx = $trimmed.IndexOf("=")
            if ($eqIdx -gt 0) {
                $key = $trimmed.Substring(0, $eqIdx).Trim()
                if ($key) {
                    if ($remoteSections.ContainsKey($currentSection) -and $remoteSections[$currentSection].Contains($key)) {
                        # Skip: remote entry will be grouped in managed section
                        $tailBuffer.Clear()
                    } elseif ($currentSection -eq "libraries" -and $remoteModuleSet.Count -gt 0) {
                        # Check if this local entry's module is already provided by remote
                        $localMod = Extract-Module $trimmed
                        if ($localMod -and $remoteModuleSet.ContainsKey($localMod)) {
                            # Duplicate module – skip local entry in favor of remote
                            # Record the version.ref so we can remove it if orphaned
                            if ($trimmed -match 'version\.ref\s*=\s*"([^"]+)"') {
                                $skippedVersionRefs[$Matches[1]] = $true
                            }
                            $tailBuffer.Clear()
                        } else {
                            # Local-only: flush buffered lines and keep
                            foreach ($bl in $tailBuffer) { [void]$result.Add($bl) }
                            $tailBuffer.Clear()
                            [void]$result.Add($line)
                        }
                    } elseif ($currentSection -eq "versions" -and $remoteSections.ContainsKey("versions") -and -not $remoteSections["versions"].Contains($key)) {
                        # Keep for now; will remove orphans after full merge
                        foreach ($bl in $tailBuffer) { [void]$result.Add($bl) }
                        $tailBuffer.Clear()
                        [void]$result.Add($line)
                    } else {
                        # Local-only: flush buffered lines and keep
                        foreach ($bl in $tailBuffer) { [void]$result.Add($bl) }
                        $tailBuffer.Clear()
                        [void]$result.Add($line)
                    }
                    continue
                }
            }
        }

        # ── Non-entry line (blank, comment) ───────────────────────────────
        if ($currentSection) {
            [void]$tailBuffer.Add($line)
        } else {
            [void]$result.Add($line)
        }
    }

    # Handle last section
    if ($currentSection -and $remoteSections.ContainsKey($currentSection)) {
        $headerEmitted = $false
        foreach ($rKey in $remoteSections[$currentSection].Keys) {
            if (-not $writtenKeys.ContainsKey($rKey)) {
                if (-not $headerEmitted) {
                    [void]$result.Add("")
                    [void]$result.Add("# ── Managed by catalog (do not edit below) ──")
                    $headerEmitted = $true
                }
                [void]$result.Add($remoteSections[$currentSection][$rKey])
                $writtenKeys[$rKey] = $true
            }
        }
    }
    foreach ($bl in $tailBuffer) { [void]$result.Add($bl) }

    # Append entirely new sections from remote that don't exist in local
    $localSectionNames = @{}
    foreach ($l in $localLines) {
        if ($l.Trim() -match '^\[([^\]]+)\]\s*$') { $localSectionNames[$Matches[1].Trim()] = $true }
    }
    foreach ($sec in $remoteSections.Keys) {
        if (-not $localSectionNames.ContainsKey($sec)) {
            [void]$result.Add("")
            [void]$result.Add("[$sec]")
            [void]$result.Add("# ── Managed by catalog (do not edit below) ──")
            foreach ($rKey in $remoteSections[$sec].Keys) {
                [void]$result.Add($remoteSections[$sec][$rKey])
            }
        }
    }

    # ── Remove orphaned version keys from skipped local entries ───────────
    if ($skippedVersionRefs.Count -gt 0) {
        $mergedText = $result -join "`n"
        $keysToRemove = @()
        foreach ($vRef in $skippedVersionRefs.Keys) {
            if ($mergedText -notmatch ('version\.ref\s*=\s*"' + [regex]::Escape($vRef) + '"')) {
                $keysToRemove += $vRef
            }
        }
        if ($keysToRemove.Count -gt 0) {
            $cleaned = [System.Collections.ArrayList]@()
            foreach ($rl in $result) {
                $skip = $false
                $rtrim = $rl.Trim()
                if ($rtrim -and -not $rtrim.StartsWith("#") -and -not $rtrim.StartsWith("[")) {
                    $eqi = $rtrim.IndexOf("=")
                    if ($eqi -gt 0) {
                        $vk = $rtrim.Substring(0, $eqi).Trim()
                        if ($keysToRemove -contains $vk) { $skip = $true }
                    }
                }
                if (-not $skip) { [void]$cleaned.Add($rl) }
            }
            $result = $cleaned
        }
    }

    return ($result -join "`n")
}

# ── Temp file ──────────────────────────────────────────────────────────────────
$TmpFile = [System.IO.Path]::GetTempFileName()

try {
    $ok = Get-RemoteCatalog -CatalogUrl $Url `
                            -OutFile $TmpFile -ConnTimeout $ConnectTimeout -ReadTimeout $ReadTimeout
    if (-not $ok) {
        Write-Host "[CatalogSync] [WARN] Cannot reach remote catalog."
        Write-Host "[CatalogSync] Using existing local file (if present)."
        exit 0
    }

    Write-Host "[CatalogSync] [SYNC] Updating catalog..."

    $localDir = Split-Path $LocalPath -Parent
    if ($localDir) { New-Item -ItemType Directory -Force -Path $localDir | Out-Null }

    if (Test-Path $LocalPath) {
        $merged = Merge-CatalogContent -LocalFile $LocalPath -RemoteFile $TmpFile
        [System.IO.File]::WriteAllText($LocalPath, $merged)
    } else {
        Copy-Item -LiteralPath $TmpFile -Destination $LocalPath -Force
    }

    Write-Host "[CatalogSync] [OK] Catalog saved -> $LocalPath"
    Write-Host "[CatalogSync] [INFO] Re-sync the project / restart the build to apply new versions."
} finally {
    if (Test-Path $TmpFile) { Remove-Item -LiteralPath $TmpFile -Force -ErrorAction SilentlyContinue }
}
