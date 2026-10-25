// soak_surface_churn.m —— 用户态 IOSurface / CoreAnimation 抖动器（soak 压测的第二个负载）
//
// 目的：制造 "新 IOSurface → 画进共享用户页 → 交给 WindowServer 合成 → 立刻丢弃" 的高频循环。
// 这个循环对应内核里的连锁动作：
//   IOSurface 新分配        -> i915_gem_userptr_alloc 把客户端页 pin 住
//   layer.contents = surf   -> WindowServer 合成器 import 该 surface（再 pin 一次）
//   下一帧替换 contents     -> 旧 surface 引用归零 -> i915_gem_object_free
//                           -> i915_gem_userptr_put_pages -> linux_release_pages
//                           -> xg_bsd_vm_page_free("xegfx: vm: freeing wired page ... (ref 0x1)")
// 所以本工具的核心不是"渲染多快"，而是"每秒创建/丢弃多少次带 IOSurface 的 layer 内容"。
//
// 参数（都不需要 root，只要当前用户在图形会话里）：
//   --seconds N     运行多少秒，默认 60
//   --windows N     窗口数（= 并发合成器 surface 槽位数），默认 1
//   --surfaces N    每次迭代每窗口新建的 IOSurface 数，默认 2
//   --size WxH      surface 尺寸，默认 512x384（×3 种尺寸轮换，制造不同页数）
//   --metal         额外走一遍 CVMetalTextureCache/Metal 纹理（默认关闭；驱动不稳时再开）
//   --quiet         不打印每秒统计（仍然打印 FINAL 行）
//
// 输出：每秒一行 "t=..s iter=.. fps=.. surf=.. win=.. metal=.."，结尾一行 FINAL，便于上层脚本解析。
//
// 编译：clang -O2 -framework Cocoa -framework QuartzCore -framework IOSurface \
//              -framework Metal -framework CoreVideo -o /tmp/soak_surface_churn soak_surface_churn.m
// （不使用 ARC：手工 retain/release / CFRelease，行为可预测，也不依赖 blocks。）

#import <Cocoa/Cocoa.h>
#import <QuartzCore/QuartzCore.h>
#import <IOSurface/IOSurface.h>
#import <CoreGraphics/CoreGraphics.h>
#import <Metal/Metal.h>
#import <CoreVideo/CoreVideo.h>

// 把字符串形式的 "WxH" 解析成宽高；失败返回 0
static int parse_size(const char *s, int *w, int *h) {
    int a = 0, b = 0;
    if (!s || sscanf(s, "%dx%d", &a, &b) != 2) return 0;
    if (a < 16 || b < 16 || a > 8192 || b > 8192) return 0;
    *w = a; *h = b;
    return 1;
}

// 用 CoreGraphics 往 IOSurface 的映射页里画一帧（移动色块 + 渐变条）。
// 这一步直接写共享用户页，对应 userptr 的"客户端页"来源。
static void draw_frame(void *base, size_t bpr, int w, int h, long iter) {
    if (!base || bpr == 0) return;
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    if (!cs) return;
    CGContextRef ctx = CGBitmapContextCreateWithData(
        base, (size_t)w, (size_t)h, 8, bpr, cs,
        (CGBitmapInfo)(kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little),
        NULL, NULL);            // 释放回调 NULL：内存归 IOSurface，不交给 CG 释放
    if (ctx) {
        // 背景随迭代缓慢变化，保证每帧内容都不同（避免合成器做内容去重）
        CGFloat r = 0.05f + (CGFloat)((iter * 7) % 100) / 500.0f;
        CGFloat g = 0.10f + (CGFloat)((iter * 13) % 100) / 900.0f;
        CGContextSetRGBFillColor(ctx, r, g, 0.35f, 1.0f);
        CGContextFillRect(ctx, CGRectMake(0, 0, w, h));
        // 三个运动色块：每帧位置不同 -> 合成器必须重新上传/重绘这块 surface
        int i;
        for (i = 0; i < 3; i++) {
            CGFloat t = (CGFloat)((iter + i * 31) % 120) / 120.0f;
            CGFloat x = t * (CGFloat)(w - 40);
            CGFloat y = (CGFloat)((iter * 3 + i * 47) % (h > 40 ? h - 40 : 1));
            CGContextSetRGBFillColor(ctx, 0.9f, 0.35f + 0.2f * (CGFloat)i, 0.1f + 0.15f * (CGFloat)i, 1.0f);
            CGContextFillRect(ctx, CGRectMake(x, y, 40 + (CGFloat)(i * 12), 28));
        }
        CGContextFlush(ctx);
        CGContextRelease(ctx);
    }
    CGColorSpaceRelease(cs);
}

