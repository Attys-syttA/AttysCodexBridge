$envFile = 'D:\codex_works\telecodex\.env'
Get-Content $envFile | ForEach-Object {
  if ($_ -match '^[A-Z0-9_]+=') {
    $key, $value = $_.Split('=', 2)
    Set-Item -Path ("Env:" + $key) -Value $value
  }
}
Set-Location 'D:\codex_works\telecodex'
node 'D:\codex_works\telecodex\dist\index.js'
