// Local macOS frame reader. The Python entry point handles evidence and output paths.
#import <AVFoundation/AVFoundation.h>
#import <ImageIO/ImageIO.h>
#import <Foundation/Foundation.h>

__attribute__((noreturn)) static void fail(NSString *message) {
    fprintf(stderr, "%s\n", message.UTF8String);
    exit(1);
}

static NSDictionary *timeRecord(CMTime t) {
    if (!CMTIME_IS_NUMERIC(t)) fail(@"Encountered an unavailable media time");
    return @{@"value": @(t.value), @"timescale": @(t.timescale), @"seconds": @(CMTimeGetSeconds(t))};
}

static NSArray *codecs(AVAssetTrack *track) {
    NSMutableArray *names = [NSMutableArray array];
    for (id desc in track.formatDescriptions) {
        FourCharCode c = CMFormatDescriptionGetMediaSubType((__bridge CMFormatDescriptionRef)desc);
        char str[] = {(char)(c >> 24), (char)(c >> 16), (char)(c >> 8), (char)c, 0};
        [names addObject:[NSString stringWithCString:str encoding:NSMacOSRomanStringEncoding] ?: @"unknown"];
    }
    return names;
}

@interface FVFrameTime : NSObject
@property(nonatomic) CMTime sample;
@property(nonatomic) CMTime presentation;
@end
@implementation FVFrameTime
@end

// Compressed samples can arrive in decoding order. Build the presentation-order
// index using the movie timeline, respecting the track edit range and hidden samples.
static NSArray<FVFrameTime *> *presentationTimes(AVURLAsset *asset, AVAssetTrack *track) {
    NSError *error = nil;
    AVAssetReader *reader = [[AVAssetReader alloc] initWithAsset:asset error:&error];
    if (!reader) fail(error.localizedDescription);
    AVAssetReaderTrackOutput *out = [AVAssetReaderTrackOutput assetReaderTrackOutputWithTrack:track outputSettings:nil];
    out.alwaysCopiesSampleData = NO;
    if (![reader canAddOutput:out]) fail(@"Cannot read the video track");
    [reader addOutput:out];
    if (![reader startReading]) fail(reader.error.localizedDescription ?: @"Cannot start reading");
    NSMutableArray<FVFrameTime *> *times = [NSMutableArray array];
    CMSampleBufferRef buf;
    while ((buf = [out copyNextSampleBuffer])) {
        @autoreleasepool {
            CMItemCount count = CMSampleBufferGetNumSamples(buf);
            // The sample PTS is on the encoded media timeline. The output PTS
            // includes movie edits such as an empty lead-in or a trimmed start.
            CMItemCount nTimings = 0;
            CMSampleTimingInfo *outputTimings = NULL;
            if (count > 1) {
                outputTimings = calloc(count, sizeof(*outputTimings));
                if (!outputTimings || CMSampleBufferGetOutputSampleTimingInfoArray(buf, count, outputTimings, &nTimings) != noErr ||
                    (nTimings != count && nTimings != 1)) fail(@"Unable to resolve movie times in a multi-sample buffer");
            }
            CFArrayRef attachments = CMSampleBufferGetSampleAttachmentsArray(buf, false);
            for (CMItemIndex j = 0; j < count; j++) {
                CFDictionaryRef att = attachments && j < CFArrayGetCount(attachments) ? CFArrayGetValueAtIndex(attachments, j) : NULL;
                if (att && CFDictionaryGetValue(att, kCMSampleAttachmentKey_DoNotDisplay) == kCFBooleanTrue) continue;
                CMSampleTimingInfo timing;
                if (CMSampleBufferGetSampleTimingInfo(buf, j, &timing) != noErr) fail(@"Missing video sample timing");
                CMTime outPTS = CMSampleBufferGetOutputPresentationTimeStamp(buf);
                if (count > 1) {
                    if (nTimings == count) outPTS = outputTimings[j].presentationTimeStamp;
                    else outPTS = CMTimeAdd(outputTimings[0].presentationTimeStamp, CMTimeMultiply(outputTimings[0].duration, (int32_t)j));
                }
                if (!CMTIME_IS_NUMERIC(outPTS) || !CMTIME_IS_NUMERIC(timing.presentationTimeStamp)) fail(@"A presentable video sample has no PTS");
                if (CMTimeRangeContainsTime(track.timeRange, outPTS)) {
                    FVFrameTime *frame = [FVFrameTime new];
                    frame.sample = timing.presentationTimeStamp;
                    frame.presentation = outPTS;
                    [times addObject:frame];
                }
            }
            free(outputTimings);
            CFRelease(buf);
        }
    }
    if (reader.status != AVAssetReaderStatusCompleted) fail(reader.error.localizedDescription ?: @"Incomplete video track");
    if (!times.count) fail(@"No presentable frames in the video track");
    [times sortUsingComparator:^NSComparisonResult(FVFrameTime *a, FVFrameTime *b) {
        return CMTimeCompare(a.presentation, b.presentation);
    }];
    return times;
}

