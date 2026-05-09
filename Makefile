SWIFTC ?= swiftc
SRC    := swift/meian-watcher.swift
OUT    := bin/meian-watcher

.PHONY: build clean

build: $(OUT)

$(OUT): $(SRC)
	@mkdir -p bin
	$(SWIFTC) -O -o $(OUT) $(SRC)

clean:
	rm -rf bin
