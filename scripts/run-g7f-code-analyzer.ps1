$ErrorActionPreference = "Stop"

$reportDir = "reports"
New-Item -ItemType Directory -Force -Path $reportDir | Out-Null

Write-Host "Running AppExchange + Recommended Security rules..."
sf code-analyzer run `
    --workspace force-app `
    --rule-selector AppExchange `
    --rule-selector "Recommended:Security" `
    --severity-threshold 3 `
    --view detail `
    --output-file "$reportDir/G7F_AppExchange_Security.html" `
    --output-file "$reportDir/G7F_AppExchange_Security.json"

if ($LASTEXITCODE -ne 0) {
    Write-Error "AppExchange/Security Code Analyzer gate found Moderate-or-higher findings. Review the reports before proceeding."
    exit $LASTEXITCODE
}

Write-Host "Running the full Recommended rule set..."
sf code-analyzer run `
    --workspace force-app `
    --rule-selector Recommended `
    --severity-threshold 3 `
    --view detail `
    --output-file "$reportDir/G7F_Recommended.html" `
    --output-file "$reportDir/G7F_Recommended.json"

if ($LASTEXITCODE -ne 0) {
    Write-Error "Recommended Code Analyzer gate found Moderate-or-higher findings. Review the reports before proceeding."
    exit $LASTEXITCODE
}

Write-Host "Running LWC/JavaScript lint..."
npm run lint

if ($LASTEXITCODE -ne 0) {
    Write-Error "ESLint failed."
    exit $LASTEXITCODE
}

Write-Host ""
Write-Host "Static-analysis gate passed."
Write-Host "Reports:"
Write-Host "  $reportDir/G7F_AppExchange_Security.html"
Write-Host "  $reportDir/G7F_AppExchange_Security.json"
Write-Host "  $reportDir/G7F_Recommended.html"
Write-Host "  $reportDir/G7F_Recommended.json"
