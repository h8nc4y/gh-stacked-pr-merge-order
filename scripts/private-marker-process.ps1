Set-StrictMode -Version Latest

# `$env:OS` is caller-controlled and therefore cannot select containment or
# argument-handling security paths. Derive the host kernel once from .NET.
$script:privateMarkerIsWindows =
    [Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT

# Windows の初回 child は atomic launcher だけから起動する。helper 自体を
# scanner と self-test の双方が共有し、どちらか一方だけ race が残るのを防ぐ。
if ($script:privateMarkerIsWindows) {
    $windowsProcessSupport = Join-Path `
        $PSScriptRoot `
        'private-marker-windows-process.ps1'
    if (-not (Test-Path -LiteralPath $windowsProcessSupport -PathType Leaf)) {
        throw 'Missing atomic Windows process support script.'
    }
    . $windowsProcessSupport
}

# Windows PowerShell 5.1 lacks Process.Kill(entireProcessTree). A kill-on-close
# Job Object also remains usable after the direct child exits, which is the only
# reliable way to stop a descendant that still owns a redirected pipe.
if ($script:privateMarkerIsWindows -and
    $null -eq ('GhStackedPrMergeOrder.PrivateMarkerJob' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;

namespace GhStackedPrMergeOrder
{
    public static class PrivateMarkerJob
    {
        private const uint JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE = 0x00002000;
        private const uint JOB_OBJECT_LIMIT_BREAKAWAY_OK = 0x00000800;
        private const uint JOB_OBJECT_LIMIT_SILENT_BREAKAWAY_OK = 0x00001000;
        private const int JobObjectExtendedLimitInformation = 9;

        [StructLayout(LayoutKind.Sequential)]
        private struct JOBOBJECT_BASIC_LIMIT_INFORMATION
        {
            public long PerProcessUserTimeLimit;
            public long PerJobUserTimeLimit;
            public uint LimitFlags;
            public UIntPtr MinimumWorkingSetSize;
            public UIntPtr MaximumWorkingSetSize;
            public uint ActiveProcessLimit;
            public UIntPtr Affinity;
            public uint PriorityClass;
            public uint SchedulingClass;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct IO_COUNTERS
        {
            public ulong ReadOperationCount;
            public ulong WriteOperationCount;
            public ulong OtherOperationCount;
            public ulong ReadTransferCount;
            public ulong WriteTransferCount;
            public ulong OtherTransferCount;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct JOBOBJECT_EXTENDED_LIMIT_INFORMATION
        {
            public JOBOBJECT_BASIC_LIMIT_INFORMATION BasicLimitInformation;
            public IO_COUNTERS IoInfo;
            public UIntPtr ProcessMemoryLimit;
            public UIntPtr JobMemoryLimit;
            public UIntPtr PeakProcessMemoryUsed;
            public UIntPtr PeakJobMemoryUsed;
        }

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode)]
        private static extern IntPtr CreateJobObject(
            IntPtr jobAttributes,
            string name
        );

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool SetInformationJobObject(
            IntPtr job,
            int informationClass,
            IntPtr information,
            uint informationLength
        );

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool AssignProcessToJobObject(
            IntPtr job,
            IntPtr process
        );

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool CloseHandle(IntPtr handle);

        [DllImport("kernel32.dll")]
        private static extern IntPtr GetCurrentProcess();

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool IsProcessInJob(
            IntPtr process,
            IntPtr job,
            out bool result
        );

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool QueryInformationJobObject(
            IntPtr job,
            int informationClass,
            IntPtr information,
            uint informationLength,
            IntPtr returnLength
        );

        public static IntPtr CreateKillOnClose()
        {
            IntPtr job = CreateJobObject(IntPtr.Zero, null);
            if (job == IntPtr.Zero)
            {
                throw new Win32Exception(
                    Marshal.GetLastWin32Error(),
                    "CreateJobObject failed."
                );
            }

            var information = new JOBOBJECT_EXTENDED_LIMIT_INFORMATION();
            information.BasicLimitInformation.LimitFlags =
                JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
            int size = Marshal.SizeOf(
                typeof(JOBOBJECT_EXTENDED_LIMIT_INFORMATION)
            );
            IntPtr buffer = Marshal.AllocHGlobal(size);
            try
            {
                Marshal.StructureToPtr(information, buffer, false);
                if (!SetInformationJobObject(
                    job,
                    JobObjectExtendedLimitInformation,
                    buffer,
                    (uint)size
                ))
                {
                    throw new Win32Exception(
                        Marshal.GetLastWin32Error(),
                        "SetInformationJobObject failed."
                    );
                }
                return job;
            }
            catch
            {
                CloseHandle(job);
                throw;
            }
            finally
            {
                Marshal.FreeHGlobal(buffer);
            }
        }

        public static void Assign(IntPtr job, IntPtr process)
        {
            if (!AssignProcessToJobObject(job, process))
            {
                throw new Win32Exception(
                    Marshal.GetLastWin32Error(),
                    "AssignProcessToJobObject failed."
                );
            }
        }

        public static bool Close(IntPtr job)
        {
            return job == IntPtr.Zero || CloseHandle(job);
        }

        public static bool IsCurrentProcessInOwnedJob()
        {
            bool inJob;
            if (!IsProcessInJob(GetCurrentProcess(), IntPtr.Zero, out inJob) ||
                !inJob)
            {
                return false;
            }

            int size = Marshal.SizeOf(
                typeof(JOBOBJECT_EXTENDED_LIMIT_INFORMATION)
            );
            IntPtr buffer = Marshal.AllocHGlobal(size);
            try
            {
                if (!QueryInformationJobObject(
                    IntPtr.Zero,
                    JobObjectExtendedLimitInformation,
                    buffer,
                    (uint)size,
                    IntPtr.Zero
                ))
                {
                    return false;
                }
                var information =
                    (JOBOBJECT_EXTENDED_LIMIT_INFORMATION)
                    Marshal.PtrToStructure(
                        buffer,
                        typeof(JOBOBJECT_EXTENDED_LIMIT_INFORMATION)
                    );
                uint flags =
                    information.BasicLimitInformation.LimitFlags;
                return
                    (flags & JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE) != 0 &&
                    (flags & JOB_OBJECT_LIMIT_BREAKAWAY_OK) == 0 &&
                    (flags & JOB_OBJECT_LIMIT_SILENT_BREAKAWAY_OK) == 0;
            }
            finally
            {
                Marshal.FreeHGlobal(buffer);
            }
        }
    }
}
'@
}

# POSIX group signaling must distinguish ESRCH ("already gone") from EPERM
# and other failures. The kill utility commonly maps both to exit 1, so its
# process exit code is not a sufficient cleanup proof.
if (-not $script:privateMarkerIsWindows -and
    $null -eq ('GhStackedPrMergeOrder.PrivateMarkerPosixSignal' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

namespace GhStackedPrMergeOrder
{
    public static class PrivateMarkerPosixSignal
    {
        private const int SIGKILL = 9;
        private const int ESRCH = 3;

        [DllImport("libc", SetLastError = true)]
        private static extern int kill(int pid, int signal);

        public static bool IsSuccessfulResult(int result, int error)
        {
            return result == 0 || (result == -1 && error == ESRCH);
        }

        public static bool KillProcessGroup(int processGroupId)
        {
            if (processGroupId <= 0)
            {
                return false;
            }
            int result = kill(-processGroupId, SIGKILL);
            int error = result == 0 ? 0 : Marshal.GetLastWin32Error();
            return IsSuccessfulResult(result, error);
        }
    }
}
'@
}

function ConvertTo-PrivateMarkerProcessArgument {
    param([AllowEmptyString()][string]$Argument)

    if ([string]::IsNullOrEmpty($Argument)) {
        return '""'
    }
    if ($Argument -notmatch '[\s"]') {
        return $Argument
    }

    # Windows PowerShell 5.1 lacks ProcessStartInfo.ArgumentList. Apply the
    # C-runtime escaping rules only for that compatibility path.
    $builder = New-Object System.Text.StringBuilder
    [void]$builder.Append([char]34)
    $backslashes = 0
    foreach ($character in $Argument.ToCharArray()) {
        if ($character -eq [char]92) {
            $backslashes++
            continue
        }
        if ($character -eq [char]34) {
            [void]$builder.Append([char]92, (($backslashes * 2) + 1))
            [void]$builder.Append([char]34)
            $backslashes = 0
            continue
        }
        if ($backslashes -gt 0) {
            [void]$builder.Append([char]92, $backslashes)
            $backslashes = 0
        }
        [void]$builder.Append($character)
    }
    if ($backslashes -gt 0) {
        [void]$builder.Append([char]92, ($backslashes * 2))
    }
    [void]$builder.Append([char]34)
    return $builder.ToString()
}

function Stop-PrivateMarkerPosixProcessGroupBounded {
    param(
        [int]$ProcessGroupId,
        [int]$WaitMilliseconds = 5000
    )

    # kill(2) is synchronous as a signal-delivery decision. Success means
    # SIGKILL was accepted; ESRCH means the group was already gone. EPERM and
    # every other errno remain a cleanup failure.
    return [GhStackedPrMergeOrder.PrivateMarkerPosixSignal]::KillProcessGroup(
        $ProcessGroupId
    )
}

function Stop-PrivateMarkerOwnedProcessTreeBounded {
    param(
        [object]$Process,
        [ref]$WindowsJobHandle,
        [int]$PosixProcessGroupId,
        [int]$WaitMilliseconds = 5000
    )

    # Atomic Windows launcher は Job handle を object 内で所有する。close が
    # descendant 全体への kill request になり、direct child の終了も有限に待つ。
    if ($Process.GetType().FullName -eq
        'GhStackedPrMergeOrder.PrivateMarkerWindowsProcess') {
        $closed = $Process.CloseJob()
        if (-not $Process.HasExited) {
            [void]$Process.WaitForExit($WaitMilliseconds)
        }
        return $closed -and $Process.HasExited
    }

    if ($WindowsJobHandle.Value -ne [IntPtr]::Zero) {
        $closed = [GhStackedPrMergeOrder.PrivateMarkerJob]::Close(
            $WindowsJobHandle.Value
        )
        $WindowsJobHandle.Value = [IntPtr]::Zero
        if (-not $Process.HasExited) {
            [void]$Process.WaitForExit($WaitMilliseconds)
        }
        return $closed -and $Process.HasExited
    }
    if ($PosixProcessGroupId -gt 0) {
        $groupStopped = Stop-PrivateMarkerPosixProcessGroupBounded `
            -ProcessGroupId $PosixProcessGroupId `
            -WaitMilliseconds $WaitMilliseconds
        if (-not $Process.HasExited) {
            [void]$Process.WaitForExit($WaitMilliseconds)
        }
        return $groupStopped -and $Process.HasExited
    }
    return Stop-PrivateMarkerProcessTreeBounded `
        -Process $Process `
        -WaitMilliseconds $WaitMilliseconds
}

function Stop-PrivateMarkerProcessTreeBounded {
    param(
        [System.Diagnostics.Process]$Process,
        [int]$WaitMilliseconds = 5000
    )

    if ($Process.HasExited) {
        return $true
    }

    try {
        $killTreeMethod = $Process.GetType().GetMethod('Kill', [Type[]]@([bool]))
        if ($null -ne $killTreeMethod) {
            [void]$killTreeMethod.Invoke($Process, @($true))
        } elseif ($script:privateMarkerIsWindows) {
            # .NET Framework has no Kill(entireProcessTree). taskkill /T is the
            # bounded Windows fallback and is itself bounded below.
            $taskkillInfo = New-Object System.Diagnostics.ProcessStartInfo
            $taskkillInfo.FileName = Join-Path $env:SystemRoot 'System32\taskkill.exe'
            $taskkillInfo.Arguments = "/PID $($Process.Id) /T /F"
            $taskkillInfo.UseShellExecute = $false
            $taskkillInfo.CreateNoWindow = $true
            $taskkill = [System.Diagnostics.Process]::Start($taskkillInfo)
            try {
                if (-not $taskkill.WaitForExit($WaitMilliseconds)) {
                    $taskkill.Kill()
                    [void]$taskkill.WaitForExit($WaitMilliseconds)
                }
            }
            finally {
                $taskkill.Dispose()
            }
        } else {
            $Process.Kill()
        }
    }
    catch {
        if (-not $Process.HasExited) {
            try { $Process.Kill() } catch { }
        }
    }

    if (-not $Process.WaitForExit($WaitMilliseconds) -and -not $Process.HasExited) {
        try { $Process.Kill() } catch { }
        [void]$Process.WaitForExit($WaitMilliseconds)
    }
    return $Process.HasExited
}

function Invoke-PrivateMarkerBoundedProcess {
    param(
        [Parameter(Mandatory = $true)]
        [string]$FileName,

        [string[]]$Arguments = @(),

        [Parameter(Mandatory = $true)]
        [string]$IsolationRoot,

        [string]$WorkingDirectory = '',

        [hashtable]$InheritedEnvironment = @{},

        [AllowNull()]
        [byte[]]$StandardInputBytes = $null,

        [int]$MaxStdinBytes = 1048576,

        [int]$TimeoutMilliseconds = 30000,

        # Native child output is untrusted. Bound both streams independently so
        # a corrupted repository, fake executable, or noisy failure cannot grow
        # the scanner process without limit.
        [int]$MaxStdoutBytes = 16777216,

        [int]$MaxStderrBytes = 1048576,

        [int]$DrainTimeoutMilliseconds = 5000,

        # Test-only selector for the portable libc setsid gate. Production
        # POSIX calls use it automatically when an external setsid is absent.
        [switch]$ForceNativePosixSessionGate,

        # Use only when testing the public scanner entrypoint. The scanner must
        # receive the hostile parent environment and isolate its own Git child.
        [switch]$PassThroughGitEnvironment,

        # Self-test 専用。suspended child の Job 割当前/Resume 前 failure で
        # sentinel が実行されず、全 handle が bounded cleanup されることを測る。
        [ValidateSet('', 'assign', 'resume')]
        [string]$ForceWindowsLaunchFailure = ''
    )

    if ($TimeoutMilliseconds -le 0 -or
        $MaxStdinBytes -lt 0 -or
        $MaxStdoutBytes -lt 0 -or
        $MaxStderrBytes -lt 0 -or
        $DrainTimeoutMilliseconds -le 0) {
        throw 'Bounded process limits must be positive (output limits may be zero).'
    }
    if ($null -ne $StandardInputBytes -and
        $StandardInputBytes.Length -gt $MaxStdinBytes) {
        throw 'Bounded process standard input exceeds the configured byte limit.'
    }

    $ownedJobMarkerName = 'GH_STACKED_PR_MERGE_ORDER_OWNED_WINDOWS_JOB'
    $reuseOwnedWindowsJob = $false
    if ($script:privateMarkerIsWindows -and
        [Environment]::GetEnvironmentVariable($ownedJobMarkerName) -eq '1') {
        $reuseOwnedWindowsJob =
            [GhStackedPrMergeOrder.PrivateMarkerJob]::
                IsCurrentProcessInOwnedJob()
    }

    $effectiveFileName = $FileName
    $effectiveArguments = @($Arguments)
    $usePosixProcessGroup = $false
    $useNativePosixSessionGate = $false
    $posixGateReadyPath = $null
    $posixGateReleasePath = $null
    if ($script:privateMarkerIsWindows -and -not $reuseOwnedWindowsJob) {
        # FileName/Arguments は変更せず、下の native launcher に渡す。
        # wrapper を挟まないため stdout/stderr は raw bytes のまま保持され、
        # decode/re-encode で binary Git protocol を壊さない。
    } elseif (-not $script:privateMarkerIsWindows) {
        $setsidPath = @('/usr/bin/setsid', '/bin/setsid') |
            Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } |
            Select-Object -First 1
        if (-not $ForceNativePosixSessionGate -and
            -not [string]::IsNullOrWhiteSpace($setsidPath)) {
            # setsid creates a group whose ID is the launched process ID. The
            # group remains addressable after the direct child exits.
            $effectiveFileName = $setsidPath
            $effectiveArguments = @('--', $FileName) + @($Arguments)
            $usePosixProcessGroup = $true
        } else {
            # macOS commonly has setsid(2) but no setsid executable. A trusted
            # same-host wrapper creates its session before it decodes or starts
            # the requested target, publishes readiness, and waits for the
            # parent to record the new process-group ID before release.
            $usePosixProcessGroup = $true
            $useNativePosixSessionGate = $true
            $gateId = [Guid]::NewGuid().ToString('N')
            $posixGateReadyPath = Join-Path `
                $IsolationRoot `
                "posix-session-ready-$gateId"
            $posixGateReleasePath = Join-Path `
                $IsolationRoot `
                "posix-session-release-$gateId"
            $payloadJson = [pscustomobject]@{
                FileName = $FileName
                Arguments = @($Arguments)
            } | ConvertTo-Json -Compress -Depth 4
            $payloadBase64 = [Convert]::ToBase64String(
                [Text.Encoding]::UTF8.GetBytes($payloadJson)
            )
            $readyPathBase64 = [Convert]::ToBase64String(
                [Text.Encoding]::UTF8.GetBytes($posixGateReadyPath)
            )
            $releasePathBase64 = [Convert]::ToBase64String(
                [Text.Encoding]::UTF8.GetBytes($posixGateReleasePath)
            )
            $posixWrapperTemplate = @'
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ($null -eq ('GhStackedPrMergeOrder.PrivateMarkerPosixSession' -as [type])) {
    Add-Type -TypeDefinition @"
using System.Runtime.InteropServices;

namespace GhStackedPrMergeOrder
{
    public static class PrivateMarkerPosixSession
    {
        [DllImport("libc", SetLastError = true)]
        private static extern int setsid();

        public static int Create()
        {
            return setsid();
        }
    }
}
"@
}
try {
    if ([GhStackedPrMergeOrder.PrivateMarkerPosixSession]::Create() -lt 0) {
        [Console]::Error.WriteLine('Bounded POSIX session setup failed.')
        exit 126
    }
    $readyPath = [Text.Encoding]::UTF8.GetString(
        [Convert]::FromBase64String('__READY_PATH__')
    )
    $releasePath = [Text.Encoding]::UTF8.GetString(
        [Convert]::FromBase64String('__RELEASE_PATH__')
    )
    [IO.File]::WriteAllText(
        $readyPath,
        'ready',
        [Text.UTF8Encoding]::new($false)
    )
    $released = $false
    for ($gateAttempt = 0; $gateAttempt -lt 3000; $gateAttempt++) {
        if ([IO.File]::Exists($releasePath)) {
            $released = $true
            break
        }
        Start-Sleep -Milliseconds 10
    }
    if (-not $released) {
        exit 124
    }
    $payloadJson = [Text.Encoding]::UTF8.GetString(
        [Convert]::FromBase64String('__PAYLOAD__')
    )
    $payload = ConvertFrom-Json -InputObject $payloadJson
    $invokeArguments = @($payload.Arguments | ForEach-Object { [string]$_ })
    & ([string]$payload.FileName) @invokeArguments
    $childExitCode = $LASTEXITCODE
    if ($null -eq $childExitCode) {
        $childExitCode = 0
    }
    exit [int]$childExitCode
}
catch {
    [Console]::Error.WriteLine('Bounded child launch failed.')
    exit 127
}
'@
            $posixWrapperScript = $posixWrapperTemplate.Replace(
                '__READY_PATH__',
                $readyPathBase64
            ).Replace(
                '__RELEASE_PATH__',
                $releasePathBase64
            ).Replace(
                '__PAYLOAD__',
                $payloadBase64
            )
            $posixWrapperBase64 = [Convert]::ToBase64String(
                [Text.Encoding]::Unicode.GetBytes($posixWrapperScript)
            )
            $effectiveFileName = (
                [Diagnostics.Process]::GetCurrentProcess()
            ).MainModule.FileName
            $effectiveArguments = @(
                '-NoProfile',
                '-EncodedCommand',
                $posixWrapperBase64
            )
        }
    }

    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $effectiveFileName
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.RedirectStandardInput = $null -ne $StandardInputBytes
    if (-not [string]::IsNullOrWhiteSpace($WorkingDirectory)) {
        $startInfo.WorkingDirectory = $WorkingDirectory
    }

    $argumentListProperty = $startInfo.PSObject.Properties['ArgumentList']
    if ($null -ne $argumentListProperty) {
        foreach ($argument in $effectiveArguments) {
            $startInfo.ArgumentList.Add($argument)
        }
    } else {
        $startInfo.Arguments = (
            $effectiveArguments | ForEach-Object {
                ConvertTo-PrivateMarkerProcessArgument -Argument $_
            }
        ) -join ' '
    }

    # ProcessStartInfo begins with a child-only environment clone. Apply the
    # test overrides to that clone; never mutate the parent process.
    $childEnvironment = $startInfo.EnvironmentVariables
    foreach ($name in $InheritedEnvironment.Keys) {
        $childEnvironment["$name"] = [string]$InheritedEnvironment[$name]
    }
    $childEnvironment.Remove($ownedJobMarkerName)
    if ($script:privateMarkerIsWindows) {
        $childEnvironment[$ownedJobMarkerName] = '1'
    }

    if (-not $PassThroughGitEnvironment) {
        $homeDirectory = Join-Path $IsolationRoot 'home'
        $xdgDirectory = Join-Path $IsolationRoot 'xdg'
        $templateDirectory = Join-Path $IsolationRoot 'empty-template'
        $hooksDirectory = Join-Path $IsolationRoot 'empty-hooks'
        foreach ($directory in @(
            $homeDirectory,
            $xdgDirectory,
            $templateDirectory,
            $hooksDirectory
        )) {
            New-Item -ItemType Directory -Path $directory -Force | Out-Null
        }

        $emptyGlobalConfig = Join-Path $IsolationRoot 'empty-global.gitconfig'
        $emptySystemConfig = Join-Path $IsolationRoot 'empty-system.gitconfig'
        $emptyAttributes = Join-Path $IsolationRoot 'empty-attributes'
        $emptyExcludes = Join-Path $IsolationRoot 'empty-excludes'
        foreach ($emptyFile in @(
            $emptyGlobalConfig,
            $emptySystemConfig,
            $emptyAttributes,
            $emptyExcludes
        )) {
            if (-not (Test-Path -LiteralPath $emptyFile -PathType Leaf)) {
                [System.IO.File]::WriteAllText(
                    $emptyFile,
                    '',
                    [System.Text.UTF8Encoding]::new($false)
                )
            }
        }

        # Strip every Git control surface, including repo/index/object/trace
        # redirects, then add only the bounded configuration required here.
        foreach ($name in @($childEnvironment.Keys | ForEach-Object { "$_" })) {
            if ($name -like 'GIT_*') {
                $childEnvironment.Remove($name)
            }
        }
        foreach ($name in @('HOME', 'USERPROFILE', 'XDG_CONFIG_HOME')) {
            $childEnvironment.Remove($name)
        }
        $childEnvironment['HOME'] = $homeDirectory
        $childEnvironment['USERPROFILE'] = $homeDirectory
        $childEnvironment['XDG_CONFIG_HOME'] = $xdgDirectory
        $childEnvironment['GIT_CONFIG_NOSYSTEM'] = '1'
        $childEnvironment['GIT_ATTR_NOSYSTEM'] = '1'
        $childEnvironment['GIT_CONFIG_GLOBAL'] = $emptyGlobalConfig.Replace([string][char]92, '/')
        $childEnvironment['GIT_CONFIG_SYSTEM'] = $emptySystemConfig.Replace([string][char]92, '/')
        $childEnvironment['GIT_TERMINAL_PROMPT'] = '0'
        $childEnvironment['GIT_LFS_SKIP_SMUDGE'] = '1'
        $childEnvironment['GIT_OPTIONAL_LOCKS'] = '0'
        $childEnvironment['GIT_NO_REPLACE_OBJECTS'] = '1'
        $childEnvironment['GIT_NO_LAZY_FETCH'] = '1'

        $safeConfig = @(
            [pscustomobject]@{
                Key = 'core.hooksPath'
                Value = $hooksDirectory.Replace([string][char]92, '/')
            },
            [pscustomobject]@{
                Key = 'core.attributesFile'
                Value = $emptyAttributes.Replace([string][char]92, '/')
            },
            [pscustomobject]@{
                Key = 'core.excludesFile'
                Value = $emptyExcludes.Replace([string][char]92, '/')
            },
            [pscustomobject]@{ Key = 'core.fsmonitor'; Value = 'false' },
            [pscustomobject]@{ Key = 'protocol.allow'; Value = 'never' },
            [pscustomobject]@{ Key = 'submodule.recurse'; Value = 'false' },
            [pscustomobject]@{
                Key = 'init.templateDir'
                Value = $templateDirectory.Replace([string][char]92, '/')
            }
        )
        $childEnvironment['GIT_CONFIG_COUNT'] = [string]$safeConfig.Count
        for ($index = 0; $index -lt $safeConfig.Count; $index++) {
            $childEnvironment["GIT_CONFIG_KEY_$index"] = $safeConfig[$index].Key
            $childEnvironment["GIT_CONFIG_VALUE_$index"] = $safeConfig[$index].Value
        }
    }

    $process = $null
    $processStarted = $false
    $usesAtomicWindowsProcess =
        $script:privateMarkerIsWindows -and -not $reuseOwnedWindowsJob
    $windowsJobHandle = [IntPtr]::Zero
    $posixProcessGroupId = 0
    $ownedTreeStopRequested = $false
    $stdinTask = $null
    $stdoutTask = $null
    $stderrTask = $null
    $stdoutChunk = New-Object byte[] 8192
    $stderrChunk = New-Object byte[] 8192
    $stdoutBuffer = New-Object System.IO.MemoryStream
    $stderrBuffer = New-Object System.IO.MemoryStream
    $timedOut = $false
    $outputLimitExceeded = $false
    $treeStopped = $true
    $streamsDrained = $false
    $streamReadFailed = $false
    $exitCode = -1
    $stdoutBytes = [byte[]]@()
    $stderrBytes = [byte[]]@()
    try {
        if ($usesAtomicWindowsProcess) {
            # CREATE_SUSPENDED →限定 handle→Job assign→resume は C# helper 内で
            # 1 transaction として完了する。失敗時は child を走らせず cleanup する。
            $process =
                [GhStackedPrMergeOrder.PrivateMarkerWindowsProcess]::
                    StartContained(
                        $effectiveFileName,
                        [string[]]$effectiveArguments,
                        $childEnvironment,
                        $WorkingDirectory,
                        $ForceWindowsLaunchFailure
                    )
        } else {
            $process = New-Object System.Diagnostics.Process
            $process.StartInfo = $startInfo
            if (-not $process.Start()) {
                throw "Failed to start bounded child process: $FileName"
            }
        }
        $processStarted = $true
        if ($usePosixProcessGroup) {
            if ($useNativePosixSessionGate) {
                $posixGateReady = $false
                for ($gateAttempt = 0;
                    $gateAttempt -lt 2000;
                    $gateAttempt++) {
                    if ([IO.File]::Exists($posixGateReadyPath)) {
                        $posixGateReady = $true
                        break
                    }
                    if ($process.HasExited) {
                        break
                    }
                    Start-Sleep -Milliseconds 5
                }
                if (-not $posixGateReady) {
                    [void](Stop-PrivateMarkerProcessTreeBounded `
                        -Process $process `
                        -WaitMilliseconds 5000)
                    throw 'Failed to establish the bounded POSIX session gate.'
                }
                # Readiness is written only after setsid(2) succeeds. Record the
                # stable group ID before allowing any requested target to run.
                $posixProcessGroupId = $process.Id
                try {
                    [IO.File]::WriteAllText(
                        $posixGateReleasePath,
                        'release',
                        [Text.UTF8Encoding]::new($false)
                    )
                }
                catch {
                    [void](Stop-PrivateMarkerPosixProcessGroupBounded `
                        -ProcessGroupId $posixProcessGroupId)
                    throw
                }
            } else {
                $posixProcessGroupId = $process.Id
            }
        }
        $standardInputStream = if ($usesAtomicWindowsProcess) {
            $process.StandardInput
        } elseif ($null -ne $StandardInputBytes) {
            $process.StandardInput.BaseStream
        } else {
            $null
        }
        $standardOutputStream = if ($usesAtomicWindowsProcess) {
            $process.StandardOutput
        } else {
            $process.StandardOutput.BaseStream
        }
        $standardErrorStream = if ($usesAtomicWindowsProcess) {
            $process.StandardError
        } else {
            $process.StandardError.BaseStream
        }
        if ($null -ne $StandardInputBytes) {
            if ($StandardInputBytes.Length -eq 0) {
                $process.StandardInput.Close()
            } else {
                $stdinTask = $standardInputStream.WriteAsync(
                    $StandardInputBytes,
                    0,
                    $StandardInputBytes.Length
                )
            }
        } elseif ($usesAtomicWindowsProcess) {
            # Native launcher は stdin pipe を常に作る。入力なしなら parent endpoint
            # を直ちに閉じ、child が EOF を待って deadline まで残らないようにする。
            $process.StandardInput.Close()
        }
        $stdoutTask = $standardOutputStream.ReadAsync(
            $stdoutChunk,
            0,
            $stdoutChunk.Length
        )
        $stderrTask = $standardErrorStream.ReadAsync(
            $stderrChunk,
            0,
            $stderrChunk.Length
        )

        # Poll both asynchronous byte reads and process state under one finite
        # deadline. This avoids ReadToEnd/CopyToAsync waits that can outlive the
        # child when a descendant inherits a redirected pipe.
        $runtime = [System.Diagnostics.Stopwatch]::StartNew()
        $stdoutClosed = $false
        $stderrClosed = $false
        $stdoutDiscarding = $false
        $stderrDiscarding = $false
        $stdinClosed = $null -eq $StandardInputBytes -or
            $StandardInputBytes.Length -eq 0
        $stdinWriteFailed = $false
        $exitObservedAt = -1L
        # Even if native tree termination itself fails, the helper must return
        # after one finite outer deadline instead of polling forever.
        $hardStopDeadlineMilliseconds =
            [long]$TimeoutMilliseconds +
            [long]$DrainTimeoutMilliseconds +
            5000L
        while ($runtime.ElapsedMilliseconds -lt
            $hardStopDeadlineMilliseconds) {
            if (-not $stdinClosed -and $stdinTask.IsCompleted) {
                try {
                    [void]$stdinTask.GetAwaiter().GetResult()
                }
                catch {
                    $stdinWriteFailed = $true
                }
                try {
                    $process.StandardInput.Close()
                }
                catch {
                    $stdinWriteFailed = $true
                }
                $stdinClosed = $true
            }

            if (-not $stdoutClosed -and $stdoutTask.IsCompleted) {
                try {
                    $stdoutCount = $stdoutTask.GetAwaiter().GetResult()
                }
                catch {
                    $streamReadFailed = $true
                    $stdoutCount = 0
                }
                if ($stdoutCount -eq 0) {
                    $stdoutClosed = $true
                } elseif ($stdoutDiscarding -or
                    ($stdoutBuffer.Length + $stdoutCount) -gt
                    $MaxStdoutBytes) {
                    $outputLimitExceeded = $true
                    $stdoutDiscarding = $true
                    $stdoutTask = $standardOutputStream.ReadAsync(
                        $stdoutChunk,
                        0,
                        $stdoutChunk.Length
                    )
                } else {
                    $stdoutBuffer.Write($stdoutChunk, 0, $stdoutCount)
                    $stdoutTask = $standardOutputStream.ReadAsync(
                        $stdoutChunk,
                        0,
                        $stdoutChunk.Length
                    )
                }
            }

            if (-not $stderrClosed -and $stderrTask.IsCompleted) {
                try {
                    $stderrCount = $stderrTask.GetAwaiter().GetResult()
                }
                catch {
                    $streamReadFailed = $true
                    $stderrCount = 0
                }
                if ($stderrCount -eq 0) {
                    $stderrClosed = $true
                } elseif ($stderrDiscarding -or
                    ($stderrBuffer.Length + $stderrCount) -gt
                    $MaxStderrBytes) {
                    $outputLimitExceeded = $true
                    $stderrDiscarding = $true
                    $stderrTask = $standardErrorStream.ReadAsync(
                        $stderrChunk,
                        0,
                        $stderrChunk.Length
                    )
                } else {
                    $stderrBuffer.Write($stderrChunk, 0, $stderrCount)
                    $stderrTask = $standardErrorStream.ReadAsync(
                        $stderrChunk,
                        0,
                        $stderrChunk.Length
                    )
                }
            }

            if ($outputLimitExceeded -and -not $ownedTreeStopRequested) {
                $ownedTreeStopRequested = $true
                $treeStopped = Stop-PrivateMarkerOwnedProcessTreeBounded `
                    -Process $process `
                    -WindowsJobHandle ([ref]$windowsJobHandle) `
                    -PosixProcessGroupId $posixProcessGroupId
            }

            if (-not $process.HasExited -and
                $runtime.ElapsedMilliseconds -ge $TimeoutMilliseconds) {
                $timedOut = $true
                if (-not $ownedTreeStopRequested) {
                    $ownedTreeStopRequested = $true
                    $treeStopped = Stop-PrivateMarkerOwnedProcessTreeBounded `
                        -Process $process `
                        -WindowsJobHandle ([ref]$windowsJobHandle) `
                        -PosixProcessGroupId $posixProcessGroupId
                }
            }

            if ($process.HasExited -and $exitObservedAt -lt 0) {
                $exitObservedAt = $runtime.ElapsedMilliseconds
                $exitCode = $process.ExitCode
            }

            if ($process.HasExited -and $stdinClosed -and
                $stdoutClosed -and $stderrClosed) {
                $streamsDrained = -not $streamReadFailed -and
                    -not $stdinWriteFailed
                break
            }

            if ($exitObservedAt -ge 0 -and
                -not $ownedTreeStopRequested -and
                ($runtime.ElapsedMilliseconds - $exitObservedAt) -ge 250) {
                # Normal pipe EOF follows direct-child exit almost immediately.
                # A pipe still open after a short grace period is owned by a
                # descendant; close the job/process group before it can outlive
                # the bounded operation.
                $ownedTreeStopRequested = $true
                $treeStopped = Stop-PrivateMarkerOwnedProcessTreeBounded `
                    -Process $process `
                    -WindowsJobHandle ([ref]$windowsJobHandle) `
                    -PosixProcessGroupId $posixProcessGroupId
            }

            if ($exitObservedAt -ge 0 -and
                ($runtime.ElapsedMilliseconds - $exitObservedAt) -ge
                $DrainTimeoutMilliseconds) {
                # A leaked descendant pipe or failed async read must make the
                # caller fail closed, but it must never hold this process open.
                $streamsDrained = $false
                break
            }

            Start-Sleep -Milliseconds 5
        }
        if ($runtime.ElapsedMilliseconds -ge
            $hardStopDeadlineMilliseconds) {
            $timedOut = $true
            $streamsDrained = $false
            if (-not $ownedTreeStopRequested) {
                $ownedTreeStopRequested = $true
                $treeStopped = Stop-PrivateMarkerOwnedProcessTreeBounded `
                    -Process $process `
                    -WindowsJobHandle ([ref]$windowsJobHandle) `
                    -PosixProcessGroupId $posixProcessGroupId
            }
        }
        $runtime.Stop()

        $stdoutBytes = $stdoutBuffer.ToArray()
        $stderrBytes = $stderrBuffer.ToArray()
    }
    finally {
        if ($null -ne $process) {
            if ($processStarted -and -not $process.HasExited) {
                $treeStopped = Stop-PrivateMarkerOwnedProcessTreeBounded `
                    -Process $process `
                    -WindowsJobHandle ([ref]$windowsJobHandle) `
                    -PosixProcessGroupId $posixProcessGroupId
            } elseif ($windowsJobHandle -ne [IntPtr]::Zero) {
                $treeStopped =
                    [GhStackedPrMergeOrder.PrivateMarkerJob]::Close(
                        $windowsJobHandle
                    ) -and $treeStopped
                $windowsJobHandle = [IntPtr]::Zero
            } elseif ($posixProcessGroupId -gt 0) {
                # Kill detached descendants even when they did not inherit a
                # redirected pipe and the direct command already exited.
                $treeStopped =
                    (Stop-PrivateMarkerPosixProcessGroupBounded `
                        -ProcessGroupId $posixProcessGroupId) -and
                    $treeStopped
            }
            if ($usesAtomicWindowsProcess -or
                $startInfo.RedirectStandardInput) {
                try { $process.StandardInput.Dispose() } catch { }
            }
            $process.Dispose()
        } elseif ($windowsJobHandle -ne [IntPtr]::Zero) {
            [void][GhStackedPrMergeOrder.PrivateMarkerJob]::Close(
                $windowsJobHandle
            )
        }
        foreach ($gatePath in @(
            $posixGateReadyPath,
            $posixGateReleasePath
        )) {
            if (-not [string]::IsNullOrWhiteSpace($gatePath)) {
                try { [IO.File]::Delete($gatePath) } catch { }
            }
        }
        $stdoutBuffer.Dispose()
        $stderrBuffer.Dispose()
    }

    $utf8 = [System.Text.UTF8Encoding]::new($false, $false)
    $stdoutText = $utf8.GetString($stdoutBytes)
    $stderrText = $utf8.GetString($stderrBytes)
    $output = @($stdoutText, $stderrText) -join [Environment]::NewLine
    if ($timedOut) {
        $output += [Environment]::NewLine +
            "Process timed out after $TimeoutMilliseconds ms."
    }
    if (-not $treeStopped) {
        $output += [Environment]::NewLine +
            'Process tree did not stop within the bounded cleanup window.'
    }
    if (-not $streamsDrained) {
        $output += [Environment]::NewLine +
            'Process output streams did not close within the bounded drain window.'
    }
    if ($outputLimitExceeded) {
        $output += [Environment]::NewLine +
            'Process output exceeded the configured byte limit.'
    }

    return [pscustomobject]@{
        ExitCode = $exitCode
        StdoutBytes = $stdoutBytes
        StderrBytes = $stderrBytes
        Output = $output.TrimEnd()
        TimedOut = $timedOut
        OutputLimitExceeded = $outputLimitExceeded
        TreeStopped = $treeStopped
        StreamsDrained = $streamsDrained
    }
}
