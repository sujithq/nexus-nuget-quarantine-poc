using System.Globalization;
using System.Text.RegularExpressions;

namespace NexusQuarantine.Core;

public static partial class QuarantinePeriod
{
    public static TimeSpan Parse(string value)
    {
        if (string.IsNullOrWhiteSpace(value))
        {
            throw new ArgumentException("The quarantine period cannot be empty.", nameof(value));
        }

        Match match = Pattern().Match(value.Trim());
        if (!match.Success)
        {
            throw new FormatException(
                $"'{value}' is not a valid quarantine period. Use an integer followed by s, m, h, or d.");
        }

        if (!long.TryParse(
                match.Groups["amount"].Value,
                NumberStyles.None,
                CultureInfo.InvariantCulture,
                out long amount))
        {
            throw new FormatException($"'{value}' is too large for a .NET time span.");
        }
        double totalSeconds = match.Groups["unit"].Value.ToLowerInvariant() switch
        {
            "s" => amount,
            "m" => amount * 60d,
            "h" => amount * 3_600d,
            "d" => amount * 86_400d,
            _ => throw new InvalidOperationException("Unreachable quarantine period unit.")
        };

        if (totalSeconds > TimeSpan.MaxValue.TotalSeconds)
        {
            throw new FormatException($"'{value}' is too large for a .NET time span.");
        }

        return TimeSpan.FromSeconds(totalSeconds);
    }

    [GeneratedRegex(
        @"^(?<amount>\d+)(?<unit>[smhdSMHD])$",
        RegexOptions.CultureInvariant,
        matchTimeoutMilliseconds: 1_000)]
    private static partial Regex Pattern();
}
