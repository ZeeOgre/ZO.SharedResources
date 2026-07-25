
Add cmdline switch to preserve parent .MAT files
Jul 23
·
DevModManager
·
…add-cmdline-switch-to-preserve-parent-.mat-files
·
+85
-43

Archive

Share
View PR


New update for DevModManager:
https://github.com/ZeeOgre/SharedResources/blob/main/scripts/StarfieldArchiveManager.ps1
https://github.com/ZeeOgre/DevModManager/tree/main/DMM.Standalone.DependencyChecker

we need a cmdline switch (thinking --preserve-parent-mat)
and a checkbox on archive manager to drive it.

When this is selected, dmmdeps should alter its behavior slightly when scanning for parent files.

a parent .MAT file should be added (without further walking) to the .achlist/backup/zip list when this switch is selected

so in my example I have a kitbashed nif, which consists solely of vanilla .mat resources

we have a suspicion that despite this, the .mat's aren't "picking up" by the game engine

see chat https://chatgpt.com/c/6a614327-e6f0-83ea-93e0-5c754a83418b starting today about 2:05 pm for further details and screenshots of problems we're encountering.

Our current working theory is that by adding the .mat files to the mod .ba2, the engine will pick them up and render them correctly -- whereas in the development environment those files were available as loose files out in the game folders
Copy
Summary

Added the --preserve-parent-mat dmmdeps switch. It identifies parent-archive MAT files before MAT dependency traversal, avoids walking their referenced textures, and keeps matching MATs in the generated achlist instead of the warning list. 

Added a persisted Preserve parent .MAT files checkbox to Starfield Archive Manager and forward its selected value to dmmdeps as --preserve-parent-mat. 

Added the default configuration entry for the new archive-manager option. 

Committed the changes on the current branch: 2d497fa Preserve parent MAT files in archives.

Testing

✅ dotnet build DMM.Standalone.DependencyChecker/DMM.Standalone.DependencyChecker.csproj -v:minimal

✅ dotnet run --project DMM.Standalone.DependencyChecker/DMM.Standalone.DependencyChecker.csproj --no-build -- --preserve-parent-mat

✅ git diff --check

⚠️ pwsh --version (PowerShell is not installed in this Linux environment, so the WinForms script could not receive a runtime syntax/UI check.)


Files (3)

Program.cs
DMM.Standalone.DependencyChecker/Program.cs
+50
-23

StarfieldArchiveManager.ini
_references/dmmdep_wrapper_script/StarfieldArchiveManager.ini
+1
-0

StarfieldArchiveManager.ps1
_references/dmmdep_wrapper_script/StarfieldArchiveManager.ps1
+34
-20



Diff
Logs

DMM.Standalone.DependencyChecker/Program.cs
DMM.Standalone.DependencyChecker/Program.cs
+50
-23

