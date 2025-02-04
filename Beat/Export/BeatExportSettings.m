//
//  BeatExportSettings.m
//  Beat
//
//  Created by Lauri-Matti Parppei on 22.6.2021.
//  Copyright © 2021 Lauri-Matti Parppei. All rights reserved.
//

#import "BeatExportSettings.h"

@implementation BeatExportSettings

+ (BeatExportSettings*)operation:(BeatHTMLOperation)operation document:(BeatDocument* _Nullable)doc header:(NSString*)header  printSceneNumbers:(bool)printSceneNumbers {
	return [[BeatExportSettings alloc] initWithOperation:operation document:doc header:header printSceneNumbers:printSceneNumbers printNotes:NO revisions:@[] scene:@"" coloredPages:NO revisedPageColor:@""];
}

+ (BeatExportSettings*)operation:(BeatHTMLOperation)operation document:(BeatDocument*)doc header:(NSString*)header printSceneNumbers:(bool)printSceneNumbers revisions:(NSArray*)revisions {
	return [[BeatExportSettings alloc] initWithOperation:operation document:doc header:header printSceneNumbers:printSceneNumbers printNotes:NO revisions:revisions scene:@"" coloredPages:NO revisedPageColor:@""];
}

+ (BeatExportSettings*)operation:(BeatHTMLOperation)operation document:(BeatDocument*)doc header:(NSString*)header printSceneNumbers:(bool)printSceneNumbers revisions:(NSArray*)revisions scene:(NSString* _Nullable )scene {
	return [[BeatExportSettings alloc] initWithOperation:operation document:doc header:header printSceneNumbers:printSceneNumbers printNotes:NO revisions:revisions scene:scene coloredPages:NO revisedPageColor:@""];
}

+ (BeatExportSettings*)operation:(BeatHTMLOperation)operation document:(BeatDocument*)doc header:(NSString*)header printSceneNumbers:(bool)printSceneNumbers printNotes:(bool)printNotes revisions:(NSArray*)revisions scene:(NSString* _Nullable )scene coloredPages:(bool)coloredPages revisedPageColor:(NSString*)revisedPagecolor {
	return [[BeatExportSettings alloc] initWithOperation:operation document:doc header:header printSceneNumbers:printSceneNumbers printNotes:printNotes revisions:revisions scene:nil coloredPages:coloredPages revisedPageColor:revisedPagecolor];
}

-(instancetype)initWithOperation:(BeatHTMLOperation)operation document:(BeatDocument*)doc header:(NSString*)header printSceneNumbers:(bool)printSceneNumbers printNotes:(bool)printNotes revisions:(NSArray*)revisions scene:(NSString* _Nullable )scene coloredPages:(bool)coloredPages revisedPageColor:(NSString*)revisedPageColor {
	self = [super init];
	
	if (self) {
		_document = doc;
		_operation = operation;
		_header = (header.length) ? header : @"";
		_printSceneNumbers = printSceneNumbers;
		_revisions = revisions.copy;
		_currentScene = scene;
		_printNotes = printNotes;
		_coloredPages = coloredPages;
		_pageRevisionColor = revisedPageColor;
	}
	return self;
}

- (BeatPaperSize)paperSize {
	// Check paper size
#if TARGET_OS_IOS
    NSLog(@"### IMPLEMENT IOS PAGE SIZES");
    return BeatA4;
#else
	if (self.document.printInfo.paperSize.width > 596) return BeatUSLetter;
	else return BeatA4;
#endif
}

@end
/*

 Olen verkon silmässä kala. En pääse pois:
 ovat viiltävät säikeet jo syvällä lihassa mulla.
 Vesi häilyvä, selvä ja syvä minun silmäini edessä ois.
 Vesiaavikot vapaat, en voi minä luoksenne tulla!
 
 Meren silmiin vihreisiin vain loitolta katsonut oon.
 Mikä autuus ois lohen kilpaveikkona olla!
 Kuka rannan liejussa uupuu, hän pian uupukoon!
 – Vaan verkot on vitkaan-tappavat kohtalolla.
 
 */
