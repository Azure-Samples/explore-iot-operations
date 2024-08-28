# Use the official .NET SDK image as a build stage
FROM mcr.microsoft.com/dotnet/sdk:8.0 AS build

# Set the working directory
WORKDIR /app

# Copy the NuGet.config file
COPY NuGet.config ./

# Copy the project file and restore dependencies
COPY ContextAppForDSS/ContextAppForDSS.csproj ./ContextAppForDSS/
RUN dotnet restore ./ContextAppForDSS/ContextAppForDSS.csproj

# Copy the remaining source code and build the application
COPY ContextAppForDSS/ ./ContextAppForDSS/
RUN dotnet publish ./ContextAppForDSS/ContextAppForDSS.csproj -c Release -o out

# Use the official .NET runtime image as a runtime stage
FROM mcr.microsoft.com/dotnet/aspnet:8.0 AS runtime
WORKDIR /app
COPY --from=build /app/out .

# Set the entry point for the application
ENTRYPOINT ["dotnet", "ContextAppForDSS.dll"]
