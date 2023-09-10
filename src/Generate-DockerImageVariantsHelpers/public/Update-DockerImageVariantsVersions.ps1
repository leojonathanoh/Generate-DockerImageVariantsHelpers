function Update-DockerImageVariantsVersions {
    [CmdletBinding(DefaultParameterSetName='Default',SupportsShouldProcess)]
    param (
        [Parameter(Mandatory,ParameterSetName='Default',Position=0)]
        [ValidateNotNullOrEmpty()]
        [System.Collections.Specialized.OrderedDictionary]$VersionsChanged
    ,
        [Parameter(HelpMessage="Whether to open a PR for each updated version in version.json")]
        [Parameter(ParameterSetName='Default')]
        [Parameter(ParameterSetName='Pipeline')]
        [switch]$PR
    ,
        [Parameter(HelpMessage="Whether to merge each PR one after another (note that this is not GitHub merge queue which cannot handle merge conflicts). The queue ensures each PR is rebased to prevent merge conflicts.")]
        [Parameter(ParameterSetName='Default')]
        [Parameter(ParameterSetName='Pipeline')]
        [switch]$AutoMergeQueue
    ,
        [Parameter(HelpMessage="Whether to create a tagged release and closing milestone, after merging all PRs")]
        [Parameter(ParameterSetName='Default')]
        [Parameter(ParameterSetName='Pipeline')]
        [switch]$AutoRelease
    ,
        [Parameter(ValueFromPipeline,ParameterSetName='Pipeline')]
        [ValidateNotNullOrEmpty()]
        [System.Collections.Specialized.OrderedDictionary]$InputObject
    )

    if ($InputObject) {
        $VersionsChanged = $InputObject
    }

    $prs = @()
    foreach ($vc in $VersionsChanged.Values) {
        if ($vc['kind'] -eq 'new') {
            "New: $( $vc['to'] )" | Write-Host -ForegroundColor Green
            $versions = @(
                $vc['to']
                Get-DockerImageVariantsVersions
            )
            Set-DockerImageVariantsVersions -Versions $versions
            if ($PR) {
                $prs += New-DockerImageVariantsPR -Version $vc['to'] -Verb add
            }
        }elseif ($vc['kind'] -eq 'update') {
            $versions = [System.Collections.ArrayList]@()
            foreach ($v in (Get-DockerImageVariantsVersions)) {
                if ($v -eq $vc['from']) {
                    "Update: $( $vc['from'] ) to $( $vc['to'] )" | Write-Host -ForegroundColor Green
                    $versions.Add($vc['to']) > $null
                }else {
                    $versions.Add($v) > $null
                }
            }
            Set-DockerImageVariantsVersions -Versions $versions
            if ($PR) {
                $prs += New-DockerImageVariantsPR -Version $vc['from'] -VersionNew $vc['to'] -Verb update
            }
        }
    }

    if ($PR -and $AutoMergeQueue) {
        if ($PSCmdlet.ShouldProcess("PRs", 'automerge')) {
            "Will automerge all PRs" | Write-Host -ForegroundColor Green
            $autoMergeResults = [ordered]@{
                AllPRs = @()
                FailPRNumbers = @()
                FailCount = 0
            }
            for ($i = 0; $i -lt $prs.Count; $i++) {
                $_pr = $prs[$i]
                try {
                    "Will automerge PR #$( $_pr.number )" | Write-Host -ForegroundColor Green
                    $autoMergeResults['AllPRs'] += Automerge-DockerImageVariantsPR -PR $_pr
                    "Automerge succeeded for PR #$( $_pr.number )" | Write-Host -ForegroundColor Green
                }catch {
                    "Automerge failed for PR #$( $_pr.number )" | Write-Warning
                    $autoMergeResults['AllPRs'] += $_pr
                    $autoMergeResults['FailPRNumbers'] += $prs[$i].number
                    $autoMergeResults['FailCount']++
                }
            }
            if ($autoMergeResults['FailCount']) {
                $msg = "$( $autoMergeResults['FailCount'] ) PRs failed to merge. PRs: $( ($autoMergeResults['PRs'] | % { "#$_" }) -join ', ' )"
                if ($ErrorActionPreference -eq 'Stop') {
                    throw $msg
                }
                if ($ErrorActionPreference -eq 'Continue') {
                    $msg | Write-Error
                }
            }
        }
        if ($PSCmdlet.ShouldProcess("Result of merged PRs", 'return')) {
            $autoMergeResults   # Return the results
        }
        if ($AutoRelease) {
            if ($PSCmdlet.ShouldProcess("autorelease", 'create')) {
                $tag = New-Release
            }
            if ($PSCmdlet.ShouldProcess("Tag of release", 'return')) {
                $tag
            }
        }
    }elseif ($PR) {
        if ($PSCmdlet.ShouldProcess("PRs", 'return')) {
            ,$prs   # Return the PRs
        }
    }
}
