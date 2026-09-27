#:package Gherkin@42.0.1

// Verifies that every scenario declared in the .feature files on disk was executed and passed,
// reading the Cucumber Messages (NDJSON) written by the BDD runner during the test run.
// Exit codes: 0 verified, 1 not verified, 2 invalid invocation or unreadable input.

using System.Text;
using System.Text.Json;
using Gherkin;

Console.OutputEncoding = Encoding.UTF8;

try
{
    var options = CoverageOptions.Parse(args);
    var corpus = FeatureCorpus.Load(options.Root);
    var runs = RunLog.Load(options.Root, options.MessagesFile, corpus);
    var report = CoverageReport.Compare(corpus, runs);
    report.Print(options.Root);
    if (options.SummaryPath is not null)
        File.WriteAllText(options.SummaryPath, report.ToMarkdown(options.Root));
    return report.IsVerified ? 0 : 1;
}
catch (InvalidInputException error)
{
    Console.Error.WriteLine($"ERRORE {error.Message}");
    return 2;
}

sealed class InvalidInputException(string message) : Exception(message);

sealed record CoverageOptions(string Root, string MessagesFile, string? SummaryPath)
{
    const string Usage = "uso: ScenarioCoverage.cs --root <cartella> --messages-file <suffisso/del/file.ndjson> [--summary <file.md>]";

    public static CoverageOptions Parse(string[] args)
    {
        var values = ReadPairs(args);
        var root = Required(values, "--root");
        if (!Directory.Exists(root))
            throw new InvalidInputException($"la cartella --root non esiste: {root}");
        return new CoverageOptions(
            Paths.Normalize(Path.GetFullPath(root)),
            Paths.Normalize(Required(values, "--messages-file")).TrimStart('/'),
            values.GetValueOrDefault("--summary"));
    }

    static Dictionary<string, string> ReadPairs(string[] args)
    {
        if (args.Length % 2 != 0)
            throw new InvalidInputException(Usage);
        var values = new Dictionary<string, string>();
        for (var i = 0; i < args.Length; i += 2)
        {
            if (args[i] is not ("--root" or "--messages-file" or "--summary"))
                throw new InvalidInputException($"opzione sconosciuta {args[i]}. {Usage}");
            values[args[i]] = args[i + 1];
        }
        return values;
    }

    static string Required(Dictionary<string, string> values, string name) =>
        values.TryGetValue(name, out var value) && value.Length > 0
            ? value
            : throw new InvalidInputException($"manca {name}. {Usage}");
}

static class Paths
{
    // Build outputs are pruned only for the .feature scan: a feature copied next to the binaries would count twice.
    static readonly HashSet<string> NeverScanned = new(StringComparer.OrdinalIgnoreCase) { "node_modules" };
    static readonly HashSet<string> BuildOutputs = new(StringComparer.OrdinalIgnoreCase) { "bin", "obj" };

    public static string Normalize(string path) => path.Replace('\\', '/');

    public static string Relative(string root, string path) =>
        path.StartsWith(root + "/", StringComparison.Ordinal) ? path[(root.Length + 1)..] : path;

    public static IEnumerable<string> SourceFiles(string root, string pattern) => Walk(root, pattern, skipBuildOutputs: true);

    public static IEnumerable<string> AllFiles(string root, string pattern) => Walk(root, pattern, skipBuildOutputs: false);

    static IEnumerable<string> Walk(string directory, string pattern, bool skipBuildOutputs)
    {
        foreach (var file in Directory.EnumerateFiles(directory, pattern).Order(StringComparer.Ordinal))
            yield return Normalize(Path.GetFullPath(file));
        foreach (var child in Directory.EnumerateDirectories(directory).Order(StringComparer.Ordinal))
        {
            var name = Path.GetFileName(child);
            if (name.StartsWith('.') || NeverScanned.Contains(name) || (skipBuildOutputs && BuildOutputs.Contains(name)))
                continue;
            foreach (var file in Walk(child, pattern, skipBuildOutputs))
                yield return file;
        }
    }
}

sealed record ScenarioKey(string FeaturePath, int ScenarioLine, int ExampleLine)
{
    public int Line => ExampleLine > 0 ? ExampleLine : ScenarioLine;
}

sealed record ExpectedScenario(ScenarioKey Key, string Name, bool Ignored);

sealed record Finding(string FeaturePath, int Line, string Name, string Reason);

sealed class FeatureCorpus
{
    const string IgnoreTag = "@ignore";

    public List<string> FeaturePaths { get; } = [];
    public List<ExpectedScenario> Scenarios { get; } = [];
    public List<Finding> Defects { get; } = [];

    public static FeatureCorpus Load(string root)
    {
        var corpus = new FeatureCorpus();
        foreach (var path in Paths.SourceFiles(root, "*.feature"))
            corpus.Add(path);
        return corpus;
    }

