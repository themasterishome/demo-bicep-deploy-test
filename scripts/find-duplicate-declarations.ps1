<#
.SYNOPSIS
  Find Azure resources that are declared more than once across a Bicep entry point's module graph.

.DESCRIPTION
  Read-only, no Azure calls. Compiles the template (and its .bicepparam) with the local Bicep CLI
  (`az bicep build-params --stdout`, or `az bicep build --stdout` when there is no parameter file),
  then walks the ARM JSON recursively through every nested Microsoft.Resources/deployments template.

  For every non-existing resource it computes the key
      (deployment scope, extension scope, resource type, resource name)
  where the scope comes from the nested deployment's resourceGroup / subscriptionId / scope
  property or from the enclosing scope. Names and scopes are resolved by a small ARM-expression
  evaluator (parameters, variables, copy loops, format/concat/contains/if/...). environment() returns
  the values of Azure's public cloud (AzureCloud), where the estate runs. Anything that cannot
  be resolved statically (reference(), uniqueString(), lambdas, ...) is reported as "unresolved" and
  never guessed.

  Conditions (`if (...)` in Bicep, `condition` in ARM) are evaluated against the parameter file:
    active                 condition true (or no condition)        -> counts as a declaration
    gated-off              condition false with these parameters   -> does not count (reported as latent)
    condition-unresolved   condition cannot be evaluated            -> COUNTS (treated as included)

  A key declared by two or more counting declarations is an ACTIVE duplicate (ARM would fail with
  ResourceDeployedMultipleTimes). A key declared two or more times in total, but with fewer than two
  counting declarations, is a LATENT duplicate (it collides as soon as a gate is turned on).

  For each duplicate the deployment path (nested deployment names) and the Bicep file chain
  (entry point > module file > ... > declaring file) are printed, plus whether the resolved resource
  bodies are identical. When they differ, the differing JSON paths are listed.

.PARAMETER Template
  Path to the entry-point .bicep file (for example a subscription main.bicep).

.PARAMETER Parameters
  Path to the .bicepparam file. The default is parameters.bicepparam next to the template, if it exists.

.PARAMETER NoParameters
  Ignore any parameter file. Parameter defaults are used, parameters without defaults are unresolved.

.PARAMETER OutJson
  Optional path for a machine-readable report.

.PARAMETER DeclarationsCsv
  Optional path for a CSV of every declaration walked, one row each: scope, extension scope, type, name,
  whether the name and scope resolved, status, where a false condition was found, deployment path, first
  module file, declaring file and the comparison key.

.EXAMPLE
  ./scripts/find-duplicate-declarations.ps1 -Template "infra/subscriptions/demo/main.bicep"

.NOTES
  Exit codes: 0 = no active duplicates (latent ones are reported but do not fail the run),
  1 = active duplicates, 2 = tool error.
  Each duplicate lists at most 25 differing JSON paths.
  Runs unchanged under Windows PowerShell 5.1 and PowerShell 7 (Windows and Linux). The evaluator is
  embedded C# (C# 5) compiled with Add-Type, with its own JSON reader, so it needs no library that
  only one of the two .NET runtimes has.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Template,
    [string]$Parameters,
    [switch]$NoParameters,
    [string]$OutJson,
    [string]$DeclarationsCsv
)

