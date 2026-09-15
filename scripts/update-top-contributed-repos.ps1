param(
    [string]$UserName = "dogledogle",
    [int]$TopCount = 5,
    [string]$ReadmePath = "README.md"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$startMarker = "<!-- TOP-CONTRIBUTED-REPOS:START -->"
$endMarker = "<!-- TOP-CONTRIBUTED-REPOS:END -->"
$badgeLabelColor = "18181B"
$badgeColors = @(
    "0077FF"
    "2563EB"
    "4F46E5"
    "7C3AED"
    "9333EA"
)

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
    foreach ($propertyName in @('nameWithOwner', 'fullName')) {
        $nameProperty = $repository.PSObject.Properties[$propertyName]
        if ($null -ne $nameProperty -and
            -not [string]::IsNullOrWhiteSpace([string]$nameProperty.Value)) {
            return [string]$nameProperty.Value
        }
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

$parsedCommits = $json | ConvertFrom-Json

$commits = [System.Collections.Generic.List[object]]::new()
foreach ($commit in $parsedCommits) {
    $commits.Add($commit)
}

Write-Host "Found $($commits.Count) commits."

if ($commits.Count -eq 1000) {
    throw "Commit search reached the 1000-result limit; repository counts would be incomplete."
}

$commitRepositories = [System.Collections.Generic.List[string]]::new()
foreach ($commit in $commits) {
    $repoFullName = Get-RepositoryName $commit
    if (-not [string]::IsNullOrWhiteSpace($repoFullName)) {
        $commitRepositories.Add($repoFullName)
    }
}

if ($commits.Count -gt 0 -and $commitRepositories.Count -eq 0) {
    throw "Commit search returned results, but no repository names could be parsed."
}

$eligibleCommitRepositories = @(
    $commitRepositories | Where-Object { $candidateRepositories.ContainsKey($_) }
)

$repositories = @(
    $eligibleCommitRepositories |
        Group-Object |
        Sort-Object -Property `
            @{ Expression = "Count"; Descending = $true },
            @{ Expression = "Name"; Descending = $false } |
        Select-Object -First $TopCount
)

$encodedUserName = [Uri]::EscapeDataString($UserName)

$badgeLines = @(
    for ($index = 0; $index -lt $repositories.Count; $index++) {
        $repository = $repositories[$index]
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

        # Shields queries GitHub when the README image is requested, so the
        # displayed count stays current without rewriting README.md.
        $badgeUrl = "https://img.shields.io/github/commit-activity/t/$ownerRepo" +
            "?authorFilter=$encodedUserName" +
            "&amp;label=$encodedRepository" +
            "&amp;labelColor=$badgeLabelColor" +
            "&amp;color=$($badgeColors[$index % $badgeColors.Count])" +
            "&amp;style=flat-square"

        '<a href="{0}"><img align="center" src="{1}" alt="{2} - commits by {3}" /></a>' -f `
            $commitsUrl, $badgeUrl, $repositoryLabel, $UserName
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
