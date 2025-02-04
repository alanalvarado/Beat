//
//  BeatLocalization.m
//  Beat
//
//  Created by Lauri-Matti Parppei on 4.1.2022.
//  Copyright © 2022 Lauri-Matti Parppei. All rights reserved.
//
/*
 
 This class can be used to replace placeholder values in strings.
 
 Example:
 NSString *string = @"<h1>#localize.this#</h1>"
 NSString *result = [BeatLocalization localizeString:string];
 
 */

#import "BeatLocalization.h"

@implementation BeatLocalization

+ (NSString*)localizeString:(NSString*)string
{
	// Get localization dictionary
	NSString *stringsPath = [NSBundle.mainBundle pathForResource:@"Localizable" ofType:@"strings"];
	NSMutableDictionary *dictionary = [NSMutableDictionary dictionaryWithContentsOfFile:stringsPath];
		
	// Fallback dictionary is English
	NSBundle *bundle = [NSBundle bundleWithPath:[[NSBundle mainBundle] pathForResource:@"en" ofType:@"lproj"]];
	NSString *enStringsPath = [bundle pathForResource:@"Localizable" ofType:@"strings"];
	NSDictionary *fallbackDictionary = [NSDictionary dictionaryWithContentsOfFile:enStringsPath];
	
	// Add missing stuff
	for (NSString *key in fallbackDictionary) {
		if (!dictionary[key]) {
			dictionary[key] = fallbackDictionary[key];
		}
	}
	
	// Iterate through localized strings and replace them in the string
	for (NSString *key in dictionary) {
		// Find all occurences of #keys#, as in #plugins.title#
		NSString *stringToFind = [NSString stringWithFormat:@"#%@#", key];
		NSString *localization = dictionary[key];
				
		string = [string stringByReplacingOccurrencesOfString:stringToFind withString:localization];
	}
	
	return string;
}

@end
/*
 
	MULTINATIONAL CORPORATIONS
	GENOCIDE OF THE STARVING NATIONS
 
		MULTINATIONAL CORPORATIONS
		GENOCIDE OF THE STARVING NATIONS
 
 */