@@ -36,50 +36,51 @@ namespace DmmDep
    [JsonSourceGenerationOptions(WriteIndented = true)]
    [JsonSerializable(typeof(string[]))]
    [JsonSerializable(typeof(DependencyManifest))]
    internal partial class AchlistSerializerContext : JsonSerializerContext
    {
    }

    internal sealed class Options
    {
        public string PluginPath { get; set; } = "";
        public string? GameRootOverride { get; set; }
        public string? XboxDataOverride { get; set; }
        public string? PS5DataOverride { get; set; }
        public string? TifRootOverride { get; set; } = "..\\..\\Source\\TGATextures";
        public string? ScriptsRootOverride { get; set; } = "Scripts";
        public bool TestMode { get; set; } // --test switch

        // New switches
        public bool Quiet { get; set; }   // --quiet : suppress skipped-file messages
        public bool Silent { get; set; }  // --silent: only show start and completion
        public bool Verbose { get; set; } // --verbose: emit detailed ignored-file diagnostics

        public bool SmartClobber { get; set; } // --smartclobber : seed candidates from existing .achlist
        public bool RebuildCache { get; set; } // --rebuildcache : force rebuild of parent archive cache
        public bool IncludePsc { get; set; }    // --include-psc : include .psc source files in achlist
        public bool PreserveParentMat { get; set; } // --preserve-parent-mat : package parent MATs without scanning their dependencies
    }

    internal static class Program
    {
        // runtime flags populated from options
        private static bool s_quiet = false;
        private static bool s_silent = false;
        private static bool s_verbose = false;

        // logger helpers honoring --quiet / --silent
        private static class Log
        {
            public static void Info(string message, bool isSkipped = false)
            {
                if (s_silent) return;
                if (isSkipped && s_quiet) return;
                Console.WriteLine(message);
            }

            public static void Warn(string message)
            {
                if (s_silent) return;
                Console.WriteLine(message);
            }

@@ -577,73 +578,108 @@ namespace DmmDep
                            }
                        }
                        else if (!token.Contains('.') && token.Contains("\\"))
                        {
                            string stem = token.TrimStart('\\');

                            int nullChar = stem.IndexOf('\0');
                            if (nullChar >= 0)
                            {
                                stem = stem.Substring(0, nullChar);
                            }
                            stem = stem.TrimEnd();

                            string meshRel = stem.StartsWith("geometries\\", StringComparison.OrdinalIgnoreCase)
                                ? NormalizeRel(Path.Combine("Data", stem + ".mesh"))
                                : NormalizeRel(Path.Combine("Data\\geometries", stem + ".mesh"));

                            if (File.Exists(Path.Combine(gameRoot, meshRel)))
                            {
                                AddFile(manifest, achlistPaths, meshRel, FileKind.Mesh, $"nif:{nifRel}", gameRoot, xboxDataRoot);
                            }
                        }
                    }
                }

                // Load the parent index before walking MAT dependencies so --preserve-parent-mat
                // can retain a parent material itself without adding its referenced textures.
                var masterPlugins = ParentArchiveCache.ParsePluginMasters(pluginPath);
                if (masterPlugins.Count > 0)
                {
                    Log.Info($"[2.5] Found {masterPlugins.Count} master plugin(s): {string.Join(", ", masterPlugins)}");
                }
                else
                {
                    Log.Info("[2.5] No master plugins found");
                }

                if (options.RebuildCache)
                {
                    Log.Info("[2.5] --rebuildcache: Clearing existing cache...");
                    ParentArchiveCache.ClearCache();
                }

                var parentArchiveIndex = ParentArchiveCache.GetOrBuildIndex(
                    gameRoot,
                    masterPlugins,
                    msg => Log.Info(msg)
                );
                Log.Info($"[2.5] Parent archive index loaded: {parentArchiveIndex.Count} files indexed");

                // ---- 3. MATs -> DDS ----
                Log.Info("[3] Scanning MATs for DDS tokens (via JSON File/FileName)...");

                int matsWithCustom = 0;
                int matsWithoutCustom = 0;
                int totalDdsHits = 0;

                foreach (var matRel in matRelPaths)
                {
                    string fullMat = Path.Combine(gameRoot, matRel);
                    if (!File.Exists(fullMat))
                    {
                        AddIgnoredFileNotFound(manifest, matRel, "mat-missing-on-disk");
                        if (s_verbose)
                            Log.Warn($"[verbose] Ignored MAT (file not found): {matRel}");
                        continue;
                    }

                    // Keep MATs that are explicitly referenced and present on disk,
                    // even when they do not point to custom DDS files. Material parameter
                    // edits can still be meaningful without custom textures.
                    AddFile(manifest, achlistPaths, matRel, FileKind.Mat, "mat-referenced", gameRoot, xboxDataRoot);

                    string normalizedMatPath = matRel.Replace('/', '\\').Trim('\\').ToLowerInvariant();
                    if (!normalizedMatPath.StartsWith("data\\", StringComparison.Ordinal))
                        normalizedMatPath = "data\\" + normalizedMatPath;

                    if (options.PreserveParentMat && parentArchiveIndex.ContainsKey(normalizedMatPath))
                    {
                        Log.Info($"[3] Preserving parent MAT without walking dependencies: {matRel}");
                        continue;
                    }

                    string matText = File.ReadAllText(fullMat);
                    var found = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
                    bool hasCustomTextures = false;

                    List<string> ddsTokens = new();
                    try
                    {
                        using var doc = JsonDocument.Parse(matText);
                        CollectMatDdsTokensFromJson(doc.RootElement, ddsTokens);
                    }
                    catch
                    {
                        var ddsAnyRegex = new Regex(@"([A-Za-z0-9_\\/\-\.]+\.dds)\b", RegexOptions.IgnoreCase);
                        foreach (Match m in ddsAnyRegex.Matches(matText))
                            ddsTokens.Add(m.Groups[1].Value);
                    }

                    foreach (var raw in ddsTokens)
                    {
                        string? ddsRel = NormalizeDdsPathFromMat(raw);
                        if (ddsRel == null)
                            continue;

                        string fullTexPc = Path.Combine(gameRoot, ddsRel);
                        bool pcExists = File.Exists(fullTexPc);
@@ -764,71 +800,50 @@ namespace DmmDep
                    foreach (Match m in importRegex.Matches(text))
                    {
                        string importName = m.Groups[1].Value.Trim();

                        string impPscRel = ToPscRel(importName);
                        string impPexRel = ToPexRel(importName);

                        if (File.Exists(Path.Combine(gameRoot, impPscRel)) && pscSet.Add(impPscRel))
                        {
                            if (options.IncludePsc)
                                AddFile(manifest, achlistPaths, impPscRel, FileKind.Psc, "psc-import", gameRoot, xboxDataRoot);
                            else
                                AddBackupOnlyFile(manifest, impPscRel, "psc-import");
                        }

                        if (File.Exists(Path.Combine(gameRoot, impPexRel)) && pexSet.Add(impPexRel))
                            AddFile(manifest, achlistPaths, impPexRel, FileKind.Pex, "pex-from-psc-import", gameRoot, xboxDataRoot);
                    }
                }

                Log.Info($"[6] After PSC imports: {pscSet.Count} PSC, {pexSet.Count} PEX");

                // ---- 7. Check for parent archive matches using cached index ----
                Log.Info("[7] Loading parent archive index (cached)...");

                // Parse master plugins from the plugin file
                var masterPlugins = ParentArchiveCache.ParsePluginMasters(pluginPath);
                if (masterPlugins.Count > 0)
                {
                    Log.Info($"[7] Found {masterPlugins.Count} master plugin(s): {string.Join(", ", masterPlugins)}");
                }
                else
                {
                    Log.Info("[7] No master plugins found");
                }

                if (options.RebuildCache)
                {
                    Log.Info("[7] --rebuildcache: Clearing existing cache...");
                    ParentArchiveCache.ClearCache();
                }
                var parentArchiveIndex = ParentArchiveCache.GetOrBuildIndex(
                    gameRoot,
                    masterPlugins,
                    msg => Log.Info(msg)
                );
                Log.Info($"[7] Parent archive index loaded: {parentArchiveIndex.Count} files indexed");

                // Mark files that match parent archives
                int parentMatchCount = 0;
                var sampleMatches = new List<string>();
                var sampleMisses = new List<string>();

                foreach (var file in manifest.Files.ToList())
                {
                    if (file.Kind != "missing" && !file.Source.StartsWith("ignored-filenotfound:", StringComparison.OrdinalIgnoreCase))
                    {
                        // Normalize path for parent archive lookup:
                        // - Replace / with \
                        // - Ensure Data\ prefix
                        // - Lowercase for case-insensitive comparison
                        string normalizedPath = file.PcPath.Replace('/', '\\').Trim('\\');
                        if (!normalizedPath.StartsWith("Data\\", StringComparison.OrdinalIgnoreCase))
                            normalizedPath = "Data\\" + normalizedPath;
                        normalizedPath = normalizedPath.ToLowerInvariant();

                        if (parentArchiveIndex.ContainsKey(normalizedPath))
                        {
                            string archiveName = parentArchiveIndex[normalizedPath];

                            // Update kind to ParentMatch
@@ -879,52 +894,60 @@ namespace DmmDep
                var achlistDiscard = new HashSet<string>(StringComparer.OrdinalIgnoreCase);

                // Log manifest file kinds for diagnostics
                if (s_verbose)
                {
                    var kindCounts = manifest.Files
                        .GroupBy(f => f.Kind)
                        .Select(g => $"{g.Key}={g.Count()}")
                        .ToList();
                    Log.Info($"[Manifest Kinds] {string.Join(", ", kindCounts)}");
                }

                // Categorize files from manifest
                foreach (var file in manifest.Files)
                {
                    if (string.IsNullOrWhiteSpace(file.PcPath))
                        continue;

                    if (file.Kind == "missing" || file.Source.StartsWith("ignored-filenotfound:", StringComparison.OrdinalIgnoreCase))
                    {
                        // Files referenced but not found on disk go to discard
                        achlistDiscard.Add(file.PcPath);
                    }
                    else if (file.Kind == "parentmatch")
                    {
                        // Files that match parent archives go to warn list
                        achlistWarn.Add(file.PcPath);
                        if (options.PreserveParentMat && file.PcPath.EndsWith(".mat", StringComparison.OrdinalIgnoreCase))
                        {
                            // Explicitly retain a parent material so Archive2 and backup/zip consume it.
                            achlistKeep.Add(file.PcPath);
                        }
                        else
                        {
                            // Files that match parent archives go to warn list.
                            achlistWarn.Add(file.PcPath);
                        }
                    }
                    else if (file.Kind == "warn")
                    {
                        // Warn files (unclassified extensions, etc.) go to warn list
                        achlistWarn.Add(file.PcPath);
                    }
                    else if (file.Kind == "backuponly")
                    {
                        // Backup files are never included in achlist (PSC source, TIF source, etc.)
                        // They are tracked for backup purposes but not distributed
                        continue;
                    }
                    else
                    {
                        // All other files go to keep
                        achlistKeep.Add(file.PcPath);
                    }
                }

                Log.Info($"[Categorization] Keep={achlistKeep.Count}, Warn={achlistWarn.Count}, Discard={achlistDiscard.Count}");

                // ---- Outputs ----
                string achlistFileName = pluginName + (options.TestMode ? ".achlist.test" : ".achlist");
                string achlistPath = Path.Combine(outputRoot, achlistFileName);
                WriteAchlistJsonAsciiCrLf(achlistPath, achlistKeep.OrderBy(p => p, StringComparer.OrdinalIgnoreCase));
@@ -965,50 +988,51 @@ namespace DmmDep

        private static void PrintUsage()
        {
            Console.WriteLine("dmmdep.exe <pluginPath> [options]");
            Console.WriteLine();
            Console.WriteLine("Outputs:");
            Console.WriteLine("  <plugin>.achlist         Files to include (exist on disk, referenced by plugin)");
            Console.WriteLine("  <plugin>.achlist_warn    Files with warnings (unclassified or questionable)");
            Console.WriteLine("  <plugin>.achlist_discard Files to discard (referenced but not found on disk)");
            Console.WriteLine("  <plugin>_deps.csv        Dependency manifest (CSV format)");
            Console.WriteLine("  <plugin>_deps.json       Dependency manifest (JSON format, unless --silent)");
            Console.WriteLine();
            Console.WriteLine("Options:");
            Console.WriteLine("  --gameroot <path>     Override inferred game root (parent of Data).");
            Console.WriteLine("  --xboxdata <path>     Override XBOX Data root (default from CreationKit.ini).");
            Console.WriteLine("  --ps5data <path>      Override PS5 Data root (default <GameRoot>\\PS5\\Data).");
            Console.WriteLine("  --tifroot <path>      Override TIF root (default ..\\..\\Source\\TGATextures).");
            Console.WriteLine("  --scriptsroot <path>  Override Data\\Scripts root.");
            Console.WriteLine("  --test                Write .achlist.test instead of .achlist.");
            Console.WriteLine("  --quiet               Suppress output about skipped files (e.g. 'Skipping MAT').");
            Console.WriteLine("  --silent              Suppress all informational output except starting and completion.");
            Console.WriteLine("  --verbose             Emit detailed ignored/missing-file diagnostics and record ignored-filenotfound entries in deps outputs.");
            Console.WriteLine("  --smartclobber        Seed candidates from existing .achlist (captures manual overrides like Data\\Interface\\mapicons.swf).");
            Console.WriteLine("  --rebuildcache        Force rebuild of parent archive cache (useful if game updated).");
            Console.WriteLine("  --include-psc         Include .psc script source files in achlist (for distributing source code).");
            Console.WriteLine("  --preserve-parent-mat Include parent-archive .mat files in achlist without scanning their referenced files.");
        }

        private static Options? ParseArgs(string[] args)
        {
            var opts = new Options();
            int i = 0;

            if (!args[0].StartsWith("-", StringComparison.Ordinal))
            {
                opts.PluginPath = args[0];
                i = 1;
            }

            for (; i < args.Length; i++)
            {
                string arg = args[i];
                switch (arg.ToLowerInvariant())
                {
                    case "--gameroot":
                        if (++i >= args.Length) return null;
                        opts.GameRootOverride = args[i];
                        break;
                    case "--xboxdata":
                        if (++i >= args.Length) return null;
                        opts.XboxDataOverride = args[i];
@@ -1024,50 +1048,53 @@ namespace DmmDep
                    case "--scriptsroot":
                        if (++i >= args.Length) return null;
                        opts.ScriptsRootOverride = args[i];
                        break;
                    case "--test":
                        opts.TestMode = true;
                        break;
                    case "--quiet":
                        opts.Quiet = true;
                        break;
                    case "--silent":
                        opts.Silent = true;
                        break;
                    case "--smartclobber":
                        opts.SmartClobber = true;
                        break;
                    case "--rebuildcache":
                        opts.RebuildCache = true;
                        break;
                    case "--verbose":
                        opts.Verbose = true;
                        break;
                    case "--include-psc":
                        opts.IncludePsc = true;
                        break;
                    case "--preserve-parent-mat":
                        opts.PreserveParentMat = true;
                        break;
                    default:
                        Console.Error.WriteLine($"Unknown option: {arg}");
                        return null;
                }
            }

            if (string.IsNullOrWhiteSpace(opts.PluginPath))
                return null;

            // if --silent is set, it implies --quiet
            if (opts.Silent)
                opts.Quiet = true;

            return opts;
        }

        private static string? FindCreationKitIni(string gameRoot)
        {
            string custom = Path.Combine(gameRoot, "CreationKitCustom.ini");
            if (File.Exists(custom)) return custom;
            string ini = Path.Combine(gameRoot, "CreationKit.ini");
            return File.Exists(ini) ? ini : null;
        }

        private static string InferXboxDataRoot(string gameRoot, string? iniPath)
_references/dmmdep_wrapper_script/StarfieldArchiveManager.ini
_references/dmmdep_wrapper_script/StarfieldArchiveManager.ini
+1
-0

﻿VoiceFolderUpdate=True
DataFolder=G:\SteamLibrary\steamapps\common\Starfield\Data
SmartClobber=False
PreserveParentMat=False
InputFile=G:\SteamLibrary\steamapps\common\Starfield\Data\dmf_ZEO.esp
XboxArchive=True
BackupFolder=G:\SyncShare\GameDriveShare\mod_backups
WindowsArchive=True
ArchiverPath=G:\SteamLibrary\steamapps\common\Starfield\Tools\Archive2\Archive2.exe
UseDmmdeps=True
Zip=True
RebuildAchlist=True
DmmdepsPath=G:\gitrepos\moddersmilk\zeeogre\devmodmanager\DMM.Standalone.DependencyChecker\publish\framework-dependent\win-x64\DMM.Standalone.DependencyChecker.exe
CleanCopy=True
SortAchlist=True
XboxFolder=G:\SteamLibrary\steamapps\common\Starfield\XBOX\Data
Copy=True
_references/dmmdep_wrapper_script/StarfieldArchiveManager.ps1
_references/dmmdep_wrapper_script/StarfieldArchiveManager.ps1
+34
-20

Large diff
492 lines

Load diff
