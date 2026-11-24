# Vadeli Pusula yerel sunucusu
# - Paneli http://localhost:8765 adresinden sunar
# - /coinalyze/... isteklerini API anahtarını ekleyerek api.coinalyze.net'e iletir
#   (anahtar sadece bu bilgisayarda, coinalyze-key.txt dosyasında durur; panele veya tarayıcıya gönderilmez)

$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$port = 8765
$keyFile = Join-Path $root 'coinalyze-key.txt'
$cache = @{}

function Get-ApiKey {
  if (-not (Test-Path $keyFile)) { return $null }
  foreach ($line in Get-Content $keyFile) {
    $k = $line.Trim()
    if ($k -and -not $k.StartsWith('#') -and $k -ne 'BURAYA_ANAHTARI_YAPISTIR') { return $k }
  }
  return $null
}

function Send-Bytes($ctx, [int]$status, [string]$type, [byte[]]$bytes) {
  $ctx.Response.StatusCode = $status
  $ctx.Response.ContentType = $type
  $ctx.Response.Headers.Add('Cache-Control', 'no-store')
  $ctx.Response.OutputStream.Write($bytes, 0, $bytes.Length)
  $ctx.Response.Close()
}
function Send-Text($ctx, [int]$status, [string]$type, [string]$text) {
  Send-Bytes $ctx $status $type ([System.Text.Encoding]::UTF8.GetBytes($text))
}

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add("http://localhost:$port/")
try { $listener.Start() } catch { Write-Host "Port $port kullanımda; sunucu muhtemelen zaten açık."; exit 0 }
Write-Host "Vadeli Pusula sunucusu çalışıyor: http://localhost:$port  (kapatmak için bu pencereyi kapatın)"

while ($listener.IsListening) {
  $ctx = $listener.GetContext()
  try {
    $path = $ctx.Request.Url.AbsolutePath

    if ($path -like '/coinalyze/*') {
      $key = Get-ApiKey
      if (-not $key) { Send-Text $ctx 503 'application/json' '{"error":"no_key","message":"coinalyze-key.txt dosyasında API anahtarı yok"}'; continue }
      $sub = $path.Substring('/coinalyze/'.Length)
      $url = "https://api.coinalyze.net/v1/$sub" + $ctx.Request.Url.Query
      $now = Get-Date
      # Önbellek anahtarı from/to içermez; böylece sayfa yenilense de aynı veri tekrar sorgulanmaz.
      # Günlük veriler ve funding geçmişi 15 dk, diğerleri ~2 dk saklanır (Coinalyze ücretsiz planı dakikada ~40 sembol sorgusu).
      $cacheKey = ($sub + $ctx.Request.Url.Query) -replace '[&?](from|to)=\d+', ''
      $ttl = if ($cacheKey -match 'interval=daily|funding-rate-history') { 900 } else { 110 }
      if ($cache.ContainsKey($cacheKey) -and ($now - $cache[$cacheKey].t).TotalSeconds -lt $ttl) {
        Send-Text $ctx 200 'application/json' $cache[$cacheKey].body; continue
      }
      try {
        $r = Invoke-WebRequest -Uri $url -Headers @{ api_key = $key } -UseBasicParsing -TimeoutSec 20
        $body = $r.Content
        $cache[$cacheKey] = @{ t = $now; body = $body }
        Send-Text $ctx 200 'application/json' $body
      } catch [System.Net.WebException] {
        # Sınır aşılırsa elde varsa son veriyi ver
        if ($cache.ContainsKey($cacheKey)) { Send-Text $ctx 200 'application/json' $cache[$cacheKey].body; continue }
        $code = 502; $body = '{"error":"upstream"}'
        if ($_.Exception.Response) {
          $code = [int]$_.Exception.Response.StatusCode
          $sr = New-Object System.IO.StreamReader($_.Exception.Response.GetResponseStream())
          $body = $sr.ReadToEnd()
          if (-not $body) { $body = '{"error":"upstream"}' }
        }
        Send-Text $ctx $code 'application/json' $body
      }
      continue
    }

    if ($path -eq '/coinalyze-status') {
      $has = [bool](Get-ApiKey)
      Send-Text $ctx 200 'application/json' ('{"key":' + $has.ToString().ToLower() + '}'); continue
    }

    $rel = $path.TrimStart('/')
    if ($rel -eq '') { $rel = 'vadeli-pusula.html' }
    if ($rel -notmatch '^[A-Za-z0-9._-]+\.(html|css|js|json)$') { Send-Text $ctx 404 'text/plain' 'bulunamadı'; continue }
    $file = Join-Path $root $rel
    if (Test-Path $file -PathType Leaf) {
      $type = @{ html = 'text/html; charset=utf-8'; css = 'text/css'; js = 'text/javascript'; json = 'application/json' }[$rel.Split('.')[-1]]
      Send-Bytes $ctx 200 $type ([System.IO.File]::ReadAllBytes($file))
    } else { Send-Text $ctx 404 'text/plain' 'bulunamadı' }
  } catch {
    try { Send-Text $ctx 500 'text/plain' 'sunucu hatası' } catch {}
  }
}
