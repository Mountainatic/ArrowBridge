// Report the main display's CG mode refresh rate and the CVDisplayLink nominal output period.
// The firmware framebuffer describes its modes with no timing (refreshRate 0), CoreVideo then falls back to
// 30 Hz through WindowServer's realtime VBL delta; this probe prints both paths so a kext change can be checked.
#include <ApplicationServices/ApplicationServices.h>
#include <CoreVideo/CoreVideo.h>
#include <stdio.h>
int main(void) {
    CGDirectDisplayID d = CGMainDisplayID();
    CGDisplayModeRef m = CGDisplayCopyDisplayMode(d);
    printf("main display id=%u online=%d active=%d\n", (unsigned)d, CGDisplayIsOnline(d), CGDisplayIsActive(d));
    if (m) {
        printf("CGDisplayMode: %zux%zu refresh=%.4f Hz pixelEncoding=%s\n", CGDisplayModeGetWidth(m), CGDisplayModeGetHeight(m),
               CGDisplayModeGetRefreshRate(m), CGDisplayModeCopyPixelEncoding(m) ? "yes" : "no");
        CFRelease(m);
    } else printf("CGDisplayMode: <none>\n");
    CVDisplayLinkRef link = NULL;
    CVReturn r = CVDisplayLinkCreateWithCGDisplay(d, &link);
    printf("CVDisplayLinkCreateWithCGDisplay: %d\n", r);
    if (r == kCVReturnSuccess && link) {
        CVTime t = CVDisplayLinkGetNominalOutputVideoRefreshPeriod(link);
        printf("CVDisplayLink nominal: %d/%d flags=%d -> %.6f Hz\n", (int)t.timeValue, (int)t.timeScale, (int)t.flags,
               t.timeValue ? (double)t.timeScale / (double)t.timeValue : 0.0);
        CVDisplayLinkRelease(link);
    }
    return 0;
}
