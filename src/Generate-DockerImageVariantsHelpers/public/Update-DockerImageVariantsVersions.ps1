function Update-DockerImageVariantsVersions {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [System.Collections.Specialized.OrderedDictionary]$VersionsChanged
    ,
        [Parameter(HelpMessage="Whether to perform a dry run (skip writing versions.json")]
        [switch]$DryRun
    ,
        [Parameter(HelpMessage="Whether to open a PR for each updated version in version.json")]
        [switch]$PR
    )

    foreach ($vc in $VersionsChanged.Values) {
        if ($vc['kind'] -eq 'new') {
            "New: $( $vc['to'] )" | Write-Host -ForegroundColor Green
            $versions = (Get-DockerImageVariantsVersions) + $vc['to']
            if (!$DryRun) {
                Set-DockerImageVariantsVersions $versions
                if ($PR) {
                    New-DockerImageVariantsPR -Version $vc['to'] -Verb add
                }
            }
        }elseif ($vc['kind'] -eq 'update') {
            $versions = [System.Collections.ArrayList]@()
            foreach ($v in (Get-DockerImageVariantsVersions)) {
                if ($v -eq $vc['from']) {
                    "Update: $( $vc['from'] ) to $( $vc['to'] )" | Write-Host -ForegroundColor Green
                    $versions.Add($vc['to']) > $null
                }else {
                    $versions.Add($vc) > $null
                }
            }
            if (!$DryRun) {
                Set-DockerImageVariantsVersions $versions
                if ($PR) {
                    New-DockerImageVariantsPR -Version $vc['from'] -VersionNew $vc['to'] -Verb update
                }
            }
        }
    }
}