$ErrorActionPreference = "Stop"

$org = "devscratchorg"

$tests = @(
    "SABFXSecurityHardeningTest",
    "SABFXRevaluationPreviewServiceTest",
    "SABFXRevaluationPostingServiceTest",
    "SABFXRevaluationReversalServiceTest",
    "SABRealizedFXSettlementServiceTest",
    "SABForeignCurrencySettlementServiceTest",
    "SABFXOperationsWorkspaceControllerTest",
    "SABExchangeRateServiceTest",
    "SABPostingServiceTest",
    "SABReversalServiceTest",
    "SABAccountingEventServiceTest",
    "SABCompanyAccessServiceTest",
    "SABSecurityHardeningTest"
)

foreach ($testClass in $tests) {
    Write-Host ""
    Write-Host "============================================================"
    Write-Host "Running $testClass"
    Write-Host "============================================================"

    sf apex run test `
        --tests $testClass `
        --target-org $org `
        --result-format human `
        --wait 120 `
        --code-coverage

    if ($LASTEXITCODE -ne 0) {
        Write-Error "G7F regression stopped because $testClass failed."
        exit $LASTEXITCODE
    }
}

Write-Host ""
Write-Host "G7F regression gate passed: all test classes completed successfully."
