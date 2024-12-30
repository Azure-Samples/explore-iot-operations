FROM mcr.microsoft.com/dotnet/aspnet:6.0 AS base
WORKDIR /app
EXPOSE 80

FROM mcr.microsoft.com/dotnet/sdk:6.0 AS build
WORKDIR /src
COPY ["TelemetryPersister.csproj", "TelemetryPersister/"]
RUN dotnet restore "TelemetryPersister/TelemetryPersister.csproj"
COPY . .

FROM build AS publish
RUN dotnet publish "TelemetryPersister.csproj" -c Release -o /app/publish /p:UseAppHost=false

FROM base AS final
WORKDIR /app
COPY --from=publish /app/publish .
ENTRYPOINT ["dotnet", "TelemetryPersister.dll"]