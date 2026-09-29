#import <Cocoa/Cocoa.h>
#import <WebKit/WebKit.h>
#import <EventKit/EventKit.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

static NSInteger const DataSchemaVersion = 3;
static NSString * const ViewModeKey = @"v140WebViewMode";
static NSString * const FrameKey = @"v140WebFrame";
static NSString * const LayoutMigrationKey = @"v140WebLayoutApplied";
static NSString * const CalendarSyncKey = @"v40CalendarSync";
static NSString * const BackgroundPathKey = @"v2BackgroundPath";
static NSString * const BackgroundVisibilityKey = @"v143BackgroundVisibility";
static NSString * const ThemeKey = @"v140Theme";

@interface DesktopPanel : NSPanel @end
@implementation DesktopPanel
- (BOOL)canBecomeKeyWindow { return YES; }
- (BOOL)canBecomeMainWindow { return YES; }
@end

@interface AppDelegate : NSObject <NSApplicationDelegate, WKScriptMessageHandler, WKNavigationDelegate, NSWindowDelegate>
@property DesktopPanel *panel;
@property WKWebView *webView;
@property NSStatusItem *statusItem;
@property NSMutableDictionary *state;
@property EKEventStore *eventStore;
@property BOOL calendarSyncEnabled;
@property BOOL edgeCollapsed;
@property NSString *theme;
@property CGFloat backgroundVisibility;
@property NSRect expandedFrame;
@property NSRect drawerClosedFrame;
@property NSString *currentMode;
@property id edgeClickMonitor;
@end

@implementation AppDelegate

