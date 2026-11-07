TARGET			= clearsword
BUILD_CONFIG 	= Release

CLANG 			= clang -isysroot "$(shell xcrun --show-sdk-path --sdk iphoneos)"
CODESIGN		= codesign
ARCH 			= -arch arm64
FRAMEWORKS		= -framework IOKit -framework Foundation -framework IOSurface -framework Metal
C_FLAGS 		= -I./$(TARGET)/ -I./$(TARGET)/include
BINARY_FLAGS	= -mios-version-min=18.6 -fobjc-arc
SOURCES			= $(TARGET)/*.c
OBJC_SOURCES	= $(TARGET)/agx.m

.PHONY: all clean binary debug_binary runner ios_app ios_ipa clean_ios_app ipa

all: clean binary ipa

ipa:
	xcodebuild clean build CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO PRODUCT_BUNDLE_IDENTIFIER="com.0xjohnnydev.agxrwios" -sdk iphoneos -configuration $(BUILD_CONFIG)
	rm -rf Payload
	mkdir Payload
	cp -r build/$(BUILD_CONFIG)-iphoneos/$(TARGET).app Payload/
	xattr -cr Payload/$(TARGET).app
	strip Payload/$(TARGET).app/$(TARGET)
	zip -r9 $(TARGET).ipa Payload

binary:
	$(CLANG) $(C_FLAGS) $(BINARY_FLAGS) $(ARCH) $(FRAMEWORKS) -o $(TARGET).bin binary.c $(SOURCES) $(OBJC_SOURCES)
	strip $(TARGET).bin
	$(CODESIGN) --force --sign - $(TARGET).bin

debug_binary:
	$(CLANG) $(C_FLAGS) -DDEBUG -g $(BINARY_FLAGS) $(ARCH) $(FRAMEWORKS) -o $(TARGET)-debug.bin binary.c $(SOURCES) $(OBJC_SOURCES)
	$(CODESIGN) --force --sign - --entitlements ent.xml $(TARGET)-debug.bin

runner: debug_binary
	ssh -p2222 root@localhost "rm -rf /var/jb/var/mobile/poc"
	cat $(TARGET)-debug.bin | ssh -p2222 root@localhost "cat > /var/jb/var/mobile/poc"
	ssh -p2222 root@localhost "chmod +x /var/jb/var/mobile/poc"
	ssh -tt -p2222 root@localhost "/var/jb/var/mobile/poc 2>&1"

clean:
	rm -rf build Payload $(TARGET).ipa $(APP_IPA) **/*.deb *.bin
