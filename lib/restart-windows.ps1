param([string]$RequestPath, [switch]$Launch)

$ErrorActionPreference = 'Stop'

function Initialize-RestartNative {
  if ('DshPurge.RestartNative' -as [type]) { return }
  Add-Type @'
using System;
using System.Text;
using System.Diagnostics;
using System.ComponentModel;
using System.Runtime.InteropServices;
namespace DshPurge {
  public static class RestartNative {
    [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)]
    struct StartupInfo {
      public int cb; public string reserved, desktop, title;
      public int x,y,xs,ys,xc,yc,fill,flags; public short show,cb2;
      public IntPtr reserved2,input,output,error;
    }
    [StructLayout(LayoutKind.Sequential)]
    struct ProcessInfo { public IntPtr process,thread; public int pid,tid; }
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
    static extern bool CreateProcess(string app, StringBuilder command, IntPtr pa, IntPtr ta,
      bool inherit, uint flags, IntPtr env, string cwd, ref StartupInfo si, out ProcessInfo pi);
    [DllImport("kernel32.dll", SetLastError=true)]
    static extern bool IsProcessInJob(IntPtr process, IntPtr job, out bool result);
    [StructLayout(LayoutKind.Sequential)]
    struct BasicLimits {
      public long processTime,jobTime; public uint flags;
      public UIntPtr minWorking,maxWorking; public uint active;
      public UIntPtr affinity; public uint priority,scheduling;
    }
    [StructLayout(LayoutKind.Sequential)]
    struct ExtendedLimits {
      public BasicLimits basic; public ulong readOps,writeOps,otherOps,readBytes,writeBytes,otherBytes;
      public UIntPtr processMemory,jobMemory,peakProcessMemory,peakJobMemory;
    }
    [DllImport("kernel32.dll", SetLastError=true)]
    static extern bool QueryInformationJobObject(IntPtr job, int info, out ExtendedLimits limits, int size, IntPtr returned);
    [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr handle);
    public static bool InJob(Process process) {
      bool result;
      if (!IsProcessInJob(process.Handle, IntPtr.Zero, out result))
        throw new Win32Exception(Marshal.GetLastWin32Error());
      return result;
    }
    public static uint JobFlags() {
      if (!InJob(Process.GetCurrentProcess())) return 0;
      ExtendedLimits limits;
      if (!QueryInformationJobObject(IntPtr.Zero, 9, out limits, Marshal.SizeOf(typeof(ExtendedLimits)), IntPtr.Zero))
        throw new Win32Exception(Marshal.GetLastWin32Error());
      return limits.basic.flags;
    }
    public static Process Start(string app, string arguments) {
      var si = new StartupInfo(); si.cb = Marshal.SizeOf(si); ProcessInfo pi;
      // DETACHED_PROCESS does not escape a Job. Refuse shutdown if breakaway is denied.
      if (!CreateProcess(app, new StringBuilder("\"" + app + "\" " + arguments),
          IntPtr.Zero, IntPtr.Zero, false, 0x01000000 | 0x08000000,
          IntPtr.Zero, null, ref si, out pi))
        throw new Win32Exception(Marshal.GetLastWin32Error());
      try { return Process.GetProcessById(pi.pid); }
      finally { CloseHandle(pi.thread); CloseHandle(pi.process); }
    }
  }
}
'@
}

function Write-RestartLog([string]$Message) {
  [IO.File]::AppendAllText($script:LogPath, [DateTime]::UtcNow.ToString('o') + ' ' + $Message + "`r`n")
}

function Write-RestartState([string]$Phase, [string]$Message = '') {
  $json = @{ phase = $Phase; pid = $PID; message = $Message } | ConvertTo-Json -Compress
  [IO.File]::WriteAllText($script:StatePath + '.tmp', $json)
  Move-Item -LiteralPath ($script:StatePath + '.tmp') -Destination $script:StatePath -Force
  Write-RestartLog ($Phase + ' ' + $Message)
}

function Read-RestartState {
  if (-not [IO.File]::Exists($script:StatePath)) { return $null }
  return [IO.File]::ReadAllText($script:StatePath) | ConvertFrom-Json
}