- (NSURL *)supportURL {
    NSURL *base = [[NSFileManager defaultManager] URLsForDirectory:NSApplicationSupportDirectory inDomains:NSUserDomainMask].firstObject;
    return [base URLByAppendingPathComponent:@"PinnedNote" isDirectory:YES];
}
- (NSURL *)dataURL { return [[self supportURL] URLByAppendingPathComponent:@"data.json"]; }
- (NSURL *)backupsURL { return [[self supportURL] URLByAppendingPathComponent:@"Backups" isDirectory:YES]; }
- (NSString *)dayKey:(NSDate *)date {
    static NSDateFormatter *formatter; static dispatch_once_t once;
    dispatch_once(&once, ^{ formatter=[NSDateFormatter new]; formatter.locale=[NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"]; formatter.dateFormat=@"yyyy-MM-dd"; });
    return [formatter stringFromDate:date ?: NSDate.date];
}
- (NSMutableDictionary *)defaultState {
    return [@{ @"schemaVersion":@(DataSchemaVersion), @"tasks":[NSMutableArray array], @"events":[NSMutableArray array], @"ideas":[NSMutableArray array], @"taskTimer":[@{ @"mode":@"stopwatch",@"startedAt":@0,@"limit":@0 } mutableCopy], @"focus":[@{ @"mode":@"countdown",@"title":@"",@"duration":@1500,@"elapsed":@0,@"startedAt":@0,@"running":@NO } mutableCopy] } mutableCopy];
}
- (void)loadState {
    NSData *data=[NSData dataWithContentsOfURL:[self dataURL]]; NSDictionary *stored=data?[NSJSONSerialization JSONObjectWithData:data options:NSJSONReadingMutableContainers error:nil]:nil;
    self.state=[stored isKindOfClass:NSDictionary.class]?[stored mutableCopy]:[self defaultState];
    if(![self.state[@"tasks"] isKindOfClass:NSArray.class]) self.state[@"tasks"]=[NSMutableArray array];
    if(![self.state[@"events"] isKindOfClass:NSArray.class]) self.state[@"events"]=[NSMutableArray array];
    if(![self.state[@"ideas"] isKindOfClass:NSArray.class]) self.state[@"ideas"]=[NSMutableArray array];
    self.calendarSyncEnabled=[NSUserDefaults.standardUserDefaults boolForKey:CalendarSyncKey];
    if(self.calendarSyncEnabled){
        EKAuthorizationStatus status=[EKEventStore authorizationStatusForEntityType:EKEntityTypeEvent];
        BOOL allowed=NO;
        if(@available(macOS 14.0,*))allowed=(status==EKAuthorizationStatusWriteOnly||status==EKAuthorizationStatusFullAccess);else allowed=(status==EKAuthorizationStatusAuthorized);
        if(!allowed){self.calendarSyncEnabled=NO;[NSUserDefaults.standardUserDefaults setBool:NO forKey:CalendarSyncKey];}
    }
    self.theme=[NSUserDefaults.standardUserDefaults stringForKey:ThemeKey] ?: @"blue";
    self.backgroundVisibility=[NSUserDefaults.standardUserDefaults objectForKey:BackgroundVisibilityKey]?[NSUserDefaults.standardUserDefaults doubleForKey:BackgroundVisibilityKey]:82.0;
    self.currentMode=[NSUserDefaults.standardUserDefaults stringForKey:ViewModeKey] ?: @"all";
}
- (void)backupCurrentDataIfNeeded {
    NSFileManager *fm=NSFileManager.defaultManager;
    if(![fm fileExistsAtPath:[self dataURL].path])return;
    [fm createDirectoryAtURL:[self backupsURL] withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions:@0700} error:nil];
    NSDateFormatter *formatter=[NSDateFormatter new];formatter.locale=[NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];formatter.dateFormat=@"yyyy-MM-dd";
    NSURL *backup=[[self backupsURL] URLByAppendingPathComponent:[NSString stringWithFormat:@"data-%@.json",[formatter stringFromDate:NSDate.date]]];
    if(![fm fileExistsAtPath:backup.path])[fm copyItemAtURL:[self dataURL] toURL:backup error:nil];
    NSArray<NSURL *> *files=[fm contentsOfDirectoryAtURL:[self backupsURL] includingPropertiesForKeys:@[NSURLContentModificationDateKey] options:NSDirectoryEnumerationSkipsHiddenFiles error:nil];
    files=[files sortedArrayUsingComparator:^NSComparisonResult(NSURL *a,NSURL *b){NSDate *ad=nil,*bd=nil;[a getResourceValue:&ad forKey:NSURLContentModificationDateKey error:nil];[b getResourceValue:&bd forKey:NSURLContentModificationDateKey error:nil];return [bd compare:ad];}];
    for(NSUInteger i=12;i<files.count;i++)[fm removeItemAtURL:files[i] error:nil];
}
- (void)writeState {
    NSFileManager *fm=NSFileManager.defaultManager; [fm createDirectoryAtURL:[self supportURL] withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions:@0700} error:nil];[self backupCurrentDataIfNeeded];
    self.state[@"schemaVersion"]=@(DataSchemaVersion); self.state[@"savedAt"]=@(NSDate.date.timeIntervalSince1970);
    NSData *json=[NSJSONSerialization dataWithJSONObject:self.state options:NSJSONWritingPrettyPrinted|NSJSONWritingSortedKeys error:nil];
    if(json && [json writeToURL:[self dataURL] options:NSDataWritingAtomic error:nil]) [fm setAttributes:@{NSFilePosixPermissions:@0600} ofItemAtPath:[self dataURL].path error:nil];
}
- (NSString *)backgroundDataURL {
    NSString *path=[NSUserDefaults.standardUserDefaults stringForKey:BackgroundPathKey]; NSData *data=path.length?[NSData dataWithContentsOfFile:path]:nil; if(!data.length)return @"";
    NSString *ext=path.pathExtension.lowercaseString; NSString *mime=[ext isEqualToString:@"png"]?@"image/png":([ext isEqualToString:@"webp"]?@"image/webp":@"image/jpeg");
    return [NSString stringWithFormat:@"data:%@;base64,%@",mime,[data base64EncodedStringWithOptions:0]];
}
- (NSDictionary *)bootstrapPayload {
    return @{ @"state":self.state ?: [self defaultState], @"viewMode":self.currentMode ?: @"all", @"calendarSync":@(self.calendarSyncEnabled), @"background":[self backgroundDataURL], @"backgroundVisibility":@(self.backgroundVisibility), @"theme":self.theme ?: @"blue" };
}
- (void)pushState {
    NSData *json=[NSJSONSerialization dataWithJSONObject:[self bootstrapPayload] options:0 error:nil]; if(!json)return;
    NSString *payload=[[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding];
    [self.webView evaluateJavaScript:[NSString stringWithFormat:@"window.__PINNED_NOTE_BOOTSTRAP__(%@)",payload] completionHandler:nil];
}
- (void)sendResultKind:(NSString *)kind ok:(BOOL)ok message:(NSString *)message {
    NSData *data=[NSJSONSerialization dataWithJSONObject:@[kind ?: @"",@(ok),message ?: @""] options:0 error:nil];
    NSString *arguments=[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    [self.webView evaluateJavaScript:[NSString stringWithFormat:@"window.__PINNED_NOTE_RESULT__ && window.__PINNED_NOTE_RESULT__.apply(null,%@)",arguments] completionHandler:nil];
}
- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory]; [self loadState]; [self makeWindow]; [self makeStatusItem]; [self.panel orderFrontRegardless];
}
- (void)makeWindow {
    NSUserDefaults *defaults=NSUserDefaults.standardUserDefaults; NSRect frame=NSZeroRect; NSString *saved=[defaults stringForKey:FrameKey]; if(saved.length)frame=NSRectFromString(saved);
    if(![defaults boolForKey:LayoutMigrationKey] || frame.size.width<720 || frame.size.height<520){NSScreen *screen=NSScreen.mainScreen; frame=NSMakeRect(NSMidX(screen.visibleFrame)-450,NSMidY(screen.visibleFrame)-330,900,660);[defaults setBool:YES forKey:LayoutMigrationKey];}
    self.panel=[[DesktopPanel alloc] initWithContentRect:frame styleMask:NSWindowStyleMaskTitled|NSWindowStyleMaskResizable|NSWindowStyleMaskFullSizeContentView backing:NSBackingStoreBuffered defer:NO];
    self.panel.title=@"钉笺"; self.panel.titleVisibility=NSWindowTitleHidden; self.panel.titlebarAppearsTransparent=YES; self.panel.opaque=NO; self.panel.backgroundColor=NSColor.clearColor; self.panel.hasShadow=YES; self.panel.minSize=NSMakeSize(430,500); self.panel.releasedWhenClosed=NO; self.panel.hidesOnDeactivate=NO; self.panel.delegate=self;
    for(NSButton *button in @[[self.panel standardWindowButton:NSWindowCloseButton],[self.panel standardWindowButton:NSWindowMiniaturizeButton],[self.panel standardWindowButton:NSWindowZoomButton]])button.hidden=YES;
    self.panel.collectionBehavior=NSWindowCollectionBehaviorCanJoinAllSpaces|NSWindowCollectionBehaviorStationary|NSWindowCollectionBehaviorIgnoresCycle;
    WKWebViewConfiguration *configuration=[WKWebViewConfiguration new]; configuration.websiteDataStore=WKWebsiteDataStore.nonPersistentDataStore; [configuration.userContentController addScriptMessageHandler:self name:@"pinnedNote"];
    self.webView=[[WKWebView alloc] initWithFrame:NSZeroRect configuration:configuration]; self.webView.translatesAutoresizingMaskIntoConstraints=NO; self.webView.navigationDelegate=self; self.webView.wantsLayer=YES; self.webView.layer.cornerRadius=18; self.webView.layer.masksToBounds=YES; [self.webView setValue:@NO forKey:@"drawsBackground"];
    NSView *root=[NSView new]; root.translatesAutoresizingMaskIntoConstraints=NO; self.panel.contentView=root; [root addSubview:self.webView]; [NSLayoutConstraint activateConstraints:@[[self.webView.leadingAnchor constraintEqualToAnchor:root.leadingAnchor],[self.webView.trailingAnchor constraintEqualToAnchor:root.trailingAnchor],[self.webView.topAnchor constraintEqualToAnchor:root.topAnchor],[self.webView.bottomAnchor constraintEqualToAnchor:root.bottomAnchor]]];
    NSURL *url=[NSBundle.mainBundle URLForResource:@"ui" withExtension:@"html"]; [self.webView loadFileURL:url allowingReadAccessToURL:url.URLByDeletingLastPathComponent]; self.expandedFrame=frame; [self dockToDesktop];
    __weak typeof(self) weakSelf=self;
    self.edgeClickMonitor=[NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskLeftMouseDown handler:^NSEvent *(NSEvent *event){
        typeof(self) strongSelf=weakSelf;
        if(strongSelf.edgeCollapsed && event.window==strongSelf.panel){[strongSelf expandFromEdge];return nil;}
        return event;
    }];
}
- (void)webView:(WKWebView *)webView didFinishNavigation:(WKNavigation *)navigation { [self pushState]; }

- (void)userContentController:(WKUserContentController *)userContentController didReceiveScriptMessage:(WKScriptMessage *)message {
    if(![message.body isKindOfClass:NSDictionary.class])return; NSDictionary *body=message.body; NSString *type=body[@"type"];
    if([type isEqualToString:@"save"]){NSDictionary *incoming=body[@"state"]; if([incoming isKindOfClass:NSDictionary.class]){self.state=[incoming mutableCopy];[self writeState];}return;}
    if([type isEqualToString:@"mode"]){NSString *next=body[@"mode"] ?: @"all";NSUserDefaults *d=NSUserDefaults.standardUserDefaults;[d setObject:NSStringFromRect(self.panel.frame) forKey:[@"v140Frame_" stringByAppendingString:self.currentMode?:@"all"]];self.currentMode=next;[d setObject:next forKey:ViewModeKey];NSString *saved=[d stringForKey:[@"v140Frame_" stringByAppendingString:next]];NSRect target=saved.length?NSRectFromString(saved):NSZeroRect;if(target.size.width<430){NSSize size=[next isEqualToString:@"all"]?NSMakeSize(900,660):([next isEqualToString:@"schedule"]?NSMakeSize(430,560):NSMakeSize(430,520));target=self.panel.frame;target.origin.y+=target.size.height-size.height;target.size=size;}[self.panel setFrame:[self.panel constrainFrameRect:target toScreen:self.panel.screen?:NSScreen.mainScreen] display:YES animate:YES];return;}
    if([type isEqualToString:@"drawer"]){BOOL open=[body[@"open"] boolValue];if(open){self.drawerClosedFrame=self.panel.frame;NSRect f=self.panel.frame;f.size.width+=260;NSScreen*s=self.panel.screen?:NSScreen.mainScreen;CGFloat overflow=NSMaxX(f)-NSMaxX(s.visibleFrame);if(overflow>0)f.origin.x-=overflow;[self.panel setFrame:[self.panel constrainFrameRect:f toScreen:s] display:YES animate:YES];}else if(self.drawerClosedFrame.size.width>=360)[self.panel setFrame:self.drawerClosedFrame display:YES animate:YES];return;}
    if([type isEqualToString:@"move"]){CGFloat dx=[body[@"dx"] doubleValue],dy=[body[@"dy"] doubleValue];NSRect f=self.panel.frame;f.origin.x+=dx;f.origin.y-=dy;[self.panel setFrameOrigin:f.origin];return;}
    if([type isEqualToString:@"resize"]){CGFloat dw=[body[@"dw"] doubleValue],dh=[body[@"dh"] doubleValue];NSRect f=self.panel.frame;f.size.width=MAX(430,f.size.width+dw);f.size.height=MAX(500,f.size.height-dh);f.origin.y+=dh;[self.panel setFrame:f display:YES];return;}
    if([type isEqualToString:@"collapse"]){[self collapseToEdge];return;}
    if([type isEqualToString:@"quit"]){[self writeState];[NSApp terminate:nil];return;}
    if([type isEqualToString:@"calendarSync"]){[self setCalendarSync:[body[@"enabled"] boolValue]];return;}
    if([type isEqualToString:@"theme"]){NSString *theme=body[@"theme"] ?: @"blue";if(![@[@"blue",@"sky",@"navy"] containsObject:theme])theme=@"blue";self.theme=theme;[NSUserDefaults.standardUserDefaults setObject:theme forKey:ThemeKey];return;}
    if([type isEqualToString:@"backgroundVisibility"]){CGFloat value=MAX(20,MIN(100,[body[@"value"] doubleValue]));self.backgroundVisibility=value;[NSUserDefaults.standardUserDefaults setDouble:value forKey:BackgroundVisibilityKey];return;}
    if([type isEqualToString:@"calendarEvent"]){[self syncCalendarTitle:body[@"title"] start:[NSDate dateWithTimeIntervalSince1970:[body[@"start"] doubleValue]] end:[NSDate dateWithTimeIntervalSince1970:[body[@"end"] doubleValue]] source:body[@"source"] ?: @"钉笺"];return;}
    if([type isEqualToString:@"chooseBackground"]){[self chooseBackground];return;}
    if([type isEqualToString:@"removeBackground"]){[self removeBackground];return;}
    if([type isEqualToString:@"export"]){[self exportData];return;}
    if([type isEqualToString:@"import"]){[self importData];return;}
}
- (void)setCalendarSync:(BOOL)enabled {
    if(!enabled){self.calendarSyncEnabled=NO;[NSUserDefaults.standardUserDefaults setBool:NO forKey:CalendarSyncKey];[self pushState];[self sendResultKind:@"calendar" ok:YES message:@"已关闭 Apple 日历同步"];return;}
    if(!self.eventStore)self.eventStore=[EKEventStore new];
    void (^finish)(BOOL,NSError *)=^(BOOL granted,NSError *error){dispatch_async(dispatch_get_main_queue(), ^{self.calendarSyncEnabled=granted;[NSUserDefaults.standardUserDefaults setBool:granted forKey:CalendarSyncKey];[self pushState];NSString *message=granted?@"已开启，新的日程与计时会同步到 Apple 日历":(error.localizedDescription.length?error.localizedDescription:@"没有获得日历权限，请到系统设置中允许钉笺访问日历");[self sendResultKind:@"calendar" ok:granted message:message];});};
    if(@available(macOS 14.0,*))[self.eventStore requestWriteOnlyAccessToEventsWithCompletion:^(BOOL granted,NSError*error){finish(granted,error);}];else[self.eventStore requestAccessToEntityType:EKEntityTypeEvent completion:^(BOOL granted,NSError*error){finish(granted,error);}];
}
- (void)syncCalendarTitle:(NSString *)title start:(NSDate *)start end:(NSDate *)end source:(NSString *)source {
    if(!self.calendarSyncEnabled || !title.length || [end timeIntervalSinceDate:start]<=0)return; if(!self.eventStore)self.eventStore=[EKEventStore new];
    EKEvent *event=[EKEvent eventWithEventStore:self.eventStore];event.title=title;event.startDate=start;event.endDate=end;event.notes=[NSString stringWithFormat:@"由钉笺自动记录 · %@",source];event.calendar=self.eventStore.defaultCalendarForNewEvents;NSError *error=nil;BOOL saved=[self.eventStore saveEvent:event span:EKSpanThisEvent commit:YES error:&error];dispatch_async(dispatch_get_main_queue(), ^{[self sendResultKind:@"calendar" ok:saved message:saved?@"已同步到 Apple 日历":(error.localizedDescription.length?error.localizedDescription:@"写入 Apple 日历失败")];});
}
- (void)chooseBackground {
    NSOpenPanel *panel=NSOpenPanel.openPanel;panel.allowedContentTypes=@[UTTypeImage];panel.allowsMultipleSelection=NO;[panel beginSheetModalForWindow:self.panel completionHandler:^(NSModalResponse result){if(result!=NSModalResponseOK)return;NSURL *source=panel.URL;NSString *ext=source.pathExtension.length?source.pathExtension:@"png";NSURL *dest=[[self supportURL] URLByAppendingPathComponent:[@"custom-background." stringByAppendingString:ext]];NSFileManager *fm=NSFileManager.defaultManager;NSError *error=nil;[fm createDirectoryAtURL:[self supportURL] withIntermediateDirectories:YES attributes:nil error:&error];if(!error){NSString *oldPath=[NSUserDefaults.standardUserDefaults stringForKey:BackgroundPathKey];if(![source.path isEqualToString:dest.path]){[fm removeItemAtURL:dest error:nil];if(![fm copyItemAtURL:source toURL:dest error:&error]&&error==nil)error=[NSError errorWithDomain:@"PinnedNote" code:1 userInfo:@{NSLocalizedDescriptionKey:@"无法复制这张图片"}];}else dest=source;}if(!error){NSString *oldPath=[NSUserDefaults.standardUserDefaults stringForKey:BackgroundPathKey];if(oldPath.length&&![oldPath isEqualToString:dest.path]&&[oldPath hasPrefix:[self supportURL].path])[fm removeItemAtPath:oldPath error:nil];[NSUserDefaults.standardUserDefaults setObject:dest.path forKey:BackgroundPathKey];[self pushState];[self sendResultKind:@"background" ok:YES message:@"背景图片已更新"];}else [self sendResultKind:@"background" ok:NO message:error.localizedDescription ?: @"背景图片设置失败"];}];
}
- (void)removeBackground {NSString *path=[NSUserDefaults.standardUserDefaults stringForKey:BackgroundPathKey];if(path.length&&[path hasPrefix:[self supportURL].path])[NSFileManager.defaultManager removeItemAtPath:path error:nil];[NSUserDefaults.standardUserDefaults removeObjectForKey:BackgroundPathKey];[self pushState];[self sendResultKind:@"background" ok:YES message:@"已恢复默认背景"];}
- (void)exportData { [self writeState]; NSSavePanel *panel=NSSavePanel.savePanel;panel.allowedContentTypes=@[UTTypeJSON];panel.nameFieldStringValue=@"钉笺数据.json";[panel beginSheetModalForWindow:self.panel completionHandler:^(NSModalResponse result){if(result==NSModalResponseOK)[NSFileManager.defaultManager copyItemAtURL:[self dataURL] toURL:panel.URL error:nil];}]; }
- (void)importData {NSOpenPanel *panel=NSOpenPanel.openPanel;panel.allowedContentTypes=@[UTTypeJSON];[panel beginSheetModalForWindow:self.panel completionHandler:^(NSModalResponse result){if(result!=NSModalResponseOK)return;NSData *data=[NSData dataWithContentsOfURL:panel.URL];NSDictionary *incoming=data?[NSJSONSerialization JSONObjectWithData:data options:NSJSONReadingMutableContainers error:nil]:nil;if([incoming isKindOfClass:NSDictionary.class]&&[incoming[@"schemaVersion"] integerValue]<=DataSchemaVersion){self.state=[incoming mutableCopy];[self writeState];[self pushState];}}];}

- (void)dockToDesktop {self.panel.level=CGWindowLevelForKey(kCGDesktopIconWindowLevelKey)+1;[self.panel orderFrontRegardless];}
- (void)collapseToEdge {if(self.edgeCollapsed)return;self.expandedFrame=self.panel.frame;NSScreen *screen=self.panel.screen?:NSScreen.mainScreen;NSRect f=self.panel.frame;f.origin.x=NSMaxX(screen.visibleFrame)-8;self.edgeCollapsed=YES;[self.webView evaluateJavaScript:@"document.documentElement.classList.add('edge-collapsed')" completionHandler:nil];[self.panel setFrame:f display:YES animate:YES];}
- (void)expandFromEdge {if(!self.edgeCollapsed)return;self.edgeCollapsed=NO;[self.webView evaluateJavaScript:@"document.documentElement.classList.remove('edge-collapsed')" completionHandler:nil];[self.panel setFrame:[self.panel constrainFrameRect:self.expandedFrame toScreen:self.panel.screen?:NSScreen.mainScreen] display:YES animate:YES];[self dockToDesktop];}
- (void)showMain:(id)sender {if(self.edgeCollapsed)[self expandFromEdge];[self.panel orderFrontRegardless];}
- (void)hideMain:(id)sender {[self collapseToEdge];}
- (void)quit:(id)sender {[self writeState];[NSApp terminate:nil];}
- (void)makeStatusItem {self.statusItem=[NSStatusBar.systemStatusBar statusItemWithLength:NSSquareStatusItemLength];self.statusItem.button.image=[NSImage imageWithSystemSymbolName:@"checklist" accessibilityDescription:@"钉笺"];NSMenu *menu=[NSMenu new];[menu addItemWithTitle:@"显示钉笺" action:@selector(showMain:) keyEquivalent:@"1"];[menu addItemWithTitle:@"收进右侧" action:@selector(hideMain:) keyEquivalent:@"2"];[menu addItem:NSMenuItem.separatorItem];[menu addItemWithTitle:@"退出钉笺" action:@selector(quit:) keyEquivalent:@"q"];self.statusItem.menu=menu;}
- (void)windowDidResize:(NSNotification *)notification {if(self.edgeCollapsed)return;self.expandedFrame=self.panel.frame;[NSUserDefaults.standardUserDefaults setObject:NSStringFromRect(self.panel.frame) forKey:FrameKey];}
- (void)windowDidMove:(NSNotification *)notification {if(self.edgeCollapsed)return;self.expandedFrame=self.panel.frame;[NSUserDefaults.standardUserDefaults setObject:NSStringFromRect(self.panel.frame) forKey:FrameKey];}
- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender{return NO;}
@end

int main(int argc,const char *argv[]){@autoreleasepool{NSApplication *app=NSApplication.sharedApplication;AppDelegate *delegate=[AppDelegate new];app.delegate=delegate;[app run];}return 0;}
