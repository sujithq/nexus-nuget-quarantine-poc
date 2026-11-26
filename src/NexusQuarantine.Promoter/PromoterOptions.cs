using NexusQuarantine.Core;

namespace NexusQuarantine.Promoter;

internal sealed record PromoterOptions(
    Uri NexusBaseUri,
    string Username,
    string Password,
    TimeSpan QuarantinePeriod)
{
    public static PromoterOptions Parse(string[] arguments)
    {
        string? baseUrl = Environment.GetEnvironmentVariable("NEXUS_BASE_URL");
        string username = Environment.GetEnvironmentVariable("NEXUS_ADMIN_USER") ?? "admin";
        string? password = Environment.GetEnvironmentVariable("NEXUS_ADMIN_PASSWORD");
        string periodText = Environment.GetEnvironmentVariable("QUARANTINE_PERIOD") ?? "7d";

        for (int index = 0; index < arguments.Length; index++)
        {
            string argument = arguments[index];
            if (argument is "--help" or "-h")
            {
                throw new HelpRequestedException();
            }

            if (!TryReadOption(arguments, ref index, out string value, out string option))
            {
                throw new ArgumentException($"Unknown option '{argument}'.");
            }

            switch (option)
            {
                case "--base-url":
                    baseUrl = value;
                    break;
                case "--username":
                    username = value;
                    break;
                case "--password":
                    password = value;
                    break;
                case "--period":
                    periodText = value;
                    break;
                default:
                    throw new ArgumentException($"Unknown option '{option}'.");
            }
        }

        if (string.IsNullOrWhiteSpace(baseUrl))
        {
            baseUrl = "http://localhost:8081";
        }

        if (string.IsNullOrWhiteSpace(password))
        {
            throw new ArgumentException(
                "NEXUS_ADMIN_PASSWORD is required (or pass --password for a development-only run).");
        }

        if (!Uri.TryCreate(baseUrl, UriKind.Absolute, out Uri? uri) ||
            uri.Scheme is not ("http" or "https"))
        {
            throw new ArgumentException($"'{baseUrl}' is not an absolute HTTP(S) URL.");
        }

        Uri normalizedBaseUri = new(
            uri.GetLeftPart(UriPartial.Authority).TrimEnd('/') + "/",
            UriKind.Absolute);

        return new PromoterOptions(
            normalizedBaseUri,
            username,
            password,
            NexusQuarantine.Core.QuarantinePeriod.Parse(periodText));
    }

    private static bool TryReadOption(
        string[] arguments,
        ref int index,
        out string value,
        out string option)
    {
        option = arguments[index];
        value = string.Empty;

        if (!option.StartsWith("--", StringComparison.Ordinal))
        {
            return false;
        }

        if (index + 1 >= arguments.Length)
        {
            throw new ArgumentException($"Option '{option}' requires a value.");
        }

        value = arguments[++index];
        if (value.StartsWith("--", StringComparison.Ordinal))
        {
            throw new ArgumentException($"Option '{option}' requires a value.");
        }

        return true;
    }
}

internal sealed class HelpRequestedException : Exception;
