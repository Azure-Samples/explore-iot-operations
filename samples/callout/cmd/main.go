package main

import (
	"context"
	_ "embed"
	"fmt"
	"io"
	"os"
	"os/signal"
	"path"
	"strings"

	"github.com/reddydMSFT/callout/pkg/serving"
	"github.com/rs/zerolog"
	"github.com/rs/zerolog/log"
	"github.com/spf13/viper"
	"gopkg.in/natefinch/lumberjack.v2"
)

func main() {
	// handle process exit gracefully
	sig := make(chan os.Signal, 1)
	signal.Notify(sig, os.Interrupt)
	ctx := context.Background()
	ctx, cancel := context.WithCancel(ctx)

	defer func() {
		// Close the os signal channel to prevent any leak.
		signal.Stop(sig)
	}()

	// load configuration and initialize logger
	cfg, err := loadConfig()
	if err != nil {
		panic(fmt.Errorf("failed to initialize configuration. %w", err))
	}
	initLogger(cfg)

	go serving.StartAdmin(cfg.Port)

	// Wait signal / cancellation
	<-sig

	cancel() // Wait for device to completely shut down.
}

// loadConfig loads the configuration file
func loadConfig() (*config, error) {
	colorReset := "\033[0m"
	//colorRed := "\033[31m"
	colorGreen := "\033[32m"
	//colorYellow := "\033[33m"
	colorBlue := "\033[34m"
	//colorPurple := "\033[35m"
	//colorCyan := "\033[36m"
	//colorWhite := "\033[37m"
	fmt.Printf(string(colorGreen))
	fmt.Printf(`
 ██████╗ █████╗ ██╗     ██╗      ██████╗ ██╗   ██╗████████╗
██╔════╝██╔══██╗██║     ██║     ██╔═══██╗██║   ██║╚══██╔══╝
██║     ███████║██║     ██║     ██║   ██║██║   ██║   ██║   
██║     ██╔══██║██║     ██║     ██║   ██║██║   ██║   ██║   
╚██████╗██║  ██║███████╗███████╗╚██████╔╝╚██████╔╝   ██║   
 ╚═════╝╚═╝  ╚═╝╚══════╝╚══════╝ ╚═════╝  ╚═════╝    ╚═╝   
`)
	fmt.Printf(string(colorBlue))
	fmt.Printf("        AIO DATA PROCESSOR CALLOUT\n")
	fmt.Printf(string(colorReset))

	viper.SetConfigName("callout")
	viper.SetConfigType("json")
	viper.AddConfigPath(".")
	viper.AddConfigPath("./bin")

	viper.AutomaticEnv()
	if err := viper.ReadInConfig(); err != nil {
		if _, ok := err.(viper.ConfigFileNotFoundError); ok {
			fmt.Print(`Add a configuration file (callout.json) with the file contents below:

{
  "logger": {
    "logLevel": "Debug",
    "logsDir": "./logs"
  },
  "port": 8888
}

\n`)
			return nil, err
		}
	}

	cfg := newConfig()
	if err := viper.Unmarshal(cfg); err != nil {
		return nil, err
	}

	//fmt.Printf("loaded configuration from %s\n", viper.ConfigFileUsed())
	return cfg, nil
}

// initLogger initializes the logger with output format
func initLogger(cfg *config) {
	var writers []io.Writer
	writers = append(writers, zerolog.ConsoleWriter{Out: os.Stderr, TimeFormat: "15:04:05"})

	fileLoggingEnabled := false
	if len(cfg.Logger.LogsDir) > 0 {
		fileLoggingEnabled = true
	}
	if fileLoggingEnabled {
		logsDir := cfg.Logger.LogsDir
		if err := os.MkdirAll(logsDir, 0744); err != nil {
			fmt.Printf("can't create log directory, so file logging is disabled, error: %s", err.Error())
		} else {
			fileWriter := &lumberjack.Logger{
				Filename:   path.Join(logsDir, "callout.log"),
				MaxBackups: 3,  // files
				MaxSize:    10, // megabytes
				MaxAge:     30, // days
			}

			writers = append(writers, fileWriter)
			//fmt.Printf("file logging is enabled, logsDir: %s\n", logsDir)
		}
	}
	mw := io.MultiWriter(writers...)

	log.Logger = zerolog.New(mw).With().Timestamp().Logger()
	//log.Logger = log.Output(zerolog.ConsoleWriter{Out: os.Stderr, TimeFormat: "15:04:05"})

	switch strings.ToLower(cfg.Logger.LogLevel) {
	case "panic":
		zerolog.SetGlobalLevel(zerolog.PanicLevel)
	case "fatal":
		zerolog.SetGlobalLevel(zerolog.FatalLevel)
	case "error":
		zerolog.SetGlobalLevel(zerolog.ErrorLevel)
	case "warn":
		zerolog.SetGlobalLevel(zerolog.WarnLevel)
	case "info":
		zerolog.SetGlobalLevel(zerolog.InfoLevel)
	case "trace":
		zerolog.SetGlobalLevel(zerolog.TraceLevel)
	default:
		zerolog.SetGlobalLevel(zerolog.DebugLevel)
	}
}