    void Add(string path)
    {
        FeaturePaths.Add(path);
        Gherkin.Ast.GherkinDocument document;
        try
        {
            document = new Parser().Parse(path);
        }
        catch (ParserException error)
        {
            Defects.Add(new Finding(path, 0, "", $"Gherkin non valido: {error.Message}"));
            return;
        }
        if (document.Feature is null)
        {
            Defects.Add(new Finding(path, 0, "", "nessuna Funzionalità dichiarata"));
            return;
        }
        var featureTags = Tags(document.Feature.Tags).ToList();
        foreach (var child in document.Feature.Children)
            AddChild(path, child, featureTags);
    }

    void AddChild(string path, Gherkin.Ast.IHasLocation child, IReadOnlyList<string> inheritedTags)
    {
        switch (child)
        {
            case Gherkin.Ast.Rule rule:
                var ruleTags = inheritedTags.Concat(Tags(rule.Tags)).ToList();
                foreach (var ruleChild in rule.Children)
                    AddChild(path, ruleChild, ruleTags);
                break;
            case Gherkin.Ast.Scenario scenario:
                AddScenario(path, scenario, inheritedTags.Concat(Tags(scenario.Tags)).ToList());
                break;
        }
    }

    // Mirrors the Gherkin pickle compiler: a scenario with Examples yields one pickle per table row.
    void AddScenario(string path, Gherkin.Ast.Scenario scenario, IReadOnlyList<string> tags)
    {
        var line = scenario.Location.Line;
        if (!scenario.Examples.Any())
        {
            Scenarios.Add(new ExpectedScenario(new ScenarioKey(path, line, 0), scenario.Name, IsIgnored(tags)));
            return;
        }
        var rows = scenario.Examples
            .SelectMany(examples => (examples.TableBody ?? []).Select(row => (row, tags: tags.Concat(Tags(examples.Tags)).ToList())))
            .ToList();
        if (rows.Count == 0)
            Defects.Add(new Finding(path, line, scenario.Name, "schema dello scenario senza righe di esempio"));
        foreach (var (row, rowTags) in rows)
            Scenarios.Add(new ExpectedScenario(new ScenarioKey(path, line, row.Location.Line), scenario.Name, IsIgnored(rowTags)));
    }

    static IEnumerable<string> Tags(IEnumerable<Gherkin.Ast.Tag> tags) => tags.Select(tag => tag.Name);

    static bool IsIgnored(IEnumerable<string> tags) => tags.Any(tag => tag.Equals(IgnoreTag, StringComparison.OrdinalIgnoreCase));
}

static class StepStatus
{
    public const string Passed = "PASSED";
    public const string NoSteps = "NO_STEPS";
    public const string Interrupted = "INTERRUPTED";

    static readonly string[] BySeverity =
        [Passed, "SKIPPED", "PENDING", "UNDEFINED", "AMBIGUOUS", NoSteps, Interrupted, "FAILED", "UNKNOWN"];

    public static string Worst(IEnumerable<string> statuses) => statuses.MaxBy(Severity) ?? NoSteps;

    static int Severity(string status)
    {
        var index = Array.IndexOf(BySeverity, status);
        return index < 0 ? BySeverity.Length : index;
    }

    public static string Describe(string status) => status switch
    {
        "FAILED" => "fallito",
        "UNDEFINED" => "frase senza binding",
        "PENDING" => "step pending",
        "AMBIGUOUS" => "binding ambiguo",
        "SKIPPED" => "saltato a runtime senza @ignore",
        NoSteps => "eseguito senza alcuno step",
        Interrupted => "avviato e mai concluso",
        _ => $"esito {status}",
    };
}

sealed class RunLog
{
    public int FileCount { get; private set; }
    public Dictionary<ScenarioKey, List<string>> Outcomes { get; } = [];
    public List<Finding> Orphans { get; } = [];

    public static RunLog Load(string root, string messagesFile, FeatureCorpus corpus)
    {
        var log = new RunLog();
        foreach (var file in Paths.AllFiles(root, Path.GetFileName(messagesFile)).Where(file => file.EndsWith("/" + messagesFile, StringComparison.Ordinal)))
        {
            log.FileCount++;
            log.Merge(file, MessagesFile.Read(file), corpus);
        }
        return log;
    }

    void Merge(string file, MessagesFile messages, FeatureCorpus corpus)
    {
        foreach (var (pickleId, statuses) in messages.OutcomesByPickle())
        {
            var pickle = messages.Pickles[pickleId];
            var featurePath = ResolveFeature(file, pickle.Uri, corpus);
            if (featurePath is null)
            {
                Orphans.Add(new Finding(pickle.Uri, 0, pickle.Name, $"eseguito ma assente dai .feature sotto la root ({Paths.Normalize(file)})"));
                continue;
            }
            var key = new ScenarioKey(featurePath, messages.LineOf(pickle.Uri, pickle.ScenarioId), pickle.ExampleId is null ? 0 : messages.LineOf(pickle.Uri, pickle.ExampleId));
            if (!Outcomes.TryGetValue(key, out var outcomes))
                Outcomes[key] = outcomes = [];
            outcomes.AddRange(statuses);
        }
    }

