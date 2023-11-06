FROM mcr.microsoft.com/dotnet/sdk:7.0 AS build-env
WORKDIR /App

# Copy everything
COPY . ./

# Build and publish a release
RUN dotnet publish --os linux -c Release -o out

# Build runtime image
FROM mcr.microsoft.com/dotnet/runtime:7.0-alpine
WORKDIR /App
COPY --from=build-env /App/out .
ENTRYPOINT ["dotnet", "SampleDotnetMqtt.dll"]