function Assert-RestartFiles($Request) {
  $exe = [IO.Path]::GetFullPath($Request.exe)
  if ([IO.Path]::GetFileName($exe) -notin @('DeepSeek Harness.exe', 'DSH Desktop.exe')) {
    throw 'Unexpected desktop executable name.'
  }
  if (-not [IO.File]::Exists($exe)) { throw 'Desktop executable is missing.' }
  $resources = Join-Path (Split-Path -Parent $exe) 'resources'
  $expectedAsar = Join-Path $resources 'app.asar'
  if ([IO.Path]::GetFullPath($Request.asar) -ne $expectedAsar) { throw 'Archive is outside this installation.' }
  foreach ($relative in @('package.json', 'lib\main.js', 'dsh\node_modules\@deepseek-ai\dsh-desktop-host\lib\index.js')) {
    if (-not [IO.File]::Exists((Join-Path (Join-Path $resources 'app') $relative))) {
      throw ('Incomplete unpacked application: ' + $relative)
    }
  }
}

function Get-RestartProcesses([string]$Exe) {
  return @(Get-CimInstance Win32_Process | Where-Object { $_.ExecutablePath -eq $Exe })
}

function Stop-RestartProcesses([string]$Exe) {
  $targets = @(Get-RestartProcesses $Exe)
  $ids = @($targets | ForEach-Object { $_.ProcessId })
  # The shell must stop before its Host; otherwise it reports an unexpected Host exit.
  $ordered = @($targets | Sort-Object @{Expression={ if ($_.ParentProcessId -in $ids) { 1 } else { 0 } }})
  foreach ($target in $ordered) {
    $current = Get-CimInstance Win32_Process -Filter ('ProcessId=' + $target.ProcessId)
    if (-not $current) { continue }
    if ($current.ExecutablePath -ne $Exe -or $current.CreationDate -ne $target.CreationDate) {
      throw ('Process identity changed: ' + $target.ProcessId)
    }
    Write-RestartLog ('stop pid=' + $target.ProcessId)
    Stop-Process -Id $target.ProcessId -Force
  }
  $deadline = [DateTime]::UtcNow.AddSeconds(20)
  do {
    $left = @(Get-Process -Name ([IO.Path]::GetFileNameWithoutExtension($Exe)) -ErrorAction SilentlyContinue |
      Where-Object { $_.Path -eq $Exe })
    if ($left.Count -eq 0) { return }
    Start-Sleep -Milliseconds 100
  } while ([DateTime]::UtcNow -lt $deadline)
  throw 'Desktop processes did not stop; archive was not changed.'
}

function Move-RestartArchive([string]$Asar, [string]$Backup, [int]$TimeoutSeconds = 10) {
  if (-not [IO.File]::Exists($Asar)) { return $false }
  $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
  do {
    try {
      [IO.File]::Move($Asar, $Backup)
      return $true
    } catch [IO.IOException] {
      if ([DateTime]::UtcNow -ge $deadline) { throw }
      Start-Sleep -Milliseconds 100
    }
  } while ($true)
}

function Start-RestartDesktop($Request) {
  $info = New-Object Diagnostics.ProcessStartInfo
  $info.FileName = $Request.exe
  $info.WorkingDirectory = Split-Path -Parent $Request.exe
  $info.UseShellExecute = $false
  foreach ($key in @('ELECTRON_RUN_AS_NODE', 'DSH_BASE', 'DSH_PERMISSION_MODE', 'DSH_PURGE_RESTART')) {
    $info.EnvironmentVariables.Remove($key)
  }
  $info.EnvironmentVariables['DSH_PROFILE'] = 'desktop'
  if ($Request.home) { $info.EnvironmentVariables['DSH_HOME'] = $Request.home }
  $child = [Diagnostics.Process]::Start($info)
  if ($child.WaitForExit(3000)) { throw ('Desktop exited during launch: ' + $child.ExitCode) }
  return $child.Id
}

