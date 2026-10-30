/* Document runner: a one-time-installed app that opens a .cosmo file (the unmodified fat executable) by starting the Cosmopolitan loader on it.
 * The file is a document to Launch Services; only this app is assessed by Gatekeeper. Proof of the run goes to /tmp/runner-proof.txt for the CI test. */
#import <Cocoa/Cocoa.h>
@interface D : NSObject <NSApplicationDelegate> @end
@implementation D
- (BOOL)application:(NSApplication *)app openFile:(NSString *)path {
  NSString *res = [[NSBundle mainBundle] resourcePath];
  NSString *loader = [[[NSBundle mainBundle] executablePath] stringByDeletingLastPathComponent];
  loader = [loader stringByAppendingPathComponent:@"ape-loader"];
  NSTask *t = [[NSTask alloc] init]; t.launchPath = loader; t.arguments = @[path];
  NSPipe *p = [NSPipe pipe]; t.standardOutput = p; t.standardError = p;
  @try { [t launch]; } @catch (NSException *e) { [@"launch failed" writeToFile:@"/tmp/runner-proof.txt" atomically:YES encoding:NSUTF8StringEncoding error:nil]; [NSApp terminate:nil]; return NO; }
  NSData *d = [[p fileHandleForReading] readDataToEndOfFile]; [t waitUntilExit];
  NSString *s = [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding];
  [[NSString stringWithFormat:@"exit %d\n%@", t.terminationStatus, s] writeToFile:@"/tmp/runner-proof.txt" atomically:YES encoding:NSUTF8StringEncoding error:nil];
  (void)res; [NSApp terminate:nil]; return YES;
}
@end
int main(void) { @autoreleasepool { NSApplication *a = [NSApplication sharedApplication]; D *d = [D new]; a.delegate = d; [a run]; } return 0; }
