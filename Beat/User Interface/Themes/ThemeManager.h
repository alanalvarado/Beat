//
//  ThemeManager.h
//  Writer / Beat
//
//  Parts Copyright © 2019 Lauri-Matti Parppei. All rights reserved.
//  Copyright © 2016 Hendrik Noeller. All rights reserved.
//

#import <Cocoa/Cocoa.h>
#import "DynamicColor.h"
#import "Theme.h"
#import "ThemeEditor.h"

@interface ThemeManager : NSObject

@property (nonatomic) ThemeEditor *themeEditor;
@property (nonatomic) Theme* theme;

+ (ThemeManager*)sharedManager;

- (void)showEditor;

- (Theme*)defaultTheme;
- (Theme*)dictionaryToTheme:(NSDictionary*)values;
- (void)revertToSaved; /// Loads default and saved custom themes and applies them
- (void)readTheme:(Theme*)theme; /// Read a single, preprocessed theme
- (void)loadThemeForAllDocuments;
- (void)resetToDefault;
- (void)saveTheme;

//Access the current theme
- (Theme*) theme;

- (DynamicColor*)currentBackgroundColor;
- (DynamicColor*)currentSelectionColor;
- (DynamicColor*)currentTextColor;
- (DynamicColor*)currentInvisibleTextColor;
- (DynamicColor*)currentCaretColor;
- (DynamicColor*)currentCommentColor;
- (DynamicColor*)currentMarginColor;
- (DynamicColor*)currentOutlineBackground;
- (DynamicColor*)currentOutlineHighlight;
- (DynamicColor*)currentHighlightColor;

- (DynamicColor*)backgroundColor;
- (DynamicColor*)marginColor;
- (DynamicColor*)selectionColor;
- (DynamicColor*)textColor;
- (DynamicColor*)invisibleTextColor;
- (DynamicColor*)caretColor;
- (DynamicColor*)commentColor;
- (DynamicColor*)outlineHighlight;
- (DynamicColor*)outlineBackground;
- (DynamicColor*)pageNumberColor;
- (DynamicColor*)sectionTextColor;
- (DynamicColor*)synopsisTextColor;
- (DynamicColor*)highlightColor;

- (DynamicColor*)genderWomanColor;
- (DynamicColor*)genderManColor;
- (DynamicColor*)genderOtherColor;
- (DynamicColor*)genderUnspecifiedColor;

@end