    // A message uri is relative to its project: the deepest project directory holding the messages file wins.
    static string? ResolveFeature(string messagesFile, string uri, FeatureCorpus corpus) =>
        corpus.FeaturePaths
            .Where(path => path.EndsWith("/" + uri, StringComparison.Ordinal))
            .Select(path => (path, projectRoot: path[..^uri.Length]))
            .Where(candidate => messagesFile.StartsWith(candidate.projectRoot, StringComparison.Ordinal))
            .OrderByDescending(candidate => candidate.projectRoot.Length)
            .Select(candidate => candidate.path)
            .FirstOrDefault();
}

sealed record PickleMessage(string Uri, string Name, string ScenarioId, string? ExampleId, int StepCount);

sealed class MessagesFile
{
    public Dictionary<string, PickleMessage> Pickles { get; } = [];
    readonly Dictionary<(string Uri, string NodeId), int> lines = [];
    readonly Dictionary<string, string> pickleByTestCase = [];
    readonly Dictionary<string, string> testCaseByAttempt = [];
    readonly Dictionary<string, List<string>> stepStatusesByAttempt = [];
    readonly Dictionary<string, bool> retriedByAttempt = [];

    public static MessagesFile Read(string path)
    {
        var messages = new MessagesFile();
        var number = 0;
        foreach (var line in File.ReadLines(path, Encoding.UTF8))
        {
            number++;
            if (string.IsNullOrWhiteSpace(line))
                continue;
            try
            {
                using var envelope = JsonDocument.Parse(line);
                messages.Accept(envelope.RootElement);
            }
            catch (Exception error) when (error is JsonException or KeyNotFoundException or InvalidOperationException)
            {
                throw new InvalidInputException($"{Paths.Normalize(path)}:{number} non è un Cucumber Message leggibile: {error.Message}");
            }
        }
        return messages;
    }

    void Accept(JsonElement envelope)
    {
        if (envelope.TryGetProperty("gherkinDocument", out var document))
            IndexLines(document.GetProperty("uri").GetString()!, document.GetProperty("feature"));
        else if (envelope.TryGetProperty("pickle", out var pickle))
            AddPickle(pickle);
        else if (envelope.TryGetProperty("testCase", out var testCase))
            pickleByTestCase[testCase.GetProperty("id").GetString()!] = testCase.GetProperty("pickleId").GetString()!;
        else if (envelope.TryGetProperty("testCaseStarted", out var started))
            StartAttempt(started);
        else if (envelope.TryGetProperty("testStepFinished", out var step))
            stepStatusesByAttempt[step.GetProperty("testCaseStartedId").GetString()!]
                .Add(step.GetProperty("testStepResult").GetProperty("status").GetString()!);
        else if (envelope.TryGetProperty("testCaseFinished", out var finished))
            retriedByAttempt[finished.GetProperty("testCaseStartedId").GetString()!] = finished.TryGetProperty("willBeRetried", out var retried) && retried.GetBoolean();
    }

    void StartAttempt(JsonElement started)
    {
        var attempt = started.GetProperty("id").GetString()!;
        testCaseByAttempt[attempt] = started.GetProperty("testCaseId").GetString()!;
        stepStatusesByAttempt[attempt] = [];
    }

    void AddPickle(JsonElement pickle)
    {
        var astNodeIds = pickle.GetProperty("astNodeIds").EnumerateArray().Select(id => id.GetString()!).ToList();
        Pickles[pickle.GetProperty("id").GetString()!] = new PickleMessage(
            pickle.GetProperty("uri").GetString()!,
            pickle.GetProperty("name").GetString()!,
            astNodeIds[0],
            astNodeIds.Count > 1 ? astNodeIds[1] : null,
            pickle.GetProperty("steps").GetArrayLength());
    }

    void IndexLines(string uri, JsonElement node)
    {
        if (node.ValueKind == JsonValueKind.Object)
        {
            if (node.TryGetProperty("id", out var id) && node.TryGetProperty("location", out var location))
                lines[(uri, id.GetString()!)] = location.GetProperty("line").GetInt32();
            foreach (var property in node.EnumerateObject())
                IndexLines(uri, property.Value);
        }
        else if (node.ValueKind == JsonValueKind.Array)
        {
            foreach (var item in node.EnumerateArray())
                IndexLines(uri, item);
        }
    }

