CARGO_PROFILE := $(if $(value RELEASE),--release,)
STAGING_DESTINATION := /tmp/main
TARGET_SUBDIRECTORY := $(if $(value RELEASE),release,debug)

REPOSITORY_ROOT := $(shell git rev-parse --show-toplevel)

1P_MODULES := otel-transform otel-enrich

TAGS ?= {{repository}}
EXTRA_FLAGS += $(if $(value PUSH),--push,--load)

graphs: $(1P_MODULES)

.PHONY: $(1P_MODULES)
$(1P_MODULES):
	mkdir -p ./graphs/wasm-modules
	$(eval VERSION ?= 1.0.0)
	$(eval MODE := $(if $(DEBUG),debug,release))
# 	pushd $(REPOSITORY_ROOT)/samples/wasm/rust/examples/$@
	cd examples/$@
	cargo build --target wasm32-wasip2 -p $@ $(if $(DEBUG),, --release) $(CARGOFLAGS)
# 	popd
	$(eval file_naming := $(subst -,_,$@))
	cp --archive ./target/wasm32-wasip2/$(MODE)/$(file_naming).wasm ./graphs/wasm-modules/processor-$@-$(VERSION).wasm