function Invoke-RestartTransaction($Request) {
  Assert-RestartFiles $Request
  Write-RestartState 'stopping'
  Stop-RestartProcesses $Request.exe
  $asar = $Request.asar
  $app = Join-Path (Split-Path -Parent $asar) 'app'
  $unpacked = $asar + '.unpacked'
  if ([IO.Directory]::Exists($unpacked)) {
    & robocopy.exe $unpacked $app /E /XC /XN /XO /NFL /NDL /NJH /NJS /nc /ns /np 2>&1 |
      ForEach-Object { Write-RestartLog ('overlay: ' + $_) }
    if ($LASTEXITCODE -gt 7) { throw ('Native resource overlay failed: robocopy=' + $LASTEXITCODE) }
  }
  $backup = $asar + '.bak-' + [IO.Path]::GetFileName($script:WorkDir)
  $moved = Move-RestartArchive $asar $backup
  if ($moved) { Write-RestartLog ('archive backup=' + $backup) }
  try {
    $pending = $asar + '.rename-pending'
    if ([IO.File]::Exists($pending)) { [IO.File]::Delete($pending) }
    $childPid = Start-RestartDesktop $Request
    Write-RestartState 'started' ('pid=' + $childPid)
  } catch {
    $launchError = $_
    Write-RestartLog ('launch failed: ' + $launchError.Exception.Message)
    if ($moved) {
      [IO.File]::Move($backup, $asar)
      Write-RestartLog 'launch failed; original archive restored'
    }
    throw $launchError
  }
}

# Dot sourcing exposes the transaction functions to isolated tests without starting anything.
if ($MyInvocation.InvocationName -eq '.') { return }

$script:WorkDir = Split-Path -Parent ([IO.Path]::GetFullPath($RequestPath))
$script:LogPath = Join-Path $script:WorkDir 'restart.log'
$script:StatePath = Join-Path $script:WorkDir 'state.json'
$mutex = $null
$ownsMutex = $false
try {
  $request = [IO.File]::ReadAllText($RequestPath) | ConvertFrom-Json
  Initialize-RestartNative
  if ($Launch) {
    $shell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $arguments = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' + $PSCommandPath + '" -RequestPath "' + $RequestPath + '"'
    $controller = [DshPurge.RestartNative]::Start($shell, $arguments)
    $deadline = [DateTime]::UtcNow.AddSeconds(15)
    do {
      $state = Read-RestartState
      if ($state -and $state.phase -eq 'ready') {
        if ($controller.HasExited) { throw 'Controller exited before handoff.' }
        $state | ConvertTo-Json -Compress
        exit 0
      }
      if ($state -and $state.phase -eq 'failed') { throw $state.message }
      if ($controller.HasExited) { throw ('Controller exited: ' + $controller.ExitCode) }
      Start-Sleep -Milliseconds 100
    } while ([DateTime]::UtcNow -lt $deadline)
    throw 'Controller readiness timed out; desktop was not stopped.'
  }
  $jobFlags = [DshPurge.RestartNative]::JobFlags()
  # A shared resource Job may remain after breakaway; only a terminating Job prevents handoff.
  if ($jobFlags -band 0x2000) { throw 'Controller is still in a kill-on-close Job; shutdown refused.' }
  Write-RestartLog ('isolation verified; remaining job flags=' + $jobFlags)
  Assert-RestartFiles $request
  $hash = [Security.Cryptography.SHA256]::Create().ComputeHash([Text.Encoding]::UTF8.GetBytes($request.exe.ToLowerInvariant()))
  $mutex = New-Object Threading.Mutex($false, ('Local\DshPurgeRestart-' + [BitConverter]::ToString($hash).Replace('-', '')))
  try { $ownsMutex = $mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $ownsMutex = $true }
  if (-not $ownsMutex) { throw 'Another controller owns this installation restart.' }
  Write-RestartState 'ready'
  $deadline = [DateTime]::UtcNow.AddSeconds(15)
  while (-not [IO.File]::Exists((Join-Path $script:WorkDir 'commit'))) {
    if ([IO.File]::Exists((Join-Path $script:WorkDir 'cancel'))) {
      Write-RestartState 'cancelled' 'Desktop was not stopped.'
      return
    }
    if ([DateTime]::UtcNow -ge $deadline) { throw 'Restart was not committed; desktop was not stopped.' }
    Start-Sleep -Milliseconds 100
  }
  Invoke-RestartTransaction $request
} catch {
  $message = $_.Exception.Message
  if (-not $Launch) { Write-RestartState 'failed' $message }
  else { Write-RestartLog ('launcher failed: ' + $message) }
  [Console]::Error.WriteLine($message)
  exit 1
} finally {
  if ($ownsMutex) { $mutex.ReleaseMutex() }
  if ($mutex) { $mutex.Dispose() }
}
