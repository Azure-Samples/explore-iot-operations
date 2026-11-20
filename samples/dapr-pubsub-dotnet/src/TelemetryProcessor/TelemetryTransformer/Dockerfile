FROM mcr.microsoft.com/dotnet/aspnet:6.0 AS base
WORKDIR /app
EXPOSE 5050

FROM mcr.microsoft.com/dotnet/sdk:6.0-bullseye-slim-amd64 AS build
WORKDIR /src
COPY ["TelemetryTransformer.csproj", "TelemetryTransformer/"]
RUN dotnet restore "TelemetryTransformer/TelemetryTransformer.csproj"
COPY . .

FROM build AS publish
RUN dotnet publish "TelemetryTransformer.csproj" -c Release -o /app/publish /p:UseAppHost=false

FROM base AS final
WORKDIR /app
COPY --from=publish /app/publish .
ENTRYPOINT ["dotnet", "TelemetryTransformer.dll"]