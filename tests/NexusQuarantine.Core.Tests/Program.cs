using NexusQuarantine.Core;

(string Name, Action Body)[] tests =
[
    ("eligibility is inclusive at the exact age boundary", ExactBoundaryIsEligible),
    ("one tick before the age boundary is ineligible", OneTickBeforeBoundaryIsIneligible),
    ("a future publication timestamp is always ineligible", FuturePublicationIsIneligible),
    ("a zero-day policy accepts a package observed at upload", ZeroThresholdIsImmediate),
    ("a one-second package age has one second of age", AgeIsMeasuredFromPublication),
    ("remaining time is zero once eligible", EligibleDecisionHasNoRemainingTime),
    ("remaining time counts down after upload", PendingDecisionHasRemainingTime),
    ("negative policy thresholds are rejected", NegativeThresholdIsRejected),
    ("the default production period parses as seven days", SevenDaysParses),
    ("the demo override parses as forty-five seconds", FortyFiveSecondsParses),
    ("period units are case-insensitive and trim whitespace", PeriodParsingNormalizes),
    ("invalid period syntax is rejected", InvalidPeriodIsRejected),
    ("periods outside TimeSpan are rejected", OversizedPeriodIsRejected)
];

int failures = 0;
foreach ((string name, Action body) in tests)
{
    try
    {
        body();
        Console.WriteLine($"PASS {name}");
    }
    catch (Exception exception)
    {
        failures++;
        Console.Error.WriteLine($"FAIL {name}: {exception.GetType().Name}: {exception.Message}");
    }
}

Console.WriteLine($"Test summary: passed={tests.Length - failures}, failed={failures}.");
return failures == 0 ? 0 : 1;

static void ExactBoundaryIsEligible()
{
    DateTimeOffset publishedAt = new(2026, 1, 1, 0, 0, 0, TimeSpan.Zero);
    DateTimeOffset observedAt = publishedAt.AddDays(7);
    EligibilityDecision result = new PackageAgePolicy(TimeSpan.FromDays(7)).Evaluate(
        publishedAt,
        observedAt);

    AssertTrue(result.IsEligible);
    AssertEqual(TimeSpan.Zero, result.Remaining);
}

static void OneTickBeforeBoundaryIsIneligible()
{
    DateTimeOffset publishedAt = new(2026, 1, 1, 0, 0, 0, TimeSpan.Zero);
    EligibilityDecision result = new PackageAgePolicy(TimeSpan.FromDays(7)).Evaluate(
        publishedAt,
        publishedAt.AddDays(7).AddTicks(-1));

    AssertFalse(result.IsEligible);
    AssertEqual(TimeSpan.FromTicks(1), result.Remaining);
}

static void FuturePublicationIsIneligible()
{
    DateTimeOffset now = new(2026, 1, 1, 0, 0, 0, TimeSpan.Zero);
    EligibilityDecision result = new PackageAgePolicy(TimeSpan.Zero).Evaluate(
        now.AddSeconds(1),
        now);

    AssertFalse(result.IsEligible);
    AssertTrue(result.Age < TimeSpan.Zero);
}

static void ZeroThresholdIsImmediate()
{
    DateTimeOffset publishedAt = new(2026, 1, 1, 0, 0, 0, TimeSpan.Zero);
    EligibilityDecision result = new PackageAgePolicy(TimeSpan.Zero).Evaluate(
        publishedAt,
        publishedAt);

    AssertTrue(result.IsEligible);
}

static void AgeIsMeasuredFromPublication()
{
    DateTimeOffset publishedAt = new(2026, 1, 1, 0, 0, 0, TimeSpan.Zero);
    EligibilityDecision result = new PackageAgePolicy(TimeSpan.FromSeconds(45)).Evaluate(
        publishedAt,
        publishedAt.AddSeconds(1));

    AssertEqual(TimeSpan.FromSeconds(1), result.Age);
}

static void EligibleDecisionHasNoRemainingTime()
{
    DateTimeOffset publishedAt = new(2026, 1, 1, 0, 0, 0, TimeSpan.Zero);
    EligibilityDecision result = new PackageAgePolicy(TimeSpan.FromSeconds(10)).Evaluate(
        publishedAt,
        publishedAt.AddSeconds(11));

    AssertEqual(TimeSpan.Zero, result.Remaining);
}

static void PendingDecisionHasRemainingTime()
{
    DateTimeOffset publishedAt = new(2026, 1, 1, 0, 0, 0, TimeSpan.Zero);
    EligibilityDecision result = new PackageAgePolicy(TimeSpan.FromSeconds(45)).Evaluate(
        publishedAt,
        publishedAt.AddSeconds(15));

    AssertEqual(TimeSpan.FromSeconds(30), result.Remaining);
    AssertEqual(publishedAt.AddSeconds(45), result.EligibleAt);
}

static void NegativeThresholdIsRejected() =>
    AssertThrows<ArgumentOutOfRangeException>(
        () => new PackageAgePolicy(TimeSpan.FromTicks(-1)));

static void SevenDaysParses() =>
    AssertEqual(TimeSpan.FromDays(7), QuarantinePeriod.Parse("7d"));

static void FortyFiveSecondsParses() =>
    AssertEqual(TimeSpan.FromSeconds(45), QuarantinePeriod.Parse("45s"));

static void PeriodParsingNormalizes() =>
    AssertEqual(TimeSpan.FromHours(2), QuarantinePeriod.Parse(" 2H "));

static void InvalidPeriodIsRejected() =>
    AssertThrows<FormatException>(() => QuarantinePeriod.Parse("tomorrow"));

static void OversizedPeriodIsRejected() =>
    AssertThrows<FormatException>(() => QuarantinePeriod.Parse("999999999999999999999d"));

static void AssertTrue(bool condition)
{
    if (!condition)
    {
        throw new InvalidOperationException("Expected true.");
    }
}

static void AssertFalse(bool condition)
{
    if (condition)
    {
        throw new InvalidOperationException("Expected false.");
    }
}

static void AssertEqual<T>(T expected, T actual)
{
    if (!EqualityComparer<T>.Default.Equals(expected, actual))
    {
        throw new InvalidOperationException($"Expected '{expected}', got '{actual}'.");
    }
}

static void AssertThrows<TException>(Action action)
    where TException : Exception
{
    try
    {
        action();
    }
    catch (TException)
    {
        return;
    }

    throw new InvalidOperationException($"Expected {typeof(TException).Name}.");
}
