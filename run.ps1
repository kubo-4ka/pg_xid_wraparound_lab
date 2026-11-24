# 使い方: .\run.ps1 e02_warn_stop   -> results\e02_warn_stop.txt
#  - VM 内スクリプトの終了コード (PASS=0 / FAIL=1) を伝播する
#  - ホスト側の環境 (Vagrant/VirtualBox) を結果の先頭に記録し、results\MANIFEST.sha256 を更新する
param([Parameter(Mandatory = $true)][string]$name)
Set-Location $PSScriptRoot
$out = "results\$name.txt"
$hostInfo = "# host: $((vagrant --version) -join ' ') / VirtualBox $((VBoxManage --version) -join ' ') / box almalinux/9 9.7.20260518"
Set-Content -Encoding utf8 $out $hostInfo
# vagrant ssh の stderr を PowerShell の例外レコードにしないよう、VM 側で 2>&1 にまとめる
$cmd = "sed -i 's/\r$//' /vagrant/scripts/*.sh /vagrant/scripts/*.sql; sudo -iu postgres bash /vagrant/scripts/$name.sh 2>&1; echo EXIT_CODE=`$?"
vagrant ssh -c $cmd -- -T | Out-File -Append -Encoding utf8 $out
$code = 1
$m = Select-String -Path $out -Pattern '^EXIT_CODE=(\d+)' | Select-Object -Last 1
if ($m) { $code = [int]$m.Matches[0].Groups[1].Value }
Select-String -Path $out -Pattern '^(SUMMARY|RESULT|CHECK FAIL)' | ForEach-Object { $_.Line }
# 証跡の同一性 (F-07): スクリプト・結果・ログの SHA-256
Get-ChildItem scripts\*, results\*.txt, results\logs\*, report\*, REPORT.md -File | Get-FileHash -Algorithm SHA256 |
  ForEach-Object { "$($_.Hash.ToLower())  $(Resolve-Path -Relative $_.Path)" } |
  Set-Content -Encoding utf8 results\MANIFEST.sha256
"exit=$code lines=$((Get-Content $out).Count)"
exit $code
