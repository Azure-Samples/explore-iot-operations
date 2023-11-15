module github.com/explore-iot-ops/samples/anomaly-detection

go 1.21.3

replace (
	github.com/explore-iot-ops/lib/env => ../../lib/env
	github.com/explore-iot-ops/lib/logger => ../../lib/logger
	github.com/explore-iot-ops/lib/mage => ../../lib/mage
	github.com/explore-iot-ops/lib/proto => ../../lib/proto
)

require (
	github.com/explore-iot-ops/lib/env v0.0.0-00010101000000-000000000000
	github.com/gofiber/fiber/v2 v2.51.0
	github.com/stretchr/testify v1.8.4
)

require (
	github.com/andybalholm/brotli v1.0.5 // indirect
	github.com/davecgh/go-spew v1.1.1 // indirect
	github.com/google/uuid v1.4.0 // indirect
	github.com/klauspost/compress v1.16.7 // indirect
	github.com/mattn/go-colorable v0.1.13 // indirect
	github.com/mattn/go-isatty v0.0.20 // indirect
	github.com/mattn/go-runewidth v0.0.15 // indirect
	github.com/pmezard/go-difflib v1.0.0 // indirect
	github.com/rivo/uniseg v0.2.0 // indirect
	github.com/valyala/bytebufferpool v1.0.0 // indirect
	github.com/valyala/fasthttp v1.50.0 // indirect
	github.com/valyala/tcplisten v1.0.0 // indirect
	golang.org/x/sys v0.14.0 // indirect
	gopkg.in/yaml.v3 v3.0.1 // indirect
)
