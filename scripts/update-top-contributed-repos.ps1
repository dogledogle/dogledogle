param(
    [string]$UserName = "dogledogle",
    [int]$TopCount = 5,
    [string]$ReadmePath = "README.md"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$startMarker = "<!-- TOP-CONTRIBUTED-REPOS:START -->"
$endMarker = "<!-- TOP-CONTRIBUTED-REPOS:END -->"

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
    Write-Warning "The ranking may omit older pull requests."
}

# --- 新增过滤逻辑：排除自己创建的仓库 ---
$filteredPullRequests = $pullRequests | Where-Object {
    $repoFullName = $_.repository.nameWithOwner
    # 如果仓库全名 (如 "dogledogle/my-repo") 不以 "dogledogle/" 开头，则保留
    -not $repoFullName.StartsWith("$UserName/")
}

$excludedCount = $pullRequests.Count - $filteredPullRequests.Count
if ($excludedCount -gt 0) {
    Write-Host "Excluded $excludedCount pull requests from repositories owned by '$UserName'."
}
# --- 过滤结束 ---

# 修改统计来源：使用 $filteredPullRequests 替代原来的 $pullRequests
$repositories = @(
    $filteredPullRequests |
        Group-Object -Property { $_.repository.nameWithOwner } |
        Sort-Object -Property `
            @{ Expression = "Count"; Descending = $true },
            @{ Expression = "Name"; Descending = $false } |
        Select-Object -First $TopCount
)

# Optional visual overrides for specific repositories.
# Repositories not listed here use their repository name and GitHub logo.
$badgeOverrides = @{
    "vitejs/docs-cn" = @{
        Label = "Vite Docs CN"
        Logo  = "vite"
        Color  = "b39aff"
    }
    
    "vitejs/vite" = @{
        Label = "Vite"
        Logo  = "vite"
        Color  = "646CFF"
    }

    "wangdoc/typescript-tutorial" = @{
        Label = "TypeScript Tutorial"
        Logo  = "typescript"
        Color  = "e57102"
    }

    "ant-design/ant-design" = @{
        Label = "Ant Design"
        Logo  = "antdesign"
        Color  = "1677ff"
    }

    "mdn/translated-content" = @{
        Label = "MDN"
        Logo  = "mdnwebdocs"
        Color  = "0a5dbd"
    }

    "vuejs-translations/docs-zh-cn" = @{
        Label = "Vue.js 中文文档"
        Logo  = "vuedotjs"
        Color  = "42b883"
    }

    "DavidHDev/canvas-ui" = @{
        Label = "Canvas UI"
        Logo  = "html5"
        Color  = "0a0a0a"
    }
}

$badgeLines = @(
    foreach ($repository in $repositories) {
        $ownerRepo = $repository.Name
        $repoName = ($ownerRepo -split "/")[-1]

        $labelText = $repoName
        $logoName = "github"
        $color = "000000"
        
        if ($badgeOverrides.ContainsKey($ownerRepo)) {
            $labelText = $badgeOverrides[$ownerRepo].Label
            $logoName = $badgeOverrides[$ownerRepo].Logo
            $color = $badgeOverrides[$ownerRepo].Color
        }

        $linkQuery = [Uri]::EscapeDataString(
            "is:pr is:merged author:$UserName"
        )

        $badgeQuery = [Uri]::EscapeDataString(
            "repo:$ownerRepo is:pr is:merged author:$UserName"
        )

        $encodedLabel = [Uri]::EscapeDataString($labelText)
        $encodedLogo = [Uri]::EscapeDataString($logoName)

        $pullsUrl = "https://github.com/$ownerRepo/pulls?q=$linkQuery"

        $badgeUrl = "https://img.shields.io/github/issues-search" +
            "?query=$badgeQuery" +
            "&amp;label=$encodedLabel" +
            "&amp;style=flat-square" +
            "&amp;logo=$encodedLogo" +
            "&amp;logoColor=white" +
            "&amp;color=$color"

        '<a href="{0}"><img src="{1}" alt="{2} merged PRs" /></a>' -f `
            $pullsUrl, $badgeUrl, $labelText
    }
)

if ($badgeLines.Count -eq 0) {
    $badgeLines = @("<em>No merged pull requests found.</em>")
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

$badgeHtml = $badgeLines -join " "

$replacementLines = @(
    $startMarker
    "<!-- Generated automatically. Do not edit this section manually. -->"
    "<p align=`"center`">$badgeHtml</p>"
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
    Write-Host ("{0,4} merged PRs  {1}" -f `
        $repository.Count, $repository.Name)
}
