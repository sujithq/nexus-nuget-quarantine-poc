using System.Net.Http.Headers;
using System.Text;
using System.Text.Json;

namespace NexusQuarantine.Promoter;

internal sealed class NexusClient : IDisposable
{
    private static readonly JsonSerializerOptions JsonOptions = new(JsonSerializerDefaults.Web);
    private readonly HttpClient _httpClient;
    private readonly Uri _baseUri;

    public NexusClient(Uri baseUri, string username, string password)
    {
        _baseUri = baseUri;
        _httpClient = new HttpClient
        {
            BaseAddress = baseUri,
            Timeout = TimeSpan.FromMinutes(5)
        };
        _httpClient.DefaultRequestHeaders.Authorization = new AuthenticationHeaderValue(
            "Basic",
            Convert.ToBase64String(Encoding.UTF8.GetBytes($"{username}:{password}")));
        _httpClient.DefaultRequestHeaders.Accept.Add(
            new MediaTypeWithQualityHeaderValue("application/json"));
    }

    public async Task<IReadOnlyList<NexusComponent>> ListComponentsAsync(
        string repository,
        string format,
        CancellationToken cancellationToken)
    {
        var components = new List<NexusComponent>();
        string? continuationToken = null;

        do
        {
            string relativeUrl =
                $"service/rest/v1/search?repository={Uri.EscapeDataString(repository)}" +
                $"&format={Uri.EscapeDataString(format)}";

            if (!string.IsNullOrWhiteSpace(continuationToken))
            {
                relativeUrl += $"&continuationToken={Uri.EscapeDataString(continuationToken)}";
            }

            using HttpResponseMessage response = await _httpClient.GetAsync(
                relativeUrl,
                cancellationToken);
            await EnsureSuccessAsync(response, cancellationToken);

            await using Stream stream = await response.Content.ReadAsStreamAsync(cancellationToken);
            NexusSearchPage page =
                await JsonSerializer.DeserializeAsync<NexusSearchPage>(
                    stream,
                    JsonOptions,
                    cancellationToken)
                ?? throw new JsonException($"Nexus returned an empty search page for '{repository}'.");

            components.AddRange(page.Items);
            continuationToken = page.ContinuationToken;
        }
        while (!string.IsNullOrWhiteSpace(continuationToken));

        return components;
    }

    public async Task CopyComponentAsync(
        NexusComponent component,
        string targetRepository,
        CancellationToken cancellationToken)
    {
        List<NexusPackageAsset> packageAssets = PackageAssetSelector
            .Select(component.Format, component.Name, component.Version, component.Assets)
            .ToList();

        if (packageAssets.Count == 0)
        {
            throw new InvalidOperationException(
                $"Component {ComponentKey.From(component)} has no promotable {component.Format} asset.");
        }

        var temporaryFiles = new List<(string Path, string Name)>();
        string temporaryDirectory = Path.Combine(
            Path.GetTempPath(),
            $"nexus-quarantine-{Guid.NewGuid():N}");
        Directory.CreateDirectory(temporaryDirectory);

        try
        {
            foreach (NexusPackageAsset asset in packageAssets)
            {
                Uri downloadUri = ResolveNexusDownloadUri(asset.DownloadUrl);
                string fileName = PackageAssetSelector.GetFileName(component, asset);
                string temporaryPath = Path.Combine(temporaryDirectory, fileName);

                using HttpResponseMessage downloadResponse = await _httpClient.GetAsync(
                    downloadUri,
                    cancellationToken);
                await EnsureSuccessAsync(downloadResponse, cancellationToken);
                await using FileStream file = File.Create(temporaryPath);
                await downloadResponse.Content.CopyToAsync(file, cancellationToken);
                temporaryFiles.Add((temporaryPath, fileName));
            }

            using var form = new MultipartFormDataContent();
            foreach ((string path, string name) in temporaryFiles)
            {
                var content = new StreamContent(File.OpenRead(path));
                content.Headers.ContentType = new MediaTypeHeaderValue("application/octet-stream");
                form.Add(content, $"{component.Format}.asset", name);
            }

            string uploadUrl =
                $"service/rest/v1/components?repository={Uri.EscapeDataString(targetRepository)}";
            using HttpResponseMessage uploadResponse = await _httpClient.PostAsync(
                uploadUrl,
                form,
                cancellationToken);
            await EnsureSuccessAsync(uploadResponse, cancellationToken);
        }
        finally
        {
            Directory.Delete(temporaryDirectory, recursive: true);
        }
    }

    public void Dispose() => _httpClient.Dispose();

