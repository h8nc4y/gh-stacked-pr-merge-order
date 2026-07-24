# Windows PowerShell 5.1 の構文解析用に、このファイルは UTF-8 with BOM を維持する。
# NOTE: This file contains Japanese comments and must remain UTF-8 with BOM.
# 検査対象のリポジトリ本文は Windows PowerShell 5.1 でも BOM-less UTF-8 を
# 正しく読めるよう、Get-Content の -Encoding UTF8 を固定する。
[CmdletBinding()]
param(
    [string]$Path = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptRoot = $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($scriptRoot)) {
    $scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
}

if ([string]::IsNullOrWhiteSpace($Path)) {
    $Path = Split-Path -Parent $scriptRoot
}

$root = (Resolve-Path -LiteralPath $Path).Path
$failures = New-Object System.Collections.Generic.List[string]

function Add-Failure {
    param([string]$Message)
    $failures.Add($Message) | Out-Null
}

function Get-RepoFilePath {
    param([string]$RelativePath)
    return Join-Path $root $RelativePath
}

function Assert-FileExists {
    param([string]$RelativePath)

    $filePath = Get-RepoFilePath -RelativePath $RelativePath
    if (-not (Test-Path -LiteralPath $filePath -PathType Leaf)) {
        Add-Failure "Missing required file: $RelativePath"
    }
}

function Assert-FileContains {
    param(
        [string]$RelativePath,
        [string]$Pattern,
        [string]$Description
    )

    $filePath = Get-RepoFilePath -RelativePath $RelativePath
    if (-not (Test-Path -LiteralPath $filePath -PathType Leaf)) {
        Add-Failure "Cannot inspect missing file: $RelativePath ($Description)"
        return
    }

    # Windows PowerShell 5.1 が BOM-less UTF-8 の日本語コメントや文書を
    # ANSI code page として誤読しないよう、UTF-8 を明示する。
    $content = Get-Content -LiteralPath $filePath -Raw -Encoding UTF8
    if ($content -notmatch $Pattern) {
        Add-Failure "$RelativePath is missing: $Description"
    }
}

function Assert-FileHasUtf8Bom {
    param([string]$RelativePath)

    $filePath = Get-RepoFilePath -RelativePath $RelativePath
    if (-not (Test-Path -LiteralPath $filePath -PathType Leaf)) {
        Add-Failure "Cannot inspect missing file: $RelativePath (UTF-8 BOM)"
        return
    }

    # editor 設定だけでなく staged bytes 自体を読み、将来の formatter が BOM を
    # 剥がしても Windows PowerShell 5.1 gate より前に固定理由付きで検出する。
    $stream = [IO.File]::OpenRead($filePath)
    try {
        $prefix = New-Object byte[] 3
        $read = $stream.Read($prefix, 0, $prefix.Length)
        if ($read -ne 3 -or
            $prefix[0] -ne 0xEF -or
            $prefix[1] -ne 0xBB -or
            $prefix[2] -ne 0xBF) {
            Add-Failure "$RelativePath must use UTF-8 with BOM."
        }
    }
    finally {
        $stream.Dispose()
    }
}

# workflow内の対象action参照を全件抽出し、40桁SHA以外を1件でも拒否する。
# exact行が別に残っていてもtag/suffixを併記してgateをすり抜けられない。
function Assert-WorkflowActionPin {
    param(
        [string]$RelativePath,
        [string]$Action,
        [string]$Commit,
        [string]$Description
    )

    $filePath = Get-RepoFilePath -RelativePath $RelativePath
    if (-not (Test-Path -LiteralPath $filePath -PathType Leaf)) {
        Add-Failure "Cannot inspect missing file: $RelativePath ($Description)"
        return
    }
    if ($Commit -cnotmatch '^[0-9a-f]{40}$') {
        Add-Failure "$Description must use one exact lowercase 40-character SHA."
        return
    }

    $content = Get-Content -LiteralPath $filePath -Raw -Encoding UTF8
    $escapedAction = [regex]::Escape($Action)
    $usePattern =
        "(?m)^[ `t]*uses:[ `t]*$escapedAction@" +
        '(?<Reference>[^ \t#\r\n]+)' +
        '(?:[ \t]+#[^\r\n]*)?[ \t]*$'
    $matches = [regex]::Matches($content, $usePattern)
    if ($matches.Count -eq 0) {
        Add-Failure "$RelativePath is missing: $Description"
        return
    }

    foreach ($match in $matches) {
        if ($match.Groups['Reference'].Value -cne $Commit) {
            Add-Failure "$RelativePath has a non-immutable $Action reference."
        }
    }
}

function Test-SkillFrontmatter {
    $skillPath = Get-RepoFilePath -RelativePath 'SKILL.md'
    if (-not (Test-Path -LiteralPath $skillPath -PathType Leaf)) {
        return
    }

    $lines = Get-Content -LiteralPath $skillPath -Encoding UTF8
    if ($lines.Count -lt 4 -or $lines[0] -ne '---') {
        Add-Failure 'SKILL.md must start with YAML frontmatter.'
        return
    }

    $closingIndex = -1
    for ($index = 1; $index -lt $lines.Count; $index++) {
        if ($lines[$index] -eq '---') {
            $closingIndex = $index
            break
        }
    }

    if ($closingIndex -lt 0) {
        Add-Failure 'SKILL.md frontmatter must be closed with --- before content.'
        return
    }

    $frontmatter = $lines[1..($closingIndex - 1)] -join "`n"
    if ($frontmatter -notmatch '(?m)^name:\s*gh-stacked-pr-merge-order\s*$') {
        Add-Failure 'SKILL.md frontmatter must declare name: gh-stacked-pr-merge-order.'
    }
    if ($frontmatter -notmatch '(?m)^description:\s*\S') {
        Add-Failure 'SKILL.md frontmatter must include a non-empty description.'
    }
    if ($frontmatter.Length -gt 1024) {
        Add-Failure 'SKILL.md frontmatter must stay under 1024 characters.'
    }
}

