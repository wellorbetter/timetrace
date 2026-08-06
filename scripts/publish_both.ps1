# 一次发布 GitHub + Gitee 两个平台
# 用法: powershell -ExecutionPolicy Bypass -File scripts/publish_both.ps1 -Tag v1.0.1 -Notes "更新说明..."
# 环境: GITEE_TOKEN（Gitee 私人令牌）
param([string]$Tag = 'v1.0.0', [string]$Notes = 'TimeTrace release', [string]$Zip = '')

$root = 'I:\Github\pr\timetrace'
if (-not $Zip) { $Zip = "$root\dist\TimeTrace-$Tag-windows-x64.zip" }
if (-not (Test-Path $Zip)) { Write-Error "zip 不存在: $Zip"; exit 1 }
$Token = $env:GITEE_TOKEN
if (-not $Token) { Write-Error "请设置 GITEE_TOKEN"; exit 1 }

# 0. 打 tag + 双推（GitHub + Gitee 一次搞定）
git -C $root tag $Tag 2>$null
git -C $root push origin main
git -C $root push origin $Tag
Write-Output "== 代码已双推 =="

# 1. GitHub release（gh CLI）
gh release create $Tag $Zip --title "TimeTrace $Tag" --notes $Notes --repo wellorbetter/timetrace
Write-Output "== GitHub release 完成 =="

# 2. Gitee release（API）
$api = 'https://gitee.com/api/v5'
$owner = 'wellorbetter'; $repo = 'timetrace'
$rels = Invoke-RestMethod -Uri "$api/repos/$owner/$repo/releases?per_page=20&access_token=$Token"
$relId = $null
foreach ($r in $rels) { if ($r.tag_name -eq $Tag) { $relId = $r.id } }
if (-not $relId) {
  $rel = Invoke-RestMethod -Uri "$api/repos/$owner/$repo/releases?access_token=$Token" -Method Post -Body @{
    tag_name = $Tag; name = "TimeTrace $Tag"; body = $Notes; target_commitish = 'main'
  }
  $relId = $rel.id
}
$url = "$api/repos/$owner/$repo/releases/$relId/attach_files?access_token=$Token"
& curl.exe -s -X POST $url -F "file=@$Zip" | Out-Null
Write-Output "== Gitee release 完成 =="
Write-Output "GitHub: https://github.com/$owner/$repo/releases/tag/$Tag"
Write-Output "Gitee : https://gitee.com/$owner/$repo/releases/tag/$Tag"
