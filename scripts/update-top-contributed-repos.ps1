param(
    [string]$UserName = "dogledogle",
    [int]$TopCount = 5,
    [string]$ReadmePath = "README.md"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$startMarker = "<!-- TOP-CONTRIBUTED-REPOS:START -->"
$endMarker = "<!-- TOP-CONTRIBUTED-REPOS:END -->"

function Get-RepositoryName {
    param([object]$Item)

    if ($null -eq $Item) {
        return $null
    }

    $repositoryProperty = $Item.PSObject.Properties['repository']
    if ($null -eq $repositoryProperty -or $null -eq $repositoryProperty.Value) {
        return $null
    }

    $repository = $repositoryProperty.Value
    $nameWithOwnerProperty = $repository.PSObject.Properties['nameWithOwner']
    if ($null -ne $nameWithOwnerProperty -and
        -not [string]::IsNullOrWhiteSpace([string]$nameWithOwnerProperty.Value)) {
        return [string]$nameWithOwnerProperty.Value
    }

    return $null
}

if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
    throw "GitHub CLI (gh) is not installed or is not available in PATH."
}

if (-not (Test-Path -LiteralPath $ReadmePath)) {
    throw "README file not found: $ReadmePath"
}

Write-Host "Searching merged pull requests for @$UserName ..."

$json = gh search prs `
    --author $UserName `
    --merged `
    --limit 1000 `
    --json repository

if ($LASTEXITCODE -ne 0) {
    throw "GitHub CLI search failed with exit code $LASTEXITCODE."
}

$parsed = $json | ConvertFrom-Json

# Flatten the JSON result consistently across PowerShell versions.
$pullRequests = [System.Collections.Generic.List[object]]::new()

foreach ($pullRequest in $parsed) {
    $pullRequests.Add($pullRequest)
}

Write-Host "Found $($pullRequests.Count) merged pull requests."

if ($pullRequests.Count -eq 1000) {
    Write-Warning "GitHub Search returned 1000 results, which is the API limit."
    Write-Warning "The candidate set may omit repositories with older pull requests."
}

$candidateRepositories = @{}
foreach ($pullRequest in $pullRequests) {
    $repoFullName = Get-RepositoryName $pullRequest
    if (-not [string]::IsNullOrWhiteSpace($repoFullName) -and
        -not $repoFullName.StartsWith("$UserName/")) {
        $candidateRepositories[$repoFullName] = $true
    }
}

Write-Host "Searching commits for @$UserName ..."

$json = gh search commits `
    --author $UserName `
    --limit 1000 `
    --json repository

if ($LASTEXITCODE -ne 0) {
    throw "GitHub commit search failed with exit code $LASTEXITCODE."
}

$commits = @($json | ConvertFrom-Json)
if ($commits.Count -eq 1000) {
    throw "Commit search reached the 1000-result limit; repository counts would be incomplete."
}

$eligibleCommits = @(
    foreach ($commit in $commits) {
        $repoFullName = Get-RepositoryName $commit
        if (-not [string]::IsNullOrWhiteSpace($repoFullName) -and
            $candidateRepositories.ContainsKey($repoFullName)) {
            $commit
        }
    }
)

$repositories = @(
    $eligibleCommits |
        Group-Object -Property { Get-RepositoryName $_ } |
        Sort-Object -Property `
            @{ Expression = "Count"; Descending = $true },
            @{ Expression = "Name"; Descending = $false } |
        Select-Object -First $TopCount
)

$badgeLines = @(
    foreach ($repository in $repositories) {
        $ownerRepo = $repository.Name
        $repositoryParts = $ownerRepo -split "/", 2
        $repositoryLabel = if ($repositoryParts.Count -eq 2 -and $repositoryParts[0] -eq $repositoryParts[1]) {
            $repositoryParts[0]
        }
        else {
            $ownerRepo
        }
        $encodedRepository = [Uri]::EscapeDataString($repositoryLabel)

        $commitsUrl = "https://github.com/$ownerRepo/commits?author=$UserName"

        $badgeUrl = "https://img.shields.io/static/v1" +
            "?label=$encodedRepository" +
            "&amp;message=$($repository.Count)" +
            "&amp;style=flat-square"

        '<a href="{0}"><img align="center" src="{1}" alt="{2} - {3}" /></a>' -f `
            $commitsUrl, $badgeUrl, $repositoryLabel, $repository.Count
    }
)

if ($badgeLines.Count -eq 0) {
    $badgeLines = @("<em>No commits found in contributed repositories.</em>")
}

$readmeFullPath = (Resolve-Path -LiteralPath $ReadmePath).Path
$readme = [System.IO.File]::ReadAllText($readmeFullPath)

$startMarkerCount = (
    [regex]::Matches($readme, [regex]::Escape($startMarker))
).Count

$endMarkerCount = (
    [regex]::Matches($readme, [regex]::Escape($endMarker))
).Count

if ($startMarkerCount -ne 1 -or $endMarkerCount -ne 1) {
    throw "README must contain exactly one start marker and one end marker."
}

$newLine = if ($readme.Contains("`r`n")) {
    "`r`n"
}
else {
    "`n"
}

$replacementLines = @(
    $startMarker
    "<!-- Generated automatically. Do not edit this section manually. -->"
    $badgeLines
    $endMarker
)

$replacement = $replacementLines -join $newLine

$pattern = [regex]::Escape($startMarker) +
    ".*?" +
    [regex]::Escape($endMarker)

$markerRegex = [regex]::new(
    $pattern,
    [System.Text.RegularExpressions.RegexOptions]::Singleline
)

$updatedReadme = $markerRegex.Replace(
    $readme,
    $replacement,
    1
)

$utf8WithoutBom = [System.Text.UTF8Encoding]::new($false)

[System.IO.File]::WriteAllText(
    $readmeFullPath,
    $updatedReadme,
    $utf8WithoutBom
)

Write-Host "README updated with $($repositories.Count) repositories."

foreach ($repository in $repositories) {
    Write-Host ("{0,4} commits  {1}" -f `
        $repository.Count, $repository.Name)
}
