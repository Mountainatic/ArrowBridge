#import <Cocoa/Cocoa.h>
#import <QuartzCore/QuartzCore.h>
int main(void) { @autoreleasepool {
  [NSApplication sharedApplication];
  [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
  NSRect frame = NSMakeRect(100, 100, 1400, 900);
  NSWindow *win = [[NSWindow alloc] initWithContentRect:frame styleMask:NSWindowStyleMaskBorderless backing:NSBackingStoreBuffered defer:NO];
  [win setLevel:NSFloatingWindowLevel]; [win setOpaque:YES];
  [win setBackgroundColor:[NSColor colorWithCalibratedRed:0.1 green:0.2 blue:0.5 alpha:1.0]];
  [win setReleasedWhenClosed:NO]; [win orderFrontRegardless];
  NSView *v = [[NSView alloc] initWithFrame:frame]; [v setWantsLayer:YES];
  [win setContentView:v];
  CALayer *ball = [CALayer layer];
  ball.bounds = CGRectMake(0,0,700,500); ball.position = CGPointMake(100,450);
  ball.backgroundColor = [[NSColor colorWithCalibratedRed:0.9 green:0.45 blue:0.1 alpha:1.0] CGColor];
  [v.layer addSublayer:ball];
  CABasicAnimation *a = [CABasicAnimation animationWithKeyPath:@"position.x"];
  a.fromValue = @100.0; a.toValue = @1200.0; a.duration = 1.5; a.autoreverses = YES; a.repeatCount = 4;
  [ball addAnimation:a forKey:@"bench"];
  [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:7.0]];
  [win orderOut:nil];
} return 0; }
