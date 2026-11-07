#import "ViewController.h"
#import "agx.h"
#import "poc.h"

@interface ViewController ()

@property(weak, nonatomic) IBOutlet UIButton* runButton;
@property(weak, nonatomic) IBOutlet UITextView* logView;
@property(nonatomic) BOOL started;
@property(nonatomic) BOOL selfTestOnly;
@property(nonatomic) agx_test_mode_t testMode;
@property(nonatomic) uint64_t testArgument;

@end

static __weak UITextView* activeLogView;

static void appendLog(const char* line) {
    NSString* text = [NSString stringWithUTF8String:line];
    if (!text) return;

    dispatch_async(dispatch_get_main_queue(), ^{
      UITextView* logView = activeLogView;
      if (!logView) return;
      logView.text = [logView.text stringByAppendingFormat:@"%@\n", text];
      [logView scrollRangeToVisible:NSMakeRange(logView.text.length, 0)];
    });
}

@implementation ViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    activeLogView = self.logView;
    self.logView.font = [UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightRegular];
    self.logView.backgroundColor = UIColor.blackColor;
    self.logView.textColor = UIColor.systemGreenColor;
    self.selfTestOnly = [NSProcessInfo.processInfo.arguments containsObject:@"--agx-self-test"];
    self.testMode = AGX_TEST_SHADOW;
    NSArray<NSString*>* arguments = NSProcessInfo.processInfo.arguments;
    for (NSUInteger index = 0; index < arguments.count; index++) {
        NSString* argument = arguments[index];
        agx_test_mode_t mode;
        if (!agx_test_mode_from_argument(argument.UTF8String, &mode)) continue;
        self.testMode = mode;
        if (mode == AGX_TEST_READ && index + 1 < arguments.count) {
            self.testArgument = strtoull(arguments[index + 1].UTF8String, NULL, 0);
        }
    }
    poc_set_log_handler(appendLog);
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];

    if (!self.started) {
        self.started = YES;
        [self go:self.runButton];
    }
}

- (IBAction)go:(UIButton*)sender {
    if (!sender.enabled) {
        return;
    }

    sender.enabled = NO;
    [sender setTitle:@"running..." forState:UIControlStateDisabled];
    BOOL selfTestOnly = self.selfTestOnly;
    agx_test_mode_t testMode = self.testMode;
    uint64_t testArgument = self.testArgument;

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
      int result = selfTestOnly ? (agx_buffer_rw_self_test() ? 0 : -1) : clearsword_run_test(testMode, testArgument);
      dispatch_async(dispatch_get_main_queue(), ^{
        NSString* title;
        if (result == 0) {
            title = selfTestOnly ? @"AGX R/W ready" : (testMode == AGX_TEST_ACQUIRE_ONLY ? @"KRW acquired — reboot" : @"KRW + AGX ready");
        } else {
            title = result == -2 ? @"Reboot required" : @"Retry";
        }
        BOOL enabled = result == -1;
        [sender setTitle:title forState:UIControlStateNormal];
        [sender setTitle:title forState:UIControlStateDisabled];
        sender.enabled = enabled;
      });
    });
}

- (void)dealloc {
    if (activeLogView == self.logView) {
        activeLogView = nil;
        poc_set_log_handler(NULL);
    }
}

@end
