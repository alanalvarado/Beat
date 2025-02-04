//
//  FNHTMLScript.h
//	Modified for Beat
//
//  Copyright (c) 2012-2013 Nima Yousefi & John August
//  Parts copyright (c) 2019 Lauri-Matti Parppei / Lauri-Matti Parppei
//
//  Permission is hereby granted, free of charge, to any person obtaining a copy 
//  of this software and associated documentation files (the "Software"), to 
//  deal in the Software without restriction, including without limitation the 
//  rights to use, copy, modify, merge, publish, distribute, sublicense, and/or 
//  sell copies of the Software, and to permit persons to whom the Software is 
//  furnished to do so, subject to the following conditions:
//
//  The above copyright notice and this permission notice shall be included in 
//  all copies or substantial portions of the Software.
//
//  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR 
//  IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, 
//  FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE 
//  AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER 
//  LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING 
//  FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS 
//  IN THE SOFTWARE.
//

/*
#if TARGET_OS_IOS
    #define BeatFont UIFont
#else
*/
    #define BeatFont NSFont
    #import <Cocoa/Cocoa.h>
/* #endif */

#import <Foundation/Foundation.h>
#import "BeatEditorDelegate.h"
#import "BeatExportSettings.h"
#import "ContinuousFountainParser.h"
 
@interface BeatHTMLScript : NSObject

@property (strong, nonatomic) BeatFont *font;
@property (strong, nonatomic) NSArray *script;
@property (strong, nonatomic) NSArray *titlePage;
@property (strong, nonatomic) NSDocument *document;
@property (strong, nonatomic) NSNumber *customPage;
@property (strong, nonatomic) NSNumber *forRendering;
@property (copy, nonatomic) NSString *bodyText;

- (id)initWithScript:(BeatScreenplay*)script settings:(id)settings; // The new way
// - (id)initForPreview:(NSDictionary *)script document:(NSDocument*)document scene:(NSString*)scene printSceneNumbers:(bool)printSceneNumbers;
//- (id)initForPrint:(NSDictionary *)script document:(NSDocument*)document printSceneNumbers:(bool)printSceneNumbers;
- (id)initForQuickLook:(BeatScreenplay*)script;

- (NSInteger)pages;
- (NSString *)html;
- (NSString *)htmlClassForType:(NSString *)elementType;
- (NSString *)bodyForScript;
- (NSString *)content; // Returns only the ARTICLE part
- (NSString *)htmlHeader;
- (NSString *)htmlFooter;

@end