$diffLineLimit = 25   # differing JSON paths printed per duplicate

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
# Windows PowerShell 5.1 writes UTF8 with a byte order mark. PowerShell 7 writes the same bytes only with utf8BOM.
$utf8Bom = if ($PSVersionTable.PSVersion.Major -ge 6) { 'utf8BOM' } else { 'UTF8' }
# A path given with '\' (for example "$env:RUNNER_TEMP\x") is used with '/' on Linux.
if ([IO.Path]::DirectorySeparatorChar -ne '\') {
    if ($Template) { $Template = $Template.Replace('\', '/') }
    if ($Parameters) { $Parameters = $Parameters.Replace('\', '/') }
    if ($OutJson) { $OutJson = $OutJson.Replace('\', '/') }
    if ($DeclarationsCsv) { $DeclarationsCsv = $DeclarationsCsv.Replace('\', '/') }
}

# ---------------------------------------------------------------------------------------------
# Embedded evaluator and walker (C# 5, no external dependencies, compiles on .NET Framework and .NET)
# ---------------------------------------------------------------------------------------------
$cs = @'
using System;
using System.Collections;
using System.Collections.Generic;
using System.Globalization;
using System.Text;

namespace FindDuplicateDeclarations
{
    public sealed class U
    {
        public static readonly U V = new U();
        private U() { }
        public override string ToString() { return "<unresolved>"; }
    }

    public static class J
    {
        public static Dictionary<string, object> NewDict()
        {
            return new Dictionary<string, object>(StringComparer.OrdinalIgnoreCase);
        }

        public static object Get(object o, string key)
        {
            IDictionary d = o as IDictionary;
            if (d == null || key == null) return null;
            if (d.Contains(key)) return d[key];
            foreach (DictionaryEntry e in d)
            {
                if (string.Equals(e.Key as string, key, StringComparison.OrdinalIgnoreCase)) return e.Value;
            }
            return null;
        }

        public static bool Has(object o, string key)
        {
            IDictionary d = o as IDictionary;
            if (d == null || key == null) return false;
            if (d.Contains(key)) return true;
            foreach (DictionaryEntry e in d)
            {
                if (string.Equals(e.Key as string, key, StringComparison.OrdinalIgnoreCase)) return true;
            }
            return false;
        }

        // Reads JSON into the shapes and number types of JavaScriptSerializer.DeserializeObject of .NET Framework.
        // An object is a Dictionary<string, object> in file order (a repeated key keeps its last value), an array
        // is an object[], and a number is an int, then a long, then a decimal, then a double. JavaScriptSerializer
        // exists only on .NET Framework, so this reader gives the same result under Windows PowerShell 5.1 and
        // PowerShell 7. Its one extra rule, "\/Date(n)\/" text read as a date, never occurs in compiled Bicep and
        // is not copied.
        public static object Parse(string json)
        {
            JsonReader r = new JsonReader(json);
            r.Ws();
            object v = r.Value();
            r.Ws();
            if (!r.AtEnd) throw new FormatException("Unexpected text after the JSON value at position " + r.Pos);
            return v;
        }

        public static bool IsNum(object o)
        {
            return o is int || o is long || o is decimal || o is double || o is float || o is short || o is byte;
        }

        public static string Canon(object o)
        {
            StringBuilder sb = new StringBuilder();
            WriteCanon(o, sb);
            return sb.ToString();
        }

        public static string NumStr(object o)
        {
            try { return Convert.ToDecimal(o, CultureInfo.InvariantCulture).ToString("G29", CultureInfo.InvariantCulture); }
            catch { return Convert.ToString(o, CultureInfo.InvariantCulture); }
        }

        static void WriteCanon(object o, StringBuilder sb)
        {
            if (o == null) { sb.Append("null"); return; }
            if (o is U) { sb.Append("\"<unresolved>\""); return; }
            string s = o as string;
            if (s != null) { WriteStr(s, sb); return; }
            if (o is bool) { sb.Append((bool)o ? "true" : "false"); return; }
            if (IsNum(o)) { sb.Append(NumStr(o)); return; }
            IDictionary d = o as IDictionary;
            if (d != null)
            {
                List<string> keys = new List<string>();
                foreach (object k in d.Keys) keys.Add((string)k);
                keys.Sort(StringComparer.OrdinalIgnoreCase);
                sb.Append('{');
                bool first = true;
                foreach (string k in keys)
                {
                    if (!first) sb.Append(',');
                    first = false;
                    WriteStr(k, sb);
                    sb.Append(':');
                    WriteCanon(d[k], sb);
                }
                sb.Append('}');
                return;
            }
            IList l = o as IList;
            if (l != null)
            {
                sb.Append('[');
                for (int i = 0; i < l.Count; i++)
                {
                    if (i > 0) sb.Append(',');
                    WriteCanon(l[i], sb);
                }
                sb.Append(']');
                return;
            }
            WriteStr(o.ToString(), sb);
        }

        static void WriteStr(string s, StringBuilder sb)
        {
            sb.Append('"');
            foreach (char c in s)
            {
                switch (c)
                {
                    case '"': sb.Append("\\\""); break;
                    case '\\': sb.Append("\\\\"); break;
                    case '\n': sb.Append("\\n"); break;
                    case '\r': sb.Append("\\r"); break;
                    case '\t': sb.Append("\\t"); break;
                    default:
                        if (c < 0x20) sb.Append("\\u" + ((int)c).ToString("x4")); else sb.Append(c);
                        break;
                }
            }
            sb.Append('"');
        }

        public static bool DeepEq(object a, object b)
        {
            if (a is U || b is U) return false;
            return Canon(a) == Canon(b);
        }

        public static void Diff(object a, object b, string path, List<string> outList)
        {
            if (a is U || b is U)
            {
                if (!(a is U && b is U)) outList.Add(path + "  A=" + Trunc(Canon(a)) + "  B=" + Trunc(Canon(b)));
                else outList.Add(path + "  (unresolved on both sides)");
                return;
            }
            IDictionary da = a as IDictionary;
            IDictionary db = b as IDictionary;
            if (da != null && db != null)
            {
                SortedDictionary<string, string> keys = new SortedDictionary<string, string>(StringComparer.OrdinalIgnoreCase);
                foreach (object k in da.Keys) keys[(string)k] = (string)k;
                foreach (object k in db.Keys) if (!keys.ContainsKey((string)k)) keys[(string)k] = (string)k;
                foreach (string k in keys.Keys)
                {
                    bool ha = Has(da, k), hb = Has(db, k);
                    string p = path + "." + k;
                    if (ha && !hb) outList.Add(p + "  only in A: " + Trunc(Canon(Get(da, k))));
                    else if (!ha && hb) outList.Add(p + "  only in B: " + Trunc(Canon(Get(db, k))));
                    else if (Canon(Get(da, k)) != Canon(Get(db, k))) Diff(Get(da, k), Get(db, k), p, outList);
                }
                return;
            }
            IList la = a as IList;
            IList lb = b as IList;
            if (la != null && lb != null)
            {
                if (la.Count != lb.Count)
                {
                    outList.Add(path + "  array length A=" + la.Count + " B=" + lb.Count);
                }
                int n = Math.Min(la.Count, lb.Count);
                for (int i = 0; i < n; i++)
                {
                    if (Canon(la[i]) != Canon(lb[i])) Diff(la[i], lb[i], path + "[" + i + "]", outList);
                }
                return;
            }
            if (Canon(a) != Canon(b)) outList.Add(path + "  A=" + Trunc(Canon(a)) + "  B=" + Trunc(Canon(b)));
        }

        static string Trunc(string s)
        {
            if (s.Length <= 160) return s;
            return s.Substring(0, 157) + "...";
        }
    }

    public sealed class JsonReader
    {
        readonly string s;
        int i;

        public JsonReader(string text) { s = text; i = 0; }
        public int Pos { get { return i; } }
        public bool AtEnd { get { return i >= s.Length; } }

        public void Ws() { while (i < s.Length && char.IsWhiteSpace(s[i])) i++; }

        FormatException Err(string what) { return new FormatException("Invalid JSON at position " + i + ": " + what); }

        public object Value()
        {
            Ws();
            if (i >= s.Length) throw Err("unexpected end");
            char c = s[i];
            if (c == '{') return Obj();
            if (c == '[') return Arr();
            if (c == '"') return Str();
            return Primitive();
        }

        Dictionary<string, object> Obj()
        {
            Dictionary<string, object> d = new Dictionary<string, object>();
            i++;
            Ws();
            if (i < s.Length && s[i] == '}') { i++; return d; }
            while (true)
            {
                Ws();
                if (i >= s.Length || s[i] != '"') throw Err("property name expected");
                string k = Str();
                Ws();
                if (i >= s.Length || s[i] != ':') throw Err("':' expected");
                i++;
                d[k] = Value();
                Ws();
                if (i < s.Length && s[i] == ',') { i++; continue; }
                if (i < s.Length && s[i] == '}') { i++; return d; }
                throw Err("',' or '}' expected");
            }
        }

        object[] Arr()
        {
            List<object> l = new List<object>();
            i++;
            Ws();
            if (i < s.Length && s[i] == ']') { i++; return l.ToArray(); }
            while (true)
            {
                l.Add(Value());
                Ws();
                if (i < s.Length && s[i] == ',') { i++; continue; }
                if (i < s.Length && s[i] == ']') { i++; return l.ToArray(); }
                throw Err("',' or ']' expected");
            }
        }

        string Str()
        {
            i++;
            StringBuilder sb = new StringBuilder();
            while (true)
            {
                if (i >= s.Length) throw Err("unterminated string");
                char c = s[i++];
                if (c == '"') return sb.ToString();
                if (c != '\\') { sb.Append(c); continue; }
                if (i >= s.Length) throw Err("unterminated escape");
                char e = s[i++];
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
                        if (i + 4 > s.Length) throw Err("short \\u escape");
                        sb.Append((char)int.Parse(s.Substring(i, 4), NumberStyles.HexNumber, CultureInfo.InvariantCulture));
                        i += 4;
                        break;
                    default: throw Err("unknown escape \\" + e);
                }
            }
        }

        // The number rules of JavaScriptSerializer. Without an exponent it tries int, long, then decimal, and
        // otherwise double.
        object Primitive()
        {
            int st = i;
            while (i < s.Length && (char.IsLetterOrDigit(s[i]) || s[i] == '.' || s[i] == '-' || s[i] == '_' || s[i] == '+')) i++;
            string t = s.Substring(st, i - st);
            if (t.Length == 0) throw Err("value expected");
            if (t == "null") return null;
            if (t == "true") return true;
            if (t == "false") return false;
            bool hasPoint = t.IndexOf('.') >= 0;
            bool hasExp = t.LastIndexOf("e", StringComparison.OrdinalIgnoreCase) >= 0;
            if (!hasExp)
            {
                if (!hasPoint)
                {
                    int n;
                    if (int.TryParse(t, NumberStyles.Integer, CultureInfo.InvariantCulture, out n)) return n;
                    long l;
                    if (long.TryParse(t, NumberStyles.Integer, CultureInfo.InvariantCulture, out l)) return l;
                }
                decimal m;
                if (decimal.TryParse(t, NumberStyles.Number, CultureInfo.InvariantCulture, out m)) return m;
            }
            double dbl;
            if (double.TryParse(t, NumberStyles.Float, CultureInfo.InvariantCulture, out dbl)) return dbl;
            throw Err("invalid value '" + t + "'");
        }
    }

    public class Node
    {
        public string Kind; // lit, ident, call, prop, idx
        public object Value;
        public string Name;
        public List<Node> Args;
        public Node Target;
        public Node Index;
    }

    public class Parser
    {
        string s;
        int i;
        static Dictionary<string, Node> cache = new Dictionary<string, Node>();

        public static Node Parse(string expr)
        {
            Node n;
            if (cache.TryGetValue(expr, out n)) return n;
            Parser p = new Parser();
            p.s = expr;
            p.i = 0;
            n = p.ParseExpr();
            p.Ws();
            if (p.i != p.s.Length) throw new FormatException("Trailing input in expression: " + expr);
            cache[expr] = n;
            return n;
        }

        void Ws() { while (i < s.Length && char.IsWhiteSpace(s[i])) i++; }

        void Expect(char c)
        {
            Ws();
            if (i >= s.Length || s[i] != c) throw new FormatException("Expected '" + c + "' at " + i + " in: " + s);
            i++;
        }

        string Ident()
        {
            Ws();
            int st = i;
            while (i < s.Length && (char.IsLetterOrDigit(s[i]) || s[i] == '_' || s[i] == '$' || s[i] == '#')) i++;
            if (i == st) throw new FormatException("Identifier expected at " + i + " in: " + s);
            return s.Substring(st, i - st);
        }

        List<Node> ParseArgs()
        {
            Expect('(');
            List<Node> args = new List<Node>();
            Ws();
            if (i < s.Length && s[i] == ')') { i++; return args; }
            while (true)
            {
                args.Add(ParseExpr());
                Ws();
                if (i < s.Length && s[i] == ',') { i++; continue; }
                Expect(')');
                break;
            }
            return args;
        }

        Node ParseExpr()
        {
            Ws();
            Node n = ParsePrimary();
            while (true)
            {
                Ws();
                if (i < s.Length && s[i] == '.')
                {
                    i++;
                    string id = Ident();
                    Ws();
                    if (i < s.Length && s[i] == '(')
                    {
                        Node c = new Node();
                        c.Kind = "call";
                        c.Name = "<ns>." + id;
                        c.Args = ParseArgs();
                        c.Target = n;
                        n = c;
                    }
                    else
                    {
                        Node pn = new Node();
                        pn.Kind = "prop";
                        pn.Target = n;
                        pn.Name = id;
                        n = pn;
                    }
                }
                else if (i < s.Length && s[i] == '[')
                {
                    i++;
                    Node idx = ParseExpr();
                    Expect(']');
                    Node xn = new Node();
                    xn.Kind = "idx";
                    xn.Target = n;
                    xn.Index = idx;
                    n = xn;
                }
                else break;
            }
            return n;
        }

        Node ParsePrimary()
        {
            Ws();
            if (i >= s.Length) throw new FormatException("Unexpected end of expression: " + s);
            char c = s[i];
            if (c == '\'')
            {
                i++;
                StringBuilder sb = new StringBuilder();
                while (true)
                {
                    if (i >= s.Length) throw new FormatException("Unterminated string in: " + s);
                    if (s[i] == '\'')
                    {
                        if (i + 1 < s.Length && s[i + 1] == '\'') { sb.Append('\''); i += 2; continue; }
                        i++;
                        break;
                    }
                    sb.Append(s[i]);
                    i++;
                }
                Node n = new Node();
                n.Kind = "lit";
                n.Value = sb.ToString();
                return n;
            }
            if (char.IsDigit(c) || (c == '-' && i + 1 < s.Length && char.IsDigit(s[i + 1])))
            {
                int st = i;
                i++;
                while (i < s.Length && (char.IsDigit(s[i]) || s[i] == '.')) i++;
                string num = s.Substring(st, i - st);
                Node n = new Node();
                n.Kind = "lit";
                if (num.IndexOf('.') >= 0) n.Value = decimal.Parse(num, CultureInfo.InvariantCulture);
                else n.Value = long.Parse(num, CultureInfo.InvariantCulture);
                return n;
            }
            if (char.IsLetter(c) || c == '_' || c == '$')
            {
                string id = Ident();
                Ws();
                if (i < s.Length && s[i] == '(')
                {
                    Node n = new Node();
                    n.Kind = "call";
                    n.Name = id;
                    n.Args = ParseArgs();
                    return n;
                }
                Node b = new Node();
                b.Kind = "ident";
                b.Name = id;
                return b;
            }
            throw new FormatException("Unexpected character '" + c + "' at " + i + " in: " + s);
        }
    }

    public class Ctx
    {
        public Dictionary<string, object> Params = J.NewDict();
        public Dictionary<string, object> VarDefs = J.NewDict();
        public Dictionary<string, object> VarCopy = J.NewDict();
        public Dictionary<string, object> VarCache = J.NewDict();
        public HashSet<string> VarBusy = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        public Dictionary<string, int> Loops = new Dictionary<string, int>(StringComparer.OrdinalIgnoreCase);
        public string CurrentLoop;
        public Ctx Root;
        public string Kind;   // tenant | mg | sub | rg | unresolved
        public string Mg;
        public string Sub;    // null = the deployment's own subscription
        public string Rg;
        public string DeploymentName;

        public Ctx WithLoop(string name, int idx)
        {
            Ctx c = (Ctx)this.MemberwiseClone();
            c.Loops = new Dictionary<string, int>(this.Loops, StringComparer.OrdinalIgnoreCase);
            c.Loops[name ?? ""] = idx;
            c.CurrentLoop = name ?? "";
            return c;
        }

        public string ScopeDisplay()
        {
            switch (Kind)
            {
                case "rg": return "rg:" + (Sub == null ? "" : Sub + "/") + Rg;
                case "sub": return Sub == null ? "subscription" : "sub:" + Sub;
                case "mg": return "mg:" + Mg;
                case "tenant": return "tenant";
                default: return "<unresolved-scope>";
            }
        }
    }

    public static class Ev
    {
        // When true, format()/concat() render unresolved arguments as '*' (used only for deployment display names).
        public static bool Wildcard;

        public static object Deep(object v, Ctx ctx)
        {
            if (v == null) return null;
            string s = v as string;
            if (s != null) return Str(s, ctx);
            IDictionary d = v as IDictionary;
            if (d != null)
            {
                Dictionary<string, object> outD = J.NewDict();
                IList cpl = J.Get(d, "copy") as IList;
                bool isPropLoop = cpl != null && cpl.Count > 0 && cpl[0] is IDictionary && J.Has(cpl[0], "input");
                foreach (DictionaryEntry e in d)
                {
                    string k = (string)e.Key;
                    if (isPropLoop && string.Equals(k, "copy", StringComparison.OrdinalIgnoreCase)) continue;
                    outD[k] = Deep(e.Value, ctx);
                }
                if (isPropLoop)
                {
                    foreach (object co in cpl)
                    {
                        IDictionary c = co as IDictionary;
                        if (c == null) continue;
                        string nm = J.Get(c, "name") as string;
                        object cnt = Deep(J.Get(c, "count"), ctx);
                        if (J.IsNum(cnt))
                        {
                            List<object> list = new List<object>();
                            int n = Convert.ToInt32(cnt);
                            for (int k = 0; k < n; k++) list.Add(Deep(J.Get(c, "input"), ctx.WithLoop(nm, k)));
                            outD[nm ?? "copy"] = list;
                        }
                        else outD[nm ?? "copy"] = U.V;
                    }
                }
                return outD;
            }
            IList l = v as IList;
            if (l != null)
            {
                List<object> outL = new List<object>();
                foreach (object x in l) outL.Add(Deep(x, ctx));
                return outL;
            }
            return v;
        }

        public static object Str(string s, Ctx ctx)
        {
            if (s.StartsWith("[[")) return s.Substring(1);
            if (s.Length >= 2 && s[0] == '[' && s[s.Length - 1] == ']')
            {
                try { return E(Parser.Parse(s.Substring(1, s.Length - 2)), ctx); }
                catch (Exception) { return U.V; }
            }
            return s;
        }

        static bool AnyU(List<object> a)
        {
            foreach (object o in a) if (o is U) return true;
            return false;
        }

        static string ToStr(object o)
        {
            if (o == null) return "";
            string s = o as string;
            if (s != null) return s;
            if (o is bool) return (bool)o ? "True" : "False";
            if (J.IsNum(o)) return J.NumStr(o);
            return J.Canon(o);
        }

        static long ToLong(object o) { return Convert.ToInt64(o, CultureInfo.InvariantCulture); }

        static object GetVar(string name, Ctx ctx)
        {
            Ctx root = ctx.Root ?? ctx;
            object cached;
            if (root.VarCache.TryGetValue(name, out cached)) return cached;
            if (root.VarBusy.Contains(name)) return U.V;
            object result = U.V;
            root.VarBusy.Add(name);
            try
            {
                object def;
                if (root.VarDefs.TryGetValue(name, out def))
                {
                    result = Deep(def, root);
                }
                else if (root.VarCopy.TryGetValue(name, out def))
                {
                    object cnt = Deep(J.Get(def, "count"), root);
                    if (J.IsNum(cnt))
                    {
                        List<object> list = new List<object>();
                        int n = Convert.ToInt32(cnt);
                        for (int k = 0; k < n; k++) list.Add(Deep(J.Get(def, "input"), root.WithLoop(name, k)));
                        result = list;
                    }
                }
            }
            finally { root.VarBusy.Remove(name); }
            root.VarCache[name] = result;
            return result;
        }

        static Dictionary<string, object> Obj(params object[] kv)
        {
            Dictionary<string, object> d = J.NewDict();
            for (int i = 0; i + 1 < kv.Length; i += 2) d[(string)kv[i]] = kv[i + 1];
            return d;
        }

        static object BuildResourceId(string sub, string rg, List<object> a, int typeIdx)
        {
            string type = (string)a[typeIdx];
            string[] tparts = type.Split('/');
            List<string> names = new List<string>();
            for (int i = typeIdx + 1; i < a.Count; i++)
            {
                string n = a[i] as string;
                if (n == null) return U.V;
                foreach (string p in n.Split('/')) names.Add(p);
            }
            StringBuilder sb = new StringBuilder();
            if (sub != null) sb.Append("/subscriptions/" + sub);
            if (rg != null) sb.Append("/resourceGroups/" + rg);
            sb.Append("/providers/" + tparts[0]);
            for (int i = 1; i < tparts.Length; i++)
            {
                sb.Append("/" + tparts[i]);
                if (i - 1 < names.Count) sb.Append("/" + names[i - 1]);
            }
            return sb.ToString();
        }

        public static object E(Node n, Ctx ctx)
        {
            switch (n.Kind)
            {
                case "lit": return n.Value;
                case "ident": return U.V;
                case "prop":
                    {
                        object t = E(n.Target, ctx);
                        if (t is U) return U.V;
                        IDictionary d = t as IDictionary;
                        if (d == null) return U.V;
                        if (!J.Has(d, n.Name)) return U.V;
                        return J.Get(d, n.Name);
                    }
                case "idx":
                    {
                        object t = E(n.Target, ctx);
                        object ix = E(n.Index, ctx);
                        if (t is U || ix is U) return U.V;
                        IList l = t as IList;
                        if (l != null && J.IsNum(ix))
                        {
                            long k = ToLong(ix);
                            if (k < 0 || k >= l.Count) return U.V;
                            return l[(int)k];
                        }
                        IDictionary d = t as IDictionary;
                        if (d != null && ix is string)
                        {
                            if (!J.Has(d, (string)ix)) return U.V;
                            return J.Get(d, (string)ix);
                        }
                        return U.V;
                    }
                case "call": return Call(n, ctx);
            }
            return U.V;
        }

        static object Call(Node n, Ctx ctx)
        {
            string fn = n.Name.ToLowerInvariant();
            if (fn.StartsWith("<ns>.")) return U.V;
            if (fn == "if")
            {
                if (n.Args.Count < 3) return U.V;
                object c = E(n.Args[0], ctx);
                if (c is bool) return (bool)c ? E(n.Args[1], ctx) : E(n.Args[2], ctx);
                return U.V;
            }
            if (fn == "and")
            {
                bool sawU = false;
                foreach (Node x in n.Args)
                {
                    object v = E(x, ctx);
                    if (v is bool) { if (!(bool)v) return false; }
                    else sawU = true;
                }
                if (sawU) return U.V;
                return true;
            }
            if (fn == "or")
            {
                bool sawU = false;
                foreach (Node x in n.Args)
                {
                    object v = E(x, ctx);
                    if (v is bool) { if ((bool)v) return true; }
                    else sawU = true;
                }
                if (sawU) return U.V;
                return false;
            }
            if (fn == "coalesce")
            {
                foreach (Node x in n.Args)
                {
                    object v = E(x, ctx);
                    if (v is U) return U.V;
                    if (v != null) return v;
                }
                return null;
            }

            List<object> a = new List<object>();
            foreach (Node x in n.Args) a.Add(E(x, ctx));

            switch (fn)
            {
                case "parameters":
                    {
                        string pn = a.Count > 0 ? a[0] as string : null;
                        object pv;
                        if (pn != null && ctx.Params.TryGetValue(pn, out pv)) return pv;
                        return U.V;
                    }
                case "variables":
                    {
                        string vn = a.Count > 0 ? a[0] as string : null;
                        if (vn == null) return U.V;
                        return GetVar(vn, ctx);
                    }
                case "copyindex":
                    {
                        string loop = ctx.CurrentLoop;
                        long offset = 0;
                        if (a.Count >= 1)
                        {
                            if (a[0] is string) { loop = (string)a[0]; if (a.Count >= 2 && J.IsNum(a[1])) offset = ToLong(a[1]); }
                            else if (J.IsNum(a[0])) offset = ToLong(a[0]);
                        }
                        int idx;
                        if (loop == null || !ctx.Loops.TryGetValue(loop, out idx) || idx < 0) return U.V;
                        return (long)idx + offset;
                    }
                case "true": return true;
                case "false": return false;
                case "null": return null;
            }

            if (Wildcard && (fn == "format" || fn == "concat"))
            {
                for (int i = 0; i < a.Count; i++) if (a[i] is U) a[i] = "*";
            }
            if (AnyU(a)) return U.V;

            switch (fn)
            {
                case "concat":
                    {
                        if (a.Count > 0 && a[0] is IList)
                        {
                            List<object> r = new List<object>();
                            foreach (object o in a) { IList l = o as IList; if (l == null) return U.V; foreach (object x in l) r.Add(x); }
                            return r;
                        }
                        StringBuilder sb = new StringBuilder();
                        foreach (object o in a) sb.Append(ToStr(o));
                        return sb.ToString();
                    }
                case "format":
                    {
                        if (a.Count == 0 || !(a[0] is string)) return U.V;
                        object[] rest = new object[a.Count - 1];
                        for (int i = 1; i < a.Count; i++) rest[i - 1] = (a[i] is string || J.IsNum(a[i])) ? a[i] : (object)ToStr(a[i]);
                        try { return string.Format(CultureInfo.InvariantCulture, (string)a[0], rest); }
                        catch (Exception) { return U.V; }
                    }
                case "string": return a.Count > 0 ? ToStr(a[0]) : (object)U.V;
                case "int": return a.Count > 0 ? (object)Convert.ToInt64(a[0] is string ? long.Parse((string)a[0], CultureInfo.InvariantCulture) : a[0]) : U.V;
                case "bool":
                    {
                        if (a.Count == 0) return U.V;
                        if (a[0] is bool) return a[0];
                        if (a[0] is string) { bool b; if (bool.TryParse((string)a[0], out b)) return b; return U.V; }
                        if (J.IsNum(a[0])) return ToLong(a[0]) != 0;
                        return U.V;
                    }
                case "tolower": return a.Count > 0 && a[0] is string ? (object)((string)a[0]).ToLowerInvariant() : U.V;
                case "toupper": return a.Count > 0 && a[0] is string ? (object)((string)a[0]).ToUpperInvariant() : U.V;
                case "trim": return a.Count > 0 && a[0] is string ? (object)((string)a[0]).Trim() : U.V;
                case "replace":
                    if (a.Count == 3 && a[0] is string && a[1] is string && a[2] is string) return ((string)a[0]).Replace((string)a[1], (string)a[2]);
                    return U.V;
                case "split":
                    {
                        if (a.Count != 2 || !(a[0] is string)) return U.V;
                        List<string> delims = new List<string>();
                        if (a[1] is string) delims.Add((string)a[1]);
                        else if (a[1] is IList) foreach (object o in (IList)a[1]) delims.Add(ToStr(o));
                        List<object> r = new List<object>();
                        foreach (string p in ((string)a[0]).Split(delims.ToArray(), StringSplitOptions.None)) r.Add(p);
                        return r;
                    }
                case "substring":
                    {
                        string s0 = a.Count > 0 ? a[0] as string : null;
                        if (s0 == null) return U.V;
                        int st = a.Count > 1 ? (int)ToLong(a[1]) : 0;
                        if (a.Count > 2) return s0.Substring(st, (int)ToLong(a[2]));
                        return s0.Substring(st);
                    }
                case "startswith": return a.Count == 2 && a[0] is string && a[1] is string ? (object)((string)a[0]).StartsWith((string)a[1], StringComparison.OrdinalIgnoreCase) : U.V;
                case "endswith": return a.Count == 2 && a[0] is string && a[1] is string ? (object)((string)a[0]).EndsWith((string)a[1], StringComparison.OrdinalIgnoreCase) : U.V;
                case "indexof": return a.Count == 2 && a[0] is string && a[1] is string ? (object)(long)((string)a[0]).IndexOf((string)a[1], StringComparison.OrdinalIgnoreCase) : U.V;
                case "lastindexof": return a.Count == 2 && a[0] is string && a[1] is string ? (object)(long)((string)a[0]).LastIndexOf((string)a[1], StringComparison.OrdinalIgnoreCase) : U.V;
                case "padleft":
                    {
                        if (a.Count < 2) return U.V;
                        string s0 = ToStr(a[0]);
                        char pc = a.Count > 2 && a[2] is string && ((string)a[2]).Length > 0 ? ((string)a[2])[0] : ' ';
                        return s0.PadLeft((int)ToLong(a[1]), pc);
                    }
                case "length":
                    {
                        if (a.Count == 0) return U.V;
                        if (a[0] is string) return (long)((string)a[0]).Length;
                        if (a[0] is IList) return (long)((IList)a[0]).Count;
                        if (a[0] is IDictionary) return (long)((IDictionary)a[0]).Count;
                        return U.V;
                    }
                case "empty":
                    {
                        if (a.Count == 0) return U.V;
                        object o = a[0];
                        if (o == null) return true;
                        if (o is string) return ((string)o).Length == 0;
                        if (o is IList) return ((IList)o).Count == 0;
                        if (o is IDictionary) return ((IDictionary)o).Count == 0;
                        return false;
                    }
                case "contains":
                    {
                        if (a.Count != 2) return U.V;
                        object c = a[0];
                        if (c is string) return ((string)c).IndexOf(ToStr(a[1]), StringComparison.Ordinal) >= 0;
                        if (c is IList) { foreach (object x in (IList)c) if (J.DeepEq(x, a[1])) return true; return false; }
                        if (c is IDictionary) return a[1] is string && J.Has(c, (string)a[1]);
                        return U.V;
                    }
                case "equals": return a.Count == 2 ? (object)J.DeepEq(a[0], a[1]) : U.V;
                case "not": return a.Count == 1 && a[0] is bool ? (object)!(bool)a[0] : U.V;
                case "greater": return Cmp(a) > 0;
                case "less": return Cmp(a) < 0;
                case "greaterorequals": return Cmp(a) >= 0;
                case "lessorequals": return Cmp(a) <= 0;
                case "add": return ToLong(a[0]) + ToLong(a[1]);
                case "sub": return ToLong(a[0]) - ToLong(a[1]);
                case "mul": return ToLong(a[0]) * ToLong(a[1]);
                case "div": return ToLong(a[0]) / ToLong(a[1]);
                case "mod": return ToLong(a[0]) % ToLong(a[1]);
                case "min": { long m = long.MaxValue; foreach (object o in Flat(a)) m = Math.Min(m, ToLong(o)); return m; }
                case "max": { long m = long.MinValue; foreach (object o in Flat(a)) m = Math.Max(m, ToLong(o)); return m; }
                case "range":
                    {
                        List<object> r = new List<object>();
                        long st = ToLong(a[0]), cnt = ToLong(a[1]);
                        for (long i = 0; i < cnt; i++) r.Add(st + i);
                        return r;
                    }
                case "createarray": return new List<object>(a);
                case "createobject":
                    {
                        Dictionary<string, object> d = J.NewDict();
                        for (int i = 0; i + 1 < a.Count; i += 2) d[ToStr(a[i])] = a[i + 1];
                        return d;
                    }
                case "json":
                    {
                        if (a.Count == 0 || !(a[0] is string)) return U.V;
                        try { return J.Parse((string)a[0]); } catch (Exception) { return U.V; }
                    }
                case "first":
                    if (a[0] is string) return ((string)a[0]).Length > 0 ? ((string)a[0]).Substring(0, 1) : "";
                    if (a[0] is IList) return ((IList)a[0]).Count > 0 ? ((IList)a[0])[0] : null;
                    return U.V;
                case "last":
                    if (a[0] is string) { string s0 = (string)a[0]; return s0.Length > 0 ? s0.Substring(s0.Length - 1) : ""; }
                    if (a[0] is IList) { IList l = (IList)a[0]; return l.Count > 0 ? l[l.Count - 1] : null; }
                    return U.V;
                case "take":
                case "skip":
                    {
                        int k = (int)ToLong(a[1]);
                        if (a[0] is string)
                        {
                            string s0 = (string)a[0];
                            k = Math.Max(0, Math.Min(k, s0.Length));
                            return fn == "take" ? s0.Substring(0, k) : s0.Substring(k);
                        }
                        IList l = a[0] as IList;
                        if (l == null) return U.V;
                        k = Math.Max(0, Math.Min(k, l.Count));
                        List<object> r = new List<object>();
                        for (int i = (fn == "take" ? 0 : k); i < (fn == "take" ? k : l.Count); i++) r.Add(l[i]);
                        return r;
                    }
                case "join":
                    {
                        IList l = a[0] as IList;
                        if (l == null || a.Count < 2) return U.V;
                        List<string> parts = new List<string>();
                        foreach (object o in l) parts.Add(ToStr(o));
                        return string.Join(ToStr(a[1]), parts.ToArray());
                    }
                case "union": return Union(a);
                case "trygetproperty":
                case "tryget":
                    {
                        object cur = a[0];
                        for (int i = 1; i < a.Count; i++)
                        {
                            if (cur == null) return null;
                            if (cur is IDictionary && a[i] is string) { if (!J.Has(cur, (string)a[i])) return null; cur = J.Get(cur, (string)a[i]); }
                            else if (cur is IList && J.IsNum(a[i])) { IList l = (IList)cur; long k = ToLong(a[i]); if (k < 0 || k >= l.Count) return null; cur = l[(int)k]; }
                            else return null;
                        }
                        return cur;
                    }
                case "items":
                    {
                        IDictionary d = a[0] as IDictionary;
                        if (d == null) return U.V;
                        List<string> keys = new List<string>();
                        foreach (object k in d.Keys) keys.Add((string)k);
                        keys.Sort(StringComparer.OrdinalIgnoreCase);
                        List<object> r = new List<object>();
                        foreach (string k in keys) r.Add(Obj("key", k, "value", d[k]));
                        return r;
                    }
                case "resourcegroup":
                    if (ctx.Kind != "rg") return U.V;
                    return Obj("name", ctx.Rg, "id", U.V, "location", U.V, "type", "Microsoft.Resources/resourceGroups", "tags", U.V, "properties", U.V, "managedBy", U.V);
                case "subscription":
                    return Obj("subscriptionId", (object)ctx.Sub ?? U.V, "id", ctx.Sub == null ? (object)U.V : "/subscriptions/" + ctx.Sub, "tenantId", U.V, "displayName", U.V);
                case "managementgroup":
                    if (ctx.Kind != "mg") return U.V;
                    return Obj("name", ctx.Mg, "id", "/providers/Microsoft.Management/managementGroups/" + ctx.Mg, "properties", U.V);
                case "deployment":
                    return Obj("name", (object)ctx.DeploymentName ?? U.V, "properties", U.V, "location", U.V, "id", U.V);
                case "resourceid":
                    {
                        int ti = -1;
                        for (int i = 0; i < a.Count && i < 3; i++) { string x = a[i] as string; if (x != null && x.IndexOf('/') > 0 && x.IndexOf('.') > 0) { ti = i; break; } }
                        if (ti < 0) return U.V;
                        string sub = ctx.Sub ?? "{subscription}";
                        string rg = ctx.Kind == "rg" ? ctx.Rg : null;
                        if (ti == 2) { sub = (string)a[0]; rg = (string)a[1]; }
                        else if (ti == 1) { rg = (string)a[0]; }
                        if (rg == null && ctx.Kind != "rg") return BuildResourceId(sub, null, a, ti);
                        return BuildResourceId(sub, rg, a, ti);
                    }
                case "subscriptionresourceid":
                    {
                        int ti = (a.Count > 0 && a[0] is string && ((string)a[0]).IndexOf('/') > 0) ? 0 : 1;
                        string sub = ti == 1 ? (string)a[0] : (ctx.Sub ?? "{subscription}");
                        return BuildResourceId(sub, null, a, ti);
                    }
                case "tenantresourceid": return BuildResourceId(null, null, a, 0);
                case "extensionresourceid":
                    {
                        string baseId = a[0] as string;
                        if (baseId == null) return U.V;
                        object ext = BuildResourceId(null, null, a, 1);
                        if (ext is U) return U.V;
                        return baseId.TrimEnd('/') + (string)ext;
                    }
                case "environment":
                    if (a.Count != 0) return U.V;
                    return AzureCloud();
            }
            // uniqueString, guid, reference, list*, utcNow, newGuid, lambdas, etc.
            return U.V;
        }

        // environment() as Azure's public cloud (AzureCloud), the cloud every subscription of the estate is in.
        // The values are the ones Microsoft documents for global Azure in the Bicep deployment functions
        // (learn.microsoft.com/azure/azure-resource-manager/bicep/bicep-functions-deployment#environment).
        // A sovereign cloud returns other values, so the checker needs its own set before it is used there.
        static Dictionary<string, object> AzureCloud()
        {
            return Obj(
                "name", "AzureCloud",
                "gallery", "https://gallery.azure.com/",
                "graph", "https://graph.windows.net/",
                "portal", "https://portal.azure.com",
                "graphAudience", "https://graph.windows.net/",
                "activeDirectoryDataLake", "https://datalake.azure.net/",
                "batch", "https://batch.core.windows.net/",
                "media", "https://rest.media.azure.net",
                "sqlManagement", "https://management.core.windows.net:8443/",
                "vmImageAliasDoc", "https://raw.githubusercontent.com/Azure/azure-rest-api-specs/master/arm-compute/quickstart-templates/aliases.json",
                "resourceManager", "https://management.azure.com/",
                "authentication", Obj(
                    "loginEndpoint", "https://login.microsoftonline.com/",
                    "audiences", new List<object> { "https://management.core.windows.net/", "https://management.azure.com/" },
                    "tenant", "common",
                    "identityProvider", "AAD"),
                "suffixes", Obj(
                    "acrLoginServer", ".azurecr.io",
                    "azureDatalakeAnalyticsCatalogAndJob", "azuredatalakeanalytics.net",
                    "azureDatalakeStoreFileSystem", "azuredatalakestore.net",
                    "azureFrontDoorEndpointSuffix", "azurefd.net",
                    "keyvaultDns", ".vault.azure.net",
                    "sqlServerHostname", ".database.windows.net",
                    "storage", "core.windows.net"));
        }

        static IEnumerable<object> Flat(List<object> a)
        {
            foreach (object o in a)
            {
                IList l = o as IList;
                if (l != null) { foreach (object x in l) yield return x; }
                else yield return o;
            }
        }

        static int Cmp(List<object> a)
        {
            if (a.Count != 2) throw new ArgumentException();
            if (J.IsNum(a[0]) && J.IsNum(a[1])) return Convert.ToDecimal(a[0]).CompareTo(Convert.ToDecimal(a[1]));
            return string.CompareOrdinal(ToStr(a[0]), ToStr(a[1]));
        }

        static object Union(List<object> a)
        {
            if (a.Count == 0) return U.V;
            if (a[0] is IList)
            {
                List<object> r = new List<object>();
                HashSet<string> seen = new HashSet<string>();
                foreach (object o in a)
                {
                    IList l = o as IList;
                    if (l == null) return U.V;
                    foreach (object x in l) if (seen.Add(J.Canon(x))) r.Add(x);
                }
                return r;
            }
            Dictionary<string, object> d = J.NewDict();
            foreach (object o in a)
            {
                IDictionary od = o as IDictionary;
                if (od == null) return U.V;
                foreach (DictionaryEntry e in od)
                {
                    string k = (string)e.Key;
                    object prev;
                    if (d.TryGetValue(k, out prev) && prev is IDictionary && e.Value is IDictionary)
                        d[k] = Union(new List<object> { prev, e.Value });
                    else d[k] = e.Value;
                }
            }
            return d;
        }
    }

    public class Decl
    {
        public string Scope;
        public string ExtScope;
        public string Type;
        public string Name;
        public string NameExpr;
        public bool Resolved;
        public string Status;
        public string Condition;
        public string GatedBy;   // where a false condition was found: deployment names and/or '(self)'
        public List<string> Path;
        public string Symbol;
        public string Key;
        public IDictionary Raw;
        public Ctx Ctx;
        private object body;
        private bool bodyDone;

        public object Body()
        {
            if (!bodyDone)
            {
                Dictionary<string, object> d = J.NewDict();
                foreach (DictionaryEntry e in Raw)
                {
                    string k = (string)e.Key;
                    switch (k.ToLowerInvariant())
                    {
                        case "condition": case "dependson": case "copy": case "comments": case "metadata": case "existing":
                            continue;
                    }
                    d[k] = e.Value;
                }
                body = Ev.Deep(d, Ctx);
                bodyDone = true;
            }
            return body;
        }

        public string BodyCanon() { return J.Canon(Body()); }

        public string[] DiffAgainst(Decl other)
        {
            List<string> outList = new List<string>();
            J.Diff(this.Body(), other.Body(), "$", outList);
            return outList.ToArray();
        }
    }

    public class Walker
    {
        public List<Decl> Decls = new List<Decl>();
        public List<string> Notes = new List<string>();
        public int Deployments;

        static int Rank(string s)
        {
            if (s == "gated-off") return 2;
            if (s == "condition-unresolved") return 1;
            return 0;
        }

        public static Ctx RootCtx(IDictionary tpl, IDictionary paramValues)
        {
            Ctx c = new Ctx();
            c.Root = c;
            string schema = (J.Get(tpl, "$schema") as string ?? "").ToLowerInvariant();
            if (schema.Contains("subscriptiondeploymenttemplate")) c.Kind = "sub";
            else if (schema.Contains("managementgroupdeploymenttemplate")) { c.Kind = "mg"; c.Mg = "<current>"; }
            else if (schema.Contains("tenantdeploymenttemplate")) c.Kind = "tenant";
            else { c.Kind = "rg"; c.Rg = "<current>"; }
            LoadVariables(tpl, c);
            IDictionary pdefs = J.Get(tpl, "parameters") as IDictionary;
            if (pdefs != null)
            {
                foreach (DictionaryEntry e in pdefs)
                {
                    string pn = (string)e.Key;
                    object supplied = paramValues == null ? null : J.Get(paramValues, pn);
                    if (supplied != null && J.Has(supplied, "value")) c.Params[pn] = J.Get(supplied, "value");
                    else if (supplied != null) c.Params[pn] = U.V; // key vault reference etc.
                    else if (J.Has(e.Value, "defaultValue")) c.Params[pn] = Ev.Deep(J.Get(e.Value, "defaultValue"), c);
                    else if (J.Get(e.Value, "nullable") is bool && (bool)J.Get(e.Value, "nullable")) c.Params[pn] = null;
                    else c.Params[pn] = U.V;
                }
            }
            return c;
        }

        static void LoadVariables(IDictionary tpl, Ctx c)
        {
            IDictionary vars = J.Get(tpl, "variables") as IDictionary;
            if (vars == null) return;
            foreach (DictionaryEntry e in vars)
            {
                string k = (string)e.Key;
                if (string.Equals(k, "copy", StringComparison.OrdinalIgnoreCase) && e.Value is IList)
                {
                    foreach (object co in (IList)e.Value)
                    {
                        string nm = J.Get(co, "name") as string;
                        if (nm != null) c.VarCopy[nm] = co;
                    }
                }
                else c.VarDefs[k] = e.Value;
            }
        }

        public void Run(IDictionary tpl, Ctx root)
        {
            WalkTemplate(tpl, root, new List<string>(), "active", "");
        }

        void WalkTemplate(IDictionary tpl, Ctx ctx, List<string> path, string inherited, string gated)
        {
            object res = J.Get(tpl, "resources");
            if (res == null) return;
            IDictionary rd = res as IDictionary;
            if (rd != null)
            {
                foreach (DictionaryEntry e in rd)
                {
                    IDictionary r = e.Value as IDictionary;
                    if (r != null) Visit(r, ctx, path, inherited, gated, (string)e.Key);
                }
                return;
            }
            IList rl = res as IList;
            if (rl != null)
            {
                foreach (object o in rl)
                {
                    IDictionary r = o as IDictionary;
                    if (r != null) Visit(r, ctx, path, inherited, gated, null);
                }
            }
        }

        void Visit(IDictionary r, Ctx ctx, List<string> path, string inherited, string gated, string symbol)
        {
            object ex = J.Get(r, "existing");
            if (ex is bool && (bool)ex) return;
            IDictionary copy = J.Get(r, "copy") as IDictionary;
            if (copy != null)
            {
                string loop = J.Get(copy, "name") as string;
                object cnt = Ev.Deep(J.Get(copy, "count"), ctx);
                if (J.IsNum(cnt))
                {
                    int n = Convert.ToInt32(cnt);
                    for (int k = 0; k < n; k++) Process(r, ctx.WithLoop(loop, k), path, inherited, gated, symbol, k.ToString(CultureInfo.InvariantCulture));
                }
                else
                {
                    Notes.Add("copy loop '" + loop + "' count unresolved at " + string.Join(" > ", path.ToArray()) + ", so one unresolved declaration is recorded");
                    Process(r, ctx.WithLoop(loop, -1), path, inherited, gated, symbol, "?");
                }
            }
            else Process(r, ctx, path, inherited, gated, symbol, null);
        }

        void Process(IDictionary r, Ctx ctx, List<string> path, string inherited, string gated, string symbol, string iter)
        {
            string status = inherited;
            string condText = null;
            bool falseHere = false;
            if (J.Has(r, "condition"))
            {
                object craw = J.Get(r, "condition");
                condText = craw is string ? (string)craw : J.Canon(craw);
                object c = Ev.Deep(craw, ctx);
                string own = "condition-unresolved";
                if (c is bool) own = (bool)c ? "active" : "gated-off";
                if (Rank(own) > Rank(status)) status = own;
                if (own == "gated-off") falseHere = true;
            }
            string type = J.Get(r, "type") as string;
            if (type == null) return;
            object nameRaw = J.Get(r, "name");
            object nameV = Ev.Deep(nameRaw, ctx);
            string nameExpr = nameRaw as string ?? J.Canon(nameRaw);

            if (string.Equals(type, "Microsoft.Resources/deployments", StringComparison.OrdinalIgnoreCase))
            {
                ProcessDeployment(r, ctx, path, status, gated, falseHere, nameV, nameExpr, iter);
                return;
            }

            Decl d = new Decl();
            d.Type = type;
            d.Status = status;
            d.Condition = condText;
            d.GatedBy = falseHere ? (gated.Length > 0 ? gated + " | (self)" : "(self)") : gated;
            d.Path = new List<string>(path);
            d.Symbol = symbol;
            d.Raw = r;
            d.Ctx = ctx;
            d.Scope = ctx.ScopeDisplay();
            d.NameExpr = nameExpr;
            bool resolved = nameV is string && ctx.Kind != "unresolved" && (ctx.Rg == null || ctx.Rg.IndexOf("<unresolved", StringComparison.Ordinal) < 0) && (ctx.Sub == null || ctx.Sub.IndexOf("<unresolved", StringComparison.Ordinal) < 0);
            d.Name = nameV is string ? (string)nameV : nameExpr;
            if (J.Has(r, "scope"))
            {
                object sv = Ev.Deep(J.Get(r, "scope"), ctx);
                if (sv is string)
                {
                    string s = (string)sv;
                    int pi = s.IndexOf("/providers/", StringComparison.OrdinalIgnoreCase);
                    if (s.StartsWith("/subscriptions/", StringComparison.OrdinalIgnoreCase) && pi >= 0) s = s.Substring(pi + 11);
                    d.ExtScope = s;
                }
                else { d.ExtScope = "<unresolved>"; resolved = false; }
            }
            d.Resolved = resolved;
            d.Key = (d.Scope + "|" + (d.ExtScope ?? "") + "|" + d.Type + "|" + d.Name).ToLowerInvariant();
            Decls.Add(d);

            IList kids = J.Get(r, "resources") as IList;
            if (kids != null && kids.Count > 0)
                Notes.Add("classic nested child 'resources' array under " + type + " '" + d.Name + "' was not walked");
        }

        void ProcessDeployment(IDictionary r, Ctx ctx, List<string> path, string status, string gated, bool falseHere, object nameV, string nameExpr, string iter)
        {
            Deployments++;
            string depName = nameV as string;
            if (depName == null)
            {
                object w;
                Ev.Wildcard = true;
                try { w = Ev.Deep(J.Get(r, "name"), ctx); }
                finally { Ev.Wildcard = false; }
                depName = (w is string && ((string)w).Length > 0) ? (string)w : "<unresolved-name>";
                if (iter != null && depName.IndexOf('*') < 0) depName += "#" + iter;
            }
            List<string> newPath = new List<string>(path);
            newPath.Add(depName);

            IDictionary props = J.Get(r, "properties") as IDictionary;
            IDictionary tpl = J.Get(props, "template") as IDictionary;
            if (tpl == null)
            {
                Notes.Add("deployment '" + string.Join(" > ", newPath.ToArray()) + "' has no inline template (templateLink?), so it is not walked");
                return;
            }

            Ctx child = new Ctx();
            child.Root = child;
            child.DeploymentName = nameV as string;
            child.Kind = ctx.Kind;
            child.Mg = ctx.Mg;
            child.Sub = ctx.Sub;
            child.Rg = ctx.Rg;

            if (J.Has(r, "scope"))
            {
                object sv = Ev.Deep(J.Get(r, "scope"), ctx);
                string s = sv as string;
                if (s == null) child.Kind = "unresolved";
                else if (s == "/" || s.Length == 0) child.Kind = "tenant";
                else
                {
                    int k = s.IndexOf("managementGroups/", StringComparison.OrdinalIgnoreCase);
                    if (k >= 0) { child.Kind = "mg"; child.Mg = s.Substring(k + 17).Trim('/'); }
                    else child.Kind = "unresolved";
                }
            }
            if (J.Has(r, "subscriptionId"))
            {
                object sv = Ev.Deep(J.Get(r, "subscriptionId"), ctx);
                child.Sub = sv is string ? (string)sv : "<unresolved>";
                if (child.Kind != "rg") child.Kind = "sub";
            }
            if (J.Has(r, "resourceGroup"))
            {
                object rv = Ev.Deep(J.Get(r, "resourceGroup"), ctx);
                child.Rg = rv is string ? (string)rv : "<unresolved>";
                child.Kind = "rg";
            }

            string evalScope = "outer";
            IDictionary eeo = J.Get(props, "expressionEvaluationOptions") as IDictionary;
            if (eeo != null && J.Get(eeo, "scope") is string) evalScope = ((string)J.Get(eeo, "scope")).ToLowerInvariant();

            if (evalScope == "inner")
            {
                LoadVariables(tpl, child);
                IDictionary pdefs = J.Get(tpl, "parameters") as IDictionary;
                IDictionary pvals = J.Get(props, "parameters") as IDictionary;
                List<string> pending = new List<string>();
                if (pdefs != null)
                {
                    foreach (DictionaryEntry e in pdefs)
                    {
                        string pn = (string)e.Key;
                        object supplied = J.Get(pvals, pn);
                        if (supplied != null)
                        {
                            object ev = Ev.Deep(supplied, ctx);
                            if (J.Has(ev, "value")) child.Params[pn] = J.Get(ev, "value");
                            else child.Params[pn] = U.V;
                        }
                        else pending.Add(pn);
                    }
                    foreach (string pn in pending)
                    {
                        object pdef = J.Get(pdefs, pn);
                        if (J.Has(pdef, "defaultValue")) child.Params[pn] = Ev.Deep(J.Get(pdef, "defaultValue"), child);
                        else if (J.Get(pdef, "nullable") is bool && (bool)J.Get(pdef, "nullable")) child.Params[pn] = null;
                        else child.Params[pn] = U.V;
                    }
                }
            }
            else
            {
                // outer evaluation scope: nested template sees the parent's parameters and variables
                child.Params = ctx.Params;
                child.VarDefs = ctx.VarDefs;
                child.VarCopy = ctx.VarCopy;
                child.VarCache = ctx.VarCache;
                child.VarBusy = ctx.VarBusy;
                child.Loops = new Dictionary<string, int>(ctx.Loops, StringComparer.OrdinalIgnoreCase);
                child.CurrentLoop = ctx.CurrentLoop;
                child.Root = ctx.Root;
            }
            if (falseHere) gated = gated.Length > 0 ? gated + " | " + depName : depName;
            WalkTemplate(tpl, child, newPath, status, gated);
        }
    }
}
'@

if (-not ('FindDuplicateDeclarations.Walker' -as [type])) {
    Add-Type -TypeDefinition $cs -Language CSharp
}

# ---------------------------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------------------------
# az on Windows (az.cmd starts Python with -I, which ignores PYTHONUTF8 and PYTHONIOENCODING) writes text in
# the ANSI code page of the system, and az on Linux writes UTF-8. So that a value with a character such as a dash
# reads the same on every host, the file az wrote is read as UTF-8 when its bytes are valid UTF-8 and otherwise,
# on Windows, in the ANSI code page. Plain ASCII output is the same either way.
function Read-AzOutput {
    param([string]$Path)
    if ([IO.Path]::DirectorySeparatorChar -eq '\') {
        $bytes = [IO.File]::ReadAllBytes($Path)
        try { $null = (New-Object System.Text.UTF8Encoding($false, $true)).GetString($bytes) }
        catch { return [Text.Encoding]::GetEncoding(0).GetString($bytes) }
    }
    return [IO.File]::ReadAllText($Path, [Text.Encoding]::UTF8)
}

function Invoke-BicepCli {
    param([string[]]$Arguments)
    $az = Get-Command az -ErrorAction SilentlyContinue
    if (-not $az) { throw 'az CLI not found on PATH (needed only for the local Bicep compiler).' }
    $out = [IO.Path]::GetTempFileName()
    $err = [IO.Path]::GetTempFileName()
    try {
        $argLine = ($Arguments | ForEach-Object { if ($_ -match '[\s"]') { '"' + ($_ -replace '"', '\"') + '"' } else { $_ } }) -join ' '
        $p = Start-Process -FilePath $az.Source -ArgumentList $argLine -NoNewWindow -PassThru `
            -RedirectStandardOutput $out -RedirectStandardError $err
        $null = $p.Handle
        $p.WaitForExit()
        $text = Read-AzOutput $out
        $errText = Read-AzOutput $err
        if ($p.ExitCode -ne 0 -or [string]::IsNullOrWhiteSpace($text)) {
            $errLines = ($errText -split "`r?`n") | Where-Object { $_ -match '\bError\b|ERROR' } | Select-Object -First 20
            throw ("az " + $argLine + " failed (exit " + $p.ExitCode + "):`n" + ($errLines -join "`n"))
        }
        return $text
    }
    finally {
        Remove-Item -LiteralPath $out, $err -ErrorAction SilentlyContinue
    }
}

$script:moduleCache = @{}
function Get-BicepModules {
    param([string]$File)
    if ($script:moduleCache.ContainsKey($File)) { return , $script:moduleCache[$File] }
    $list = New-Object System.Collections.Generic.List[object]
    if ($File -and (Test-Path -LiteralPath $File)) {
        $text = [IO.File]::ReadAllText($File)
        $ms = [regex]::Matches($text, "(?m)^[ \t]*module[ \t]+(\w+)[ \t]+'([^']+)'[ \t]*=")
        for ($i = 0; $i -lt $ms.Count; $i++) {
            $start = $ms[$i].Index
            $end = if ($i + 1 -lt $ms.Count) { $ms[$i + 1].Index } else { $text.Length }
            $block = $text.Substring($start, $end - $start)
            $nm = [regex]::Match($block, "(?m)^[ \t]*name:[ \t]*(.+?)[ \t]*$")
            $pattern = $null
            $exact = $false
            $skeleton = $null
            if ($nm.Success) {
                $v = ($nm.Groups[1].Value -replace '\s*//.*$', '').Trim()
                if ($v -match "^'(.*)'$") {
                    $parts = [regex]::Split($Matches[1], '\$\{[^}]*\}')
                    $pattern = '^' + (($parts | ForEach-Object { [regex]::Escape($_) }) -join '.*') + '$'
                    $skeleton = $parts -join '*'
                    $exact = ($parts.Count -eq 1)
                }
            }
            $rel = $ms[$i].Groups[2].Value
            $full = $null
            if ($rel -notmatch '^(br|ts)[:/]') {
                $full = [IO.Path]::GetFullPath((Join-Path (Split-Path -Parent $File) $rel))
            }
            $list.Add([pscustomobject]@{ Symbol = $ms[$i].Groups[1].Value; Path = $full; Rel = $rel; Pattern = $pattern; Exact = $exact; Skeleton = $skeleton })
        }
    }
    $script:moduleCache[$File] = $list
    return , $list
}

$script:chainCache = @{}
function Resolve-FileChain {
    param([string]$Root, [object[]]$DeploymentPath)
    $cacheKey = ($DeploymentPath -join "`n")
    if ($script:chainCache.ContainsKey($cacheKey)) { return , $script:chainCache[$cacheKey] }
    $files = New-Object System.Collections.Generic.List[string]
    $files.Add($Root)
    $cur = $Root
    foreach ($dep in $DeploymentPath) {
        if (-not $cur) { $files.Add('?'); continue }
        $mods = Get-BicepModules -File $cur
        $hit = $null
        if ($dep.Contains('*')) {
            # deployment name only partly resolvable (e.g. uniqueString), so compare skeletons
            $depRx = '^' + ([regex]::Escape($dep).Replace('\*', '.*')) + '$'
            foreach ($m in $mods) { if ($m.Skeleton -and $m.Skeleton -ieq $dep) { $hit = $m; break } }
            if (-not $hit) { foreach ($m in $mods) { if ($m.Skeleton -and $m.Skeleton -match $depRx) { $hit = $m; break } } }
        }
        else {
            foreach ($m in $mods) { if ($m.Exact -and $dep -match $m.Pattern) { $hit = $m; break } }
            if (-not $hit) { foreach ($m in $mods) { if ($m.Pattern -and -not $m.Exact -and $dep -match $m.Pattern) { $hit = $m; break } } }
        }
        if ($hit -and $hit.Path) { $files.Add($hit.Path); $cur = $hit.Path }
        elseif ($hit) { $files.Add($hit.Rel + ' (registry module)'); $cur = $null }
        else { $files.Add('?'); $cur = $null }
    }
    $arr = $files.ToArray()
    $script:chainCache[$cacheKey] = $arr
    return , $arr
}

# Keys sorted by character code, so the report lists them in the same order under every PowerShell and
# operating system (Sort-Object follows the culture, and Windows PowerShell 5.1 and PowerShell 7 order
# punctuation differently).
function Get-OrdinalSorted($keys) {
    $a = [string[]]@($keys)
    [Array]::Sort($a, [StringComparer]::Ordinal)
    return , $a
}

function Get-ShortPath {
    param([string]$Path, [string]$Base)
    if (-not $Path -or $Path -eq '?') { return '?' }
    if ($Base -and $Path.StartsWith($Base, [StringComparison]::OrdinalIgnoreCase)) {
        return $Path.Substring($Base.Length).TrimStart('\', '/') -replace '\\', '/'
    }
    return $Path
}

# The text of a Bicep or .bicepparam file as Bicep reads its statements, the same reading as in
# preflight-validate.ps1. Comments (// and /* */) and the inside of multi-line strings ('''...''', with any
# quotes right after the closing three) become spaces, and line breaks stay. A single-quoted string stays as
# it is, with the expressions inside ${...}, so a comment marker inside it is text.
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

# ---------------------------------------------------------------------------------------------
# Compile
# ---------------------------------------------------------------------------------------------
try {
    $templatePath = (Resolve-Path -LiteralPath $Template).ProviderPath
    $templateDir = Split-Path -Parent $templatePath
    # The display base is the 'infra' folder above the template when there is one, else the template folder.
    $base = $templateDir
    $probe = $templateDir
    while ($probe) {
        if ((Split-Path -Leaf $probe) -ieq 'infra') { $base = $probe; break }
        $parent = Split-Path -Parent $probe
        if ($parent -eq $probe) { break }
        $probe = $parent
    }

    $paramPath = $null
    if (-not $NoParameters) {
        if ($Parameters) { $paramPath = (Resolve-Path -LiteralPath $Parameters).ProviderPath }
        elseif (Test-Path -LiteralPath (Join-Path $templateDir 'parameters.bicepparam')) {
            $paramPath = (Resolve-Path -LiteralPath (Join-Path $templateDir 'parameters.bicepparam')).ProviderPath
        }
    }
    if ($paramPath) {
        # The using line is read as Bicep reads it, so a line inside a comment or a multi-line string does not count.
        $usingLine = [regex]::Match((Get-BicepCodeText $paramPath), "(?m)^\s*using\s+'([^']+)'")
        if ($usingLine.Success) {
            $usingTarget = [IO.Path]::GetFullPath((Join-Path (Split-Path -Parent $paramPath) $usingLine.Groups[1].Value))
            if ($usingTarget -ine $templatePath) {
                throw "Parameter file $paramPath targets $usingTarget, not $templatePath."
            }
        }
    }

    if ($paramPath) {
        Write-Host "Compiling $paramPath (az bicep build-params --stdout) ..."
        $raw = Invoke-BicepCli -Arguments @('bicep', 'build-params', '--file', $paramPath, '--stdout')
    }
    else {
        Write-Host "Compiling $templatePath (az bicep build --stdout) ..."
        $raw = Invoke-BicepCli -Arguments @('bicep', 'build', '--file', $templatePath, '--stdout')
    }

    $parsed = [FindDuplicateDeclarations.J]::Parse($raw)
    $paramValues = $null
    if ($parsed.ContainsKey('templateJson')) {
        $tpl = [FindDuplicateDeclarations.J]::Parse([string]$parsed['templateJson'])
        if ($parsed['parametersJson']) {
            $pj = [FindDuplicateDeclarations.J]::Parse([string]$parsed['parametersJson'])
            $paramValues = [FindDuplicateDeclarations.J]::Get($pj, 'parameters')
        }
    }
    else {
        $tpl = $parsed
    }

    # -----------------------------------------------------------------------------------------
    # Walk
    # -----------------------------------------------------------------------------------------
    $root = [FindDuplicateDeclarations.Walker]::RootCtx($tpl, $paramValues)
    $walker = New-Object FindDuplicateDeclarations.Walker
    $walker.Run($tpl, $root)
    $decls = $walker.Decls
}
catch {
    Write-Error $_ -ErrorAction Continue   # with the preference at Stop, a plain Write-Error would end the script with exit 1
    exit 2
}

$counting = @('active', 'condition-unresolved')
$byKey = @{}
$unresolved = New-Object System.Collections.Generic.List[object]
foreach ($d in $decls) {
    if (-not $d.Resolved) { $unresolved.Add($d); continue }
    if (-not $byKey.ContainsKey($d.Key)) { $byKey[$d.Key] = New-Object System.Collections.Generic.List[object] }
    $byKey[$d.Key].Add($d)
}

$active = New-Object System.Collections.Generic.List[object]
$latent = New-Object System.Collections.Generic.List[object]
foreach ($k in (Get-OrdinalSorted $byKey.Keys)) {
    $grp = $byKey[$k]
    if ($grp.Count -lt 2) { continue }
    $nCount = @($grp | Where-Object { $counting -contains $_.Status }).Count
    if ($nCount -ge 2) { $active.Add($grp) } else { $latent.Add($grp) }
}

$nActive = @($decls | Where-Object { $_.Status -eq 'active' }).Count
$nGated = @($decls | Where-Object { $_.Status -eq 'gated-off' }).Count
$nCondU = @($decls | Where-Object { $_.Status -eq 'condition-unresolved' }).Count

$report = [ordered]@{
    template          = $templatePath
    parameters        = $paramPath
    deployments       = $walker.Deployments
    declarations      = $decls.Count
    active            = $nActive
    gatedOff          = $nGated
    conditionUnresolved = $nCondU
    unresolvedKeys    = $unresolved.Count
    activeDuplicates  = @()
    latentDuplicates  = @()
    unresolved        = @()
    notes             = @($walker.Notes)
}

function Format-Group {
    param($Group, [string]$Kind)
    $first = $Group[0]
    $entries = @()
    foreach ($d in $Group) {
        $chain = Resolve-FileChain -Root $templatePath -DeploymentPath $d.Path.ToArray()
        $short = @($chain | ForEach-Object { Get-ShortPath -Path $_ -Base $base })
        $entries += [pscustomobject]@{
            status     = $d.Status
            gatedBy    = $d.GatedBy
            deployment = ($d.Path -join '/')
            files      = $short
            declaredIn = @($short | Where-Object { $_ -ne '?' })[-1]
            condition  = $d.Condition
            decl       = $d
        }
    }
    # Body comparison. Every declaration is compared with the first one (resolved values, not source text)
    $ref = $Group[0]
    $diffs = @()
    $identical = $true
    for ($i = 1; $i -lt $Group.Count; $i++) {
        $d = $Group[$i]
        if ($ref.BodyCanon() -ne $d.BodyCanon()) {
            $identical = $false
            $diffs += [pscustomobject]@{ a = $entries[0].declaredIn; b = $entries[$i].declaredIn; paths = @($ref.DiffAgainst($d)) }
        }
    }
    return [pscustomobject]@{
        kind      = $Kind
        scope     = $first.Scope
        extScope  = $first.ExtScope
        type      = $first.Type
        name      = $first.Name
        count     = $Group.Count
        identical = $identical
        entries   = $entries
        diffs     = $diffs
    }
}

function Write-Group {
    param($G)
    $ext = if ($G.extScope) { " (scope: $($G.extScope))" } else { '' }
    Write-Output ("  [{0}] {1} {2}{3}  x{4}  bodies: {5}" -f $G.scope, $G.type, $G.name, $ext, $G.count, $(if ($G.identical) { 'identical' } else { 'DIFFERENT' }))
    foreach ($e in $G.entries) {
        $gate = if ($e.status -eq 'gated-off') { "   [false condition at: $($e.gatedBy)]" } else { '' }
        Write-Output ("     - {0,-20} deployment: {1}{2}" -f $e.status, $e.deployment, $gate)
        Write-Output ("       {0,-20} files: {1}" -f '', ($e.files -join ' > '))
    }
    foreach ($df in $G.diffs) {
        Write-Output ("       body diff A={0}  B={1}:" -f $df.a, $df.b)
        $lines = @($df.paths)
        foreach ($l in ($lines | Select-Object -First $diffLineLimit)) { Write-Output "         $l" }
        if ($lines.Count -gt $diffLineLimit) { Write-Output ("         ... {0} more" -f ($lines.Count - $diffLineLimit)) }
    }
}

Write-Output ''
Write-Output "Template:    $templatePath"
Write-Output ("Parameters:  {0}" -f $(if ($paramPath) { $paramPath } else { '(none: defaults only)' }))
Write-Output ("Walked {0} nested deployments, {1} resource declarations: {2} active, {3} gated-off, {4} condition-unresolved (counted as included), {5} with unresolved name/scope." -f `
        $walker.Deployments, $decls.Count, $nActive, $nGated, $nCondU, $unresolved.Count)
if ($walker.Notes.Count -gt 0) {
    Write-Output ''
    Write-Output 'Notes:'
    foreach ($n in ($walker.Notes | Select-Object -Unique)) { Write-Output "  - $n" }
}

$activeOut = @()
Write-Output ''
Write-Output ("ACTIVE DUPLICATES ({0} keys): declared 2+ times with conditions true or unresolved -> ResourceDeployedMultipleTimes" -f $active.Count)
foreach ($g in $active) { $f = Format-Group -Group $g -Kind 'active'; $activeOut += $f; Write-Group $f }

$latentOut = @()
Write-Output ''
Write-Output ("LATENT DUPLICATES ({0} keys): declared 2+ times but at most one declaration is enabled by these parameters" -f $latent.Count)
foreach ($g in $latent) { $f = Format-Group -Group $g -Kind 'latent'; $latentOut += $f; Write-Group $f }

if ($unresolved.Count -gt 0) {
    Write-Output ''
    Write-Output ("UNRESOLVED ({0} declarations, not compared and not guessed, because the name or scope is not statically resolvable):" -f $unresolved.Count)
    foreach ($d in $unresolved) {
        $chain = Resolve-FileChain -Root $templatePath -DeploymentPath $d.Path.ToArray()
        Write-Output ("  - [{0}] {1} {2}  ({3})  {4}" -f $d.Scope, $d.Type, $d.NameExpr, $d.Status, (Get-ShortPath -Path $chain[-1] -Base $base))
        $report.unresolved += [pscustomobject]@{ scope = $d.Scope; type = $d.Type; name = $d.NameExpr; status = $d.Status; deployment = ($d.Path -join '/'); declaredIn = (Get-ShortPath -Path $chain[-1] -Base $base) }
    }
}

# Informational. Unresolved declarations whose scope, type and unevaluated name expression are identical.
# Not counted (the name is not known statically), but usually the same resource declared twice.
$probable = @()
$byExpr = @{}
foreach ($d in $unresolved) {
    $ek = ($d.Scope + '|' + $d.ExtScope + '|' + $d.Type + '|' + $d.NameExpr).ToLowerInvariant()
    if (-not $byExpr.ContainsKey($ek)) { $byExpr[$ek] = New-Object System.Collections.Generic.List[object] }
    $byExpr[$ek].Add($d)
}
foreach ($ek in (Get-OrdinalSorted $byExpr.Keys)) {
    $grp = $byExpr[$ek]
    if ($grp.Count -lt 2) { continue }
    $probable += [pscustomobject]@{
        scope    = $grp[0].Scope
        type     = $grp[0].Type
        nameExpr = $grp[0].NameExpr
        counting = @($grp | Where-Object { $counting -contains $_.Status }).Count
        entries  = @($grp | ForEach-Object {
                $chain = Resolve-FileChain -Root $templatePath -DeploymentPath $_.Path.ToArray()
                [pscustomobject]@{ status = $_.Status; deployment = ($_.Path -join '/'); via = $(if ($chain.Count -gt 1) { Get-ShortPath -Path $chain[1] -Base $base } else { '' }); declaredIn = (Get-ShortPath -Path $chain[-1] -Base $base) }
            })
    }
}
if ($probable.Count -gt 0) {
    Write-Output ''
    Write-Output ("PROBABLE DUPLICATES WITH UNRESOLVED NAMES ({0}, informational, not counted), each with the same scope, type and name expression:" -f $probable.Count)
    foreach ($p in $probable) {
        Write-Output ("  [{0}] {1} {2}  ({3} counting)" -f $p.scope, $p.type, $p.nameExpr, $p.counting)
        foreach ($e in $p.entries) { Write-Output ("     - {0,-20} {1}  ({2} > {3})" -f $e.status, $e.deployment, $e.via, $e.declaredIn) }
    }
}
$report['probableUnresolvedDuplicates'] = $probable

# Informational. The same type + name declared in different scopes. Not an ARM error, but often a
# copy of one live resource placed in the wrong resource group (it would be CREATED there).
$crossScope = @()
$byTypeName = @{}
foreach ($d in $decls) {
    if (-not $d.Resolved) { continue }
    $tn = ($d.Type + '|' + $d.Name + '|' + $d.ExtScope).ToLowerInvariant()
    if (-not $byTypeName.ContainsKey($tn)) { $byTypeName[$tn] = New-Object System.Collections.Generic.List[object] }
    $byTypeName[$tn].Add($d)
}
foreach ($tn in (Get-OrdinalSorted $byTypeName.Keys)) {
    $grp = $byTypeName[$tn]
    $scopes = @($grp | ForEach-Object { $_.Scope.ToLowerInvariant() } | Select-Object -Unique)
    if ($scopes.Count -lt 2) { continue }
    $crossScope += [pscustomobject]@{
        type    = $grp[0].Type
        name    = $grp[0].Name
        entries = @($grp | ForEach-Object {
                $chain = Resolve-FileChain -Root $templatePath -DeploymentPath $_.Path.ToArray()
                [pscustomobject]@{ scope = $_.Scope; status = $_.Status; deployment = ($_.Path -join '/'); via = $(if ($chain.Count -gt 1) { Get-ShortPath -Path $chain[1] -Base $base } else { '' }) }
            })
    }
}
if ($crossScope.Count -gt 0) {
    Write-Output ''
    Write-Output ("SAME TYPE+NAME IN DIFFERENT SCOPES ({0}, informational, not counted). Check that each of these scopes really holds a live resource:" -f $crossScope.Count)
    foreach ($c in $crossScope) {
        Write-Output ("  {0} {1}" -f $c.type, $c.name)
        foreach ($e in $c.entries) { Write-Output ("     - [{0}] {1,-20} {2}  ({3})" -f $e.scope, $e.status, $e.deployment, $e.via) }
    }
}
$report['crossScopeSameName'] = $crossScope

# Summary by type and scope. The groups are printed by count, highest first, and by name in character-code
# order where counts tie. Group-Object returns groups in first-seen order on Windows PowerShell 5.1 and sorted
# by name on PowerShell 7, and Sort-Object keeps ties in input order, so a plain sort differs between the two.
# The comparer is cast to IComparer so that PowerShell calls Array.Sort(Array, Array, IComparer), which sorts the
# items in place. With a StringComparer it picks the generic overload, passes a converted copy of the items, and
# only the keys end up sorted.
function Write-OrderedGroups($gs) {
    $gs = @($gs); if ($gs.Count -eq 0) { return }
    $keys = [string[]]@($gs | ForEach-Object { '{0:0000000000}|{1}' -f (1000000000 - $_.Count), $_.Name })
    [Array]::Sort($keys, $gs, [Collections.IComparer][StringComparer]::Ordinal)
    foreach ($g in $gs) { Write-Output ("  {0,4}  {1}" -f $g.Count, $g.Name) }
}
function Write-Summary {
    param($Groups, [string]$Label)
    if (@($Groups).Count -eq 0) { return }
    Write-Output ''
    Write-Output "$Label by type:"
    Write-OrderedGroups ($Groups | Group-Object type)
    Write-Output "$Label by scope:"
    Write-OrderedGroups ($Groups | Group-Object { $_.scope.ToLowerInvariant() })
}
Write-Summary -Groups $activeOut -Label 'Active duplicates'
Write-Summary -Groups $latentOut -Label 'Latent duplicates'

$report.activeDuplicates = @($activeOut | ForEach-Object { $_ | Select-Object kind, scope, extScope, type, name, count, identical, @{ n = 'entries'; e = { @($_.entries | Select-Object status, gatedBy, deployment, files, condition) } }, diffs })
$report.latentDuplicates = @($latentOut | ForEach-Object { $_ | Select-Object kind, scope, extScope, type, name, count, identical, @{ n = 'entries'; e = { @($_.entries | Select-Object status, gatedBy, deployment, files, condition) } }, diffs })
if ($DeclarationsCsv) {
    $decls | ForEach-Object {
        $chain = Resolve-FileChain -Root $templatePath -DeploymentPath $_.Path.ToArray()
        [pscustomobject]@{
            scope      = $_.Scope
            extScope   = $_.ExtScope
            type       = $_.Type
            name       = $_.Name
            resolved   = $_.Resolved
            status     = $_.Status
            gatedBy    = $_.GatedBy
            deployment = ($_.Path -join '/')
            viaFile    = $(if ($chain.Count -gt 1) { Get-ShortPath -Path $chain[1] -Base $base } else { '' })
            declaredIn = (Get-ShortPath -Path $chain[-1] -Base $base)
            key        = $_.Key
        }
    } | Export-Csv -LiteralPath $DeclarationsCsv -NoTypeInformation -Encoding $utf8Bom
    Write-Output "Declarations CSV: $DeclarationsCsv"
}
if ($OutJson) {
    # In PS 5.1 the System.Array ETS 'Count' member makes ConvertTo-Json emit {"value":[...],"Count":n}.
    Remove-TypeData -TypeName System.Array -ErrorAction SilentlyContinue
    $report | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $OutJson -Encoding $utf8Bom
    Write-Output ''
    Write-Output "JSON report: $OutJson"
}

Write-Output ''
$fail = $active.Count -gt 0
Write-Output ("RESULT: {0} active duplicate key(s), {1} latent duplicate key(s), {2} unresolved declaration(s). {3}" -f `
        $active.Count, $latent.Count, $unresolved.Count, $(if ($fail) { 'FAIL' } else { 'OK' }))
if ($fail) { exit 1 }
exit 0
