# Move as pastas com dado pessoal do bucket PÚBLICO `fotos-campo` p/ o PRIVADO `fotos-privadas` (LGPD, 2026-11-06).
# Pastas: cnh/ pessoas/ epi/ seg/ sst/  — mesmo nome de arquivo no destino (as tabelas não mudam).
#
# ⚠️ Rode SÓ DEPOIS do app com sw coleta-v331 estar publicado (o app novo procura essas pastas no bucket privado;
#    o antigo só enxerga o público). Pode rodar de novo quantas vezes quiser: só move o que ainda estiver no público
#    (útil p/ pegar envios de quem estava com o app antigo aberto).
#
# Uso (PowerShell), na pasta do repositório:
#   powershell -ExecutionPolicy Bypass -File scripts\storage\mover_fotos_privadas.ps1            # só conta (simulação)
#   powershell -ExecutionPolicy Bypass -File scripts\storage\mover_fotos_privadas.ps1 -Aplicar   # move de verdade
# A chave service_role é pedida na hora (Supabase Dashboard › Project Settings › API Keys) e não fica salva.

param([switch]$Aplicar)
$ErrorActionPreference = 'Stop'
$base    = 'https://lwttadkctfznidzvmury.supabase.co/storage/v1'
$origem  = 'fotos-campo'
$destino = 'fotos-privadas'
$pastas  = @('cnh', 'pessoas', 'epi', 'seg', 'sst')

$sec = Read-Host -AsSecureString 'Cole a chave service_role (secret) e tecle Enter'
$key = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec))
if (-not $key) { Write-Host 'Nenhuma chave informada — nada foi feito.'; exit 1 }
$h = @{ apikey = $key }
if ($key.StartsWith('eyJ')) { $h['Authorization'] = "Bearer $key" }   # chave antiga (JWT) vai também no Authorization

function Listar($pasta) {
  $tudo = @(); $off = 0
  while ($true) {
    $body = @{ prefix = "$pasta/"; limit = 1000; offset = $off; sortBy = @{ column = 'name'; order = 'asc' } } | ConvertTo-Json -Compress
    $r = Invoke-RestMethod -Method Post -Uri "$base/object/list/$origem" -Headers $h -ContentType 'application/json' -Body $body
    $arqs = @($r | Where-Object { $_.id })            # id nulo = subpasta (não há nestas pastas)
    $tudo += $arqs | ForEach-Object { "$pasta/$($_.name)" }
    if (@($r).Count -lt 1000) { break }; $off += 1000
  }
  return $tudo
}

try {
  $total = 0; $ok = 0; $erros = @()
  foreach ($p in $pastas) {
    $nomes = Listar $p
    Write-Host ("{0,-8} {1,5} arquivo(s) no bucket público" -f "$p/", $nomes.Count)
    $total += $nomes.Count
    if (-not $Aplicar) { continue }
    foreach ($n in $nomes) {
      $body = @{ bucketId = $origem; sourceKey = $n; destinationBucket = $destino; destinationKey = $n } | ConvertTo-Json -Compress
      try { Invoke-RestMethod -Method Post -Uri "$base/object/move" -Headers $h -ContentType 'application/json' -Body $body | Out-Null; $ok++ }
      catch { $erros += "$n :: $($_.Exception.Message)" }
    }
  }
  if (-not $Aplicar) { Write-Host "`nSimulação: $total arquivo(s) seriam movidos. Rode de novo com -Aplicar para mover." }
  else {
    Write-Host "`nMovidos: $ok de $total"
    if ($erros.Count) { Write-Host "Falharam ($($erros.Count)):"; $erros | ForEach-Object { Write-Host "  $_" } }
  }
} finally { $key = $null; $h = $null }
