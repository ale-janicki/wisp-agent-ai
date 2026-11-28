export type ShellId = "pwsh" | "powershell" | "cmd";

export type LaunchPlan = {
  shell: ShellId;
  integration: string | null;
  nonce: string | null;
  integrated: boolean;
};

export function makeNonce(): string {
  const bytes = new Uint8Array(16);
  crypto.getRandomValues(bytes);
  return Array.from(bytes, (b) => b.toString(16).padStart(2, "0")).join("");
}

export function powershellScript(): string {
  return `$global:__wispNonce = $env:WISP_MARK_NONCE
Remove-Item Env:WISP_MARK_NONCE -ErrorAction SilentlyContinue
foreach ($__wispProfile in @($PROFILE.AllUsersAllHosts, $PROFILE.AllUsersCurrentHost, $PROFILE.CurrentUserAllHosts, $PROFILE.CurrentUserCurrentHost)) {
  if ($__wispProfile -and (Test-Path -LiteralPath $__wispProfile)) {
    try { . $__wispProfile } catch { Write-Host $_ -ForegroundColor Red }
  }
}
Remove-Variable __wispProfile -ErrorAction SilentlyContinue
if ($global:__wispNonce -and -not $global:__wispHooked) {
  $global:__wispHooked = $true
  $global:__wispRunning = $false
  $global:__wispHistSent = $false
  $global:__wispOrigPrompt = $function:prompt

  function global:__wispMark([string]$body) {
    [Console]::Out.Write(([string][char]27) + ']6973;' + $global:__wispNonce + ';' + $body + ([string][char]7))
  }

  function global:__wispB64([string]$text) {
    [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($text))
  }

  function global:prompt {
    $lastOk = $?
    $lastCode = $global:LASTEXITCODE
    $esc = [char]27
    $bel = [char]7
    $n = $global:__wispNonce
    $pre = ''
    if ($global:__wispRunning) {
      $exit = 0
      if (-not $lastOk) {
        $exit = 1
        if ($lastCode -is [int] -and $lastCode -ne 0) { $exit = $lastCode }
      }
      $pre += "$esc]6973;$n;D;$exit$bel"
      $global:__wispRunning = $false
    }
    try {
      if ($PWD.Provider.Name -eq 'FileSystem') {
        $url = ([System.Uri]$PWD.ProviderPath).AbsoluteUri
        $pre += "$esc]6973;$n;cwd=$url$bel"
      }
    } catch {}
    if (-not $global:__wispHistSent) {
      $global:__wispHistSent = $true
      try {
        $hist = (Get-PSReadLineOption).HistorySavePath
        if ($hist) { $pre += "$esc]6973;$n;hist=$(__wispB64 $hist)$bel" }
      } catch {}
    }
    $pre += "$esc]6973;$n;A$bel"
    if (-not $lastOk) { Write-Error 'wisp' -ErrorAction Ignore }
    $global:LASTEXITCODE = $lastCode
    $text = ''
    try { $text = [string](& $global:__wispOrigPrompt) } catch { $text = 'PS ' + $PWD.Path + '> ' }
    $pre + $text + "$esc]6973;$n;B$bel"
  }

  try {
    Set-PSReadLineKeyHandler -Chord Enter -ScriptBlock {
      $line = $null
      $cursor = $null
      [Microsoft.PowerShell.PSConsoleReadLine]::GetBufferState([ref]$line, [ref]$cursor)
      $tokens = $null
      $parseErrors = $null
      [void][System.Management.Automation.Language.Parser]::ParseInput($line, [ref]$tokens, [ref]$parseErrors)
      $incomplete = $false
      foreach ($parseError in $parseErrors) { if ($parseError.IncompleteInput) { $incomplete = $true; break } }
      if (-not $incomplete -and $line.Trim().Length -gt 0) {
        [Microsoft.PowerShell.PSConsoleReadLine]::SetCursorPosition($line.Length)
        __wispMark ('cmd=' + (__wispB64 $line.Substring(0, [Math]::Min($line.Length, 4096))))
        __wispMark 'C'
        $global:__wispRunning = $true
      }
      [Microsoft.PowerShell.PSConsoleReadLine]::AcceptLine()
    }
  } catch {
    __wispMark 'declined'
  }
} else {
  Remove-Variable __wispNonce -Scope Global -ErrorAction SilentlyContinue
}
`;
}

export function integrationScript(shell: ShellId): string | null {
  return shell === "pwsh" || shell === "powershell" ? powershellScript() : null;
}

export function planLaunch(shell: ShellId, enabled: boolean, nonce: string): LaunchPlan {
  const integration = enabled ? integrationScript(shell) : null;
  if (integration === null) return { shell, integration: null, nonce: null, integrated: false };
  return { shell, integration, nonce, integrated: true };
}
