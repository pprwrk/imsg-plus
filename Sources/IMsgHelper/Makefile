# Makefile for IMsgHelper - Objective-C helper binary

CC = clang
CFLAGS = -fobjc-arc -framework Foundation -framework IMCore -F/System/Library/PrivateFrameworks
TARGET = imsg-helper
SOURCE = main.m
OUTPUT = ../../.build/release/$(TARGET)

.PHONY: all clean

all: $(OUTPUT)

$(OUTPUT): $(SOURCE)
	@mkdir -p ../../.build/release
	$(CC) $(CFLAGS) -o $(OUTPUT) $(SOURCE)
	@echo "Built $(TARGET) successfully"

clean:
	rm -f $(OUTPUT)

test: $(OUTPUT)
	@echo '{"action":"status","params":{}}' | $(OUTPUT)