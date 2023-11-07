package main

type (
	Config struct {
		LogLevel string `json:"logLevel"` // logging level for the application
		LogsDir  string `json:"logsDir"`  // directory into which logs are written
	}

	config struct {
		Logger Config `json:"logger"`
		Port   int    `json:"port"`
	}
)

func newConfig() *config {
	return &config{
		Logger: Config{
			LogLevel: "Debug",
			LogsDir:  "./logs",
		},
		Port: 8888,
	}
}
