TARGET ?= clearsword
BUILD_CONFIG ?= Release
ARCH ?= arm64e
DERIVED_DATA ?= DerivedData

SRC_DIR := src
POC_DIR := poc
ENTITLEMENTS := config/entitlements.plist
APP_PATH := $(DERIVED_DATA)/Build/Products/$(BUILD_CONFIG)-iphoneos/$(TARGET).app

CLANG := xcrun --sdk iphoneos clang
CODESIGN := codesign
CFLAGS := -I$(SRC_DIR) -mios-version-min=18.6 -fobjc-arc -arch $(ARCH)
FRAMEWORKS := -framework IOKit -framework Foundation -framework IOSurface \
	-framework Metal -framework UIKit
LIBRARIES := -Lvendor -lcompression -lsrd
SOURCES := $(POC_DIR)/main.c $(wildcard $(SRC_DIR)/*.c) \
	$(wildcard $(SRC_DIR)/*.m)
HEADERS := $(wildcard $(SRC_DIR)/*.h)

.PHONY: all clean binary debug_binary runner ipa

all: clean binary ipa

ipa:
	xcodebuild clean build -project clearsword.xcodeproj -scheme $(TARGET) \
		-destination generic/platform=iOS -sdk iphoneos \
		-derivedDataPath $(DERIVED_DATA) \
		-configuration $(BUILD_CONFIG) ARCHS=$(ARCH) ONLY_ACTIVE_ARCH=YES \
		CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO \
		PRODUCT_BUNDLE_IDENTIFIER="com.0xjohnnydev.agxrwios"
	$(RM) -r Payload
	mkdir -p Payload
	cp -r $(APP_PATH) Payload/
	xattr -cr Payload/$(TARGET).app
	strip Payload/$(TARGET).app/$(TARGET)
	zip -r9 $(TARGET).ipa Payload

binary: $(SOURCES) $(HEADERS) vendor/libsrd.a
	$(CLANG) $(CFLAGS) $(SOURCES) $(FRAMEWORKS) $(LIBRARIES) \
		-o $(TARGET).bin
	strip $(TARGET).bin
	$(CODESIGN) --force --sign - $(TARGET).bin

debug_binary: $(SOURCES) $(HEADERS) vendor/libsrd.a
	$(CLANG) $(CFLAGS) -DDEBUG -g $(SOURCES) $(FRAMEWORKS) \
		$(LIBRARIES) -o $(TARGET)-debug.bin
	$(CODESIGN) --force --sign - --entitlements $(ENTITLEMENTS) \
		$(TARGET)-debug.bin

runner: debug_binary
	ssh -p2222 root@localhost "rm -rf /var/jb/var/mobile/poc"
	cat $(TARGET)-debug.bin | ssh -p2222 root@localhost "cat > /var/jb/var/mobile/poc"
	ssh -p2222 root@localhost "chmod +x /var/jb/var/mobile/poc"
	ssh -tt -p2222 root@localhost "/var/jb/var/mobile/poc 2>&1"

clean:
	$(RM) -r $(DERIVED_DATA) Payload
	$(RM) $(TARGET).ipa $(TARGET).bin $(TARGET)-debug.bin
