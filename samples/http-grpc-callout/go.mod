module github.com/explore-iot-ops/samples/http-grpc-callout

go 1.21.3

replace (
	github.com/explore-iot-ops/lib/env => ../../lib/env
	github.com/explore-iot-ops/lib/logger => ../../lib/logger
	github.com/explore-iot-ops/lib/mage => ../../lib/mage
	github.com/explore-iot-ops/lib/proto => ../../lib/proto
)

require (
	github.com/eclipse/paho.golang v0.12.0
	github.com/explore-iot-ops/lib/env v0.0.0-00010101000000-000000000000
	github.com/explore-iot-ops/lib/logger v0.0.0-00010101000000-000000000000
	github.com/explore-iot-ops/lib/mage v0.0.0-00010101000000-000000000000
	github.com/explore-iot-ops/lib/proto v0.0.0-00010101000000-000000000000
	github.com/gofiber/fiber/v2 v2.50.0
	github.com/rs/zerolog v1.31.0
	google.golang.org/grpc v1.59.0
	gopkg.in/yaml.v3 v3.0.1
)

require (
	github.com/VividCortex/ewma v1.1.1 // indirect
	github.com/andybalholm/brotli v1.0.5 // indirect
	github.com/cheggaaa/pb/v3 v3.0.4 // indirect
	github.com/fatih/color v1.9.0 // indirect
	github.com/golang/protobuf v1.5.3 // indirect
	github.com/google/uuid v1.3.1 // indirect
	github.com/klauspost/compress v1.16.7 // indirect
	github.com/magefile/mage v1.15.0 // indirect
	github.com/mattn/go-colorable v0.1.13 // indirect
	github.com/mattn/go-isatty v0.0.19 // indirect
	github.com/mattn/go-runewidth v0.0.15 // indirect
	github.com/princjef/mageutil v1.0.0 // indirect
	github.com/rivo/uniseg v0.2.0 // indirect
	github.com/valyala/bytebufferpool v1.0.0 // indirect
	github.com/valyala/fasthttp v1.50.0 // indirect
	github.com/valyala/tcplisten v1.0.0 // indirect
	golang.org/x/net v0.17.0 // indirect
	golang.org/x/sync v0.4.0 // indirect
	golang.org/x/sys v0.13.0 // indirect
	golang.org/x/text v0.13.0 // indirect
	google.golang.org/genproto/googleapis/rpc v0.0.0-20230822172742-b8732ec3820d // indirect
	google.golang.org/protobuf v1.31.0 // indirect
)
