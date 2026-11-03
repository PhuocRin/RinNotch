// Trình đọc "Đang phát" của RinNotch.
// Từ macOS 15.4, app bên thứ ba gọi MediaRemote trực tiếp sẽ không đọc được thông tin bài đang phát.
// Cách cộng đồng tìm ra: chạy qua /usr/bin/perl (chương trình của Apple) rồi nạp thư viện này,
// MediaRemote sẽ trả lời. RinNotch chạy: /usr/bin/perl rinmedia.pl librinmedia.dylib
// - stdout: mỗi dòng là một JSON thông tin bài đang phát
// - stdin:  lệnh "toggle" | "play" | "pause" | "next" | "prev" | "seek <giây>"
// Mã này do RinNotch tự viết; chỉ dùng chung ý tưởng chạy qua perl với cộng đồng.

#import <Foundation/Foundation.h>
#import <dlfcn.h>

typedef void (*MRGetInfoFn)(dispatch_queue_t, void (^)(CFDictionaryRef));
typedef void (*MRRegisterFn)(dispatch_queue_t);
typedef Boolean (*MRSendFn)(int, CFDictionaryRef);
typedef void (*MRIsPlayingFn)(dispatch_queue_t, void (^)(Boolean));
typedef void (*MRGetPIDFn)(dispatch_queue_t, void (^)(int));
typedef void (*MRSetElapsedFn)(double);

static MRGetInfoFn gGetInfo;
static MRRegisterFn gRegister;
static MRSendFn gSend;
static MRIsPlayingFn gIsPlaying;
static MRGetPIDFn gGetPID;
static MRSetElapsedFn gSetElapsed;
static NSString *gLastArtKey = nil;

static void writeLine(NSDictionary *obj) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:obj options:0 error:nil];
    if (!data) return;
    fwrite(data.bytes, 1, data.length, stdout);
    fputc('\n', stdout);
    fflush(stdout);
}

static id clean(id v) {
    if ([v isKindOfClass:[NSString class]] || [v isKindOfClass:[NSNumber class]]) return v;
    return nil;
}

static void emit(void) {
    if (!gGetInfo) return;
    gGetInfo(dispatch_get_main_queue(), ^(CFDictionaryRef info) {
        NSDictionary *d = (__bridge NSDictionary *)info;
        NSMutableDictionary *o = [NSMutableDictionary dictionary];
        if (d) {
            NSString *title = clean(d[@"kMRMediaRemoteNowPlayingInfoTitle"]) ?: @"";
            NSString *artist = clean(d[@"kMRMediaRemoteNowPlayingInfoArtist"]) ?: @"";
            o[@"title"] = title;
            o[@"artist"] = artist;
            o[@"album"] = clean(d[@"kMRMediaRemoteNowPlayingInfoAlbum"]) ?: @"";
            o[@"duration"] = clean(d[@"kMRMediaRemoteNowPlayingInfoDuration"]) ?: @0;
            o[@"elapsed"] = clean(d[@"kMRMediaRemoteNowPlayingInfoElapsedTime"]) ?: @0;
            o[@"rate"] = clean(d[@"kMRMediaRemoteNowPlayingInfoPlaybackRate"]) ?: @0;
            id ts = d[@"kMRMediaRemoteNowPlayingInfoTimestamp"];
            o[@"timestamp"] = [ts isKindOfClass:[NSDate class]] ? @([(NSDate *)ts timeIntervalSince1970])
                                                                : @([[NSDate date] timeIntervalSince1970]);
            NSData *art = d[@"kMRMediaRemoteNowPlayingInfoArtworkData"];
            NSString *key = [NSString stringWithFormat:@"%@|%@|%lu", title, artist, (unsigned long)art.length];
            if ([art isKindOfClass:[NSData class]] && art.length > 0 && art.length < 3000000
                && ![key isEqualToString:gLastArtKey ?: @""]) {
                o[@"artwork"] = [art base64EncodedStringWithOptions:0];
                gLastArtKey = key;
            }
        }
        void (^finish)(void) = ^{
            if (gGetPID) {
                gGetPID(dispatch_get_main_queue(), ^(int pid) {
                    o[@"pid"] = @(pid);
                    writeLine(o);
                });
            } else {
                writeLine(o);
            }
        };
        if (gIsPlaying) {
            gIsPlaying(dispatch_get_main_queue(), ^(Boolean playing) {
                o[@"playing"] = @(playing ? YES : NO);
                finish();
            });
        } else {
            finish();
        }
    });
}