    private Uri ResolveNexusDownloadUri(string downloadUrl)
    {
        if (!Uri.TryCreate(downloadUrl, UriKind.RelativeOrAbsolute, out Uri? candidate))
        {
            throw new UriFormatException($"Nexus returned an invalid asset URL: '{downloadUrl}'.");
        }

        Uri absolute = candidate.IsAbsoluteUri
            ? candidate
            : new Uri(_baseUri, candidate);

        if (!string.Equals(absolute.Scheme, _baseUri.Scheme, StringComparison.OrdinalIgnoreCase) ||
            !string.Equals(absolute.Host, _baseUri.Host, StringComparison.OrdinalIgnoreCase) ||
            absolute.Port != _baseUri.Port)
        {
            throw new InvalidOperationException(
                $"Nexus asset URL '{absolute}' is outside the configured origin '{_baseUri}'.");
        }

        return absolute;
    }

    private static async Task EnsureSuccessAsync(
        HttpResponseMessage response,
        CancellationToken cancellationToken)
    {
        if (response.IsSuccessStatusCode)
        {
            return;
        }

        string body = await response.Content.ReadAsStringAsync(cancellationToken);
        throw new HttpRequestException(
            $"Nexus returned {(int)response.StatusCode} {response.ReasonPhrase} for " +
            $"{response.RequestMessage?.Method} {response.RequestMessage?.RequestUri}: {body}");
    }
}

internal static class PackageAssetSelector
{
    public static IEnumerable<NexusPackageAsset> Select(
        string format,
        string packageName,
        string version,
        IEnumerable<NexusPackageAsset> assets)
    {
        string normalizedFormat = format.ToLowerInvariant();
        return assets.Where(asset =>
        {
            string path = asset.Path;
            return normalizedFormat switch
            {
                "nuget" => (path.EndsWith(".nupkg", StringComparison.OrdinalIgnoreCase) &&
                            !path.EndsWith(".snupkg", StringComparison.OrdinalIgnoreCase)) ||
                           path.Equals(
                               $"{packageName}/{version}",
                               StringComparison.OrdinalIgnoreCase),
                "npm" => path.EndsWith(".tgz", StringComparison.OrdinalIgnoreCase),
                "pypi" => path.EndsWith(".whl", StringComparison.OrdinalIgnoreCase) ||
                          path.EndsWith(".tar.gz", StringComparison.OrdinalIgnoreCase) ||
                          path.EndsWith(".zip", StringComparison.OrdinalIgnoreCase),
                _ => false
            };
        });
    }

    public static string GetFileName(
        NexusComponent component,
        NexusPackageAsset asset)
    {
        if (component.Format.Equals("nuget", StringComparison.OrdinalIgnoreCase) &&
            asset.Path.Equals(
                $"{component.Name}/{component.Version}",
                StringComparison.OrdinalIgnoreCase))
        {
            return $"{component.Name}.{component.Version}.nupkg";
        }

        string fileName = Path.GetFileName(new Uri(asset.DownloadUrl, UriKind.RelativeOrAbsolute)
            .IsAbsoluteUri
            ? new Uri(asset.DownloadUrl).AbsolutePath
            : asset.DownloadUrl);
        if (string.IsNullOrWhiteSpace(fileName))
        {
            throw new InvalidOperationException(
                $"Nexus asset '{asset.Path}' for {ComponentKey.From(component)} has no file name.");
        }

        return fileName;
    }
}

internal sealed class NexusSearchPage
{
    public string? ContinuationToken { get; init; }

    public List<NexusComponent> Items { get; init; } = [];
}

internal sealed class NexusComponent
{
    public string Id { get; init; } = string.Empty;
    public string Repository { get; init; } = string.Empty;
    public string Format { get; init; } = string.Empty;
    public string? Group { get; init; }
    public string Name { get; init; } = string.Empty;
    public string Version { get; init; } = string.Empty;
    public List<NexusPackageAsset> Assets { get; init; } = [];
}

internal sealed class NexusPackageAsset
{
    public string DownloadUrl { get; init; } = string.Empty;
    public string Path { get; init; } = string.Empty;
    public string LastModified { get; init; } = string.Empty;
}

internal readonly record struct ComponentKey(string Format, string Group, string Name, string Version)
{
    public static ComponentKey From(NexusComponent component) =>
        new(
            Normalize(component.Format),
            Normalize(component.Group),
            Normalize(component.Name),
            Normalize(component.Version));

    public override string ToString() =>
        $"{Format}:{(string.IsNullOrEmpty(Group) ? string.Empty : Group + "/")}{Name}@{Version}";

    private static string Normalize(string? value) =>
        value?.Trim().ToLowerInvariant() ?? string.Empty;
}
