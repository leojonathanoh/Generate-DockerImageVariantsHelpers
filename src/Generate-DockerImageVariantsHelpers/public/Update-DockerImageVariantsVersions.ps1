function Update-DockerImageVariantsVersions {
    [CmdletBinding(DefaultParameterSetName='Default',SupportsShouldProcess)]
    param (
        [Parameter(HelpMessage='Scriptblock to run before git add and git commit on a PR branch')]
        [Parameter(ParameterSetName='Default')]
        [Parameter(ParameterSetName='Pipeline')]
        [scriptblock]$CommitPreScriptblock
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
        [Parameter(HelpMessage="-AutoRelease tag convention")]
        [Parameter(ParameterSetName='Default')]
        [Parameter(ParameterSetName='Pipeline')]
        [ValidateSet('calver', 'semver')]
        [string]$AutoReleaseTagConvention
    )

    process {
        Set-StrictMode -Version Latest
        $callerEA = $ErrorActionPreference
        $ErrorActionPreference = 'Stop'
        try {
            $prs = @()
            $autoMergeResults = [ordered]@{
                AllPRs = @()
                FailPRNumbers = @()
                FailCount = 0
            }
            $_pr = $null
            $versionsConfig = Get-DockerImageVariantsVersions
            foreach ($pkg in $versionsConfig.psobject.Properties.Name) {
                $versions = $versionsConfig.$pkg.versions
                $versionsNew = try {
                    Invoke-Command -ScriptBlock ([scriptblock]::Create($versionsConfig.$pkg.versionsNewScript))
                }catch {
                    "Error in $pkg.versionsNewScript. Please review." | Write-Warning
                    throw
                }
                if ($null -eq $versionsNew) {
                    throw "$pkg.versionsNewScript returned null. It should return an array of versions (semver)."
                }
                $versionsChanged = Get-VersionsChanged -Versions $versions -VersionsNew $versionsNew -AsObject -Descending

                $changedCount = ($versionsChanged.Values | ? { $_['kind'] -ne 'existing' } | Measure-Object).Count
                if ($changedCount -eq 0) {
                    "No changed versions. Nothing to do" | Write-Host -ForegroundColor Green
                }else {
                    foreach ($vc in $VersionsChanged.Values) {
                        # Update versions.json and open PR
                        if ($vc['kind'] -eq 'new' -or $vc['kind'] -eq 'update') {
                            if ($PR) {
                                { git checkout master } | Execute-Command | Write-Host
                                { git pull origin master } | Execute-Command | Write-Host
                            }

                            if ($vc['kind'] -eq 'new') {
                                if ($vc['to'] -notin $versions) {
                                    "> New: $( $vc['to'] )" | Write-Host -ForegroundColor Green
                                    $versionsUpdated = @(
                                        $vc['to']
                                        $versions
                                    )
                                    $versionsUpdated = $versionsUpdated | Select-Object -Unique | Sort-Object { [version]$_ } -Descending
                                    $versionsConfig.$pkg.versions = $versionsUpdated
                                    Set-DockerImageVariantsVersions -Versions $versionsConfig
                                    if ($PR) {
                                        $prs += $_pr = New-DockerImageVariantsPR -Package $pkg -Version $vc['to'] -Verb add -CommitPreScriptblock $CommitPreScriptblock
                                    }
                                }
                            }elseif ($vc['kind'] -eq 'update') {
                                $versionsUpdated = [System.Collections.ArrayList]@()
                                foreach ($v in $versions) {
                                    if ($v -eq $vc['from']) {
                                        "> Update: $( $vc['from'] ) to $( $vc['to'] )" | Write-Host -ForegroundColor Green
                                        $versionsUpdated.Add($vc['to']) > $null
                                    }else {
                                        $versionsUpdated.Add($v) > $null
                                    }
                                }
                                $versionsUpdated = $versionsUpdated | Select-Object -Unique | Sort-Object { [version]$_ } -Descending
                                $versionsConfig.$pkg.versions = $versionsUpdated
                                Set-DockerImageVariantsVersions -Versions $versionsConfig
                                if ($PR) {
                                    $prs += $_pr = New-DockerImageVariantsPR -Package $pkg -Version $vc['from'] -VersionNew $vc['to'] -Verb update -CommitPreScriptblock $CommitPreScriptblock
                                }
                            }

                            # Merge PR
                            if ($PR -and $AutoMergeQueue) {
                                if ($WhatIfPreference) {
                                    $_pr = [pscustomobject]@{
                                        number = 1
                                    }
                                }
                                try {
                                    "Will automerge PR #$( $_pr.number )" | Write-Host -ForegroundColor Green
                                    $autoMergeResults['AllPRs'] += Automerge-DockerImageVariantsPR -PR $_pr
                                    "Automerge succeeded for PR #$( $_pr.number )" | Write-Host -ForegroundColor Green
                                }catch {
                                    "Automerge failed for PR #$( $_pr.number )" | Write-Warning
                                    $_ | Write-Error -ErrorAction Continue
                                    $autoMergeResults['AllPRs'] += $_pr
                                    $autoMergeResults['FailPRNumbers'] += $_pr.number
                                    $autoMergeResults['FailCount']++
                                }
                            }
                        }
                    }
                }
            }

            if ($PR -and $AutoMergeQueue) {
                # Error if any PR failed to merge
                if ($autoMergeResults['FailCount']) {
                    $msg = "$( $autoMergeResults['FailCount'] ) PRs failed to merge. PRs: $( ($autoMergeResults['PRs'] | % { "#$_" }) -join ', ' )"
                    if ($ErrorActionPreference -eq 'Stop') {
                        throw $msg
                    }
                    if ($ErrorActionPreference -eq 'Continue') {
                        $msg | Write-Error
                    }
                }
                if ($PSCmdlet.ShouldProcess("Result of merged PRs", 'return')) {
                    $autoMergeResults   # Return the results
                }
            }elseif ($PR) {
                if ($PSCmdlet.ShouldProcess("PRs", 'return')) {
                    ,$prs   # Return the PRs
                }
            }

            # Autorelease if all PRs merged
            if ($AutoRelease) {
                "Will create a tagged release" | Write-Host -ForegroundColor Green
                $tag = New-Release -TagConvention:$AutoReleaseTagConvention -WhatIf:$WhatIfPreference
                if ($PSCmdlet.ShouldProcess("tag", 'return')) {
                    $tag
                }
            }
        }catch {
            if ($callerEA -eq 'Stop') {
                throw
            }
            if ($callerEA -eq 'Continue') {
                $_ | Write-Error -ErrorAction Continue
            }
        }
    }
}