    public int LineOf(string uri, string nodeId) =>
        lines.TryGetValue((uri, nodeId), out var line)
            ? line
            : throw new InvalidInputException($"il pickle di {uri} riferisce il nodo {nodeId}, assente dal gherkinDocument");

    public IEnumerable<(string PickleId, List<string> Statuses)> OutcomesByPickle() =>
        testCaseByAttempt
            .Where(attempt => !retriedByAttempt.GetValueOrDefault(attempt.Key))
            .GroupBy(attempt => pickleByTestCase[attempt.Value], attempt => OutcomeOf(attempt.Key))
            .Select(group => (group.Key, group.ToList()));

    string OutcomeOf(string attempt)
    {
        if (!retriedByAttempt.ContainsKey(attempt))
            return StepStatus.Interrupted;
        var statuses = stepStatusesByAttempt[attempt];
        return statuses.Count == 0 ? StepStatus.NoSteps : StepStatus.Worst(statuses);
    }
}

sealed class CoverageReport
{
    public List<Finding> Problems { get; } = [];
    public List<ExpectedScenario> Pending { get; } = [];
    public int Expected { get; private set; }
    public int Verified { get; private set; }
    public int FeatureCount { get; private set; }
    public int MessagesFileCount { get; private set; }

    public bool IsVerified => Problems.Count == 0;

    public static CoverageReport Compare(FeatureCorpus corpus, RunLog runs)
    {
        var report = new CoverageReport
        {
            Expected = corpus.Scenarios.Count,
            FeatureCount = corpus.FeaturePaths.Count,
            MessagesFileCount = runs.FileCount,
        };
        report.Problems.AddRange(corpus.Defects);
        foreach (var scenario in corpus.Scenarios)
            report.Judge(scenario, runs.Outcomes.GetValueOrDefault(scenario.Key));
        report.Problems.AddRange(runs.Orphans);
        report.Problems.AddRange(runs.Outcomes.Keys
            .Except(corpus.Scenarios.Select(scenario => scenario.Key))
            .Select(key => new Finding(key.FeaturePath, key.Line, "", "eseguito ma assente dal .feature attuale: build non allineata ai sorgenti")));
        return report;
    }

    void Judge(ExpectedScenario scenario, List<string>? outcomes)
    {
        if (outcomes is null)
        {
            if (scenario.Ignored)
                Pending.Add(scenario);
            else
                Problems.Add(Finding(scenario, "non eseguito da nessun test"));
            return;
        }
        var worst = StepStatus.Worst(outcomes);
        if (worst == StepStatus.Passed)
            Verified++;
        else
            Problems.Add(Finding(scenario, StepStatus.Describe(worst)));
    }

    static Finding Finding(ExpectedScenario scenario, string reason) =>
        new(scenario.Key.FeaturePath, scenario.Key.Line, scenario.Name, reason);

    string Headline => FeatureCount == 0
        ? "Copertura scenari: nessun file .feature, niente da verificare"
        : $"Copertura scenari: {Expected} attesi, {Verified} verificati, {Pending.Count} in attesa (@ignore), {Problems.Count} problemi — {FeatureCount} file .feature, {MessagesFileCount} file di messages";

    public void Print(string root)
    {
        Console.WriteLine(Headline);
        foreach (var problem in Problems)
            Console.WriteLine($"PROBLEMA {Where(root, problem.FeaturePath, problem.Line)} {problem.Name} — {problem.Reason}");
        foreach (var scenario in Pending)
            Console.WriteLine($"IN ATTESA {Where(root, scenario.Key.FeaturePath, scenario.Key.Line)} {scenario.Name}");
    }

    public string ToMarkdown(string root)
    {
        var markdown = new StringBuilder().AppendLine("# Copertura scenari").AppendLine().AppendLine(Headline).AppendLine();
        AppendTable(markdown, "Problemi", Problems.Select(problem => (Where(root, problem.FeaturePath, problem.Line), problem.Name, problem.Reason)));
        AppendTable(markdown, "In attesa (@ignore)", Pending.Select(scenario => (Where(root, scenario.Key.FeaturePath, scenario.Key.Line), scenario.Name, "@ignore")));
        return markdown.ToString();
    }

    static void AppendTable(StringBuilder markdown, string title, IEnumerable<(string Where, string Name, string Reason)> rows)
    {
        var list = rows.ToList();
        if (list.Count == 0)
            return;
        markdown.AppendLine($"## {title}").AppendLine().AppendLine("| Dove | Scenario | Motivo |").AppendLine("|---|---|---|");
        foreach (var (where, name, reason) in list)
            markdown.AppendLine($"| `{where}` | {Escape(name)} | {Escape(reason)} |");
        markdown.AppendLine();
    }

    static string Escape(string text) => text.Replace("|", "\\|");

    static string Where(string root, string path, int line) =>
        line > 0 ? $"{Paths.Relative(root, path)}:{line}" : Paths.Relative(root, path);
}
