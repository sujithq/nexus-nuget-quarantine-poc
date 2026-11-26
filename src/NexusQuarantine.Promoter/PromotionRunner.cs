using System.Globalization;
using NexusQuarantine.Core;

namespace NexusQuarantine.Promoter;

internal sealed class PromotionRunner(
    NexusClient client,
    PackageAgePolicy policy,
    DateTimeOffset observedAt)
{
    private static readonly RepositoryPair[] RepositoryPairs =
    [
        new("pypi", "pypi-quarantine", "pypi-approved"),
        new("npm", "npm-quarantine", "npm-approved"),
        new("nuget", "nuget-quarantine", "nuget-approved")
    ];

    public async Task<int> RunAsync(CancellationToken cancellationToken)
    {
        int promoted = 0;
        int alreadyApproved = 0;
        int pending = 0;

        Console.WriteLine(
            $"Policy: minimum quarantine age {policy.MinimumAge:c}; observed at " +
            $"{observedAt:O}.");

        foreach (RepositoryPair repositories in RepositoryPairs)
        {
            IReadOnlyList<NexusComponent> quarantineComponents =
                await client.ListComponentsAsync(
                    repositories.Quarantine,
                    repositories.Format,
                    cancellationToken);
            HashSet<ComponentKey> approvedComponents =
                (await client.ListComponentsAsync(
                    repositories.Approved,
                    repositories.Format,
                    cancellationToken))
                .Select(ComponentKey.From)
                .ToHashSet();

            foreach (NexusComponent component in quarantineComponents)
            {
                ComponentKey key = ComponentKey.From(component);
                if (approvedComponents.Contains(key))
                {
                    alreadyApproved++;
                    Console.WriteLine($"[approved] {key}");
                    continue;
                }

                DateTimeOffset publishedAt = GetPublishedAt(component);
                EligibilityDecision decision = policy.Evaluate(publishedAt, observedAt);
                if (!decision.IsEligible)
                {
                    pending++;
                    Console.WriteLine(
                        $"[pending]  {key}; age={Format(decision.Age)}; " +
                        $"remaining={Format(decision.Remaining)}; eligible-at={decision.EligibleAt:O}");
                    continue;
                }

                await client.CopyComponentAsync(
                    component,
                    repositories.Approved,
                    cancellationToken);
                approvedComponents.Add(key);
                promoted++;
                Console.WriteLine($"[promoted] {key}; age={Format(decision.Age)}");
            }
        }

        Console.WriteLine(
            $"Promotion summary: promoted={promoted}, already-approved={alreadyApproved}, pending={pending}.");
        return pending == 0 ? 0 : 2;
    }

    private static DateTimeOffset GetPublishedAt(NexusComponent component)
    {
        if (component.Assets.Count == 0)
        {
            throw new InvalidOperationException(
                $"Component {ComponentKey.From(component)} has no assets.");
        }

        DateTimeOffset newestAsset = DateTimeOffset.MinValue;
        foreach (NexusPackageAsset asset in component.Assets)
        {
            if (!DateTimeOffset.TryParse(
                    asset.LastModified,
                    CultureInfo.InvariantCulture,
                    DateTimeStyles.RoundtripKind,
                    out DateTimeOffset modifiedAt))
            {
                throw new InvalidOperationException(
                    $"Asset '{asset.Path}' for {ComponentKey.From(component)} has invalid " +
                    $"lastModified value '{asset.LastModified}'.");
            }

            if (modifiedAt > newestAsset)
            {
                newestAsset = modifiedAt;
            }
        }

        return newestAsset;
    }

    private static string Format(TimeSpan duration) =>
        duration < TimeSpan.Zero
            ? $"-{duration.Negate():c}"
            : duration.ToString("c", CultureInfo.InvariantCulture);
}

internal sealed record RepositoryPair(string Format, string Quarantine, string Approved);
