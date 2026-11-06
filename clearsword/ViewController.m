#import "ViewController.h"
#import "poc.h"

@interface ViewController ()

@property(weak, nonatomic) IBOutlet UIButton* runButton;
@property(weak, nonatomic) IBOutlet UITextView* logView;
@property(nonatomic) BOOL started;

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

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
      int result = clearsword_run();
      dispatch_async(dispatch_get_main_queue(), ^{
        NSString* title = result == 0 ? @"KRW ready" : (result == -2 ? @"Reboot required" : @"Retry");
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