static NSDictionary *saveJPEG(AVAssetImageGenerator *generator, CMTime request, NSURL *url) {
    CMTime actual = kCMTimeInvalid;
    NSError *error = nil;
    CGImageRef image = [generator copyCGImageAtTime:request actualTime:&actual error:&error];
    if (!image) fail([NSString stringWithFormat:@"Frame %.9f s: %@", CMTimeGetSeconds(request), error ?: @"decode failed"]);
    if (CMTimeCompare(actual, request) != 0)
        fail([NSString stringWithFormat:@"Exact PTS check failed: requested %.9f, got %.9f", CMTimeGetSeconds(request), CMTimeGetSeconds(actual)]);
    CGImageDestinationRef dst = CGImageDestinationCreateWithURL((__bridge CFURLRef)url, CFSTR("public.jpeg"), 1, NULL);
    if (!dst) fail(@"Cannot open the JPEG destination");
    CGImageDestinationAddImage(dst, image, (__bridge CFDictionaryRef)@{(__bridge NSString *)kCGImageDestinationLossyCompressionQuality: @0.92});
    if (!CGImageDestinationFinalize(dst)) fail(@"Cannot write the JPEG");
    NSDictionary *size = @{@"width": @(CGImageGetWidth(image)), @"height": @(CGImageGetHeight(image))};
    CFRelease(dst);
    CGImageRelease(image);
    return size;
}

static AVAssetImageGenerator *imageGenerator(AVURLAsset *asset) {
    AVAssetImageGenerator *gen = [[AVAssetImageGenerator alloc] initWithAsset:asset];
    gen.appliesPreferredTrackTransform = YES;
    gen.requestedTimeToleranceBefore = kCMTimeZero;
    gen.requestedTimeToleranceAfter = kCMTimeZero;
    gen.apertureMode = AVAssetImageGeneratorApertureModeEncodedPixels;
    return gen;
}