$requiredFiles = @(
    '.editorconfig',
    '.gitattributes',
    '.gitignore',
    '.github/ISSUE_TEMPLATE/bug_report.yml',
    '.github/ISSUE_TEMPLATE/config.yml',
    '.github/pull_request_template.md',
    '.github/workflows/validate.yml',
    'CHANGELOG.md',
    'CODE_OF_CONDUCT.md',
    'CONTRIBUTING.md',
    'LICENSE',
    'README.md',
    'SECURITY.md',
    'SKILL.md',
    'docs/SCANNER-HARDENING.md',
    'docs/SKILL.ja.md',
    'examples/three-pr-stack-walkthrough.md',
    'examples/auto-close-recovery-template.md',
    'examples/pre-merge-checklist.md',
    'scripts/private-marker-process.ps1',
    'scripts/private-marker-windows-process.ps1',
    'scripts/scan-private-markers.ps1',
    'scripts/test-scan-private-markers.ps1',
    'scripts/validate-oss-readiness.ps1'
)

foreach ($requiredFile in $requiredFiles) {
    Assert-FileExists -RelativePath $requiredFile
}

$powerShellSources = @(
    'scripts/private-marker-process.ps1',
    'scripts/private-marker-windows-process.ps1',
    'scripts/scan-private-markers.ps1',
    'scripts/test-scan-private-markers.ps1',
    'scripts/validate-oss-readiness.ps1'
)
foreach ($powerShellSource in $powerShellSources) {
    Assert-FileHasUtf8Bom -RelativePath $powerShellSource
}

Assert-FileContains -RelativePath 'README.md' -Pattern '(?im)^##\s+Install' -Description 'installation instructions'
Assert-FileContains -RelativePath 'README.md' -Pattern '(?im)^##\s+Validation' -Description 'validation instructions'
Assert-FileContains -RelativePath 'README.md' -Pattern '(?im)^##\s+Contributing' -Description 'contribution guidance'
Assert-FileContains -RelativePath 'README.md' -Pattern '(?im)^##\s+Security' -Description 'security reporting guidance'
Assert-FileContains -RelativePath 'README.md' -Pattern 'CONTRIBUTING\.md' -Description 'link to CONTRIBUTING.md'
Assert-FileContains -RelativePath 'README.md' -Pattern 'SECURITY\.md' -Description 'link to SECURITY.md'
Assert-FileContains -RelativePath 'README.md' -Pattern 'docs/SKILL\.ja\.md' -Description 'link to the Japanese skill version'
Assert-FileContains -RelativePath 'README.md' -Pattern 'docs/SCANNER-HARDENING\.md' -Description 'link to the scanner hardening contract'
Assert-FileContains -RelativePath '.editorconfig' -Pattern '(?ms)^\[\*\.ps1\].*?^charset\s*=\s*utf-8-bom\s*$' -Description 'PowerShell UTF-8 BOM compatibility'
Assert-FileContains -RelativePath '.gitignore' -Pattern '\.private-markers\.local' -Description 'ignore local private marker files'
Assert-FileContains -RelativePath 'CONTRIBUTING.md' -Pattern '(?im)no token|never.*token|secret' -Description 'secret-safe contribution guidance'
Assert-FileContains -RelativePath 'SECURITY.md' -Pattern '(?im)do not.*public|private|security' -Description 'private vulnerability reporting guidance'
Assert-FileContains -RelativePath '.github/workflows/validate.yml' -Pattern 'validate-oss-readiness\.ps1' -Description 'OSS readiness validation in CI'
Assert-FileContains -RelativePath '.github/workflows/validate.yml' -Pattern 'scan-private-markers\.ps1' -Description 'private marker scan in CI'
Assert-FileContains -RelativePath '.github/workflows/validate.yml' -Pattern 'test-scan-private-markers\.ps1' -Description 'private marker scan self-test in CI'
Assert-FileContains -RelativePath '.github/workflows/validate.yml' -Pattern 'windows-latest' -Description 'Windows validation runner in CI'
Assert-FileContains -RelativePath '.github/workflows/validate.yml' -Pattern 'ubuntu-latest' -Description 'Ubuntu validation runner in CI'
Assert-FileContains -RelativePath '.github/workflows/validate.yml' -Pattern 'timeout-minutes:\s*25' -Description 'bounded CI validation job'
Assert-WorkflowActionPin `
    -RelativePath '.github/workflows/validate.yml' `
    -Action 'actions/checkout' `
    -Commit 'fbc6f3992d24b796d5a048ff273f7fcc4a7b6c09' `
    -Description 'exact immutable checkout action revision'
Assert-FileContains -RelativePath '.github/workflows/validate.yml' -Pattern 'shell:\s*powershell' -Description 'Windows PowerShell 5.1 validation in CI'

Test-SkillFrontmatter

if ($failures.Count -gt 0) {
    Write-Host 'OSS readiness validation failed:'
    foreach ($failure in $failures) {
        Write-Host "- $failure"
    }
    exit 1
}

Write-Host "OSS readiness validation passed for $root"
exit 0
