using NexusQuarantine.Core;
using NexusQuarantine.Promoter;

try
{
    PromoterOptions options = PromoterOptions.Parse(args);
    using var client = new NexusClient(options.NexusBaseUri, options.Username, options.Password);
    var policy = new PackageAgePolicy(options.QuarantinePeriod);
    var runner = new PromotionRunner(client, policy, DateTimeOffset.UtcNow);
    using var cancellation = new CancellationTokenSource();
    Console.CancelKeyPress += (_, eventArgs) =>
    {
        eventArgs.Cancel = true;
        cancellation.Cancel();
    };

    return await runner.RunAsync(cancellation.Token);
}
catch (HelpRequestedException)
{
    PrintHelp();
    return 0;
}
catch (OperationCanceledException)
{
    Console.Error.WriteLine("Promotion cancelled.");
    return 130;
}
catch (Exception exception)
{
    Console.Error.WriteLine($"Promotion failed: {exception.Message}");
    return 1;
}

static void PrintHelp()
{
    Console.WriteLine(
        """
        Nexus quarantine promoter

        Promotes aged package components from the pypi, npm, and NuGet quarantine
        repositories into their matching approved hosted repositories.

        Usage:
          dotnet run --project src/NexusQuarantine.Promoter -- [options]

        Options:
          --base-url URL       Nexus origin (default: $NEXUS_BASE_URL or http://localhost:8081)
          --username USER      Nexus user (default: $NEXUS_ADMIN_USER or admin)
          --password PASSWORD  Nexus password (default: $NEXUS_ADMIN_PASSWORD)
          --period DURATION    Minimum age (default: $QUARANTINE_PERIOD or 7d)
          --help               Show this help

        Durations use an integer followed by s, m, h, or d, for example 45s or 7d.
        """);
}
