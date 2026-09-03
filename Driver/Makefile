SDK := $(shell xcrun --show-sdk-path)
OUT := ../build/WhereSoundMeetDriver.driver
CFLAGS := -std=c11 -O2 -Wall -Wextra -fPIC -mmacosx-version-min=14.0 -isysroot $(SDK) -arch arm64 -arch x86_64
LDFLAGS := -bundle -framework CoreAudio -framework CoreFoundation -lpthread

all: $(OUT)/Contents/MacOS/WhereSoundMeetDriver

$(OUT)/Contents/MacOS/WhereSoundMeetDriver: WhereSoundMeetDriver.c WhereSoundMeetDriver.h Info.plist
	mkdir -p $(OUT)/Contents/MacOS
	clang $(CFLAGS) $(LDFLAGS) -o $@ WhereSoundMeetDriver.c
	cp Info.plist $(OUT)/Contents/Info.plist
	codesign --force --sign - --identifier com.zan.wheresoundmeet.driver $(OUT)

clean:
	rm -rf $(OUT)
