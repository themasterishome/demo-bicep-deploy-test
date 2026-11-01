<#
.SYNOPSIS
  Offline checks to run before any what-if or deployment: deployment units, compile, lint, parameters,
  file layout, duplicate declarations.

.DESCRIPTION
  No Azure calls. Run it locally before pushing. The validate workflow (.github/workflows/mirror-validate.yml) runs it too.

    1. deploy/units.json and boundaries.json parse, and every unit's template and parameters file
       exists, enabled or not (a disabled unit is still checked, so it is ready the day it is enabled).
       Every entry of boundaries.json has the fields the deploy gate reads. A boundary has a type, a
       path, a non-empty changeTypes list and onDeploy exactly "inert" or "review" (a review boundary
       also has a note), a hold has a reason and an idPattern or a type with a namePattern, and an
       expected Ignore has a pattern and a reason. Every pattern is a valid regular expression.
    2. Compiles every entry point once: tenant/main.bicep, the 11 subscription mains, every file in
       the demo subscription's resource-groups folder (the routine group files, the deploy-excluded and hash-excluded
       ones, networkwatchers.bicep and the two vpn-gateways files), and every other unit template (the
       VPN gateway, budget, pilot and tenant templates). The group files of the other ten subscriptions
       are compiled through their main.bicep, because a module behind a false condition is still compiled.
       Linter rules at error level in bicepconfig.json fail the build, so this is also the lint gate.
       Every compile of steps 2 and 3 runs in one Bicep process, the Bicep CLI's JSON-RPC server (bicep jsonrpc
       --stdio), so the Bicep CLI starts once and not once per file. The templates and diagnostics are the
       ones az bicep build and az bicep build-params give.
    3. Builds every unit's parameters file and every parameters.verify.bicepparam (the subscription
       sweep previews with those), as az bicep build-params does. A parameters file that reads a secure
       input through readEnvironmentVariable() with no default is reported and skipped when that
       variable is not set, because it cannot build without the secret.
    4. Layout (text checks, no compile). The group files are edited by hand, so this step keeps the
       rules the sweeps and the deploy script rely on:
       a. every demo resource-groups/<x>.bicep has <x>.bicepparam whose using line names './<x>.bicep'
          (the resource group sweep finds files only through their .bicepparam), except *.hash-excluded.bicep
          and the files another file calls as a module (networkwatchers.bicep from main.bicep, the two
          *.vpn-gateways.bicep files from network-gateways.bicep). Every .bicepparam there names a file that
          exists, and every demo group unit names the resource group its file is named after.
          For every unit in deploy/units.json with a .bicepparam parameters file, the using line of
          that file names the unit's template. deploy-unit.ps1 gives the Azure CLI only the .bicepparam
          file, and the CLI takes the template from that line. Every using line is read as Bicep reads
          it, so a line inside a comment or a multi-line string does not count.
       b. every module and import path in a .bicep under infra/ resolves to a file that exists, and none
          points at a file of another layout (see g).
       c. no resource name with '#' outside a *.hash-excluded.bicep file (what-if cannot preview such a
          name, and the whole preview of that group fails).
       d. a '// deploy-excluded:' marker appears only in a *.deploy-excluded.bicep file, every demo
          *.deploy-excluded.bicep file is the template of a unit, and that unit is listed in the
          measuredWith of the group's routine unit (otherwise the drift check never measures it). Every
          measuredWith and groupsDeclaredBy entry in deploy/units.json names a unit with exactly that
          name, case included, as deploy-unit.ps1 matches them.
       e. no '// Source:' or '// rg-member:' line is left under infra/subscriptions.
       f. every .bicep under infra/subscriptions, the group files included, is reached from a
          deploy/units.json template or a main.bicep through module lines. A file nothing reaches is
          never previewed or deployed.
       g. no file of another layout is present (the patterns are in $retiredPatterns below, nothing
          in this folder uses them).
       h. no .bicep or .bicepparam file under infra/ or pipelines/ has a line that ends in two carriage
          returns. Bicep counts each carriage return as a line break, so in such a file every warning
          names the wrong line and every '#disable-next-line' comment points at an empty line and is
          ignored. git also treats such a file as non-text and keeps the extra carriage returns.
       i. every path the code names (a unit's template and parameters file in deploy/units.json, a module, import
          or using line, the file of a load function such as loadJsonContent) matches the file on disk in case
          as well. Windows finds a file whose name differs only in case and Linux does not, so such a path would
          pass on one runner image and fail on the other.
    5. find-duplicate-declarations.ps1 on every subscription and resource group unit with its
       parameters file (ResourceDeployedMultipleTimes would fail that deployment), as deploy-unit.ps1
       does, and on the three subscriptions that keep a parameters.verify.bicepparam with that file, so
       the modules behind switches that are off in the routine file are checked too. Then the
       declarations of all units are merged, and the same resource (subscription, resource group, extension
       scope, type and name) declared by two units fails the run, for example a lock declared both in
       governance/locks/<group>.bicep (demo-subscription unit) and in the group's own resource group
       file, or a resource in both a routine group file and its deploy-excluded file. Names the checker
       cannot resolve take no part in the merge. The checker runs in this script's own PowerShell and reads the
       compile of step 3 (of step 2 for a unit with no parameters file), so no file is compiled twice.

  Warnings are counted and printed per rule but do not fail the run.

.PARAMETER OutDir
  Optional folder for build logs (one per compiled file) and the duplicate check output.

.PARAMETER CompileCache
  Optional folder for the compile cache. It holds the output of every compile of steps 2 and 3 that passed, and
  index.json, which lists each file a compile read with its SHA256. The validate workflow passes it, so its check of
  the pipeline units (.github/scripts/mirror-pipeline.ps1 -Mode PipelineScope, with MIRROR_COMPILE_CACHE set to the
  folder) reads these compiles instead of compiling every unit again. An entry is used only while every file it
  lists is unchanged. Without this parameter the cache lives in a temporary folder for step 5 and is removed at the end.

.PARAMETER SkipDuplicates
  Skip step 5 (the duplicate check of every unit).

.NOTES
  Exit code 0 when every check passes, 1 otherwise. Runs unchanged under Windows PowerShell 5.1 and
  PowerShell 7 (Windows and Linux).
  Needs the Bicep CLI. It takes the first bicep on PATH when AZURE_BICEP_USE_BINARY_FROM_PATH is true (the
  workflows set it after they pin the binary), else the copy that az bicep install puts in the bin folder of the
  Azure CLI's configuration folder, else the first bicep on PATH. That is the binary az bicep itself runs.