int main(int argc, char **argv) {
    double seconds = 60.0;
    int nwin = 1, nsurf = 2;
    int W = 512, H = 384;
    int useMetal = 0, quiet = 0;

    int i;
    for (i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--seconds") && i + 1 < argc) seconds = atof(argv[++i]);
        else if (!strcmp(argv[i], "--windows") && i + 1 < argc) nwin = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--surfaces") && i + 1 < argc) nsurf = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--size") && i + 1 < argc) { int w, h; if (parse_size(argv[++i], &w, &h)) W = w, H = h; }
        else if (!strcmp(argv[i], "--metal")) useMetal = 1;
        else if (!strcmp(argv[i], "--quiet")) quiet = 1;
        else if (!strcmp(argv[i], "--help")) {
            printf("usage: %s [--seconds N] [--windows N] [--surfaces N] [--size WxH] [--metal] [--quiet]\n", argv[0]);
            return 0;
        }
    }
    if (seconds <= 0) seconds = 60;
    if (nwin < 1) nwin = 1; if (nwin > 8) nwin = 8;
    if (nsurf < 1) nsurf = 1; if (nsurf > 16) nsurf = 16;
    setvbuf(stdout, NULL, _IOLBF, 0);   // 行缓冲：上层脚本按行解析

    int rc = 0;
    @autoreleasepool {
        [NSApplication sharedApplication];
        // Accessory：不抢焦点、不进 Dock，避免把用户正在用的 App 顶掉
        [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];

        NSMutableArray *windows = [[NSMutableArray alloc] init];
        NSMutableArray *slotLayers = [[NSMutableArray alloc] init];
        for (i = 0; i < nwin; i++) {
            NSRect frame = NSMakeRect(80 + i * 60, 80 + i * 50, 600, 420);
            NSWindow *win = [[NSWindow alloc] initWithContentRect:frame
                                                        styleMask:NSWindowStyleMaskBorderless
                                                          backing:NSBackingStoreBuffered
                                                            defer:NO];
            [win setLevel:NSNormalWindowLevel];
            [win setOpaque:YES];
            [win setIgnoresMouseEvents:YES];
            [win setReleasedWhenClosed:NO];
            [win setBackgroundColor:[NSColor blackColor]];
            NSView *view = [[NSView alloc] initWithFrame:frame];
            [view setWantsLayer:YES];
            [win setContentView:view];
            CALayer *slot = [CALayer layer];
            slot.frame = CGRectMake(0, 0, 600, 420);
            slot.contentsGravity = kCAGravityResize;
            [view.layer addSublayer:slot];
            [windows addObject:win];
            [slotLayers addObject:slot];
            [win orderFrontRegardless];
            [view release];
        }
        if ([windows count] == 0) {
            fprintf(stderr, "no window created (no GUI session?)\n");
            rc = 2;
        }

        // 可选 Metal 路径：把 IOSurface 包装成 CVPixelBuffer -> MTLTexture。
        // 这一步走的就是 Metal 驱动的 surface 绑定（pin）与释放（unpin）。
        id<MTLDevice> dev = nil;
        CVMetalTextureCacheRef texCache = NULL;
        if (useMetal) {
            dev = MTLCreateSystemDefaultDevice();
            if (dev) {
                CVReturn cvr = CVMetalTextureCacheCreate(kCFAllocatorDefault, NULL, dev,
                                                         NULL, &texCache);
                if (cvr != kCVReturnSuccess) texCache = NULL;
                if (!quiet) fprintf(stderr, "metal device=%s cache=%s\n",
                                    [[dev name] UTF8String], texCache ? "yes" : "no");
            } else if (!quiet) {
                fprintf(stderr, "metal device unavailable (XEMTL 插件未生效？继续纯 CA/IOSurface 负载)\n");
            }
        }

        double t0 = CFAbsoluteTimeGetCurrent();
        double next_report = t0 + 1.0;
        long iter = 0, surf_total = 0, iter_at_report = 0;

        while (1) {
            double now = CFAbsoluteTimeGetCurrent();
            if (now - t0 >= seconds) break;

            @autoreleasepool {
                int wi;
                for (wi = 0; wi < nwin && wi < 8; wi++) {
                    CALayer *slot = [slotLayers objectAtIndex:(NSUInteger)wi];
                    NSWindow *win = [windows objectAtIndex:(NSUInteger)wi];
                    // 尺寸轮换：不同页数 -> 不同的 vm 分配/释放路径
                    int w = W + (int)((iter + wi) % 3) * 64;
                    int h = H + (int)((iter + wi) % 2) * 48;
                    int si;
                    for (si = 0; si < nsurf && si < 16; si++) {
                        NSDictionary *attrs = [NSDictionary dictionaryWithObjectsAndKeys:
                            [NSNumber numberWithInt:w], (id)kIOSurfaceWidth,
                            [NSNumber numberWithInt:h], (id)kIOSurfaceHeight,
                            [NSNumber numberWithInt:4], (id)kIOSurfaceBytesPerElement,
                            [NSNumber numberWithUnsignedInt:0x42475241 /* 'BGRA' */], (id)kIOSurfacePixelFormat,
                            nil];
                        IOSurfaceRef s = IOSurfaceCreate((CFDictionaryRef)attrs);
                        if (!s) continue;
                        surf_total++;

                        // 1) 客户端页写入（userptr 的页来源）
                        if (IOSurfaceLock(s, kIOSurfaceLockAvoidSync, NULL) == kIOReturnSuccess) {
                            draw_frame(IOSurfaceGetBaseAddress(s), IOSurfaceGetBytesPerRow(s),
                                       (int)IOSurfaceGetWidth(s), (int)IOSurfaceGetHeight(s), iter);
                            IOSurfaceUnlock(s, 0, NULL);
                        }

                        // 2) 可选：Metal 纹理绑定（pin），随即释放（unpin）
                        if (texCache && si == 0) {
                            CVPixelBufferRef pb = NULL;
                            if (CVPixelBufferCreateWithIOSurface(kCFAllocatorDefault, s, NULL, &pb) == kCVReturnSuccess && pb) {
                                CVMetalTextureRef tex = NULL;
                                size_t tw = (size_t)w, th = (size_t)h;
                                if (CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, texCache, pb,
                                                                              NULL, MTLPixelFormatBGRA8Unorm,
                                                                              tw, th, 0, &tex) == kCVReturnSuccess && tex) {
                                    CVMetalTextureGetTexture(tex);   // 触发驱动侧 surface 绑定
                                    CFRelease(tex);
                                }
                                CFRelease(pb);
                            }
                        }

                        // 3) 把 surface 交给合成器：layer.contents 持有 CF 引用，下一轮替换时释放
                        if (si == 0) {
                            slot.contents = (id)s;
                            slot.contentsScale = 1.0;
                        }
                        // 4) 立刻丢掉本地引用；surface 是否存活取决于 layer/WindowServer 的引用
                        CFRelease(s);
                        (void)win;
                    }
                    // 每帧动一下几何，强制合成器重新布局这块 surface（而不是复用缓存）
                    CGFloat off = (CGFloat)(iter % 20);
                    slot.bounds = CGRectMake(0, 0, 600 + off, 420 + off);

                    // 额外的一次 layer 树增删：让 WindowServer 每次都要处理新的 surface 提交
                    CALayer *tmp = [CALayer layer];
                    tmp.frame = CGRectMake(0, 0, 32, 32);
                    tmp.backgroundColor = CGColorGetConstantColor(kCGColorWhite);
                    [[win contentView].layer addSublayer:tmp];
                    [CATransaction begin];
                    [CATransaction setDisableActions:YES];
                    [CATransaction commit];
                    [CATransaction flush];
                    [tmp removeFromSuperlayer];
                }
                iter++;
                iter_at_report++;

                // 非阻塞地抽一下 runloop，让 CA 事务真正发到 WindowServer
                CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0, true);
            }

            double t = CFAbsoluteTimeGetCurrent();
            if (t >= next_report) {
                double fps = (double)iter_at_report / (t - (next_report - 1.0));
                if (!quiet) {
                    printf("t=%.0fs iter=%ld fps=%.1f surf=%ld win=%d metal=%d\n",
                           t - t0, iter, fps, surf_total, nwin, useMetal ? 1 : 0);
                }
                iter_at_report = 0;
                next_report = t + 1.0;
            }
        }

        double total = CFAbsoluteTimeGetCurrent() - t0;
        if (total <= 0) total = 1;
        printf("FINAL seconds=%.1f iter=%ld fps=%.1f surf=%ld win=%d metal=%d\n",
               total, iter, (double)iter / total, surf_total, nwin, useMetal ? 1 : 0);

        if (texCache) CFRelease(texCache);
        int wi;
        for (wi = 0; wi < nwin && wi < 8; wi++) {
            CALayer *slot = [slotLayers objectAtIndex:(NSUInteger)wi];
            slot.contents = nil;
            [[windows objectAtIndex:(NSUInteger)wi] orderOut:nil];
        }
        [slotLayers release];
        [windows release];
    }
    return rc;
}
