module github.com/explore-iot-ops/samples/industrial-data-simulator

go 1.21.3

require (
	github.com/eclipse/paho.golang v0.11.0
	github.com/eclipse/paho.mqtt.golang v1.4.2
	github.com/explore-iot-ops/lib/env v0.0.0-00010101000000-000000000000
	github.com/explore-iot-ops/lib/logger v0.0.0-00010101000000-000000000000
	github.com/explore-iot-ops/lib/mage v0.0.0-00010101000000-000000000000
	github.com/explore-iot-ops/lib/proto v0.0.0-00010101000000-000000000000
	github.com/gofiber/fiber/v2 v2.50.0
	github.com/prometheus/client_golang v1.14.0
	github.com/rs/zerolog v1.31.0
	github.com/stretchr/testify v1.8.4
	google.golang.org/protobuf v1.31.0
	gopkg.in/yaml.v3 v3.0.1
)

require (
	github.com/VividCortex/ewma v1.1.1 // indirect
	github.com/andybalholm/brotli v1.0.5 // indirect
	github.com/beorn7/perks v1.0.1 // indirect
	github.com/cespare/xxhash/v2 v2.2.0 // indirect
	github.com/cheggaaa/pb/v3 v3.0.4 // indirect
	github.com/davecgh/go-spew v1.1.1 // indirect
	github.com/fatih/color v1.9.0 // indirect
	github.com/golang/protobuf v1.5.3 // indirect
	github.com/google/uuid v1.3.1 // indirect
	github.com/gorilla/websocket v1.5.0 // indirect
	github.com/klauspost/compress v1.16.7 // indirect
	github.com/kr/pretty v0.3.0 // indirect
	github.com/magefile/mage v1.15.0 // indirect
	github.com/mattn/go-colorable v0.1.13 // indirect
	github.com/mattn/go-isatty v0.0.19 // indirect
	github.com/mattn/go-runewidth v0.0.15 // indirect
	github.com/matttproud/golang_protobuf_extensions v1.0.4 // indirect
	github.com/pmezard/go-difflib v1.0.0 // indirect
	github.com/princjef/mageutil v1.0.0 // indirect
	github.com/prometheus/client_model v0.3.0 // indirect
	github.com/prometheus/common v0.42.0 // indirect
	github.com/prometheus/procfs v0.9.0 // indirect
	github.com/rivo/uniseg v0.4.4 // indirect
	github.com/rogpeppe/go-internal v1.8.0 // indirect
	github.com/valyala/bytebufferpool v1.0.0 // indirect
	github.com/valyala/fasthttp v1.50.0 // indirect
	github.com/valyala/tcplisten v1.0.0 // indirect
	golang.org/x/net v0.17.0 // indirect
	golang.org/x/sync v0.3.0 // indirect
	golang.org/x/sys v0.13.0 // indirect
	golang.org/x/text v0.13.0 // indirect
	google.golang.org/genproto/googleapis/rpc v0.0.0-20230822172742-b8732ec3820d // indirect
	google.golang.org/grpc v1.59.0 // indirect
)

replace (
	github.com/explore-iot-ops/lib/env => ../../lib/env
	github.com/explore-iot-ops/lib/logger => ../../lib/logger
	github.com/explore-iot-ops/lib/mage => ../../lib/mage
	github.com/explore-iot-ops/lib/proto => ../../lib/proto
)