#>
[CmdletBinding()]
param(
  [string]$OutDir,
  [string]$CompileCache,
  [switch]$SkipDuplicates
)
Set-StrictMode -Version 2
$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$infra = Join-Path $repo 'infra'
$mainFolder = 'demo'
$mainRgDir = [IO.Path]::Combine($infra, 'subscriptions', $mainFolder, 'resource-groups')
# The same script runs on Windows and Linux. Paths are built with the separator of the system. $pathCmp, used
# where a path is compared with the repository root, the demo folder or a unit's template, ignores case on
# Windows only, because Linux file names are case-sensitive. The other path comparisons below ignore case on every
# system.
$sep = [IO.Path]::DirectorySeparatorChar
$pathCmp = if ($sep -eq '\') { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
# The output folder is passed to the duplicate checker, a child process, so it is made a full path, written
# with '/' on Linux when it was given with '\' (for example "$env:RUNNER_TEMP\x").
if ($OutDir) {
  if ($sep -ne '\') { $OutDir = $OutDir.Replace('\', '/') }
  $OutDir = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutDir)
  New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
}
# The compile cache is made a full path in the same way, or is a temporary folder that the end of the script removes.
$cacheTemp = $null
if ($CompileCache) {
  if ($sep -ne '\') { $CompileCache = $CompileCache.Replace('\', '/') }
  $CompileCache = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($CompileCache)
} else {
  $cacheTemp = Join-Path ([IO.Path]::GetTempPath()) ('preflight-compiled-' + [guid]::NewGuid().ToString('N'))
  $CompileCache = $cacheTemp
}
New-Item -ItemType Directory -Force -Path $CompileCache | Out-Null
$failures = New-Object System.Collections.Generic.List[string]
$ruleCounts = @{}
# Windows (NTFS) lists the files of a folder sorted by name without case, and Linux lists them in the file
# system's own order. Every listing below is sorted the Windows way, so the output is in the same order on both.
# The comparer is cast to IComparer so that PowerShell calls Array.Sort(Array, Array, IComparer), which sorts the
# items in place. With a StringComparer it picks the generic overload, passes a converted copy of the items, and
# only the keys end up sorted.
function Get-SortedByPath($items) {
  # An empty listing binds as $null, so it is dropped and the result is an empty list, not one $null.
  $a = [object[]]@($items | Where-Object { $null -ne $_ })
  $keys = [string[]]@($a | ForEach-Object { $_.FullName })
  [Array]::Sort($keys, $a, [Collections.IComparer][StringComparer]::OrdinalIgnoreCase)
  return $a
}
# Get-ChildItem -Recurse -File in the Windows order, which is the files of a folder and then each subfolder in turn.
function Get-SortedFilesRecurse([string]$dir) {
  $items = Get-SortedByPath @(Get-ChildItem -LiteralPath $dir)
  $items | Where-Object { -not $_.PSIsContainer }
  foreach ($d in @($items | Where-Object { $_.PSIsContainer -and -not ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) })) { Get-SortedFilesRecurse $d.FullName }
}
# Windows PowerShell 5.1 writes UTF8 with a byte order mark. PowerShell 7 writes the same bytes only with utf8BOM.
$utf8Bom = if ($PSVersionTable.PSVersion.Major -ge 6) { 'utf8BOM' } else { 'UTF8' }
# A path written with '/' (units.json, module and using lines) as a path of this system.
function Get-SysPath([string]$rel) { return ($rel -replace '[\\/]', $sep) }

function Get-RepoPath([string]$rel) { [IO.Path]::GetFullPath((Join-Path $repo (Get-SysPath $rel))) }
function Get-RelPath([string]$full) {
  $f = [IO.Path]::GetFullPath($full)
  if ($f.StartsWith($repo + $sep, $pathCmp)) { $f = $f.Substring($repo.Length + 1) }
  return ($f -replace '\\', '/')
}

# The text of a Bicep or .bicepparam file as Bicep reads its statements. Comments (// and /* */) and the inside of
# multi-line strings ('''...''', with any quotes right after the closing three) become spaces, and line breaks stay. A single-quoted string stays as it is, with
# the expressions inside ${...}, so a comment marker inside it is text. So a using line inside a comment or a
# multi-line string is not taken for the one Bicep compiles.
function Get-BicepCodeText([string]$path) {
  $t = [IO.File]::ReadAllText($path)
  $n = $t.Length
  $sb = New-Object System.Text.StringBuilder $n
  # -1 marks a single-quoted string, 0 or more an expression inside ${...} with that many open braces.
  $stack = New-Object System.Collections.Generic.List[int]
  $q = [char]39; $bs = [char]92; $cr = [char]13; $lf = [char]10
  $i = 0
  while ($i -lt $n) {
    $c = $t[$i]
    if ($stack.Count -gt 0 -and $stack[$stack.Count - 1] -lt 0) {
      if ($c -eq $bs -and $i + 1 -lt $n) { [void]$sb.Append($c).Append($t[$i + 1]); $i += 2; continue }
      if ($c -eq $q) { $stack.RemoveAt($stack.Count - 1); [void]$sb.Append($c); $i++; continue }
      if ($c -eq [char]'$' -and $i + 1 -lt $n -and $t[$i + 1] -eq [char]'{') { $stack.Add(0); [void]$sb.Append('${'); $i += 2; continue }
      [void]$sb.Append($c); $i++; continue
    }
    $blankTo = -1
    if ($c -eq $q -and $i + 2 -lt $n -and $t[$i + 1] -eq $q -and $t[$i + 2] -eq $q) {
      $e = $t.IndexOf("'''", $i + 3, [StringComparison]::Ordinal)
      if ($e -lt 0) { $blankTo = $n }
      else {
        # Bicep keeps any quote right after the closing three in the string, so '''x'''' is the text x'.
        $blankTo = $e + 3
        while ($blankTo -lt $n -and $t[$blankTo] -eq $q) { $blankTo++ }
      }
    } elseif ($c -eq [char]'/' -and $i + 1 -lt $n -and $t[$i + 1] -eq [char]'/') {
      $blankTo = $t.IndexOfAny([char[]]@($cr, $lf), $i)
      if ($blankTo -lt 0) { $blankTo = $n }
    } elseif ($c -eq [char]'/' -and $i + 1 -lt $n -and $t[$i + 1] -eq [char]'*') {
      $e = $t.IndexOf('*/', $i + 2, [StringComparison]::Ordinal)
      $blankTo = if ($e -lt 0) { $n } else { $e + 2 }
    }
    if ($blankTo -ge 0) {
      for (; $i -lt $blankTo; $i++) { if ($t[$i] -eq $cr -or $t[$i] -eq $lf) { [void]$sb.Append($t[$i]) } else { [void]$sb.Append(' ') } }
      continue
    }
    if ($c -eq $q) { $stack.Add(-1) }
    elseif ($stack.Count -gt 0) {
      $top = $stack.Count - 1
      if ($c -eq [char]'{') { $stack[$top] = $stack[$top] + 1 }
      elseif ($c -eq [char]'}') { if ($stack[$top] -eq 0) { $stack.RemoveAt($top) } else { $stack[$top] = $stack[$top] - 1 } }
    }
    [void]$sb.Append($c); $i++
  }
  return $sb.ToString()
}
# The file a .bicepparam file names in its using line, as written there, or $null when it has none.
function Get-UsingPath([string]$path) {
  $m = [regex]::Match((Get-BicepCodeText $path), "(?m)^\s*using\s+'([^']+)'")
  if ($m.Success) { return $m.Groups[1].Value }
  return $null
}

# Files of another layout. Nothing may use them. Step 4g lists any that are on disk.
$retiredPatterns = @(
  '^infra/typed/',
  "^infra/subscriptions/$mainFolder/candidates-[^/]*\.bicep$",
  "^infra/subscriptions/$mainFolder/verify-candidates\.bicep$",
  "^infra/subscriptions/$mainFolder/resource-groups/_report\.txt$",
  '^infra/subscriptions/.+/workload-candidates[^/]*\.bicep$',
  '^infra/subscriptions/.+/reviewed-[^/]*\.bicep$',
  '^infra/subscriptions/.+/(network-watchers|connection-monitors)\.bicep$',
  '^infra/subscriptions/subscription-composition\.bicep$',
  '^infra/modules/identity/',
  '^infra/parameters/resource-groups\.json$',
  '^infra/subscriptions/demo/automation-modules\.bicep$',
  '^infra/subscriptions/demo/secret-bearing-connections\.bicep$',
  '^scripts/(gen-rg\.ps1|find-orphan-typed-files\.ps1|README-gen-rg\.md)$'
)
function Test-Retired([string]$full) {
  $rel = Get-RelPath $full
  foreach ($p in $retiredPatterns) { if ($rel -imatch $p) { return $true } }
  return $false
}

# Environment variables a parameters file reads with readEnvironmentVariable('X') and no default, and that are not set.
function Get-UnsetSecureInputs([string]$paramFile) {
  $text = [IO.File]::ReadAllText($paramFile)
  return @([regex]::Matches($text, "readEnvironmentVariable\(\s*'([^']+)'\s*\)") | ForEach-Object { $_.Groups[1].Value } |
           Where-Object { -not [Environment]::GetEnvironmentVariable($_) } | Select-Object -Unique)
}

# The client of Bicep's JSON-RPC server and a JSON reader with no size limit, in C# 5, which both PowerShell
# editions compile.
$rpcSource = @'
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Text;

namespace PreflightValidate
{
    // A client of the Bicep CLI's JSON-RPC server (bicep jsonrpc --stdio). Each message is a Content-Length header,
    // a blank line and the JSON text. One server compiles every file, so the start of the Bicep process is paid once.
    public sealed class BicepRpc : IDisposable
    {
        private static readonly UTF8Encoding Utf8 = new UTF8Encoding(false);
        private readonly Process proc;
        private readonly Stream input;
        private readonly Stream output;
        private readonly StringBuilder errors = new StringBuilder();
        private int nextId;

        public BicepRpc(string exe)
        {
            ProcessStartInfo psi = new ProcessStartInfo(exe, "jsonrpc --stdio");
            psi.UseShellExecute = false;
            psi.CreateNoWindow = true;
            psi.RedirectStandardInput = true;
            psi.RedirectStandardOutput = true;
            psi.RedirectStandardError = true;
            proc = Process.Start(psi);
            // Standard error is read as it comes, so a full pipe can never stop the server.
            proc.ErrorDataReceived += delegate(object sender, DataReceivedEventArgs e) { if (e.Data != null) { lock (errors) { errors.AppendLine(e.Data); } } };
            proc.BeginErrorReadLine();
            input = proc.StandardInput.BaseStream;
            output = proc.StandardOutput.BaseStream;
        }

        public string ErrorText { get { lock (errors) { return errors.ToString(); } } }

        // Sends one request and returns its result object. A JSON-RPC error or the end of the server ends in an exception.
        public Dictionary<string, object> Call(string method, string paramsJson)
        {
            int id = ++nextId;
            byte[] body = Utf8.GetBytes("{\"jsonrpc\":\"2.0\",\"id\":" + id.ToString(CultureInfo.InvariantCulture) + ",\"method\":" + Quote(method) + ",\"params\":" + paramsJson + "}\r\n\r\n");
            byte[] head = Encoding.ASCII.GetBytes("Content-Length: " + body.Length.ToString(CultureInfo.InvariantCulture) + "\r\n\r\n");
            input.Write(head, 0, head.Length);
            input.Write(body, 0, body.Length);
            input.Flush();
            while (true)
            {
                int length = ReadHeader();
                Dictionary<string, object> msg = Json.Parse(Utf8.GetString(ReadExact(length))) as Dictionary<string, object>;
                if (msg == null) { throw new InvalidDataException("the Bicep JSON-RPC server sent a message that is not a JSON object"); }
                object rid;
                if (!msg.TryGetValue("id", out rid) || rid == null) { continue; }
                if (Convert.ToInt32(rid, CultureInfo.InvariantCulture) != id) { throw new InvalidDataException("the Bicep JSON-RPC server answered request " + rid + " while request " + id + " was waiting"); }
                object err;
                if (msg.TryGetValue("error", out err) && err != null)
                {
                    Dictionary<string, object> e = err as Dictionary<string, object>;
                    object m = null;
                    if (e != null) { e.TryGetValue("message", out m); }
                    throw new InvalidOperationException("Bicep JSON-RPC " + method + " failed: " + (m == null ? "no message" : m.ToString()));
                }
                object result;
                msg.TryGetValue("result", out result);
                Dictionary<string, object> r = result as Dictionary<string, object>;
                if (r == null) { throw new InvalidDataException("Bicep JSON-RPC " + method + " returned no result object"); }
                return r;
            }
        }

        private int ReadHeader()
        {
            List<byte> line = new List<byte>();
            int length = -1;
            while (true)
            {
                int b = output.ReadByte();
                if (b < 0) { throw new EndOfStreamException("the Bicep JSON-RPC server stopped. " + ErrorText.Trim()); }
                if (b == '\n')
                {
                    string text = Encoding.ASCII.GetString(line.ToArray()).TrimEnd('\r');
                    line.Clear();
                    if (text.Length == 0) { if (length >= 0) { return length; } continue; }
                    int colon = text.IndexOf(':');
                    if (colon > 0 && string.Equals(text.Substring(0, colon).Trim(), "Content-Length", StringComparison.OrdinalIgnoreCase))
                    {
                        length = int.Parse(text.Substring(colon + 1).Trim(), NumberStyles.None, CultureInfo.InvariantCulture);
                    }
                    continue;
                }
                line.Add((byte)b);
            }
        }

        private byte[] ReadExact(int n)
        {
            byte[] buf = new byte[n];
            int done = 0;
            while (done < n)
            {
                int r = output.Read(buf, done, n - done);
                if (r <= 0) { throw new EndOfStreamException("the Bicep JSON-RPC server stopped in the middle of a message. " + ErrorText.Trim()); }
                done += r;
            }
            return buf;
        }

        public static string Quote(string s)
        {
            StringBuilder sb = new StringBuilder(s.Length + 2);
            sb.Append('"');
            foreach (char c in s)
            {
                switch (c)
                {
                    case '"': sb.Append("\\\""); break;
                    case '\\': sb.Append("\\\\"); break;
                    case '\b': sb.Append("\\b"); break;
                    case '\f': sb.Append("\\f"); break;
                    case '\n': sb.Append("\\n"); break;
                    case '\r': sb.Append("\\r"); break;
                    case '\t': sb.Append("\\t"); break;
                    default:
                        if (c < ' ') { sb.Append("\\u").Append(((int)c).ToString("x4", CultureInfo.InvariantCulture)); }
                        else { sb.Append(c); }
                        break;
                }
            }
            sb.Append('"');
            return sb.ToString();
        }

        public void Dispose()
        {
            try { input.Close(); } catch (IOException) { }
            try { if (!proc.WaitForExit(10000)) { proc.Kill(); } } catch (InvalidOperationException) { }
            proc.Dispose();
        }
    }

    // A small JSON reader. Objects become Dictionary<string, object>, arrays List<object>, numbers double, and
    // strings, true, false and null their .NET values. It has no size limit, unlike ConvertFrom-Json in Windows
    // PowerShell 5.1, which a large compiled template can exceed.
    public static class Json
    {
        public static object Parse(string text)
        {
            int i = 0;
            object v = Value(text, ref i);
            Skip(text, ref i);
            if (i != text.Length) { throw new FormatException("text after the JSON value at offset " + i); }
            return v;
        }

        private static void Skip(string t, ref int i) { while (i < t.Length && (t[i] == ' ' || t[i] == '\t' || t[i] == '\r' || t[i] == '\n')) { i++; } }

        private static object Value(string t, ref int i)
        {
            Skip(t, ref i);
            if (i >= t.Length) { throw new FormatException("unexpected end of JSON"); }
            char c = t[i];
            if (c == '{')
            {
                Dictionary<string, object> d = new Dictionary<string, object>(StringComparer.Ordinal);
                i++; Skip(t, ref i);
                if (i < t.Length && t[i] == '}') { i++; return d; }
                while (true)
                {
                    Skip(t, ref i);
                    string k = Str(t, ref i);
                    Skip(t, ref i);
                    if (i >= t.Length || t[i] != ':') { throw new FormatException("':' expected at offset " + i); }
                    i++;
                    d[k] = Value(t, ref i);
                    Skip(t, ref i);
                    if (i < t.Length && t[i] == ',') { i++; continue; }
                    if (i < t.Length && t[i] == '}') { i++; return d; }
                    throw new FormatException("',' or '}' expected at offset " + i);
                }
            }
            if (c == '[')
            {
                List<object> a = new List<object>();
                i++; Skip(t, ref i);
                if (i < t.Length && t[i] == ']') { i++; return a; }
                while (true)
                {
                    a.Add(Value(t, ref i));
                    Skip(t, ref i);
                    if (i < t.Length && t[i] == ',') { i++; continue; }
                    if (i < t.Length && t[i] == ']') { i++; return a; }
                    throw new FormatException("',' or ']' expected at offset " + i);
                }
            }
            if (c == '"') { return Str(t, ref i); }
            if (string.CompareOrdinal(t, i, "true", 0, 4) == 0) { i += 4; return true; }
            if (string.CompareOrdinal(t, i, "false", 0, 5) == 0) { i += 5; return false; }
            if (string.CompareOrdinal(t, i, "null", 0, 4) == 0) { i += 4; return null; }
            int s = i;
            while (i < t.Length && "+-0123456789.eE".IndexOf(t[i]) >= 0) { i++; }
            if (i == s) { throw new FormatException("unexpected character at offset " + i); }
            return double.Parse(t.Substring(s, i - s), NumberStyles.Float, CultureInfo.InvariantCulture);
        }

        private static string Str(string t, ref int i)
        {
            if (i >= t.Length || t[i] != '"') { throw new FormatException("string expected at offset " + i); }
            i++;
            StringBuilder sb = new StringBuilder();
            while (true)
            {
                if (i >= t.Length) { throw new FormatException("unterminated string"); }
                char c = t[i++];
                if (c == '"') { return sb.ToString(); }
                if (c != '\\') { sb.Append(c); continue; }
                if (i >= t.Length) { throw new FormatException("unterminated escape"); }
                char e = t[i++];
                switch (e)
                {
                    case '"': sb.Append('"'); break;
                    case '\\': sb.Append('\\'); break;
                    case '/': sb.Append('/'); break;
                    case 'b': sb.Append('\b'); break;
                    case 'f': sb.Append('\f'); break;
                    case 'n': sb.Append('\n'); break;
                    case 'r': sb.Append('\r'); break;
                    case 't': sb.Append('\t'); break;
                    case 'u':
                        if (i + 4 > t.Length) { throw new FormatException("short \\u escape"); }
                        sb.Append((char)int.Parse(t.Substring(i, 4), NumberStyles.HexNumber, CultureInfo.InvariantCulture));
                        i += 4;
                        break;
                    default: throw new FormatException("unknown escape at offset " + (i - 1));
                }
            }
        }
    }
}
'@
if (-not ('PreflightValidate.BicepRpc' -as [type])) { Add-Type -TypeDefinition $rpcSource -Language CSharp }
$utf8NoBom = New-Object System.Text.UTF8Encoding $false

# The Bicep CLI that az bicep runs. The first bicep on PATH when AZURE_BICEP_USE_BINARY_FROM_PATH is true, else the
# copy az bicep install keeps in the bin folder of the Azure CLI's configuration folder, else the first bicep on PATH.
function Get-PreflightBicep {
  $onPath = Get-Command bicep -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
  if (([string]$env:AZURE_BICEP_USE_BINARY_FROM_PATH) -match '^(?i:true|yes|1)$' -and $onPath) { return $onPath.Source }
  $cfg = if ($env:AZURE_CONFIG_DIR) { $env:AZURE_CONFIG_DIR } else { Join-Path $HOME '.azure' }
  $inAz = [IO.Path]::Combine($cfg, 'bin', $(if ($sep -eq '\') { 'bicep.exe' } else { 'bicep' }))
  if (Test-Path -LiteralPath $inAz -PathType Leaf) { return $inAz }
  if ($onPath) { return $onPath.Source }
  return $null
}

# The message of an exception from a .NET method, without PowerShell's wrapper text.
function Get-InnerMessage($err) {
  $e = $err.Exception
  while ($e -is [System.Management.Automation.MethodInvocationException] -and $null -ne $e.InnerException) { $e = $e.InnerException }
  return $e.Message
}

# The SHA256 of a file, read once per run.
$fileHashes = @{}
function Get-FileSha([string]$full) {
  $k = $full.ToLowerInvariant()
  if (-not $script:fileHashes.ContainsKey($k)) { $script:fileHashes[$k] = (Get-FileHash -LiteralPath $full -Algorithm SHA256).Hash }
  return $script:fileHashes[$k]
}

# The compile cache. Each compile that passed is kept in a file of its own, in the form the CLI prints with
# --stdout: the template for a .bicep file, {"parametersJson": ..., "templateJson": ...} for a .bicepparam file.
# index.json lists, for each, every file the compile read (Bicep's getFileReferences) with its SHA256, so a reader
# uses an entry only while those files are unchanged. $cacheFiles maps a compiled file to its cache file for step 5.
$cacheEntries = New-Object System.Collections.Generic.List[object]
$cacheFiles = @{}
function Save-CompiledOutput([string]$path, [bool]$isParams, $result) {
  try {
    $refs = $script:rpc.Call('bicep/getFileReferences', '{"path":' + [PreflightValidate.BicepRpc]::Quote($path) + '}')
    $inputs = @(foreach ($f in @($refs['filePaths'])) { [ordered]@{ path = (Get-RelPath ([string]$f)); sha256 = (Get-FileSha ([string]$f)) } })
    if ($isParams) { $text = '{"parametersJson":' + [PreflightValidate.BicepRpc]::Quote([string]$result['parameters']) + ',"templateJson":' + [PreflightValidate.BicepRpc]::Quote([string]$result['template']) + '}' }
    else { $text = [string]$result['contents'] }
    $name = '{0:d3}-{1}.json' -f ($script:cacheEntries.Count + 1), ((Get-RelPath $path) -replace '[^A-Za-z0-9_.-]', '_')
    $file = Join-Path $CompileCache $name
    [IO.File]::WriteAllText($file, $text, $script:utf8NoBom)
    $script:cacheEntries.Add([ordered]@{ path = (Get-RelPath $path); kind = $(if ($isParams) { 'parameters' } else { 'template' }); file = $name; inputs = $inputs })
    $script:cacheFiles[$path.ToLowerInvariant()] = $file
  } catch {
    # Without a cache entry the readers compile the file themselves, so this is a note and not a failure.
    Write-Host "  not kept in the compile cache: $(Get-RelPath $path) ($(Get-InnerMessage $_))" -ForegroundColor Yellow
  }
}

# Compiles one .bicep file (bicep/compile) or .bicepparam file (bicep/compileParams) in the Bicep server, counts
# diagnostics per rule, keeps the log, records a failure, and keeps a compile that passed in the compile cache.
# A server that stopped is started again for the next file.
function Invoke-BicepCompile([string]$path, [string]$label) {
  $isParams = $path -like '*.bicepparam'
  $q = [PreflightValidate.BicepRpc]::Quote($path)
  $log = New-Object System.Collections.Generic.List[string]
  $r = $null
  try {
    if ($null -eq $script:rpc) { $script:rpc = New-Object PreflightValidate.BicepRpc $script:bicepExe }
    if ($isParams) { $r = $script:rpc.Call('bicep/compileParams', '{"path":' + $q + ',"parameterOverrides":{}}') }
    else { $r = $script:rpc.Call('bicep/compile', '{"path":' + $q + '}') }
  } catch {
    $log.Add("Error: $(Get-InnerMessage $_)")
    if ($null -ne $script:rpc) { $script:rpc.Dispose(); $script:rpc = $null }
  }
  if ($null -ne $r) {
    foreach ($d in @($r['diagnostics'])) {
      if ($null -eq $d) { continue }
      $st = $d['range']['start']
      $log.Add(('{0}({1},{2}) : {3} {4}: {5}' -f $d['source'], ([int]$st['line'] + 1), ([int]$st['char'] + 1), $d['level'], $d['code'], $d['message']))
    }
  }
  foreach ($l in $log) {
    if ($l -match ': (Warning|Error) ([A-Za-z0-9-]+):') {
      $k = "$($Matches[1]) $($Matches[2])"
      if ($script:ruleCounts.ContainsKey($k)) { $script:ruleCounts[$k]++ } else { $script:ruleCounts[$k] = 1 }
    }
  }
  $item = Get-Item -LiteralPath $path
  if ($OutDir) { Set-Content -LiteralPath (Join-Path $OutDir ($item.Directory.Name + '__' + $item.Name + '.log')) -Value @($log) -Encoding $utf8Bom }
  if ($null -eq $r -or $r['success'] -ne $true) {
    $script:failures.Add("${label}: $path")
    $shown = @($log | Where-Object { $_ -match ': Error |^Error: ' } | Select-Object -First 20)
    if ($shown.Count -eq 0) { $shown = @($log | Select-Object -Last 10) }
    $shown | ForEach-Object { Write-Host "  $_" -ForegroundColor Red }
    return
  }
  Save-CompiledOutput $path $isParams $r
}

# The entries of deploy/boundaries.json without a field the deploy gate reads, or with a value it cannot use, one
# line each. A boundary needs a type, a path, a non-empty changeTypes list and onDeploy exactly "inert" or "review"
# (so a misspelt "review" is caught before any preview), and a review boundary needs the note the gate prints. A
# hold needs a reason and either an idPattern or a type with a namePattern. An expected Ignore needs a pattern and
# a reason. Every pattern must be a valid regular expression.
function Get-BoundaryProblems($doc) {
  $problems = New-Object System.Collections.Generic.List[string]
  $text = { param($o, [string]$name) if ($null -eq $o) { return $null }; $p = $o.PSObject.Properties[$name]; if ($null -ne $p -and $p.Value -is [string] -and $p.Value.Trim()) { return $p.Value }; return $null }
  $regexOk = { param([string]$rx) try { $null = [regex]::Match('', $rx); return $true } catch { return $false } }
  # An empty file or a top-level list is reported as one problem, the same on both PowerShell hosts.
  if (-not ($doc -is [System.Management.Automation.PSCustomObject])) { $problems.Add('boundaries.json is empty or not a JSON object'); return $problems }
  foreach ($list in 'alwaysAcceptedPropertyChangeTypes', 'boundaries', 'holds', 'expectedIgnore') {
    $p = $doc.PSObject.Properties[$list]
    if ($null -eq $p -or -not ($p.Value -is [System.Array])) { $problems.Add("boundaries.json has no $list list") }
  }
  if ($problems.Count -gt 0) { return $problems }
  foreach ($ct in @($doc.alwaysAcceptedPropertyChangeTypes)) {
    if (-not ($ct -is [string]) -or -not $ct.Trim()) { $problems.Add('boundaries.json: alwaysAcceptedPropertyChangeTypes has an entry that is not a change type name') }
  }
  $i = 0
  foreach ($b in @($doc.boundaries)) {
    $at = "boundaries[$i]"
    if ($null -eq $b) { $problems.Add("boundaries.json: $at is empty"); $i++; continue }
    $t = & $text $b 'type'; $pa = & $text $b 'path'
    if ($t -and $pa) { $at = "boundaries[$i] ($t, $pa)" }
    if (-not $t) { $problems.Add("boundaries.json: $at has no type") }
    if (-not $pa) { $problems.Add("boundaries.json: $at has no path") }
    $cp = $b.PSObject.Properties['changeTypes']
    if ($null -eq $cp -or -not ($cp.Value -is [System.Array]) -or @($cp.Value).Count -eq 0) { $problems.Add("boundaries.json: $at has no changeTypes list with at least one change type") }
    elseif (@($cp.Value | Where-Object { -not ($_ -is [string]) -or -not $_.Trim() }).Count -gt 0) { $problems.Add("boundaries.json: $at has a changeTypes entry that is not a change type name") }
    $op = $b.PSObject.Properties['onDeploy']
    $od = if ($null -ne $op) { $op.Value } else { $null }
    if (-not ([string]::Equals([string]$od, 'inert', [StringComparison]::Ordinal) -or [string]::Equals([string]$od, 'review', [StringComparison]::Ordinal))) {
      $problems.Add("boundaries.json: $at has onDeploy '$od', which must be exactly 'inert' or 'review'")
    } elseif ($od -ceq 'review' -and -not (& $text $b 'note')) { $problems.Add("boundaries.json: $at is a review boundary with no note, and the gate prints the note for the operator") }
    $i++
  }
  $i = 0
  foreach ($h in @($doc.holds)) {
    $idp = & $text $h 'idPattern'; $np = & $text $h 'namePattern'
    if ($idp) { if (-not (& $regexOk $idp)) { $problems.Add("boundaries.json: holds[$i] has an idPattern that is not a valid regular expression") } }
    elseif ($np -and (& $text $h 'type')) { if (-not (& $regexOk $np)) { $problems.Add("boundaries.json: holds[$i] has a namePattern that is not a valid regular expression") } }
    else { $problems.Add("boundaries.json: holds[$i] has neither an idPattern nor a type with a namePattern") }
    if (-not (& $text $h 'reason')) { $problems.Add("boundaries.json: holds[$i] has no reason") }
    $i++
  }
  $i = 0
  foreach ($e in @($doc.expectedIgnore)) {
    $pt = & $text $e 'pattern'
    if (-not $pt) { $problems.Add("boundaries.json: expectedIgnore[$i] has no pattern") }
    elseif (-not (& $regexOk $pt)) { $problems.Add("boundaries.json: expectedIgnore[$i] has a pattern that is not a valid regular expression") }
    if (-not (& $text $e 'reason')) { $problems.Add("boundaries.json: expectedIgnore[$i] has no reason") }
    $i++
  }
  return $problems
}

# 1. Units and boundaries
Write-Host 'Checking deploy/units.json and boundaries.json'
$units = @()
$u = $null
try {
  $u = Get-Content -Raw -LiteralPath ([IO.Path]::Combine($repo, 'deploy', 'units.json')) | ConvertFrom-Json
  $bd = Get-Content -Raw -LiteralPath ([IO.Path]::Combine($repo, 'deploy', 'boundaries.json')) | ConvertFrom-Json
  $bdProblems = @(Get-BoundaryProblems $bd)
  foreach ($pr in $bdProblems) { $failures.Add($pr); Write-Host "  $pr" -ForegroundColor Red }
  Write-Host "  $(@($bd.boundaries).Count) boundaries, $(@($bd.holds).Count) holds and $(@($bd.expectedIgnore).Count) expected Ignore patterns checked, $($bdProblems.Count) problem(s)"
  $units = @($u.units)
  foreach ($unit in $units) {
    if (-not $unit.template) { $failures.Add("units.json: $($unit.name) has no template"); continue }
    # Every unit deploys from the pipeline. The tier is absent (production) or privileged, a tenant-kind unit has no
    # subscription and names its management group, and no other unit names one. A route field is no longer allowed.
    $tierProp = $unit.PSObject.Properties['tier']
    if ($null -ne $tierProp -and -not ($tierProp.Value -is [string] -and $tierProp.Value -ceq 'privileged')) { $failures.Add("units.json: $($unit.name) has tier '$($tierProp.Value)', which must be absent (production) or exactly privileged") }
    if ($null -ne $unit.PSObject.Properties['route']) { $failures.Add("units.json: $($unit.name) has a route field, which is no longer used") }
    $mgProp = $unit.PSObject.Properties['managementGroup']
    if ($unit.kind -eq 'tenant') {
      if ($unit.subscription) { $failures.Add("units.json: $($unit.name) is a tenant-kind unit and must have subscription null") }
      if ($null -eq $mgProp -or -not ($mgProp.Value -is [string]) -or $mgProp.Value -notmatch '^[A-Za-z0-9._()-]{1,90}$') { $failures.Add("units.json: $($unit.name) is a tenant-kind unit and must name a valid managementGroup") }
    } elseif ($null -ne $mgProp) { $failures.Add("units.json: $($unit.name) is not a tenant-kind unit and must not name a managementGroup") }
    foreach ($rel in @($unit.template, $unit.parameters)) {
      if ($rel -and -not (Test-Path -LiteralPath (Get-RepoPath $rel))) { $failures.Add("units.json: $($unit.name) points at missing $rel") }
    }
  }
  Write-Host "  $($units.Count) units checked ($(@($units | Where-Object { $_.enabled }).Count) enabled)"
} catch { $failures.Add("units/boundaries JSON: $($_.Exception.Message)") }

# 2. Compile every entry point once
$seen = @{}
$entries = New-Object System.Collections.Generic.List[string]
# An estate without tenant-scope code has no infra/tenant/main.bicep, so that entry point is taken only when it exists.
$tenantMain = [IO.Path]::Combine($infra, 'tenant', 'main.bicep')
$candidates = @(Get-ChildItem -LiteralPath $tenantMain -File -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName }) +
              @(Get-SortedByPath (Get-ChildItem ([IO.Path]::Combine($infra, 'subscriptions', '*', 'main.bicep'))) | ForEach-Object { $_.FullName }) +
              @(Get-SortedByPath (Get-ChildItem (Join-Path $mainRgDir '*.bicep')) | ForEach-Object { $_.FullName }) +
              @($units | Where-Object { $_.template -and (Test-Path -LiteralPath (Get-RepoPath $_.template)) } | ForEach-Object { Get-RepoPath $_.template })
foreach ($c in $candidates) {
  if (Test-Retired $c) { continue }
  $k = $c.ToLowerInvariant()
  if (-not $seen.ContainsKey($k)) { $seen[$k] = $true; $entries.Add($c) }
}
$rpc = $null
$bicepExe = Get-PreflightBicep
$bicepVersion = ''
if (-not $bicepExe) {
  $failures.Add('compile: no Bicep CLI found. Install it with az bicep install --version v0.48.1, or put bicep on PATH')
  Write-Host '  no Bicep CLI found, so nothing is compiled' -ForegroundColor Red
  $entries.Clear()
} else {
  try {
    $rpc = New-Object PreflightValidate.BicepRpc $bicepExe
    $bicepVersion = [string]$rpc.Call('bicep/version', '{}')['version']
    Write-Host "Bicep $bicepVersion ($bicepExe), one process for every compile"
  } catch {
    $failures.Add("compile: the Bicep CLI $bicepExe did not start its JSON-RPC server. $(Get-InnerMessage $_)")
    Write-Host "  $(Get-InnerMessage $_)" -ForegroundColor Red
    if ($null -ne $rpc) { $rpc.Dispose(); $rpc = $null }
    $bicepExe = $null
    $entries.Clear()
  }
}
try {
Write-Host "Compiling $($entries.Count) entry points"
foreach ($f in $entries) { Invoke-BicepCompile $f 'compile' }

# 3. Build parameters files
$seenP = @{}
$params = New-Object System.Collections.Generic.List[string]
$pCandidates = @($units | Where-Object { $_.parameters -and (Test-Path -LiteralPath (Get-RepoPath $_.parameters)) } | ForEach-Object { Get-RepoPath $_.parameters }) +
               @(Get-SortedByPath (Get-ChildItem ([IO.Path]::Combine($infra, 'subscriptions', '*', 'parameters.verify.bicepparam'))) | ForEach-Object { $_.FullName })
foreach ($c in $pCandidates) {
  if (Test-Retired $c) { continue }
  $k = $c.ToLowerInvariant()
  if (-not $seenP.ContainsKey($k)) { $seenP[$k] = $true; $params.Add($c) }
}
Write-Host "Building $($params.Count) parameters files"
$paramsSkipped = 0
foreach ($p in $params) {
  $unset = @(Get-UnsetSecureInputs $p)
  if ($unset.Count -gt 0) { $paramsSkipped++; Write-Host "  skipped $p (secure input $($unset -join ', ') not set)" -ForegroundColor Yellow; continue }
  if (-not $bicepExe) { continue }
  Invoke-BicepCompile $p 'build-params'
}
} finally {
  if ($null -ne $rpc) { $rpc.Dispose(); $rpc = $null }
}
$cacheIndex = [ordered]@{ format = 1; bicep = $bicepVersion; entries = $cacheEntries.ToArray() }
[IO.File]::WriteAllText((Join-Path $CompileCache 'index.json'), (ConvertTo-Json -InputObject $cacheIndex -Depth 6), $utf8NoBom)
Write-Host "  $($cacheEntries.Count) compiles kept in the compile cache"
Write-Host 'Diagnostics by rule (counted once per compiled file that includes the source):'
# Rules with the same count are listed by name, because a hashtable has no fixed order in PowerShell 7.
$ruleCounts.GetEnumerator() | Sort-Object @{ Expression = 'Value'; Descending = $true }, @{ Expression = 'Key'; Descending = $false } | ForEach-Object { Write-Host ("  {0,6}  {1}" -f $_.Value, $_.Key) }

# 4. Layout
Write-Host 'Checking the file layout'
$layoutStart = $failures.Count
function Add-LayoutFailure([string]$check, [string]$message) {
  $script:failures.Add("layout ${check}: $message")
}
# The same rule as whatif-rg-sweep.sh, case-insensitive with '_' and '-' ignored.
function Get-NormName([string]$n) { return ($n -replace '[_-]', '').ToLowerInvariant() }

$allInfraFiles = @(Get-SortedFilesRecurse $infra)
$bicepFiles = @($allInfraFiles | Where-Object { $_.Extension -ieq '.bicep' -and -not (Test-Retired $_.FullName) })
$texts = @{}
foreach ($f in $bicepFiles) { $texts[$f.FullName.ToLowerInvariant()] = [IO.File]::ReadAllText($f.FullName) }

# Module and import targets of one file, resolved to full paths. Registry and template spec references
# (br:, ts:, and aliases such as br/public:) are skipped.
function Get-FileRefs([string]$full) {
  $text = $script:texts[$full.ToLowerInvariant()]
  if ($null -eq $text) { $text = [IO.File]::ReadAllText($full) }
  $dir = Split-Path -Parent $full
  $refs = New-Object System.Collections.Generic.List[string]
  $ms = @([regex]::Matches($text, "(?m)^[ \t]*module[ \t]+[A-Za-z_][A-Za-z0-9_]*[ \t]+'([^']+)'")) +
        @([regex]::Matches($text, "(?m)^[ \t]*import[ \t][^\r\n]*?'([^']+\.(bicep|json))'"))
  foreach ($m in $ms) {
    $p = $m.Groups[1].Value
    if ($p -match '^(br|ts)(:|/[^/:]+:)') { continue }
    $refs.Add([IO.Path]::GetFullPath((Join-Path $dir (Get-SysPath $p))))
  }
  return $refs
}

# a. demo group files and their parameters files
$mainRgFiles = @(Get-SortedByPath (Get-ChildItem (Join-Path $mainRgDir '*.bicep')))
# A group file that another demo file calls as a module is deployed with that file's unit, not on its own.
$mainModuleTargets = @{}
foreach ($h in @(Get-SortedByPath (Get-ChildItem (Join-Path (Split-Path -Parent $mainRgDir) '*.bicep')))) {
  foreach ($mm in [regex]::Matches([IO.File]::ReadAllText($h.FullName), "(?m)^module\s+\w+\s+'\./resource-groups/([^']+)'")) { $mainModuleTargets[$mm.Groups[1].Value.ToLowerInvariant()] = $true }
}
foreach ($f in $mainRgFiles) {
  if ($f.Name -like '*.hash-excluded.bicep' -or $mainModuleTargets.ContainsKey($f.Name.ToLowerInvariant())) { continue }
  $x = [IO.Path]::GetFileNameWithoutExtension($f.Name)
  $pf = Join-Path $mainRgDir "$x.bicepparam"
  if (-not (Test-Path -LiteralPath $pf)) { Add-LayoutFailure 'a' "$(Get-RelPath $f.FullName) has no $x.bicepparam, so the resource group sweep never previews it"; continue }
  if ((Get-UsingPath $pf) -ne "./$x.bicep") { Add-LayoutFailure 'a' "$(Get-RelPath $pf) has no using './$x.bicep' line" }
}
foreach ($pf in @(Get-SortedByPath (Get-ChildItem (Join-Path $mainRgDir '*.bicepparam')))) {
  $usingRel = Get-UsingPath $pf.FullName
  if ($null -eq $usingRel) { Add-LayoutFailure 'a' "$(Get-RelPath $pf.FullName) has no using line"; continue }
  $t = [IO.Path]::GetFullPath((Join-Path $mainRgDir (Get-SysPath $usingRel)))
  if (-not (Test-Path -LiteralPath $t)) { Add-LayoutFailure 'a' "$(Get-RelPath $pf.FullName) names $usingRel, which does not exist" }
}
foreach ($unit in @($units | Where-Object { $_.kind -eq 'resourceGroup' -and $_.template })) {
  $t = Get-RepoPath $unit.template
  if (-not $t.StartsWith($mainRgDir + $sep, $pathCmp)) { continue }
  $slug = [IO.Path]::GetFileNameWithoutExtension($t) -replace '\.(deploy|hash)-excluded$', ''
  if ((Get-NormName $slug) -ne (Get-NormName ([string]$unit.resourceGroup))) {
    Add-LayoutFailure 'a' "unit $($unit.name) deploys $($unit.template) into $($unit.resourceGroup), but the file name and the group name differ"
  }
}
# The preview and the deployment of a unit with a .bicepparam file pass only that file to the Azure CLI, which
# compiles the template its using line names. So that line must name the unit's own template, or the unit would
# preview and deploy another file than the one units.json lists and this script compiles. Both paths are compared
# in full, without case on Windows and with case on Linux. A missing file is already reported in step 1.
foreach ($unit in @($units | Where-Object { $_.template -and $_.parameters -and ([string]$_.parameters) -like '*.bicepparam' })) {
  $pf = Get-RepoPath $unit.parameters
  if (-not (Test-Path -LiteralPath $pf -PathType Leaf)) { continue }
  $t = Get-RepoPath $unit.template
  $usingPath = Get-UsingPath $pf
  if ($null -eq $usingPath) { Add-LayoutFailure 'a' "unit $($unit.name) has the parameters file $($unit.parameters), which has no using line that names a file, so it does not name the unit's template $($unit.template)"; continue }
  $target = $null
  if ($usingPath -notmatch '^(br|ts)(:|/[^/:]+:)') {
    try { $target = [IO.Path]::GetFullPath((Join-Path (Split-Path -Parent $pf) (Get-SysPath $usingPath))) } catch { $target = $null }
  }
  if ($null -eq $target -or -not [string]::Equals($target, $t, $pathCmp)) {
    $shown = if ($null -eq $target) { "'$usingPath'" } else { "'$usingPath' ($(Get-RelPath $target))" }
    Add-LayoutFailure 'a' "unit $($unit.name) has the parameters file $($unit.parameters), whose using line names $shown, but the unit's template is $($unit.template)"
  }
}

# b. Module and import paths
foreach ($f in $bicepFiles) {
  foreach ($r in (Get-FileRefs $f.FullName)) {
    $rel = Get-RelPath $r
    if ($rel -imatch '^infra/typed/') { Add-LayoutFailure 'b' "$(Get-RelPath $f.FullName) uses $rel, under infra/typed" }
    elseif (-not (Test-Path -LiteralPath $r)) { Add-LayoutFailure 'b' "$(Get-RelPath $f.FullName) uses $rel, which does not exist" }
    elseif (Test-Retired $r) { Add-LayoutFailure 'b' "$(Get-RelPath $f.FullName) uses $rel, a file of another layout" }
  }
}

# c. '#' in a resource name
foreach ($f in $bicepFiles) {
  if ($f.Name -like '*.hash-excluded.bicep') { continue }
  $lines = $texts[$f.FullName.ToLowerInvariant()] -split "`r?`n"
  for ($i = 0; $i -lt $lines.Count; $i++) {
    if ($lines[$i] -match '^\s*//') { continue }
    if ($lines[$i] -match "\bname\s*:\s*'[^']*#") { Add-LayoutFailure 'c' "$(Get-RelPath $f.FullName):$($i + 1) has a name with '#'. It belongs in a *.hash-excluded.bicep file" }
  }
}

# d. deploy-excluded markers and units
# True when the list holds the name, compared character by character, case included, as deploy-unit.ps1 compares
# unit names. PowerShell's -ccontains compares by the rules of a language, which ignore some characters that do not
# show on screen, such as a zero-width space on PowerShell 7 and a soft hyphen on Windows PowerShell 5.1.
function Test-NameInList($list, [string]$name) {
  foreach ($x in @($list)) { if ($null -ne $x -and [string]::Equals([string]$x, $name, [StringComparison]::Ordinal)) { return $true } }
  return $false
}
foreach ($f in $bicepFiles) {
  if ($f.Name -like '*.deploy-excluded.bicep') { continue }
  $n = [regex]::Matches($texts[$f.FullName.ToLowerInvariant()], '//\s*deploy-excluded:').Count
  if ($n -gt 0) { Add-LayoutFailure 'd' "$(Get-RelPath $f.FullName) has $n '// deploy-excluded:' marker(s). Those resources belong in the group's *.deploy-excluded.bicep file" }
}
foreach ($f in @($mainRgFiles | Where-Object { $_.Name -like '*.deploy-excluded.bicep' })) {
  # A deploy-excluded file that main.bicep calls as a module behind a switch is previewed with parameters.verify.bicepparam and is no unit's template.
  if ($mainModuleTargets.ContainsKey($f.Name.ToLowerInvariant())) { continue }
  $own = @($units | Where-Object { $_.template -and (Get-RepoPath $_.template) -ieq $f.FullName })
  if ($own.Count -eq 0) { Add-LayoutFailure 'd' "$(Get-RelPath $f.FullName) is the template of no unit in deploy/units.json"; continue }
  $routine = Join-Path $mainRgDir (($f.Name -replace '\.deploy-excluded\.bicep$', '') + '.bicep')
  $main = @($units | Where-Object { $_.template -and (Get-RepoPath $_.template) -ieq $routine })
  if ($main.Count -eq 0) { Add-LayoutFailure 'd' "$(Get-RelPath $f.FullName) has no routine unit for $(Get-RelPath $routine)"; continue }
  foreach ($o in $own) {
    $mw = @()
    if ($main[0].PSObject.Properties['measuredWith']) { $mw = @($main[0].measuredWith) }
    if (-not (Test-NameInList $mw ([string]$o.name))) { Add-LayoutFailure 'd' "unit $($o.name) is not in the measuredWith list of unit $($main[0].name), so the drift check never measures it" }
  }
}
# deploy-unit.ps1 matches unit names character by character, case included, so a measuredWith or groupsDeclaredBy
# entry that names no unit with exactly that name would stop the drift check of its unit.
$unitNames = @($units | ForEach-Object { [string]$_.name })
foreach ($unit in $units) {
  foreach ($field in 'measuredWith', 'groupsDeclaredBy') {
    if (-not $unit.PSObject.Properties[$field]) { continue }
    foreach ($ref in @($unit.$field)) {
      if ($ref -and -not (Test-NameInList $unitNames ([string]$ref))) { Add-LayoutFailure 'd' "unit $($unit.name) names '$ref' in $field, and no unit in deploy/units.json has exactly that name (unit names are matched with their exact case)" }
    }
  }
}

# e. Comment lines of another layout
foreach ($f in @($bicepFiles | Where-Object { (Get-RelPath $_.FullName) -like 'infra/subscriptions/*' })) {
  $n = [regex]::Matches($texts[$f.FullName.ToLowerInvariant()], '(?m)^\s*//\s*(Source|rg-member):').Count
  if ($n -gt 0) { Add-LayoutFailure 'e' "$(Get-RelPath $f.FullName) has $n '// Source:' or '// rg-member:' line(s). Remove them" }
}

# f. Every file under infra/subscriptions is reached from a unit template or a main.bicep
$roots = @(Get-SortedByPath (Get-ChildItem ([IO.Path]::Combine($infra, 'subscriptions', '*', 'main.bicep'))) | ForEach-Object { $_.FullName }) +
         @(([IO.Path]::Combine($infra, 'tenant', 'main.bicep'))) +
         @($units | Where-Object { $_.template } | ForEach-Object { Get-RepoPath $_.template })
$reached = @{}
$queue = New-Object System.Collections.Generic.Queue[string]
foreach ($r in $roots) { if ((Test-Path -LiteralPath $r) -and -not $reached.ContainsKey($r.ToLowerInvariant())) { $reached[$r.ToLowerInvariant()] = $true; $queue.Enqueue($r) } }
while ($queue.Count -gt 0) {
  $cur = $queue.Dequeue()
  if (Test-Retired $cur) { continue }
  foreach ($r in (Get-FileRefs $cur)) {
    $k = $r.ToLowerInvariant()
    if ($reached.ContainsKey($k) -or -not (Test-Path -LiteralPath $r) -or (Test-Retired $r)) { continue }
    $reached[$k] = $true; $queue.Enqueue($r)
  }
}
$subFiles = @($bicepFiles | Where-Object { (Get-RelPath $_.FullName) -like 'infra/subscriptions/*' })
foreach ($f in $subFiles) {
  if (-not $reached.ContainsKey($f.FullName.ToLowerInvariant())) { Add-LayoutFailure 'f' "$(Get-RelPath $f.FullName) is not reached from any unit template or main.bicep" }
}
$rgFileCount = @($subFiles | Where-Object { $_.Directory.Name -eq 'resource-groups' }).Count

# g. Files of another layout
$retiredFiles = @($allInfraFiles | Where-Object { Test-Retired $_.FullName })
$scriptsDir = Join-Path $repo 'scripts'
if (Test-Path -LiteralPath $scriptsDir) { $retiredFiles += @(Get-SortedByPath (Get-ChildItem -LiteralPath $scriptsDir -File) | Where-Object { Test-Retired $_.FullName }) }
$typedCount = @($retiredFiles | Where-Object { (Get-RelPath $_.FullName) -like 'infra/typed/*' }).Count
if ($typedCount -gt 0) { Add-LayoutFailure 'g' "infra/typed ($typedCount files) is not part of the layout and nothing uses it. Remove the folder" }
foreach ($f in @($retiredFiles | Where-Object { (Get-RelPath $_.FullName) -notlike 'infra/typed/*' } | Sort-Object FullName)) {
  Add-LayoutFailure 'g' "$(Get-RelPath $f.FullName) is not part of the layout. Remove it (git rm)"
}

# h. Line endings. One line ending per line in every Bicep and parameters file
$eolFiles = @($allInfraFiles | Where-Object { $_.Extension -ieq '.bicep' -or $_.Extension -ieq '.bicepparam' })
$pipelinesDir = Join-Path $repo 'pipelines'
if (Test-Path -LiteralPath $pipelinesDir) {
  $eolFiles += @(Get-SortedFilesRecurse $pipelinesDir | Where-Object { $_.Extension -ieq '.bicep' -or $_.Extension -ieq '.bicepparam' })
}
foreach ($f in $eolFiles) {
  $text = [IO.File]::ReadAllText($f.FullName)
  $at = $text.IndexOf("`r`r")
  if ($at -ge 0) {
    $line = ([regex]::Matches($text.Substring(0, $at), "`n")).Count + 1
    Add-LayoutFailure 'h' "$(Get-RelPath $f.FullName):$line ends in two carriage returns. Save the file with one line ending per line"
  }
}
# i. Paths that match a file only when case is ignored
$caseDirs = @{}
# The path as it is on disk when $full names an existing file or folder of the repository with other case, else
# $null (also when nothing matches, which the checks above report).
function Get-CaseOnDisk([string]$full) {
  $f = [IO.Path]::GetFullPath($full)
  if (-not $f.StartsWith($repo + $sep, [StringComparison]::OrdinalIgnoreCase)) { return $null }
  $dir = $repo
  $parts = New-Object System.Collections.Generic.List[string]
  $differs = $false
  foreach ($p in $f.Substring($repo.Length + 1).Split([char[]]@('\', '/'), [StringSplitOptions]::RemoveEmptyEntries)) {
    if (-not $script:caseDirs.ContainsKey($dir)) {
      $names = @()
      try { $names = @([IO.Directory]::GetFileSystemEntries($dir) | ForEach-Object { [IO.Path]::GetFileName($_) }) } catch { }
      $script:caseDirs[$dir] = $names
    }
    $names = $script:caseDirs[$dir]
    $hit = @($names | Where-Object { [string]::Equals($_, $p, [StringComparison]::Ordinal) })
    if ($hit.Count -eq 0) {
      $hit = @($names | Where-Object { [string]::Equals($_, $p, [StringComparison]::OrdinalIgnoreCase) })
      if ($hit.Count -eq 0) { return $null }
      $differs = $true
    }
    $parts.Add($hit[0])
    $dir = Join-Path $dir $hit[0]
  }
  if ($differs) { return ($parts -join '/') }
  return $null
}
function Test-PathCase([string]$from, [string]$written, [string]$full) {
  $onDisk = Get-CaseOnDisk $full
  if ($null -ne $onDisk) { Add-LayoutFailure 'i' "$from names $written, but the file on disk is $onDisk. Linux file names are case-sensitive, so this compiles on Windows and fails on Linux" }
}
foreach ($unit in $units) {
  foreach ($rel in @($unit.template, $unit.parameters)) {
    if ($rel) { Test-PathCase "deploy/units.json ($($unit.name))" $rel (Get-RepoPath $rel) }
  }
}
foreach ($f in $bicepFiles) {
  $dir = Split-Path -Parent $f.FullName
  $code = Get-BicepCodeText $f.FullName
  $named = @([regex]::Matches($code, "(?m)^[ \t]*module[ \t]+[A-Za-z_][A-Za-z0-9_]*[ \t]+'([^']+)'")) +
           @([regex]::Matches($code, "(?m)^[ \t]*import[ \t][^\r\n]*?'([^']+\.(bicep|json))'")) +
           @([regex]::Matches($code, "\bload(?:JsonContent|TextContent|YamlContent|FileAsBase64)\(\s*'([^'$]+)'"))
  foreach ($m in $named) {
    $p = $m.Groups[1].Value
    if ($p -match '^(br|ts)(:|/[^/:]+:)') { continue }
    Test-PathCase (Get-RelPath $f.FullName) $p ([IO.Path]::GetFullPath((Join-Path $dir (Get-SysPath $p))))
  }
}
foreach ($pf in @($allInfraFiles | Where-Object { $_.Extension -ieq '.bicepparam' -and -not (Test-Retired $_.FullName) })) {
  $usingRel = Get-UsingPath $pf.FullName
  if ($null -eq $usingRel -or $usingRel -match '^(br|ts)(:|/[^/:]+:)') { continue }
  Test-PathCase (Get-RelPath $pf.FullName) $usingRel ([IO.Path]::GetFullPath((Join-Path $pf.DirectoryName (Get-SysPath $usingRel))))
}

$layoutFailures = $failures.Count - $layoutStart
Write-Host "  $($bicepFiles.Count) Bicep files read, $($subFiles.Count) under infra/subscriptions ($rgFileCount group files), $($reached.Count) reached, $layoutFailures layout failure(s)"

# 5. Duplicate declarations, per unit and across units
$dupRuns = 0; $dupSkipped = 0; $crossKeys = 0; $crossCount = 0; $crossUnresolved = 0
if (-not $SkipDuplicates) {
  $csvDir = $OutDir
  $csvTemp = $null
  if (-not $csvDir) { $csvTemp = Join-Path ([IO.Path]::GetTempPath()) ('preflight-dups-' + [guid]::NewGuid().ToString('N')); $csvDir = $csvTemp }
  New-Item -ItemType Directory -Force -Path $csvDir | Out-Null
  $checker = Join-Path $PSScriptRoot 'find-duplicate-declarations.ps1'
  # The checker runs in this PowerShell, as a script with its own scope, so its embedded evaluator is compiled
  # once and not once per unit. It reads the compile of steps 2 and 3 through -CompiledJson. A unit whose file has
  # no cache entry (its compile failed) is compiled by the checker itself.
  $dupFromCache = 0

  # Runs the checker once and returns the declarations CSV path, or $null when the run did not finish.
  function Invoke-DuplicateCheck([string]$label, [string]$template, [string]$paramFile) {
    $safe = $label -replace '[^A-Za-z0-9_.-]', '_'
    $csv = Join-Path $csvDir "duplicates__$safe.csv"
    if (Test-Path -LiteralPath $csv) { Remove-Item -LiteralPath $csv -Force }
    $chkArgs = @{ Template = $template; DeclarationsCsv = $csv }
    if ($paramFile) { $chkArgs['Parameters'] = $paramFile } else { $chkArgs['NoParameters'] = $true }
    $compiledFor = if ($paramFile) { $paramFile } else { $template }
    $compiled = $script:cacheFiles[$compiledFor.ToLowerInvariant()]
    if ($compiled) { $chkArgs['CompiledJson'] = $compiled; $script:dupFromCache++ }
    Write-Host "Duplicate declarations: $label"
    $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    $global:LASTEXITCODE = 0
    try {
      $out = @(& $checker @chkArgs *>&1 | ForEach-Object { "$_" })
      $code = $LASTEXITCODE
    } catch {
      $out = @("$(Get-InnerMessage $_)")
      $code = 2
    }
    $ErrorActionPreference = $prev
    $script:dupRuns++
    if ($OutDir) { Set-Content -LiteralPath (Join-Path $OutDir "duplicates__$safe.log") -Value $out -Encoding $utf8Bom }
    $res = @($out | Where-Object { $_ -like 'RESULT:*' } | Select-Object -Last 1)
    if ($res.Count -gt 0) { Write-Host "  $($res[0])" }
    # Exit 1 with a RESULT line means duplicates were found. Any other exit code but 0 means the check
    # could not run (compile or tool error).
    if ($code -ne 0 -and -not ($code -eq 1 -and $res.Count -gt 0)) {
      $script:failures.Add("duplicate check error: $label")
      @($out | Select-Object -Last 10) | ForEach-Object { Write-Host "  $_" -ForegroundColor Red }
      return $null
    }
    if ($code -ne 0) {
      $script:failures.Add("duplicates: $label")
      @($out | Where-Object { $_ -match 'ACTIVE|duplicate' } | Select-Object -First 20) | ForEach-Object { Write-Host "  $_" -ForegroundColor Red }
    }
    if (Test-Path -LiteralPath $csv) { return $csv }
    return $null
  }

  $rows = New-Object System.Collections.Generic.List[object]
  foreach ($unit in @($units | Where-Object { $_.kind -in 'subscription', 'resourceGroup' -and $_.template })) {
    $t = Get-RepoPath $unit.template
    $p = $null; if ($unit.parameters) { $p = Get-RepoPath $unit.parameters }
    if (-not (Test-Path -LiteralPath $t) -or ($p -and -not (Test-Path -LiteralPath $p))) { continue }
    if ($p) {
      $unset = @(Get-UnsetSecureInputs $p)
      if ($unset.Count -gt 0) { $dupSkipped++; Write-Host "Duplicate declarations: $($unit.name) skipped (secure input $($unset -join ', ') not set)" -ForegroundColor Yellow; continue }
    }
    $csv = Invoke-DuplicateCheck $unit.name $t $p
    if (-not $csv) { continue }
    $subId = ([string]$u.subscriptions.($unit.subscription)).ToLowerInvariant()
    $unitRg = ''; if ($unit.PSObject.Properties['resourceGroup']) { $unitRg = ([string]$unit.resourceGroup).ToLowerInvariant() }
    foreach ($r in @(Import-Csv -LiteralPath $csv)) {
      if ($r.status -eq 'gated-off') { continue }
      if ($r.resolved -ne 'True') { $crossUnresolved++; continue }
      $scope = ([string]$r.scope).ToLowerInvariant()
      if ($scope -eq 'subscription') { $scope = "sub:$subId" }
      elseif ($scope -eq 'rg:<current>') { $scope = "rg:$subId/$unitRg" }
      elseif ($scope -match '^rg:([^/]+)$') { $scope = "rg:$subId/$($Matches[1])" }
      if ($scope -like '*<*') { $crossUnresolved++; continue }
      $key = ('{0}|{1}|{2}|{3}' -f $scope, $r.extScope, $r.type, $r.name).ToLowerInvariant()
      $file = [string]$r.declaredIn
      if ($r.viaFile -and $r.viaFile -ne $r.declaredIn) { $file = "$($r.viaFile) > $file" }
      $rows.Add([pscustomobject]@{ Key = $key; Unit = $unit.name; File = $file; Type = $r.type; Name = $r.name; Scope = $scope })
    }
  }
  # The subscriptions that keep a parameters.verify.bicepparam are checked with it too (switches on), not merged.
  foreach ($v in @(Get-SortedByPath (Get-ChildItem ([IO.Path]::Combine($infra, 'subscriptions', '*', 'parameters.verify.bicepparam'))) | Where-Object { -not (Test-Retired $_.FullName) })) {
    $usingRel = Get-UsingPath $v.FullName
    if ($null -eq $usingRel) { $failures.Add("duplicate check error: $(Get-RelPath $v.FullName) has no using line"); continue }
    $t = [IO.Path]::GetFullPath((Join-Path $v.DirectoryName (Get-SysPath $usingRel)))
    $label = (Split-Path -Leaf $v.DirectoryName) + '/parameters.verify.bicepparam'
    $unset = @(Get-UnsetSecureInputs $v.FullName)
    if ($unset.Count -gt 0) { $dupSkipped++; Write-Host "Duplicate declarations: $label skipped (secure input $($unset -join ', ') not set)" -ForegroundColor Yellow; continue }
    $null = Invoke-DuplicateCheck $label $t $v.FullName
  }

  # The check across units for one resource declared by two units.
  Write-Host "Duplicate declarations across units ($($rows.Count) declarations with a resolved name, while $crossUnresolved with a name or scope the checker cannot resolve take no part)"
  # Group-Object returns groups in first-seen order on Windows PowerShell 5.1 and sorted by name (culture order)
  # on PowerShell 7, so both groupings are put in ordinal name order before printing.
  $keyGroups = @($rows | Group-Object Key)
  if ($keyGroups.Count -gt 1) { $gk = [string[]]@($keyGroups | ForEach-Object { $_.Name }); [Array]::Sort($gk, $keyGroups, [Collections.IComparer][StringComparer]::Ordinal) }
  foreach ($g in $keyGroups) {
    $byUnit = @($g.Group | Group-Object Unit)
    if ($byUnit.Count -gt 1) { $uk = [string[]]@($byUnit | ForEach-Object { $_.Name }); [Array]::Sort($uk, $byUnit, [Collections.IComparer][StringComparer]::Ordinal) }
    if ($byUnit.Count -lt 2) { continue }
    $crossKeys++
    $first = $g.Group[0]
    $failures.Add("duplicates across units: $($first.Type) '$($first.Name)' in $($first.Scope)")
    Write-Host "  $($first.Type) '$($first.Name)' in $($first.Scope) is declared by:" -ForegroundColor Red
    foreach ($bu in $byUnit) { Write-Host "    unit $($bu.Name): $((@($bu.Group | ForEach-Object { $_.File } | Select-Object -Unique)) -join ', ')" -ForegroundColor Red }
  }
  $crossCount = $rows.Count
  Write-Host "  $crossKeys resource(s) declared by more than one unit"
  if ($csvTemp) { Remove-Item -LiteralPath $csvTemp -Recurse -Force -ErrorAction SilentlyContinue }
}

Write-Host ''
Write-Host 'Summary:'
Write-Host "  $($units.Count) units, $($entries.Count) entry points compiled, $($params.Count) parameters files built ($paramsSkipped skipped for a secure input), in one Bicep process"
Write-Host "  layout: $layoutFailures failure(s)"
if ($SkipDuplicates) { Write-Host '  duplicates: skipped' }
else { Write-Host "  duplicates: $dupRuns checker runs ($dupSkipped skipped for a secure input, $dupFromCache read the compile of steps 2 and 3), $crossCount declarations merged ($crossUnresolved unresolved left out), $crossKeys declared by more than one unit" }
if ($cacheTemp) { Remove-Item -LiteralPath $cacheTemp -Recurse -Force -ErrorAction SilentlyContinue }

if ($failures.Count -gt 0) {
  Write-Host 'FAILED:' -ForegroundColor Red
  $failures | ForEach-Object { Write-Host "  $_" -ForegroundColor Red }
  exit 1
}
Write-Host 'All preflight checks passed.'
exit 0
