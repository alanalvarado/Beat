//
//  ApplicationDelegate.h
//  Beat
//
//  Copyright © 2019-2020 Lauri-Matti Parppei. All rights reserved.
//  Copyright © 2016 Hendrik Noeller. All rights reserved.
//	Released under GPL license.

#import <Cocoa/Cocoa.h>
#import <WebKit/WebKit.h>
#import <UserNotifications/UserNotifications.h>
#import "BeatDocumentController.h"

@interface BeatAppDelegate : NSObject <NSApplicationDelegate, NSStreamDelegate, NSMenuDelegate, UNUserNotificationCenterDelegate>

@property (nonatomic) bool darkMode;
@property (nonatomic) bool forceLightMode;
@property (nonatomic) bool forceDarkMode;

// Versioning menu
@property (nonatomic, weak) IBOutlet NSMenu *versionMenu;

// Plugin support
@property (nonatomic, weak) IBOutlet NSMenu *pluginMenu;
@property (nonatomic, weak) IBOutlet NSMenu *exportMenu;
@property (nonatomic, weak) IBOutlet NSMenu *importMenu;

// Restoration
@property (nonatomic) bool preventRestoration;

// Modifier for "pro" version, meaning the App Store edition.
// You could think that one can just change this byte to true in the open source version, but actually the "pro" stuff is just additional content and not really restricting any other functionality in the app, so it's no use.
@property (nonatomic) bool proMode;

- (IBAction)showPatchNotes:(id)sender;

- (bool)isDark;
- (void)toggleDarkMode;
- (bool)isForcedLightMode;
- (bool)isForcedDarkMode;
- (bool)OSisDark;

- (void)showTemplate:(NSString*)name;
- (void)openConsole;
- (void)clearConsole;
-(void)logToConsole:(NSString*)string pluginName:(NSString*)pluginName;

+ (NSURL*)appDataPath:(NSString*)subPath;
- (NSURL*)appDataPath:(NSString*)subPath;
- (void)newDocumentWithContents:(NSString*)string;

- (void)openURLInWebBrowser:(NSString*)urlString;

- (IBAction)openPluginLibrary:(id)sender;
- (void)showNotification:(NSString*)title body:(NSString*)body identifier:(NSString*)identifier oneTime:(BOOL)showOnce interval:(CGFloat)interval;

- (IBAction)showReference:(id)sender;
- (IBAction)openDiscord:(id)sender;
- (IBAction)showSupport:(id)sender;

@end