static NSDictionary *extract(AVURLAsset *asset, NSURL *frameDir, CMTime step, NSArray *marks) {
    NSArray<AVAssetTrack *> *videos = [asset tracksWithMediaType:AVMediaTypeVideo];
    if (!videos.count) fail(@"No readable video track");
    // ImageGenerator selects the primary video implicitly. Do not attach PTS from
    // one video track to a JPEG potentially taken from a different one.
    if (videos.count != 1) fail(@"Multiple video tracks require explicit track selection");
    AVAssetTrack *track = videos.firstObject;
    NSArray<FVFrameTime *> *times = presentationTimes(asset, track);
    AVAssetImageGenerator *gen = imageGenerator(asset);
    CMTime first = times.firstObject.presentation, next = kCMTimeZero, last = kCMTimeInvalid;
    CMTimeRange trackRange = track.timeRange;
    NSMutableArray *rows = [NSMutableArray array];
    NSUInteger mark = 0;
    for (NSUInteger i = 0; i < times.count; i++) {
        @autoreleasepool {
            CMTime pts = times[i].presentation, rel = CMTimeSubtract(pts, first);
            BOOL onGrid = CMTimeCompare(rel, next) >= 0;
            BOOL endpoint = (i + 1 == times.count);
            NSMutableArray *hits = [NSMutableArray array];
            while (mark < marks.count) {
                NSArray *request = marks[mark];
                CMTime target = CMTimeMake([request[0] longLongValue], [request[1] intValue]);
                if (CMTimeCompare(pts, target) < 0) break;
                [hits addObject:@(++mark)];
            }
            if (!onGrid && !endpoint && !hits.count) continue;
            // Two samples with equal timestamps cannot be distinguished by a seek.
            if ((i > 0 && !CMTimeCompare(pts, times[i-1].presentation)) ||
                (i + 1 < times.count && !CMTimeCompare(pts, times[i+1].presentation)))
                fail(@"Duplicate selected presentation time. Cannot uniquely identify this frame");
            NSString *name = [NSString stringWithFormat:@"frame-%08lu.jpg", (unsigned long)i];
            NSDictionary *size = saveJPEG(gen, pts, [frameDir URLByAppendingPathComponent:name]);
            [rows addObject:@{@"frame_index": @(i), @"jpeg": [@"frames/" stringByAppendingString:name],
                @"pts": timeRecord(pts), @"sample_pts": timeRecord(times[i].sample), @"elapsed_seconds": @(CMTimeGetSeconds(rel)),
                @"target_elapsed_seconds": onGrid ? @(CMTimeGetSeconds(next)) : NSNull.null,
                @"previous_gap_seconds": CMTIME_IS_NUMERIC(last) ? @(CMTimeGetSeconds(CMTimeSubtract(pts, last))) : NSNull.null,
                @"selection": i == 0 && endpoint ? @"first+last" : i == 0 ? @"first" : endpoint && onGrid ? @"grid+last" : endpoint ? @"last" : onGrid ? @"grid" : @"annotation",
                @"annotation_ids": hits, @"width": size[@"width"], @"height": size[@"height"]}];
            last = pts;
            if (onGrid) {
                // Skip all grid points covered by this frame in a VFR gap.
                CMTime inTicks = CMTimeConvertScale(rel, step.timescale, kCMTimeRoundingMethod_RoundTowardNegativeInfinity);
                int64_t tick = (inTicks.value / step.value + 1) * step.value;
                next = CMTimeMake(tick, step.timescale);
            }
        }
    }
    if (mark != marks.count) fail(@"An info.txt mark is later than the last presentable PTS");
    NSMutableArray *audio = [NSMutableArray array];
    for (AVAssetTrack *t in [asset tracksWithMediaType:AVMediaTypeAudio]) {
        [audio addObject:@{@"track_id": @(t.trackID), @"codecs": codecs(t), @"start": timeRecord(t.timeRange.start),
            @"duration": timeRecord(t.timeRange.duration)}];
    }
    CMVideoFormatDescriptionRef desc = (__bridge CMVideoFormatDescriptionRef)track.formatDescriptions.firstObject;
    if (!desc) fail(@"Missing video format description");
    CMVideoDimensions dim = CMVideoFormatDescriptionGetDimensions(desc);
    CGAffineTransform x = track.preferredTransform;
    return @{@"reader": @"AVAssetReader + AVAssetImageGenerator (zero tolerance, actualTime verified)",
        @"presentation_timeline": @"AVFoundation movie presentation time, after container edits",
        @"duration": timeRecord(asset.duration), @"video_track_id": @(track.trackID), @"video_codecs": codecs(track),
        @"track_start": timeRecord(trackRange.start), @"track_duration": timeRecord(trackRange.duration),
        @"encoded_width": @(dim.width), @"encoded_height": @(dim.height),
        @"preferred_transform": @[@(x.a), @(x.b), @(x.c), @(x.d), @(x.tx), @(x.ty)],
        @"first_video_pts": timeRecord(first), @"last_video_pts": timeRecord(times.lastObject.presentation),
        @"presentable_frame_count": @(times.count), @"interval": timeRecord(step),
        @"audio_tracks": audio, @"frames": rows};
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc != 6 && argc != 7) fail(@"Usage: native extract|frame SOURCE OUTPUT TIME_VALUE TIME_SCALE [MARKS_JSON]");
        @try {
            NSString *mode = @(argv[1]);
            AVURLAsset *asset = [AVURLAsset URLAssetWithURL:[NSURL fileURLWithPath:@(argv[2])]
                options:@{AVURLAssetPreferPreciseDurationAndTimingKey:@YES,
                          AVURLAssetReferenceRestrictionsKey:@(AVAssetReferenceRestrictionForbidAll)}];
            NSURL *output = [NSURL fileURLWithPath:@(argv[3])];
            CMTime time = CMTimeMake(atoll(argv[4]), atoi(argv[5]));
            if (!CMTIME_IS_NUMERIC(time)) fail(@"Invalid time value");
            NSDictionary *result;
            NSArray *marks = argc == 7 ? [NSJSONSerialization JSONObjectWithData:[@(argv[6]) dataUsingEncoding:NSUTF8StringEncoding] options:0 error:NULL] : @[];
            if (![marks isKindOfClass:NSArray.class]) fail(@"Invalid annotation times");
            if ([mode isEqualToString:@"extract"] && time.value > 0) result = extract(asset, output, time, marks);
            else if ([mode isEqualToString:@"frame"]) result = saveJPEG(imageGenerator(asset), time, output);
            else fail(@"Invalid mode or non-positive interval");
            NSError *error = nil;
            NSData *json = [NSJSONSerialization dataWithJSONObject:result options:0 error:&error];
            if (!json) fail(error.localizedDescription);
            [[NSFileHandle fileHandleWithStandardOutput] writeData:json];
        } @catch (NSException *exception) {
            fail(exception.reason);
        }
    }
    return 0;
}