static void handle(NSString *line) {
    line = [line stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (line.length == 0) return;
    int cmd = -1;
    if ([line isEqualToString:@"play"]) cmd = 0;
    else if ([line isEqualToString:@"pause"]) cmd = 1;
    else if ([line isEqualToString:@"toggle"]) cmd = 2;
    else if ([line isEqualToString:@"next"]) cmd = 4;
    else if ([line isEqualToString:@"prev"]) cmd = 5;
    if (cmd >= 0 && gSend) {
        Boolean ok = gSend(cmd, NULL);
        writeLine(@{@"command": line, @"ok": @(ok ? YES : NO)});
    } else if ([line hasPrefix:@"seek "] && gSetElapsed) {
        gSetElapsed([[line substringFromIndex:5] doubleValue]);
    } else if ([line isEqualToString:@"refresh"]) {
        // chỉ cần gửi lại
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ emit(); });
}

// perl gọi hàm này như một XSUB; tham số của perl không dùng tới.
__attribute__((visibility("default")))
void rn_main(void *unused1, void *unused2) {
    (void)unused1; (void)unused2;
    void *h = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_NOW);
    if (!h) {
        writeLine(@{@"error": @"Không nạp được MediaRemote"});
        exit(2);
    }
    gGetInfo = (MRGetInfoFn)dlsym(h, "MRMediaRemoteGetNowPlayingInfo");
    gRegister = (MRRegisterFn)dlsym(h, "MRMediaRemoteRegisterForNowPlayingNotifications");
    gSend = (MRSendFn)dlsym(h, "MRMediaRemoteSendCommand");
    gIsPlaying = (MRIsPlayingFn)dlsym(h, "MRMediaRemoteGetNowPlayingApplicationIsPlaying");
    gGetPID = (MRGetPIDFn)dlsym(h, "MRMediaRemoteGetNowPlayingApplicationPID");
    gSetElapsed = (MRSetElapsedFn)dlsym(h, "MRMediaRemoteSetElapsedTime");
    if (!gGetInfo) {
        writeLine(@{@"error": @"Thiếu hàm MRMediaRemoteGetNowPlayingInfo"});
        exit(3);
    }
    writeLine(@{@"ready": @YES});

    if (gRegister) gRegister(dispatch_get_main_queue());
    NSArray *names = @[
        @"kMRMediaRemoteNowPlayingInfoDidChangeNotification",
        @"kMRMediaRemoteNowPlayingApplicationIsPlayingDidChangeNotification",
        @"kMRMediaRemoteNowPlayingApplicationDidChangeNotification",
        @"kMRMediaRemoteNowPlayingPlaybackQueueChangedNotification",
    ];
    for (NSString *n in names) {
        [[NSNotificationCenter defaultCenter] addObserverForName:n object:nil queue:[NSOperationQueue mainQueue]
                                                      usingBlock:^(NSNotification *note) { (void)note; emit(); }];
    }

    // Dự phòng: hỏi lại mỗi 3 giây phòng khi thông báo bị lỡ.
    dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC), 3 * NSEC_PER_SEC, NSEC_PER_SEC / 2);
    dispatch_source_set_event_handler(timer, ^{ emit(); });
    dispatch_resume(timer);

    // Đọc lệnh từ RinNotch. RinNotch thoát (stdin đóng) thì trình đọc cũng thoát theo.
    [NSThread detachNewThreadWithBlock:^{
        char buf[512];
        while (fgets(buf, sizeof(buf), stdin)) {
            NSString *line = [NSString stringWithUTF8String:buf] ?: @"";
            dispatch_async(dispatch_get_main_queue(), ^{ handle(line); });
        }
        exit(0);
    }];

    emit();
    CFRunLoopRun();
}
