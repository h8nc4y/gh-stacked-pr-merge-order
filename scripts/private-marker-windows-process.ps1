Set-StrictMode -Version Latest

# Windows child は CREATE_SUSPENDED で止めたまま作り、stdio の 3 handle だけを
# 明示継承し、kill-on-close Job への割当が成功してから resume する。
# Process.Start 後に Job へ追加する方式では、即時 spawn した descendant が Job
# 外へ逃げる race があるため、この native launcher を唯一の初回起動経路にする。
if ($null -eq
    ('GhStackedPrMergeOrder.PrivateMarkerWindowsProcess' -as [type])) {
    Add-Type -Language CSharp -TypeDefinition @'
using System;
using System.Collections;
using System.Collections.Generic;
using System.Collections.Specialized;
using System.ComponentModel;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using Microsoft.Win32.SafeHandles;

namespace GhStackedPrMergeOrder
{
    public sealed class PrivateMarkerWindowsProcess : IDisposable
    {
        private const uint JobObjectLimitKillOnJobClose = 0x00002000;
        private const int JobObjectExtendedLimitInformationClass = 9;
        private const uint CreateSuspended = 0x00000004;
        private const uint CreateUnicodeEnvironment = 0x00000400;
        private const uint ExtendedStartupInfoPresent = 0x00080000;
        private const uint CreateNoWindow = 0x08000000;
        private const uint StartfUseStdHandles = 0x00000100;
        private const uint HandleFlagInherit = 0x00000001;
        private const uint ResumeFailed = 0xFFFFFFFF;
        private const uint WaitObject0 = 0x00000000;
        private const uint WaitFailed = 0xFFFFFFFF;
        private static readonly IntPtr ProcThreadAttributeHandleList =
            new IntPtr(0x00020002);

        private IntPtr jobHandle;
        private IntPtr processHandle;
        private bool disposed;

        public Stream StandardInput { get; private set; }
        public Stream StandardOutput { get; private set; }
        public Stream StandardError { get; private set; }
        public static int LastSyntheticFailureProcessId { get; private set; }

        private PrivateMarkerWindowsProcess(
            IntPtr childProcess,
            Stream standardInput,
            Stream standardOutput,
            Stream standardError,
            IntPtr job)
        {
            processHandle = childProcess;
            StandardInput = standardInput;
            StandardOutput = standardOutput;
            StandardError = standardError;
            jobHandle = job;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct SECURITY_ATTRIBUTES
        {
            public int nLength;
            public IntPtr lpSecurityDescriptor;
            [MarshalAs(UnmanagedType.Bool)]
            public bool bInheritHandle;
        }

        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        private struct STARTUPINFO
        {
            public int cb;
            public string lpReserved;
            public string lpDesktop;
            public string lpTitle;
            public int dwX;
            public int dwY;
            public int dwXSize;
            public int dwYSize;
            public int dwXCountChars;
            public int dwYCountChars;
            public int dwFillAttribute;
            public uint dwFlags;
            public short wShowWindow;
            public short cbReserved2;
            public IntPtr lpReserved2;
            public IntPtr hStdInput;
            public IntPtr hStdOutput;
            public IntPtr hStdError;
        }

        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        private struct STARTUPINFOEX
        {
            public STARTUPINFO StartupInfo;
            public IntPtr lpAttributeList;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct PROCESS_INFORMATION
        {
            public IntPtr hProcess;
            public IntPtr hThread;
            public int dwProcessId;
            public int dwThreadId;
        }

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

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool CreatePipe(
            out IntPtr readPipe,
            out IntPtr writePipe,
            ref SECURITY_ATTRIBUTES pipeAttributes,
            int size);

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool SetHandleInformation(
            IntPtr handle,
            uint mask,
            uint flags);

        [DllImport(
            "kernel32.dll",
            CharSet = CharSet.Unicode,
            SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool CreateProcessW(
            string applicationName,
            StringBuilder commandLine,
            IntPtr processAttributes,
            IntPtr threadAttributes,
            [MarshalAs(UnmanagedType.Bool)] bool inheritHandles,
            uint creationFlags,
            IntPtr environment,
            string currentDirectory,
            ref STARTUPINFOEX startupInfo,
            out PROCESS_INFORMATION processInformation);

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool InitializeProcThreadAttributeList(
            IntPtr attributeList,
            int attributeCount,
            int flags,
            ref IntPtr size);

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool UpdateProcThreadAttribute(
            IntPtr attributeList,
            uint flags,
            IntPtr attribute,
            IntPtr value,
            IntPtr size,
            IntPtr previousValue,
            IntPtr returnSize);

        [DllImport("kernel32.dll")]
        private static extern void DeleteProcThreadAttributeList(
            IntPtr attributeList);

        [DllImport(
            "kernel32.dll",
            CharSet = CharSet.Unicode,
            SetLastError = true)]
        private static extern IntPtr CreateJobObject(
            IntPtr jobAttributes,
            string name);

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool SetInformationJobObject(
            IntPtr job,
            int informationClass,
            ref JOBOBJECT_EXTENDED_LIMIT_INFORMATION information,
            uint informationLength);

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool AssignProcessToJobObject(
            IntPtr job,
            IntPtr process);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern uint ResumeThread(IntPtr thread);

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool TerminateProcess(
            IntPtr process,
            uint exitCode);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern uint WaitForSingleObject(
            IntPtr handle,
            uint milliseconds);

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool GetExitCodeProcess(
            IntPtr process,
            out uint exitCode);

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool CloseHandle(IntPtr handle);

        private static string Quote(string value)
        {
            if (value.Length == 0)
                return "\"\"";
            if (value.IndexOfAny(new char[] { ' ', '\t', '"' }) < 0)
                return value;

            StringBuilder result = new StringBuilder("\"");
            int slashes = 0;
            foreach (char character in value)
            {
                if (character == '\\')
                {
                    slashes++;
                    continue;
                }
                if (character == '"')
                {
                    result.Append('\\', (slashes * 2) + 1);
                    result.Append('"');
                    slashes = 0;
                    continue;
                }
                result.Append('\\', slashes);
                slashes = 0;
                result.Append(character);
            }
            result.Append('\\', slashes * 2);
            result.Append('"');
            return result.ToString();
        }

        private static StringBuilder BuildCommandLine(
            string filePath,
            string[] arguments)
        {
            StringBuilder commandLine = new StringBuilder(Quote(filePath));
            foreach (string argument in arguments)
            {
                commandLine.Append(' ');
                commandLine.Append(Quote(argument ?? String.Empty));
            }
            return commandLine;
        }

        private static IntPtr BuildEnvironmentBlock(
            StringDictionary environment)
        {
            List<string> entries = new List<string>();
            foreach (DictionaryEntry entry in environment)
            {
                string name = Convert.ToString(entry.Key);
                string value =
                    Convert.ToString(entry.Value) ?? String.Empty;
                if (String.IsNullOrEmpty(name) ||
                    name.IndexOf('=') >= 0 ||
                    name.IndexOf('\0') >= 0 ||
                    value.IndexOf('\0') >= 0)
                {
                    throw new ArgumentException(
                        "Invalid child environment entry.");
                }
                entries.Add(name + "=" + value);
            }
            entries.Sort(StringComparer.OrdinalIgnoreCase);
            string block = String.Join("\0", entries.ToArray()) + "\0\0";
            return Marshal.StringToHGlobalUni(block);
        }

        private static IntPtr CreateKillOnCloseJob()
        {
            IntPtr job = CreateJobObject(IntPtr.Zero, null);
            if (job == IntPtr.Zero)
                throw new Win32Exception(
                    Marshal.GetLastWin32Error(),
                    "CreateJobObject failed.");

            JOBOBJECT_EXTENDED_LIMIT_INFORMATION information =
                new JOBOBJECT_EXTENDED_LIMIT_INFORMATION();
            information.BasicLimitInformation.LimitFlags =
                JobObjectLimitKillOnJobClose;
            if (!SetInformationJobObject(
                    job,
                    JobObjectExtendedLimitInformationClass,
                    ref information,
                    (uint)Marshal.SizeOf(
                        typeof(JOBOBJECT_EXTENDED_LIMIT_INFORMATION))))
            {
                int error = Marshal.GetLastWin32Error();
                CloseHandle(job);
                throw new Win32Exception(
                    error,
                    "SetInformationJobObject failed.");
            }
            return job;
        }

        // resume/return前のownership移管ではclose失敗を通常経路へ流さず、
        // catchのterminate/Job close/waitへ必ず遷移させる。
        private static void CloseOwnedHandleOrThrow(
            ref IntPtr handle,
            string description)
        {
            if (handle == IntPtr.Zero)
                return;

            IntPtr ownedHandle = handle;
            if (!CloseHandle(ownedHandle))
                throw new Win32Exception(
                    Marshal.GetLastWin32Error(),
                    description);
            handle = IntPtr.Zero;
        }

        // catch内の検証付きcloseが失敗したhandleだけをfinallyで再試行する。
        // 最初のfailureは既にaggregate済みなので、ここはcleanup継続を優先する。
        private static void CloseOwnedHandleBestEffort(ref IntPtr handle)
        {
            if (handle == IntPtr.Zero)
                return;

            CloseHandle(handle);
            handle = IntPtr.Zero;
        }

        // launch failure cleanupでは、先行failureがあっても後続APIの失敗を
        // 捨てない。複合failureをすべて保持し、見かけ上のcleanup成功を防ぐ。
        private static Exception AddCleanupFailure(
            Exception current,
            Exception next)
        {
            return current == null
                ? next
                : new AggregateException(current, next);
        }

        // finallyのbest-effort closeより前に各owned handleを検証付きで閉じる。
        // 失敗時はhandleを保持し、finallyで再試行できる状態のまま原因を集約する。
        private static Exception CloseOwnedHandleForCleanup(
            ref IntPtr handle,
            string description,
            Exception current)
        {
            if (handle == IntPtr.Zero)
                return current;

            IntPtr ownedHandle = handle;
            if (CloseHandle(ownedHandle))
            {
                handle = IntPtr.Zero;
                return current;
            }

            int error = Marshal.GetLastWin32Error();
            return AddCleanupFailure(
                current,
                new Win32Exception(error, description));
        }

        public static PrivateMarkerWindowsProcess StartContained(
            string filePath,
            string[] arguments,
            StringDictionary environment,
            string currentDirectory,
            string testFailureMode)
        {
            if (!String.IsNullOrEmpty(testFailureMode))
                LastSyntheticFailureProcessId = 0;

            IntPtr stdinRead = IntPtr.Zero;
            IntPtr stdinWrite = IntPtr.Zero;
            IntPtr stdoutRead = IntPtr.Zero;
            IntPtr stdoutWrite = IntPtr.Zero;
            IntPtr stderrRead = IntPtr.Zero;
            IntPtr stderrWrite = IntPtr.Zero;
            IntPtr environmentBlock = IntPtr.Zero;
            IntPtr attributeList = IntPtr.Zero;
            IntPtr inheritedHandleList = IntPtr.Zero;
            IntPtr job = IntPtr.Zero;
            PROCESS_INFORMATION processInformation =
                new PROCESS_INFORMATION();
            SafeFileHandle stdinSafeHandle = null;
            SafeFileHandle stdoutSafeHandle = null;
            SafeFileHandle stderrSafeHandle = null;
            FileStream stdout = null;
            FileStream stderr = null;
            FileStream stdin = null;
            bool processCreated = false;
            bool processAssigned = false;
            bool attributeListInitialized = false;
            try
            {
                SECURITY_ATTRIBUTES attributes = new SECURITY_ATTRIBUTES();
                attributes.nLength =
                    Marshal.SizeOf(typeof(SECURITY_ATTRIBUTES));
                attributes.bInheritHandle = true;

                if (!CreatePipe(
                        out stdinRead,
                        out stdinWrite,
                        ref attributes,
                        0) ||
                    !CreatePipe(
                        out stdoutRead,
                        out stdoutWrite,
                        ref attributes,
                        0) ||
                    !CreatePipe(
                        out stderrRead,
                        out stderrWrite,
                        ref attributes,
                        0))
                {
                    throw new Win32Exception(
                        Marshal.GetLastWin32Error(),
                        "CreatePipe failed.");
                }
                if (!SetHandleInformation(
                        stdinWrite,
                        HandleFlagInherit,
                        0) ||
                    !SetHandleInformation(
                        stdoutRead,
                        HandleFlagInherit,
                        0) ||
                    !SetHandleInformation(
                        stderrRead,
                        HandleFlagInherit,
                        0))
                {
                    throw new Win32Exception(
                        Marshal.GetLastWin32Error(),
                        "SetHandleInformation failed.");
                }

                // bInheritHandles=true でも child stdio 以外を渡さない。
                // 親側の unrelated inheritable handle が Git や孫へ漏れる
                // ことを PROC_THREAD_ATTRIBUTE_HANDLE_LIST で防ぐ。
                IntPtr attributeListSize = IntPtr.Zero;
                InitializeProcThreadAttributeList(
                    IntPtr.Zero,
                    1,
                    0,
                    ref attributeListSize);
                if (attributeListSize == IntPtr.Zero)
                {
                    throw new Win32Exception(
                        Marshal.GetLastWin32Error(),
                        "InitializeProcThreadAttributeList size failed.");
                }
                attributeList = Marshal.AllocHGlobal(attributeListSize);
                if (!InitializeProcThreadAttributeList(
                        attributeList,
                        1,
                        0,
                        ref attributeListSize))
                {
                    throw new Win32Exception(
                        Marshal.GetLastWin32Error(),
                        "InitializeProcThreadAttributeList failed.");
                }
                attributeListInitialized = true;

                inheritedHandleList =
                    Marshal.AllocHGlobal(IntPtr.Size * 3);
                Marshal.WriteIntPtr(
                    inheritedHandleList,
                    0,
                    stdinRead);
                Marshal.WriteIntPtr(
                    inheritedHandleList,
                    IntPtr.Size,
                    stdoutWrite);
                Marshal.WriteIntPtr(
                    inheritedHandleList,
                    IntPtr.Size * 2,
                    stderrWrite);
                if (!UpdateProcThreadAttribute(
                        attributeList,
                        0,
                        ProcThreadAttributeHandleList,
                        inheritedHandleList,
                        new IntPtr(IntPtr.Size * 3),
                        IntPtr.Zero,
                        IntPtr.Zero))
                {
                    throw new Win32Exception(
                        Marshal.GetLastWin32Error(),
                        "UpdateProcThreadAttribute failed.");
                }

                STARTUPINFOEX startupInfo = new STARTUPINFOEX();
                startupInfo.StartupInfo.cb =
                    Marshal.SizeOf(typeof(STARTUPINFOEX));
                startupInfo.StartupInfo.dwFlags = StartfUseStdHandles;
                startupInfo.StartupInfo.hStdInput = stdinRead;
                startupInfo.StartupInfo.hStdOutput = stdoutWrite;
                startupInfo.StartupInfo.hStdError = stderrWrite;
                startupInfo.lpAttributeList = attributeList;

                job = CreateKillOnCloseJob();
                environmentBlock = BuildEnvironmentBlock(environment);
                string workingDirectory =
                    String.IsNullOrWhiteSpace(currentDirectory)
                        ? null
                        : currentDirectory;
                if (!CreateProcessW(
                        filePath,
                        BuildCommandLine(filePath, arguments),
                        IntPtr.Zero,
                        IntPtr.Zero,
                        true,
                        CreateSuspended |
                            CreateUnicodeEnvironment |
                            CreateNoWindow |
                            ExtendedStartupInfoPresent,
                        environmentBlock,
                        workingDirectory,
                        ref startupInfo,
                        out processInformation))
                {
                    throw new Win32Exception(
                        Marshal.GetLastWin32Error(),
                        "CreateProcessW failed.");
                }
                processCreated = true;
                if (!String.IsNullOrEmpty(testFailureMode))
                    LastSyntheticFailureProcessId =
                        processInformation.dwProcessId;

                // Job 割当が失敗した suspended process は決して resume
                // しない。catch で terminate/close/wait してから失敗を返す。
                if (String.Equals(
                        testFailureMode,
                        "assign",
                        StringComparison.Ordinal))
                {
                    throw new InvalidOperationException(
                        "Synthetic Job assignment failure.");
                }
                if (!AssignProcessToJobObject(
                        job,
                        processInformation.hProcess))
                {
                    throw new Win32Exception(
                        Marshal.GetLastWin32Error(),
                        "AssignProcessToJobObject failed.");
                }
                processAssigned = true;

                stdinSafeHandle =
                    new SafeFileHandle(stdinWrite, true);
                stdinWrite = IntPtr.Zero;
                stdoutSafeHandle =
                    new SafeFileHandle(stdoutRead, true);
                stdoutRead = IntPtr.Zero;
                stderrSafeHandle =
                    new SafeFileHandle(stderrRead, true);
                stderrRead = IntPtr.Zero;
                stdin = new FileStream(
                    stdinSafeHandle,
                    FileAccess.Write,
                    8192,
                    false);
                stdinSafeHandle = null;
                stdout = new FileStream(
                    stdoutSafeHandle,
                    FileAccess.Read,
                    8192,
                    false);
                stdoutSafeHandle = null;
                stderr = new FileStream(
                    stderrSafeHandle,
                    FileAccess.Read,
                    8192,
                    false);
                stderrSafeHandle = null;

                // Child pipe ends は resume 前に parent 側で閉じる。これを
                // 残すと EOF が観測できず bounded drain が成立しない。
                CloseOwnedHandleOrThrow(
                    ref stdinRead,
                    "Failed to close child stdin read handle before resume.");
                CloseOwnedHandleOrThrow(
                    ref stdoutWrite,
                    "Failed to close child stdout write handle before resume.");
                CloseOwnedHandleOrThrow(
                    ref stderrWrite,
                    "Failed to close child stderr write handle before resume.");

                if (String.Equals(
                        testFailureMode,
                        "resume",
                        StringComparison.Ordinal))
                {
                    throw new InvalidOperationException(
                        "Synthetic ResumeThread failure.");
                }
                if (ResumeThread(processInformation.hThread) ==
                    ResumeFailed)
                {
                    throw new Win32Exception(
                        Marshal.GetLastWin32Error(),
                        "ResumeThread failed.");
                }
                CloseOwnedHandleOrThrow(
                    ref processInformation.hThread,
                    "Failed to close resumed process thread handle.");

                PrivateMarkerWindowsProcess result =
                    new PrivateMarkerWindowsProcess(
                        processInformation.hProcess,
                        stdin,
                        stdout,
                        stderr,
                        job);
                processInformation.hProcess = IntPtr.Zero;
                stdin = null;
                stdout = null;
                stderr = null;
                job = IntPtr.Zero;
                return result;
            }
            catch (Exception launchFailure)
            {
                Exception cleanupFailure = null;
                if (processCreated)
                {
                    if (processAssigned && job != IntPtr.Zero)
                    {
                        // Job close が失敗しても suspended process を残さない。
                        // handle を finally の再試行用に保持し、process terminate
                        // も fallback として要求する。
                        if (CloseHandle(job))
                        {
                            job = IntPtr.Zero;
                        }
                        else
                        {
                            cleanupFailure = AddCleanupFailure(
                                cleanupFailure,
                                new Win32Exception(
                                    Marshal.GetLastWin32Error(),
                                    "Failed to close the assigned Job."));
                            if (!TerminateProcess(
                                    processInformation.hProcess,
                                    1))
                            {
                                cleanupFailure = AddCleanupFailure(
                                    cleanupFailure,
                                    new Win32Exception(
                                        Marshal.GetLastWin32Error(),
                                        "Fallback process termination failed."));
                            }
                        }
                    }
                    else
                    {
                        if (!TerminateProcess(
                                processInformation.hProcess,
                                1))
                        {
                            cleanupFailure = AddCleanupFailure(
                                cleanupFailure,
                                new Win32Exception(
                                    Marshal.GetLastWin32Error(),
                                    "Suspended process termination failed."));
                        }
                    }

                    uint waitResult = WaitForSingleObject(
                        processInformation.hProcess,
                        5000);
                    if (waitResult != WaitObject0)
                    {
                        Exception waitFailure = waitResult == WaitFailed
                            ? (Exception)new Win32Exception(
                                Marshal.GetLastWin32Error(),
                                "Process cleanup wait failed.")
                            : new TimeoutException(
                                "Process cleanup did not finish in time.");
                        cleanupFailure = AddCleanupFailure(
                            cleanupFailure,
                            waitFailure);
                    }
                }

                // process waitの評価後、launch途中で所有した全raw handleを
                // 検証付きで閉じる。各close failureは先行failureへ必ず集約する。
                cleanupFailure = CloseOwnedHandleForCleanup(
                    ref stdinRead,
                    "Failed to close child stdin read handle.",
                    cleanupFailure);
                cleanupFailure = CloseOwnedHandleForCleanup(
                    ref stdinWrite,
                    "Failed to close parent stdin write handle.",
                    cleanupFailure);
                cleanupFailure = CloseOwnedHandleForCleanup(
                    ref stdoutRead,
                    "Failed to close parent stdout read handle.",
                    cleanupFailure);
                cleanupFailure = CloseOwnedHandleForCleanup(
                    ref stdoutWrite,
                    "Failed to close child stdout write handle.",
                    cleanupFailure);
                cleanupFailure = CloseOwnedHandleForCleanup(
                    ref stderrRead,
                    "Failed to close parent stderr read handle.",
                    cleanupFailure);
                cleanupFailure = CloseOwnedHandleForCleanup(
                    ref stderrWrite,
                    "Failed to close child stderr write handle.",
                    cleanupFailure);
                cleanupFailure = CloseOwnedHandleForCleanup(
                    ref processInformation.hThread,
                    "Failed to close suspended process thread handle.",
                    cleanupFailure);
                cleanupFailure = CloseOwnedHandleForCleanup(
                    ref processInformation.hProcess,
                    "Failed to close suspended process handle.",
                    cleanupFailure);
                cleanupFailure = CloseOwnedHandleForCleanup(
                    ref job,
                    "Failed to close process Job handle.",
                    cleanupFailure);

                if (cleanupFailure != null)
                    throw new AggregateException(
                        "Contained child launch cleanup failed.",
                        launchFailure,
                        cleanupFailure);
                throw;
            }
            finally
            {
                if (environmentBlock != IntPtr.Zero)
                    Marshal.FreeHGlobal(environmentBlock);
                if (attributeListInitialized)
                    DeleteProcThreadAttributeList(attributeList);
                if (attributeList != IntPtr.Zero)
                    Marshal.FreeHGlobal(attributeList);
                if (inheritedHandleList != IntPtr.Zero)
                    Marshal.FreeHGlobal(inheritedHandleList);
                CloseOwnedHandleBestEffort(ref stdinRead);
                CloseOwnedHandleBestEffort(ref stdinWrite);
                CloseOwnedHandleBestEffort(ref stdoutRead);
                CloseOwnedHandleBestEffort(ref stdoutWrite);
                CloseOwnedHandleBestEffort(ref stderrRead);
                CloseOwnedHandleBestEffort(ref stderrWrite);
                CloseOwnedHandleBestEffort(ref processInformation.hThread);
                CloseOwnedHandleBestEffort(ref processInformation.hProcess);
                if (job != IntPtr.Zero)
                    CloseOwnedHandleBestEffort(ref job);
                if (stdout != null)
                    stdout.Dispose();
                if (stderr != null)
                    stderr.Dispose();
                if (stdin != null)
                    stdin.Dispose();
                if (stdinSafeHandle != null)
                    stdinSafeHandle.Dispose();
                if (stdoutSafeHandle != null)
                    stdoutSafeHandle.Dispose();
                if (stderrSafeHandle != null)
                    stderrSafeHandle.Dispose();
            }
        }

        public bool WaitForExit(int milliseconds)
        {
            return WaitForSingleObject(
                processHandle,
                (uint)milliseconds) == WaitObject0;
        }

        public bool HasExited
        {
            get
            {
                return WaitForSingleObject(
                    processHandle,
                    0) == WaitObject0;
            }
        }

        public int ExitCode
        {
            get
            {
                uint exitCode;
                if (!GetExitCodeProcess(processHandle, out exitCode))
                    throw new Win32Exception(
                        Marshal.GetLastWin32Error());
                return unchecked((int)exitCode);
            }
        }

        public bool CloseJob()
        {
            if (jobHandle == IntPtr.Zero)
                return true;
            IntPtr handle = jobHandle;
            jobHandle = IntPtr.Zero;
            return CloseHandle(handle);
        }

        public void Dispose()
        {
            if (disposed)
                return;
            disposed = true;
            try
            {
                CloseJob();
            }
            finally
            {
                try
                {
                    StandardInput.Dispose();
                    StandardOutput.Dispose();
                    StandardError.Dispose();
                }
                finally
                {
                    CloseOwnedHandleBestEffort(ref processHandle);
                }
            }
        }
    }
}
'@
}
