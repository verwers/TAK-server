<#
.SYNOPSIS
    Share generated certs / Data Packages over HTTP (Windows PowerShell equivalent of shareCerts.sh).

.DESCRIPTION
    Serves *.zip files from the certs directory over a small HTTP listener.

    WARNING: this serves CERTIFICATES and KEYS over plain HTTP with NO authentication.
    Anyone who can reach the bound address can download them. Use only on a trusted
    network and stop the server (Ctrl-C) as soon as your clients have what they need.

.PARAMETER Public
    Bind to 0.0.0.0 (LAN-wide). Default is 127.0.0.1 (loopback only).

.PARAMETER Port
    TCP port to listen on. Default 12345.

.PARAMETER Src
    Source directory containing the .zip files. Default: data/certs
    (overridable via $env:TAK_CERT_DIR).

.EXAMPLE
    .\scripts\shareCerts.ps1
    # Safe default: http://127.0.0.1:12345/

.EXAMPLE
    .\scripts\shareCerts.ps1 -Public -Port 8000
    # LAN-wide on port 8000
#>
[CmdletBinding()]
param(
    [switch]$Public,
    [int]$Port = 12345,
    [string]$Src = $(if ($env:TAK_CERT_DIR) { $env:TAK_CERT_DIR } else { 'data/certs' })
)

$ErrorActionPreference = 'Stop'

$bind = if ($Public) { '0.0.0.0' } else { '127.0.0.1' }

if (-not (Test-Path $Src)) {
    Write-Error "Source directory not found: $Src"
    exit 1
}

$zips = @(Get-ChildItem -Path $Src -Filter '*.zip' -File -ErrorAction SilentlyContinue)
if ($zips.Count -eq 0) {
    Write-Error "No .zip files found in $Src"
    exit 1
}

if ($bind -ne '127.0.0.1') {
    Write-Warning "Serving $Src\*.zip on ${bind}:${Port} with NO auth."
    Write-Warning "Anyone on this network can download these files."
}

# HttpListener requires a hostname it can resolve; '+' = bind all, otherwise loopback.
# Using '+' may require admin / URL ACL on Windows; fall back gracefully.
$prefix = if ($bind -eq '0.0.0.0') { "http://+:$Port/" } else { "http://127.0.0.1:$Port/" }
$displayUrl = if ($bind -eq '0.0.0.0') { "http://${bind}:${Port}/" } else { "http://127.0.0.1:${Port}/" }

$listener = [System.Net.HttpListener]::new()
$listener.Prefixes.Add($prefix)

try {
    $listener.Start()
}
catch [System.Net.HttpListenerException] {
    Write-Error @"
Failed to bind to $prefix : $($_.Exception.Message)

If you used -Public, Windows requires either:
  1. Running this script in an elevated (Administrator) PowerShell, or
  2. Adding a URL ACL once:
       netsh http add urlacl url=http://+:$Port/ user=$env:USERNAME
"@
    exit 1
}

Write-Host ""
Write-Host "Serving $($zips.Count) file(s) from $Src on $displayUrl" -ForegroundColor Green
Write-Host "Press Ctrl-C to stop." -ForegroundColor Yellow
Write-Host ""
foreach ($z in $zips) { Write-Host "  - $($z.Name)" }
Write-Host ""

try {
    while ($listener.IsListening) {
        $ctx = $listener.GetContext()
        $req = $ctx.Request
        $res = $ctx.Response

        # Sanitize requested path: strip leading slash, reject traversal.
        $reqPath = [System.Uri]::UnescapeDataString($req.Url.AbsolutePath.TrimStart('/'))

        if ([string]::IsNullOrEmpty($reqPath)) {
            # Directory index
            $body = "<html><body><h1>Data Packages</h1><ul>"
            foreach ($z in $zips) {
                $body += "<li><a href=""/$([System.Uri]::EscapeDataString($z.Name))"">$($z.Name)</a></li>"
            }
            $body += "</ul></body></html>"
            $bytes = [System.Text.Encoding]::UTF8.GetBytes($body)
            $res.ContentType = 'text/html; charset=utf-8'
            $res.ContentLength64 = $bytes.Length
            $res.OutputStream.Write($bytes, 0, $bytes.Length)
        }
        elseif ($reqPath -match '[\\/]' -or $reqPath -eq '..') {
            $res.StatusCode = 400
        }
        else {
            $file = $zips | Where-Object { $_.Name -eq $reqPath } | Select-Object -First 1
            if ($null -eq $file) {
                $res.StatusCode = 404
            }
            else {
                $res.ContentType = 'application/zip'
                $res.ContentLength64 = $file.Length
                $fs = [System.IO.File]::OpenRead($file.FullName)
                try {
                    $fs.CopyTo($res.OutputStream)
                }
                finally {
                    $fs.Dispose()
                }
                Write-Host "  served: $($file.Name) -> $($req.RemoteEndPoint)" -ForegroundColor DarkGray
            }
        }

        $res.Close()
    }
}
finally {
    if ($listener.IsListening) { $listener.Stop() }
    $listener.Close()
}
