# 使い方: .\run_all.ps1                 -> 全シナリオを順に実行 (失敗しても続行)
#         .\run_all.ps1 e09_many_small_tables e10_truncate_and_locks
#  - 各シナリオの PASS/FAIL と所要時間を results\RUN_SUMMARY.txt に追記し、1 つでも失敗なら exit 1
param([Parameter(ValueFromRemainingArguments = $true)][string[]]$names)
Set-Location $PSScriptRoot
if (-not $names) { $names = Get-ChildItem scripts\e*.sh | ForEach-Object { $_.BaseName } }
$failed = 0
foreach ($n in $names) {
  $t0 = Get-Date
  & .\run.ps1 $n | Out-Null
  $code = $LASTEXITCODE
  $sec = [int]((Get-Date) - $t0).TotalSeconds
  $summary = (Select-String -Path "results\$n.txt" -Pattern '^SUMMARY' | Select-Object -Last 1).Line
  $line = "{0:yyyy-MM-dd HH:mm:ss} {1,-28} exit={2} {3,5}s {4}" -f (Get-Date), $n, $code, $sec, $summary
  Add-Content -Encoding utf8 results\RUN_SUMMARY.txt $line
  $line
  if ($code -ne 0) { $failed++ }
}
"failed scenarios: $failed"
if ($failed -gt 0) { exit 1 } else { exit 0 }
