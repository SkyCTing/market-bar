param(
    [string]$Configuration = "Release"
)

$ErrorActionPreference = "Stop"
$Root = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$WindowsRoot = Join-Path $Root "Windows"
$PublishDir = Join-Path $Root "dist/windows/GoldPriceBar-Windows-x64"
$ZipPath = Join-Path $Root "dist/GoldPriceBar-Windows-x64-1.0.3.zip"

Write-Host "Running Windows tests..."
dotnet test (Join-Path $WindowsRoot "GoldPriceBar.sln") -c $Configuration

Write-Host "Publishing self-contained portable build..."
if (Test-Path $PublishDir) { Remove-Item $PublishDir -Recurse -Force }
dotnet publish (Join-Path $WindowsRoot "GoldPriceBar.Windows/GoldPriceBar.Windows.csproj") `
    -c $Configuration `
    -r win-x64 `
    --self-contained true `
    -p:PublishReadyToRun=true `
    -p:DebugType=None `
    -p:DebugSymbols=false `
    -o $PublishDir

if (Test-Path $ZipPath) { Remove-Item $ZipPath -Force }
Compress-Archive -Path (Join-Path $PublishDir "*") -DestinationPath $ZipPath -CompressionLevel Optimal

Write-Host "Windows portable build created: $ZipPath"
