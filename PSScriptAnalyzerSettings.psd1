@{
    # diagnose.ps1 is an interactive tool that prints colored results for players,
    # so Write-Host is the intended output.
    ExcludeRules = @('PSAvoidUsingWriteHost')
}
