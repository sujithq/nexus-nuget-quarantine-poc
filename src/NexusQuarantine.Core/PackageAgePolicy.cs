namespace NexusQuarantine.Core;

public sealed class PackageAgePolicy
{
    public PackageAgePolicy(TimeSpan minimumAge)
    {
        if (minimumAge < TimeSpan.Zero)
        {
            throw new ArgumentOutOfRangeException(
                nameof(minimumAge),
                minimumAge,
                "The minimum quarantine age cannot be negative.");
        }

        MinimumAge = minimumAge;
    }

    public TimeSpan MinimumAge { get; }

    public EligibilityDecision Evaluate(DateTimeOffset publishedAt, DateTimeOffset observedAt)
    {
        TimeSpan age = observedAt - publishedAt;
        TimeSpan remaining = age < MinimumAge ? MinimumAge - age : TimeSpan.Zero;

        return new EligibilityDecision(
            age >= TimeSpan.Zero && age >= MinimumAge,
            age,
            remaining,
            publishedAt + MinimumAge);
    }
}

public sealed record EligibilityDecision(
    bool IsEligible,
    TimeSpan Age,
    TimeSpan Remaining,
    DateTimeOffset EligibleAt);
