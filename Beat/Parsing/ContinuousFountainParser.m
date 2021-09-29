//
//  ContinousFountainParser.m
//  Writer / Beat
//
//  Copyright © 2016 Hendrik Noeller. All rights reserved.
//  Parts copyright © 2019-2020 Lauri-Matti Parppei. All rights reserved.

//  Relased under GPL

/*
 
 This code is still mostly based on Hendrik Noeller's work.
 It is heavily modified for Beat, and is more and more reliable.
 
 Main differences include:
 - double-checking for all-caps actions mistaken for character cues
 - delegation with the editor
 - title page parsing (mostly for preview & export purposes)
 - new data structure called OutlineScene, which contains scene name and length, as well as a reference to the original line
 - overall tweaks to parsing here and there
 - parsing large chunks of text is optimized 	
  
 
 Update 2021-something: COVID is still on, and this class has been improved a lot.
 
 Future considerations:
 - Make it possible to change editor text via text elements. This means making lines aware of their parser, and
   even tighter integration with the editor delegate.
 - Conform to Fountain note syntax
 
 */

#import "ContinuousFountainParser.h"
#import "RegExCategories.h"
#import "Line.h"
#import "NSString+Whitespace.h"
#import "NSMutableIndexSet+Lowest.h"
#import "NSIndexSet+Subset.h"
#import "OutlineScene.h"

#define NEW_NOTES YES

@interface  ContinuousFountainParser ()
@property (nonatomic) BOOL changeInOutline;
@property (nonatomic) Line *editedLine;
@property (nonatomic) Line *lastEditedLine;
@property (nonatomic) NSUInteger editedIndex;

// Title page parsing
@property (nonatomic) NSString *openTitlePageKey;
@property (nonatomic) NSString *previousTitlePageKey;

// For initial loading
@property (nonatomic) NSInteger indicesToLoad;
@property (nonatomic) bool firstTime;

// For testing
@property (nonatomic) NSDate *executionTime;

@end

@implementation ContinuousFountainParser

static NSDictionary* patterns;

#pragma mark - Parsing

#pragma mark Bulk Parsing

- (ContinuousFountainParser*)staticParsingWithString:(NSString*)string settings:(BeatDocumentSettings*)settings {
	return [self initWithString:string delegate:nil settings:settings];
}
- (ContinuousFountainParser*)initWithString:(NSString*)string delegate:(id<ContinuousFountainParserDelegate>)delegate {
	return [self initWithString:string delegate:delegate settings:nil];
}
- (ContinuousFountainParser*)initWithString:(NSString*)string delegate:(id<ContinuousFountainParserDelegate>)delegate settings:(BeatDocumentSettings*)settings {
	self = [super init];
	
	if (self) {
		_lines = [NSMutableArray array];
		_outline = [NSMutableArray array];
		_changedIndices = [NSMutableIndexSet indexSet];
		_titlePage = [NSMutableArray array];
		_storylines = [NSMutableArray array];
		_delegate = delegate;
		_staticDocumentSettings = settings;
		 
		// Inform that this parser is STATIC and not continuous
		if (_delegate == nil) _staticParser = YES; else _staticParser = NO;
		
		[self parseText:string];
	}
	
	return self;
}
- (ContinuousFountainParser*)initWithString:(NSString*)string
{
	return [self initWithString:string delegate:nil];
}

- (void)parseText:(NSString*)text
{
	_firstTime = YES;
	
	_lines = [NSMutableArray array];
    NSArray *lines = [text componentsSeparatedByString:@"\n"];
	_indicesToLoad = lines.count;
    
    NSUInteger position = 0; //To track at which position every line begins
	NSUInteger sceneIndex = -1;
	
	Line *previousLine;
	
    for (NSString *rawLine in lines) {
        NSInteger index = [self.lines count];
        Line* line = [[Line alloc] initWithString:rawLine position:position parser:self];
        [self parseTypeAndFormattingForLine:line atIndex:index];
		
		// Quick fix for mistaking an ALL CAPS action to character cue
		if (previousLine.type == character && (line.string.length < 1 || line.type == empty)) {
			previousLine.type = [self parseLineType:previousLine atIndex:index - 1 recursive:NO currentlyEditing:NO];
			if (previousLine.type == character) previousLine.type = action;
		}
		
		// For a quick scene index lookup (wtf is this, later me)
		if (line.type == heading || line.type == synopse || line.type == section) {
			sceneIndex++;
			line.sceneIndex = sceneIndex;
		}
		
		// Quick fix for recognizing split paragraphs
        LineType currentType = line.type;
        if (line.type == action || line.type == lyrics || line.type == transitionLine) {
            if (previousLine.type == currentType && previousLine.string.length > 0) line.isSplitParagraph = YES;
        }
		
        //Add to lines array
        [self.lines addObject:line];
        //Mark change in buffered changes
		[self.changedIndices addIndex:index];
        
        position += [rawLine length] + 1; // +1 for newline character
		previousLine = line;
		_indicesToLoad--;
    }
	
	// Initial parse complete
	_indicesToLoad = -1;
	
    _changeInOutline = YES;
	[self createOutline];
	
	_firstTime = NO;
}

// This sets EVERY INDICE as changed.
- (void)resetParsing {
	NSInteger index = 0;
	while (index < self.lines.count) {
		[self.changedIndices addIndex:index];
		index++;
	}
}

#pragma mark - Continuous Parsing

/*
 
 Note for future me:
 
 I have somewhat revised the original parsing system, which parsed changes by
 always removing single characters in a loop, even with longer text blocks.
 
 I optimized the logic so that if the change includes full lines (either removed or added)
 they are removed or added as whole, rather than character-by-character. This is why
 there are two different methods for parsing the changes, and the other one is still used
 for parsing single-character edits. parseAddition/parseRemovalAt methods fall back to
 them when needed.
 
 */

- (void)parseChangeInRange:(NSRange)range withString:(NSString*)string
{
	if (range.location == NSNotFound) return; // This is for avoiding crashes when plugin developers are doing weird things
	
	_lastEditedLine = nil;
	_editedIndex = -1;

    NSMutableIndexSet *changedIndices = [[NSMutableIndexSet alloc] init];
    if (range.length == 0) { //Addition
		[changedIndices addIndexes:[self parseAddition:string atPosition:range.location]];
    } else if ([string length] == 0) { //Removal
		[changedIndices addIndexes:[self parseRemovalAt:range]];
		
    } else { //Replacement
		//First remove
		[changedIndices addIndexes:[self parseRemovalAt:range]];
        // Then add
		[changedIndices addIndexes:[self parseAddition:string atPosition:range.location]];
    }
	    	
    [self correctParsesInLines:changedIndices];
}

- (void)ensurePositions {
	// This is a method to fix anything that might get broken :-)
	// Use only when debugging.

	NSInteger previousPosition = 0;
	NSInteger previousLength = 0;
	NSInteger offset = 0;
	
	bool fixed = NO;
	
	for (Line * line in self.lines) {
		if (line.position > previousPosition + previousLength + offset && !fixed) {
			NSLog(@"🔴 [FIXING] %lu-%lu   %@", line.position, line.string.length, line.string);
			offset -= line.position - (previousPosition + previousLength);
			fixed = YES;
		}
		
		line.position += offset;
				
		previousLength = line.string.length + 1;
		previousPosition = line.position;
	}
}

- (NSIndexSet*)parseAddition:(NSString*)string  atPosition:(NSUInteger)position
{
	NSMutableIndexSet *changedIndices = [NSMutableIndexSet indexSet];
	
	// Get the line where into which we are adding characters
	NSUInteger lineIndex = [self lineIndexAtPosition:position];
	Line* line = self.lines[lineIndex];
	if (line.type == heading || line.type == synopse || line.type == section) _changeInOutline = YES;
	
	// Cache old version of the string
	[line savePreviousVersion];
	
    NSUInteger indexInLine = position - line.position;
	
	// If the added string is a multi-line block, we need to optimize the addition.
	// Else, just parse it character-by-character.
	if ([string rangeOfString:@"\n"].location != NSNotFound && string.length > 1) {
		// Split the original line into two
		NSString *head = [line.string substringToIndex:indexInLine];
		NSString *tail = (indexInLine + 1 <= line.string.length) ? [line.string substringFromIndex:indexInLine] : @"";
		 
		// Split the text block into pieces
		NSArray *newLines = [string componentsSeparatedByString:@"\n"];
		
		// Add the first line
		[changedIndices addIndex:lineIndex];

		NSInteger offset = line.position;

		[self decrementLinePositionsFromIndex:lineIndex + 1 amount:tail.length];
				
		// Go through the new lines
		for (NSInteger i = 0; i < newLines.count; i++) {
			NSString *newLine = newLines[i];
		
			if (i == 0) {
				// First line
				head = [head stringByAppendingString:newLine];
				line.string = head;
				[self incrementLinePositionsFromIndex:lineIndex + 1 amount:newLine.length + 1];
				offset += head.length + 1;
			} else {
				Line *addedLine;
				
				if (i == newLines.count - 1) {
					// Handle adding the last line a bit differently
					tail = [newLine stringByAppendingString:tail];
					addedLine = [[Line alloc] initWithString:tail position:offset parser:self];

					[self.lines insertObject:addedLine atIndex:lineIndex + i];
					[self incrementLinePositionsFromIndex:lineIndex + i + 1 amount:addedLine.string.length];
					offset += newLine.length + 1;
				} else {
					addedLine = [[Line alloc] initWithString:newLine position:offset parser:self];
					
					[self.lines insertObject:addedLine atIndex:lineIndex + i];
					[self incrementLinePositionsFromIndex:lineIndex + i + 1 amount:addedLine.string.length + 1];
					offset += newLine.length + 1;
				}
			}
		}
		
		[changedIndices addIndexesInRange:NSMakeRange(lineIndex, newLines.count)];
	} else {
		// Do it character by character...
		
		// Set the currently edited line index
		if (_editedIndex >= self.lines.count || _editedIndex < 0) {
			_editedIndex = [self lineIndexAtPosition:position];
		}

		// Find the current line and cache its previous version
		Line* line = self.lines[lineIndex];
		[line savePreviousVersion];
		
        for (int i = 0; i < string.length; i++) {
            NSString* character = [string substringWithRange:NSMakeRange(i, 1)];
			[changedIndices addIndexes:[self parseCharacterAdded:character
													  atPosition:position+i  line:line]];
        }
	}
	
	// Log any problems faced during parsing (safety measure for debugging)
	// [self report];
	
	return changedIndices;
}

- (void)report {
	NSInteger lastPos = 0;
	NSInteger lastLen = 0;
	for (Line* line in self.lines) {
		NSString *error = @"";
		if (lastPos + lastLen != line.position) error = @" 🔴 ERROR";
		
		if (error.length > 0) {
			NSLog(@"   (%lu -> %lu): %@ (%lu) %@ (%lu/%lu)", line.position, line.position + line.string.length + 1, line.string, line.string.length, error, lastPos, lastLen);
		}
		lastLen = line.string.length + 1;
		lastPos = line.position;
	}
}

- (NSIndexSet*)parseCharacterAdded:(NSString*)character atPosition:(NSUInteger)position line:(Line*)line
{
	NSUInteger lineIndex = _editedIndex;

    NSUInteger indexInLine = position - line.position;
	
	if (line.type == heading || line.type == synopse || line.type == section) _changeInOutline = true;
	
    if ([character isEqualToString:@"\n"]) {
        NSString* cutOffString;
        if (indexInLine == [line.string length]) {
            cutOffString = @"";
        } else {
            cutOffString = [line.string substringFromIndex:indexInLine];
            line.string = [line.string substringToIndex:indexInLine];
        }
        
        Line* newLine = [[Line alloc] initWithString:cutOffString
                                            position:position+1
											  parser:self];
        [self.lines insertObject:newLine atIndex:lineIndex+1];
        
        [self incrementLinePositionsFromIndex:lineIndex+2 amount:1];
        
        return [NSIndexSet indexSetWithIndexesInRange:NSMakeRange(lineIndex, 2)];
    } else {
        NSArray* pieces = @[[line.string substringToIndex:indexInLine],
                            character,
                            [line.string substringFromIndex:indexInLine]];
		
        line.string = [pieces componentsJoinedByString:@""];
        [self incrementLinePositionsFromIndex:lineIndex+1 amount:1];
        
        return [[NSIndexSet alloc] initWithIndex:lineIndex];
        
    }
}

// Return the whole document as single string
- (NSString*)rawText {
	NSMutableString *string = [NSMutableString string];
	for (Line* line in self.lines) {
		if (line != self.lines.lastObject) [string appendFormat:@"%@\n", line.string];
		else [string appendFormat:@"%@", line.string];
	}
	return string;
}

- (NSIndexSet*)parseRemovalAt:(NSRange)range {
	NSMutableIndexSet *changedIndices = [[NSMutableIndexSet alloc] init];
	
	NSString *stringToRemove = [[self rawText] substringWithRange:range];
	NSInteger lineBreaks = [stringToRemove componentsSeparatedByString:@"\n"].count - 1;
	
	if (lineBreaks > 1) {
		// If there are 2+ line breaks, optimize the operation
		NSInteger lineIndex = [self lineIndexAtPosition:range.location];
		Line *firstLine = self.lines[lineIndex];
		
		// Cache the previous version of the line
		[firstLine savePreviousVersion];
		
		// Change in outline
		if (firstLine.type == heading || firstLine.type == section || firstLine.type == synopse) _changeInOutline = YES;
		
		NSUInteger indexInLine = range.location - firstLine.position;
		
		NSString *retain = [firstLine.string substringToIndex:indexInLine];
		NSInteger nextIndex = lineIndex + 1;
				
		// +1 for line break
		NSInteger offset = firstLine.string.length - retain.length + 1;
		
		for (NSInteger i = 1; i <= lineBreaks; i++) {
			Line* nextLine = self.lines[nextIndex];
						
			if (nextLine.type == heading || nextLine.type == section || nextLine.type == synopse) {
				_changeInOutline = YES;
			}
			
			if (i < lineBreaks) {
				// NSLog(@"remove: %@", nextLine.string);
				[self.lines removeObjectAtIndex:nextIndex];
				offset += nextLine.string.length + 1;
			} else {
				// This is the last line in the array
				NSInteger indexInNextLine = range.location + range.length - nextLine.position;
				
				NSInteger nextLineLength = nextLine.string.length - indexInNextLine;
				
				NSString *nextLineString;
				
				if (indexInNextLine + nextLineLength > 0) {
					nextLineString = [nextLine.string substringWithRange:NSMakeRange(indexInNextLine, nextLineLength)];
				} else {
					nextLineString = @"";
				}
				
				firstLine.string = [retain stringByAppendingString:nextLineString];
				
				// Remove the last line
				[self.lines removeObjectAtIndex:nextIndex];
				offset += indexInNextLine;
			}
		}
		[self decrementLinePositionsFromIndex:nextIndex amount:offset];
										
		[changedIndices addIndex:lineIndex];
	} else {
		// Do it normally...
		
		// Set the currently edited line index
		if (_editedIndex >= self.lines.count || _editedIndex < 0) {
			_editedIndex = [self lineIndexAtPosition:range.location];
		}
		
		// Cache previous version of the string
		Line* line = self.lines[_editedIndex];
		[line savePreviousVersion];
		
		// Parse removal character by character
		for (int i = 0; i < range.length; i++) {
			[changedIndices addIndexes:[self parseCharacterRemovedAtPosition:range.location line:line]];
		}
	}
	
	[self report];
	
	return changedIndices;
}
- (NSIndexSet*)parseCharacterRemovedAtPosition:(NSUInteger)position line:(Line*)line
{
	/*
	 
	 I have struggled to make this faster.
	 The solution (for now) is to cache the result of lineIndexAtPosition,
	 but it's not the ideal workaround.
	 
	 Creating the temporary strings here might be the problem, though.
	 If I could skip those steps, iterating character by character might not be
	 that heavy of an operation. We could have @property NSRange affectedRange
	 and have this method check itself against that. If we'll be removing the next
	 character, too, don't bother appending any strings anywhere.
	 
	 */
		
	NSUInteger indexInLine = position - line.position;
	NSUInteger lineIndex = _editedIndex;

	if (indexInLine > line.string.length) indexInLine = line.string.length;
	
    if (indexInLine == line.string.length) {
        //Get next line and put together
        if (lineIndex == self.lines.count - 1) {
            return nil; //Removed newline at end of document without there being an empty line - should never happen but to be sure...
        }
		
        Line* nextLine = self.lines[lineIndex+1];
        line.string = [line.string stringByAppendingString:nextLine.string];
        if (nextLine.type == heading || nextLine.type == section || nextLine.type == synopse) {
            _changeInOutline = YES;
        }
		
        [self.lines removeObjectAtIndex:lineIndex+1];
        [self decrementLinePositionsFromIndex:lineIndex+1 amount:1];
        
        return [[NSIndexSet alloc] initWithIndex:lineIndex];
    } else {
        NSArray* pieces = @[[line.string substringToIndex:indexInLine],
                            [line.string substringFromIndex:indexInLine + 1]];
        
        line.string = [pieces componentsJoinedByString:@""];
        [self decrementLinePositionsFromIndex:lineIndex+1 amount:1];
        
        
        return [[NSIndexSet alloc] initWithIndex:lineIndex];
    }
}

- (NSUInteger)lineIndexAtPosition:(NSUInteger)position
{
	// First check the line we edited last
	//bool wouldReturnMatch = NO;
	NSUInteger match = -1;
	
	if (_lastEditedLine) {
		if (_lastEditedLine.position > position &&
			position < _lastEditedLine.string.length + _lastEditedLine.position) {
			match = [self.lines indexOfObject:_lastEditedLine] - 1;
			if (match < self.lines.count && match >= 0) {
				//wouldReturnMatch = YES;
				return match;
			}
		}
	}
	
    for (int i = 0; i < [self.lines count]; i++) {
        Line* line = self.lines[i];
        
        if (line.position > position) {
			_lastEditedLine = line;
						
            return i-1;
        }
    }
    return [self.lines count] - 1;
}

- (void)incrementLinePositionsFromIndex:(NSUInteger)index amount:(NSUInteger)amount
{
    for (; index < [self.lines count]; index++) {
        Line* line = self.lines[index];
        
        line.position += amount;
    }
}

- (void)decrementLinePositionsFromIndex:(NSUInteger)index amount:(NSUInteger)amount
{
    for (; index < [self.lines count]; index++) {
        Line* line = self.lines[index];
        line.position -= amount;
    }
}

- (void)correctParsesForLines:(NSArray *)lines
{
	// Intermediate method for getting indices for line objects
	NSMutableIndexSet *indices = [NSMutableIndexSet indexSet];
	
	for (Line* line in lines) {
		NSInteger i = [lines indexOfObject:line];
		if (i != NSNotFound) [indices addIndex:i];
	}
	
	[self correctParsesInLines:indices];
}
- (void)correctParsesInLines:(NSMutableIndexSet*)lineIndices
{
    while (lineIndices.count > 0) {
        [self correctParseInLine:lineIndices.lowestIndex indicesToDo:lineIndices];
    }
}

- (NSInteger)indexOfNoteOpen:(Line*)line {
	unichar string[line.string.length];
	[line.string getCharacters:string];
	
	NSInteger lastIndex = 1;
	NSInteger rangeBegin = -1;
	for (int i = (int)line.length;;i--) {
		if (i > lastIndex) break;
		
		if ((string[i] == '[' && string[i-1] == '[')) {
			rangeBegin = i;
			break;
		}
	}
	
	if (rangeBegin >= 0) return rangeBegin;
	else return NSNotFound;
}

- (NSMutableIndexSet*)parseNoteBlockFrom:(NSUInteger)idx {
	NSLog(@" begins at %lu (%@)", idx, _lines[idx]);
	NSMutableIndexSet *indicesToDo = [NSMutableIndexSet indexSet];
	
	Line *line;
	NSMutableArray *affectedLines = [NSMutableArray array];
	
	bool match = NO;
	bool unterminated = NO;
	
	// Look behind to find out where the note block ends
	for (NSInteger i = idx; i >= 0; i--) {
		line = _lines[i];
		
		[affectedLines addObject:line];
		
		if (line.type == empty) {
			NSLog(@" -> cancels behidn: '%@'", line.string);
			unterminated = YES;
		}
		else if (line.beginsNoteBlock) {
			match = YES;
			break;
		}
	}
	// We iterated through the items in reverse, so let's invert the array
	[affectedLines setArray:[[affectedLines reverseObjectEnumerator] allObjects]];
	
	// Look forward
	for (NSInteger i = idx + 1; i < self.lines.count; i++) {
		line = _lines[i];
		NSLog(@"  inspecting %@ (%lu)", line, line.noteOutIndices.count);
		if (line.endsNoteBlock) NSLog(@"     ... should end block");
		
		[affectedLines addObject:line];
		
		if (line.cancelsNoteBlock || line.type == empty) {
			NSLog(@" -> cancels frwrd: '%@'", line.string);
			unterminated = YES;
			break;
		}
		else if (line.endsNoteBlock) {
			NSLog(@"ends note block: %@", line);
			break;
		}
	}
	
	
	// Iterate through affected lines and set the fixed note ranges.
	// If the note style has changed, add the line to changed indices.
	
	if (NEW_NOTES) {
		/*
		for (Line* l in affectedLines) {
			NSMutableIndexSet *oldIndices = [[NSMutableIndexSet alloc] initWithIndexSet:l.noteRanges];
			
			if (!unterminated) {
				if (l == affectedLines.firstObject) [l.noteRanges addIndexes:l.noteOutIndices];
				else if (l == affectedLines.lastObject) [l.noteRanges addIndexes:l.noteInIndices];
				else l.noteRanges = [NSMutableIndexSet indexSetWithIndexesInRange:(NSRange){0, l.length }];
				NSLog(@" --- %@", l);
			} else {
				if (l == affectedLines.firstObject) [l.noteRanges removeIndexes:l.noteOutIndices];
				else if (l == affectedLines.lastObject) [l.noteRanges removeIndexes:l.noteInIndices];
				else {
					[l.noteRanges removeIndexesInRange:(NSRange){0,l.length}];
				}
			}
			
			if (oldIndices.count) {
				[oldIndices removeIndexes:l.noteRanges];
				if (oldIndices.count != 0) {
					//[_changedIndices addIndex:[_lines indexOfObject:l]];
					[indicesToDo addIndex:[_lines indexOfObject:l]];
				}
			}
		}
		*/
	}
	
	return indicesToDo;
}

- (void)correctParseInLine:(NSUInteger)index indicesToDo:(NSMutableIndexSet*)indices
{
    //Remove index as done from array if in array
    if (indices.count) {
        NSUInteger lowestToDo = indices.lowestIndex;
        if (lowestToDo == index) {
            [indices removeIndex:index];
        }
    }
	
	bool lastToParse = YES;
	if (indices.count) lastToParse = NO;
    
    Line* currentLine = self.lines[index];
		
	//Correct type on this line
    LineType oldType = currentLine.type;
    bool oldOmitOut = currentLine.omitOut;
	//bool oldNoteTermination = currentLine.cancelsNoteBlock;
		
    [self parseTypeAndFormattingForLine:currentLine atIndex:index];
    
    if (!self.changeInOutline && (oldType == heading || oldType == section || oldType == synopse ||
        currentLine.type == heading || currentLine.type == section || currentLine.type == synopse)) {
        self.changeInOutline = YES;
    }
    
    [self.changedIndices addIndex:index];
	
	if (currentLine.type == dialogue && currentLine.string.length == 0 && indices.count > 1 && index > 0) {
		// Check for all-caps action lines mistaken for character cues in a pasted text
		Line *previousLine = self.lines[index - 1];
		previousLine.type = action;
		currentLine.type = empty;
	}
		
	if (NEW_NOTES) {
		if (currentLine.noteOut || currentLine.noteIn) {
			// WIP
			//NSLog(@"###### parsing block...");
			//[indices addIndexes:[self parseNoteBlockFrom:index]];
		}
	}
	
	
	if (oldType != currentLine.type || oldOmitOut != currentLine.omitOut || lastToParse) {
        //If there is a next element, check if it might need a reparse because of a change in type or omit out
        if (index < self.lines.count - 1) {
            Line* nextLine = self.lines[index+1];
			if (currentLine.isTitlePage ||					// if line is a title page, parse next line too
                currentLine.type == section ||
                currentLine.type == synopse ||
                currentLine.type == character ||            //if the line became anything to
                currentLine.type == parenthetical ||        //do with dialogue, it might cause
                currentLine.type == dialogue ||             //the next lines to be dialogue
                currentLine.type == dualDialogueCharacter ||
                currentLine.type == dualDialogueParenthetical ||
                currentLine.type == dualDialogue ||
                currentLine.type == empty ||                //If the line became empty, it might
                                                            //enable the next on to be a heading
                                                            //or character
                
                nextLine.type == titlePageTitle ||          //if the next line is a title page,
                nextLine.type == titlePageCredit ||         //it might not be anymore
                nextLine.type == titlePageAuthor ||
                nextLine.type == titlePageDraftDate ||
                nextLine.type == titlePageContact ||
                nextLine.type == titlePageSource ||
                nextLine.type == titlePageUnknown ||
                nextLine.type == section ||
                nextLine.type == synopse ||
                nextLine.type == heading ||                 //If the next line is a heading or
                nextLine.type == character ||               //character or anything dialogue
                nextLine.type == dualDialogueCharacter || //related, it might not be anymore
                nextLine.type == parenthetical ||
                nextLine.type == dialogue ||
                nextLine.type == dualDialogueParenthetical ||
                nextLine.type == dualDialogue ||
                nextLine.omitIn != currentLine.omitOut	// Look for unterminated omits & notes
				//|| nextLine.noteIn != currentLine.noteOut
				
				) {
				
                [self correctParseInLine:index+1 indicesToDo:indices];
            }
        }
    }
}


#pragma mark Parsing Core

#define BOLD_PATTERN "**"
#define ITALIC_PATTERN "*"
#define UNDERLINE_PATTERN "_"
#define NOTE_OPEN_PATTERN "[["
#define NOTE_CLOSE_PATTERN "]]"
#define OMIT_OPEN_PATTERN "/*"
#define OMIT_CLOSE_PATTERN "*/"

#define HIGHLIGHT_OPEN_PATTERN "<<"
#define HIGHLIGHT_CLOSE_PATTERN ">>"
#define STRIKEOUT_OPEN_PATTERN "{{"
#define STRIKEOUT_CLOSE_PATTERN "}}"

#define BOLD_PATTERN_LENGTH 2
#define ITALIC_PATTERN_LENGTH 1
#define UNDERLINE_PATTERN_LENGTH 1
#define NOTE_PATTERN_LENGTH 2
#define OMIT_PATTERN_LENGTH 2
#define HIGHLIGHT_PATTERN_LENGTH 2
#define STRIKEOUT_PATTERN_LENGTH 2

#define COLOR_PATTERN "color"
#define STORYLINE_PATTERN "storyline"

- (void)parseTypeAndFormattingForLine:(Line*)line atIndex:(NSUInteger)index
{
	// Type and formatting are parsed by iterating through character arrays.
	// Using regexes would be much easier, but also about 10 times more costly in CPU time.
	
    line.type = [self parseLineType:line atIndex:index];
	
    NSUInteger length = line.string.length;
    unichar charArray[length];
    [line.string getCharacters:charArray];
    
	// Omits have stars in them, which can be mistaken for formatting characters.
	// We store the omit asterisks into the "excluded" index set to avoid this mixup.
    NSMutableIndexSet* excluded = [[NSMutableIndexSet alloc] init];
	
	// First, we handle notes and omits, which can bleed over multiple lines.
	// The cryptically named omitOut and noteOut mean that the line bleeds an omit out,
	// while omitIn and noteIn tell that they are part of a larger omitted/note block.
    if (index == 0) {
        line.omittedRanges = [self rangesOfOmitChars:charArray
                                             ofLength:length
                                               inLine:line
                                      lastLineOmitOut:NO
                                          saveStarsIn:excluded];
		
		line.noteRanges = [self noteRanges:charArray
										 ofLength:length
										   inLine:line
									  partOfBlock:NO];
    } else {
        Line* previousLine = self.lines[index-1];
		line.omittedRanges = [self rangesOfOmitChars:charArray
											 ofLength:length
											   inLine:line
									  lastLineOmitOut:previousLine.omitOut
										  saveStarsIn:excluded];
		
		line.noteRanges = [self noteRanges:charArray
										 ofLength:length
										   inLine:line
									  partOfBlock:previousLine.noteOut];
	}
    
	line.escapeRanges = [NSMutableIndexSet indexSet];

    line.boldRanges = [self rangesInChars:charArray
                                 ofLength:length
                                  between:BOLD_PATTERN
                                      and:BOLD_PATTERN
                               withLength:BOLD_PATTERN_LENGTH
                         excludingIndices:excluded
									 line:line];
	
    line.italicRanges = [self rangesInChars:charArray
                                   ofLength:length
                                    between:ITALIC_PATTERN
                                        and:ITALIC_PATTERN
                                 withLength:ITALIC_PATTERN_LENGTH
                           excludingIndices:excluded
									   line:line];
    line.underlinedRanges = [self rangesInChars:charArray
                                       ofLength:length
                                        between:UNDERLINE_PATTERN
                                            and:UNDERLINE_PATTERN
                                     withLength:UNDERLINE_PATTERN_LENGTH
                               excludingIndices:nil
										   line:line];
	/*
    line.noteRanges = [self rangesInChars:charArray
                                 ofLength:length
                                  between:NOTE_OPEN_PATTERN
                                      and:NOTE_CLOSE_PATTERN
                               withLength:NOTE_PATTERN_LENGTH
                         excludingIndices:nil
									 line:line];
	 */
	
	line.strikeoutRanges = [self rangesInChars:charArray
								 ofLength:length
								  between:STRIKEOUT_OPEN_PATTERN
									  and:STRIKEOUT_CLOSE_PATTERN
							   withLength:STRIKEOUT_PATTERN_LENGTH
						 excludingIndices:nil
										line:line];
	
	// Intersecting indices between bold & italic are boldItalic
	if (line.boldRanges.count && line.italicRanges.count) line.boldItalicRanges = [line.italicRanges indexesIntersectingIndexSet:line.boldRanges].mutableCopy;
	else line.boldItalicRanges = [NSMutableIndexSet indexSet];
	
    if (line.type == heading) {
		line.sceneNumberRange = [self sceneNumberForChars:charArray ofLength:length];
        
		if (line.sceneNumberRange.length == 0) {
            line.sceneNumber = nil;
        } else {
            line.sceneNumber = [line.string substringWithRange:line.sceneNumberRange];
        }
		
		line.color = [self colorForHeading:line];
		line.storylines = [self storylinesForHeading:line];
    }
	
	// set color for outline elements
	if (line.type == heading || line.type == section || line.type == synopse) {
		line.color = [self colorForHeading:line];
	}
	
	if (line.isTitlePage) {
		if ([line.string rangeOfString:@":"].location != NSNotFound && line.string.length > 0) {
			// If the title doesn't begin with \t or space, format it as key name	
			if ([line.string characterAtIndex:0] != ' ' &&
				[line.string characterAtIndex:0] != '\t' ) line.titleRange = NSMakeRange(0, [line.string rangeOfString:@":"].location + 1);
			else line.titleRange = NSMakeRange(0, 0);
		}
	}
}

/*

Update 2020-08:
The recursive madness I built should be dismantled and replaced with delegation.

An example of a clean and nice delegate method can be seen when handling scene headings,
and the same logic should apply everywhere: Oh, an empty line: Did we parse the line before
as a character cue, well, let's not, and then send that information to the UI side of things.

It might be slightly less optimal in some cases, but would save us from this terrible, terrible
and incomprehensible system of recursion.

*/


- (LineType)parseLineType:(Line*)line atIndex:(NSUInteger)index
{
	return [self parseLineType:line atIndex:index recursive:NO currentlyEditing:NO];
}

- (LineType)parseLineType:(Line*)line atIndex:(NSUInteger)index recursive:(bool)recursive
{
	return [self parseLineType:line atIndex:index recursive:recursive currentlyEditing:NO];
}

- (LineType)parseLineType:(Line*)line atIndex:(NSUInteger)index currentlyEditing:(bool)currentLine {
	return [self parseLineType:line atIndex:index recursive:NO currentlyEditing:currentLine];
}

- (LineType)parseLineType:(Line*)line atIndex:(NSUInteger)index recursive:(bool)recursive currentlyEditing:(bool)currentLine
{
    NSString* string = line.string;
    NSUInteger length = [string length];
	NSString* trimmedString = [line.string stringByTrimmingTrailingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
	
	Line* preceedingLine = (index == 0) ? nil : (Line*) self.lines[index-1];
	
	// So we need to pull all sorts of tricks out of our sleeve here.
	// Usually Fountain files are parsed from bottom to up, but here we are parsing in a linear manner.
	// I have no idea how I got this to work but it does.

	// Check for all-caps actions mistaken for character cues
	if (self.delegate && NSThread.isMainThread) {
		if (preceedingLine.string.length == 0 &&
			NSLocationInRange(self.delegate.selectedRange.location + 1, line.range)) {
			// If the preceeding line is empty, we'll check the line before that, too, to be sure.
			// This way we can check for false character cues
			if (index > 1) {
				Line* lineBeforeThat = (Line*)self.lines[index - 2];
				if (lineBeforeThat.type == character) {
					lineBeforeThat.type = action;
					[self.changedIndices addIndex:index - 2];
				}
			}
		}
	}
	
    // Check if empty.
    if (length == 0) {
		// If previous line is part of dialogue block, this line becomes dialogue right away
		// Else it's just empty.
		if (preceedingLine.type == character || preceedingLine.type == parenthetical || preceedingLine.type == dialogue) {
			// If preceeding line is formatted as dialogue BUT it's empty, we'll just return empty. OMG IT WORKS!
			if ([preceedingLine.string length] > 0) {
				// If preceeded by character cue, return dialogue
				if (preceedingLine.type == character) return dialogue;
				// If its a parenthetical line, return dialogue
				else if (preceedingLine.type == parenthetical) return dialogue;
				// AND if its just dialogue, return action.
				else return action;
			} else {
				return empty;
			}
		} else {
			return empty;
		}
    }
	
    char firstChar = [string characterAtIndex:0];
    char lastChar = [string characterAtIndex:length-1];
    
    bool containsOnlyWhitespace = [string containsOnlyWhitespace]; //Save to use again later
    bool twoSpaces = (length == 2 && firstChar == ' ' && lastChar == ' ');
    //If not empty, check if contains only whitespace. Exception: two spaces indicate a continued whatever, so keep them
    if (containsOnlyWhitespace && !twoSpaces) {
        return empty;
    }
	
	// Reset to zero to avoid strange formatting issues
	line.numberOfPrecedingFormattingCharacters = 0;
	
    //Check for forces (the first character can force a line type)
    if (firstChar == '!') {
        line.numberOfPrecedingFormattingCharacters = 1;
        return action;
    }
    if (firstChar == '@') {
        line.numberOfPrecedingFormattingCharacters = 1;
        return character;
    }
    if (firstChar == '~') {
        line.numberOfPrecedingFormattingCharacters = 1;
        return lyrics;
    }
    if (firstChar == '>' && lastChar != '<') {
        line.numberOfPrecedingFormattingCharacters = 1;
        return transitionLine;
    }
	if (firstChar == '>' && lastChar == '<') {
        //line.numberOfPreceedingFormattingCharacters = 1;
        return centered;
    }
    if (firstChar == '#') {
		// Thanks, Jacob Relkin
		NSUInteger len = [string length];
		NSInteger depth = 0;

		char character;
		for (int c = 0; c < len; c++) {
			character = [string characterAtIndex:c];
			if (character == '#') depth++; else break;
		}
		
		line.sectionDepth = depth;
		line.numberOfPrecedingFormattingCharacters = depth;
        return section;
    }
    if (firstChar == '=' && (length >= 2 ? [string characterAtIndex:1] != '=' : YES)) {
        line.numberOfPrecedingFormattingCharacters = 1;
        return synopse;
    }
	
	// '.' forces a heading. Because our American friends love to shoot their guns like we Finnish people love our booze, screenwriters might start dialogue blocks with such "words" as '.44'
	// So, let's NOT return a scene heading IF the previous line is not empty OR is a character OR is a parenthetical AND is not an omit in...
    if (firstChar == '.' && length >= 2 && [string characterAtIndex:1] != '.') {
		if (preceedingLine) {
			if (preceedingLine.type == character) return dialogue;
			else if (preceedingLine.type == parenthetical) return dialogue;
			else if (preceedingLine.string.length > 0 && ![preceedingLine.trimmed isEqualToString:@"/*"]) return action;
		}
		
		line.numberOfPrecedingFormattingCharacters = 1;
		return heading;
    }
		
    //Check for scene headings (lines beginning with "INT", "EXT", "EST",  "I/E"). "INT./EXT" and "INT/EXT" are also inside the spec, but already covered by "INT".
	if (preceedingLine.type == empty ||
		preceedingLine.string.length == 0 ||
		line.position == 0 ||
		[preceedingLine.trimmed isEqualToString:@"*/"] ||
		[preceedingLine.trimmed isEqualToString:@"/*"]) {
        if (length >= 3) {
            NSString* firstChars = [[string substringToIndex:3] lowercaseString];
			
            if ([firstChars isEqualToString:@"int"] ||
                [firstChars isEqualToString:@"ext"] ||
                [firstChars isEqualToString:@"est"] ||
                [firstChars isEqualToString:@"i/e"]) {
				
				// If it's just under 4 characters, return heading
				if (length < 4) return heading;
				else {
					char nextChar = [string characterAtIndex:3];
					if (nextChar == '.' || nextChar == ' ' || nextChar == '/') {
						// Line begins with int. or ext. etc.
						return heading;
					}
				}
            }
        }
    }
	
	//Check for title page elements. A title page element starts with "Title:", "Credit:", "Author:", "Draft date:" or "Contact:"
	//it has to be either the first line or only be preceeded by title page elements.
	if (!preceedingLine ||
		preceedingLine.type == titlePageTitle ||
		preceedingLine.type == titlePageAuthor ||
		preceedingLine.type == titlePageCredit ||
		preceedingLine.type == titlePageSource ||
		preceedingLine.type == titlePageContact ||
		preceedingLine.type == titlePageDraftDate ||
		preceedingLine.type == titlePageUnknown) {
		
		//Check for title page key: value pairs
		// - search for ":"
		// - extract key
		NSRange firstColonRange = [string rangeOfString:@":"];
		
		if (firstColonRange.length != 0 && firstColonRange.location != 0) {
			NSUInteger firstColonIndex = firstColonRange.location;
			
			NSString* key = [[string substringToIndex:firstColonIndex] lowercaseString];
			
			NSString* value = @"";
			// Trim the value
			if (string.length > firstColonIndex + 1) value = [string substringFromIndex:firstColonIndex + 1];
			value = [value stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
			
			// Store title page data
			NSDictionary *titlePageData = @{ key: [NSMutableArray arrayWithObject:value] };
			[_titlePage addObject:titlePageData];
			
			// Set this key as open (in case there are additional title page lines)
			_openTitlePageKey = key;
			
			if ([key isEqualToString:@"title"]) {
				return titlePageTitle;
			} else if ([key isEqualToString:@"author"] || [key isEqualToString:@"authors"]) {
				return titlePageAuthor;
			} else if ([key isEqualToString:@"credit"]) {
				return titlePageCredit;
			} else if ([key isEqualToString:@"source"]) {
				return titlePageSource;
			} else if ([key isEqualToString:@"contact"]) {
				return titlePageContact;
			} else if ([key isEqualToString:@"contacts"]) {
				return titlePageContact;
			} else if ([key isEqualToString:@"contact info"]) {
				return titlePageContact;
			} else if ([key isEqualToString:@"draft date"]) {
				return titlePageDraftDate;
			} else {
				return titlePageUnknown;
			}
		} else {
			// This is an additional line
			/*
			 if (length >= 2 && [[string substringToIndex:2] isEqualToString:@"  "]) {
			 line.numberOfPreceedingFormattingCharacters = 2;
			 return preceedingLine.type;
			 } else if (length >= 1 && [[string substringToIndex:1] isEqualToString:@"\t"]) {
			 line.numberOfPreceedingFormattingCharacters = 1;
			 return preceedingLine.type;
			 } */
			if (_openTitlePageKey) {
				NSMutableDictionary* dict = [_titlePage lastObject];
				[(NSMutableArray*)dict[_openTitlePageKey] addObject:line.string];
			}
			
			return preceedingLine.type;
		}
		
	}
	    
    //Check for transitionLines and page breaks
    if (trimmedString.length >= 3) {
        //transitionLine happens if the last three chars are "TO:"
        NSRange lastThreeRange = NSMakeRange(trimmedString.length - 3, 3);
        NSString *lastThreeChars = [trimmedString substringWithRange:lastThreeRange];

        if ([lastThreeChars isEqualToString:@"TO:"]) {
            return transitionLine;
        }
        
        //Page breaks start with "==="
        NSString *firstChars;
        if (trimmedString.length == 3) {
            firstChars = lastThreeChars;
        } else {
            firstChars = [trimmedString substringToIndex:3];
        }
        if ([firstChars isEqualToString:@"==="]) {
            return pageBreak;
        }
    }
    
    //Check if all uppercase (and at least 3 characters to not indent every capital leter before anything else follows) = character name.
    if (preceedingLine.type == empty || [preceedingLine.string length] == 0) {
        if (length >= 3 && [string containsOnlyUppercase] && !containsOnlyWhitespace) {
            // A character line ending in ^ is a double dialogue character
            if (lastChar == '^') {
				// PLEASE NOTE:
				// nextElementIsDualDialogue is ONLY used while staticly parsing for printing,
				// and SHOULD NOT be used anywhere else, as it won't be updated.
				NSUInteger i = index - 1;
				while (i >= 0) {
					Line *prevLine = [self.lines objectAtIndex:i];

					if (prevLine.type == character) {
						prevLine.nextElementIsDualDialogue = YES;
						break;
					}
					if (prevLine.type == heading) break;
					i--;
				}
				
                return dualDialogueCharacter;
            } else {
				// It is possible that this IS NOT A CHARACTER anyway, so let's see.
				if (index + 2 < self.lines.count && currentLine) {
					Line* nextLine = (Line*)self.lines[index+1];
					Line* twoLinesOver = (Line*)self.lines[index+2];
					
					if (recursive && [nextLine.string length] == 0 && [twoLinesOver.string length] > 0) {
						return action;
					}
				}

                return character;
            }
        }
    }
    
    //Check for centered text
    if (firstChar == '>' && lastChar == '<') {
        return centered;
    }

    //If it's just usual text, see if it might be (double) dialogue or a parenthetical, or section/synopsis
    if (preceedingLine) {
        if (preceedingLine.type == character || preceedingLine.type == dialogue || preceedingLine.type == parenthetical) {
            //Text in parentheses after character or dialogue is a parenthetical, else its dialogue
			if (firstChar == '(' && [preceedingLine.string length] > 0) {
                return parenthetical;
            } else {
				if ([preceedingLine.string length] > 0) {
					return dialogue;
				} else {
					return action;
				}
            }
        } else if (preceedingLine.type == dualDialogueCharacter || preceedingLine.type == dualDialogue || preceedingLine.type == dualDialogueParenthetical) {
            //Text in parentheses after character or dialogue is a parenthetical, else its dialogue
            if (firstChar == '(' && lastChar == ')') {
                return dualDialogueParenthetical;
            } else {
                return dualDialogue;
            }
        }
		/*
		// I beg to disagree with this.
		// This is not a part of the Fountain syntax definition, if I'm correct.
		else if (preceedingLine.type == section) {
            return section;
        } else if (preceedingLine.type == synopse) {
            return synopse;
        }
		*/
    }
    
    return action;
}

- (NSMutableIndexSet*)rangesInChars:(unichar*)string ofLength:(NSUInteger)length between:(char*)startString and:(char*)endString withLength:(NSUInteger)delimLength excludingIndices:(NSMutableIndexSet*)excludes line:(Line*)line
{
    NSMutableIndexSet* indexSet = [[NSMutableIndexSet alloc] init];
    
    NSInteger lastIndex = length - delimLength; //Last index to look at if we are looking for start
    NSInteger rangeBegin = -1; //Set to -1 when no range is currently inspected, or the the index of a detected beginning
    
    for (int i = 0;; i++) {
		if (i > lastIndex) break;
		
        // If this index is contained in the omit character indexes, skip
		if ([excludes containsIndex:i]) continue;
		
		// No range is currently inspected
        if (rangeBegin == -1) {
            bool match = YES;
            for (int j = 0; j < delimLength; j++) {
				// IF the characters in range are correct, check for an escape character (\)
				if (string[j+i] == startString[j] && i > 0 &&
					string[j + i - 1] == '\\') {
					match = NO;
					[line.escapeRanges addIndex:j+i - 1];
					break;
				}
				
                if (string[j+i] != startString[j]) {
                    match = NO;
                    break;
                }
            }
            if (match) {
                rangeBegin = i;
                i += delimLength - 1;
            }
		// We have found a range
        } else {
            bool match = YES;
            for (int j = 0; j < delimLength; j++) {
                if (string[j+i] != endString[j]) {
                    match = NO;
                    break;
				} else {
					// Check for escape characters again
					if (i > 0 && string[j+i - 1] == '\\') {
						[line.escapeRanges addIndex:j+i - 1];
						match = NO;
					}
				}
            }
            if (match) {
				// Add the current formatting ranges to future excludes
				[excludes addIndexesInRange:(NSRange){ rangeBegin, delimLength }];
				[excludes addIndexesInRange:(NSRange){ i, delimLength }];
				
                [indexSet addIndexesInRange:NSMakeRange(rangeBegin, i - rangeBegin + delimLength)];
                rangeBegin = -1;
                i += delimLength - 1;
            }
        }
    }
	
    return indexSet;
}

- (NSMutableIndexSet*)rangesOfOmitChars:(unichar*)string ofLength:(NSUInteger)length inLine:(Line*)line lastLineOmitOut:(bool)lastLineOut saveStarsIn:(NSMutableIndexSet*)stars
{
    NSMutableIndexSet* indexSet = [[NSMutableIndexSet alloc] init];
    
    NSInteger lastIndex = length - OMIT_PATTERN_LENGTH; //Last index to look at if we are looking for start
    NSInteger rangeBegin = lastLineOut ? 0 : -1; //Set to -1 when no range is currently inspected, or the the index of a detected beginning
    line.omitIn = lastLineOut;
    
    for (int i = 0;;i++) {
        if (i > lastIndex) break;
        if (rangeBegin == -1) {
            bool match = YES;
            for (int j = 0; j < OMIT_PATTERN_LENGTH; j++) {
                if (string[j+i] != OMIT_OPEN_PATTERN[j]) {
                    match = NO;
                    break;
                }
            }
            if (match) {
                rangeBegin = i;
                [stars addIndex:i+1];
            }
        } else {
            bool match = YES;
            for (int j = 0; j < OMIT_PATTERN_LENGTH; j++) {
                if (string[j+i] != OMIT_CLOSE_PATTERN[j]) {
                    match = NO;
                    break;
                }
            }
            if (match) {
                [indexSet addIndexesInRange:NSMakeRange(rangeBegin, i - rangeBegin + OMIT_PATTERN_LENGTH)];
                rangeBegin = -1;
                [stars addIndex:i];
            }
        }
    }
    
    //Terminate any open ranges at the end of the line so that this line is omited untill the end
    if (rangeBegin != -1) {
        NSRange rangeToAdd = NSMakeRange(rangeBegin, length - rangeBegin);
        [indexSet addIndexesInRange:rangeToAdd];
        line.omitOut = YES;
    } else {
        line.omitOut = NO;
    }
    
    return indexSet;
}

- (NSMutableIndexSet*)noteRanges:(unichar*)string ofLength:(NSUInteger)length inLine:(Line*)line partOfBlock:(bool)partOfBlock
{
	// If a note block is bleeding into this line, noteIn is true
	line.noteIn = partOfBlock;
	
	// Reset all indices
	NSMutableIndexSet* indexSet = [[NSMutableIndexSet alloc] init];
	
	line.cancelsNoteBlock = NO;
	line.endsNoteBlock = NO;
	[line.noteInIndices removeAllIndexes];
	[line.noteOutIndices removeAllIndexes];
	
	// Empty lines cut off note blocks
	if (line.type == empty && partOfBlock) {
		line.cancelsNoteBlock = YES;
		line.noteOut = NO;
		return indexSet;
	}
	
	// rangeBegin is -1 when a note range is not being inspected
	// and >0 when we have found the index of an open note range
	
	NSInteger lastIndex = length - NOTE_PATTERN_LENGTH; //Last index to look at if we are looking for start
	NSInteger rangeBegin = partOfBlock ? 0 : -1;
	
	bool beginsNoteBlock = NO;
	bool lookForTerminator = NO;
	if (line.noteIn) lookForTerminator = YES;
	
	for (int i = 0;;i++) {
		if (i > lastIndex) break;
		
		bool match = NO;
		if ((string[i] == '[' && string[i+1] == '[')) {
			lookForTerminator = NO;
			match = YES;
			beginsNoteBlock = YES;
			rangeBegin = i;
		}
		else if (string[i] == ']' && string[i+1] == ']') {
			
			if (lookForTerminator && rangeBegin != -1) {
				lookForTerminator = NO;
				line.endsNoteBlock = YES;
				
				beginsNoteBlock = NO;
				
				line.noteInIndices = [NSMutableIndexSet indexSetWithIndexesInRange:NSMakeRange(rangeBegin, i - rangeBegin + NOTE_PATTERN_LENGTH)];
				
				rangeBegin = -1;
			}
			else {
				match = YES;
				[indexSet addIndexesInRange:NSMakeRange(rangeBegin, i - rangeBegin + NOTE_PATTERN_LENGTH)];
				rangeBegin = -1;
			}

		}
	}
	
	//Terminate any open ranges at the end of the line so that this line is omited untill the end

	if (rangeBegin != -1) {
			//NSRange rangeToAdd = NSMakeRange(rangeBegin, length - rangeBegin);
			//[indexSet addIndexesInRange:rangeToAdd];

		// Let's take note that this line bleeds out a note range
		if (beginsNoteBlock) line.beginsNoteBlock = YES;
		line.noteOut = YES;
		
		NSRange rangeToAdd = NSMakeRange(rangeBegin, length - rangeBegin);
		NSMutableIndexSet *unterminatedIndices = [NSMutableIndexSet indexSetWithIndexesInRange:rangeToAdd];
		line.noteOutIndices = unterminatedIndices;
	} else {
		line.noteOut = NO;
		[line.noteOutIndices removeAllIndexes];
	}
	
	
	return indexSet;
}
- (void)terminateNoteFrom:(Line*)line {
	// We will now iterate
	NSInteger idx = [self.lines indexOfObject:line];
	if (idx == NSNotFound) idx = self.lines.count - 1;
	
	NSLog(@"go from %lu (%@) %@", idx, line.string, line.typeAsString);
	
	Line *prevLine;
	
	for (int i = (int)idx; i>=0; i--) {
		prevLine = self.lines[i];
		if (!prevLine.noteOut) break;
		
		NSLog(@"... %@", prevLine);
		
		unichar string[prevLine.string.length];
		[prevLine.string getCharacters:string];
		
		prevLine.noteRanges = [self noteRanges:string ofLength:prevLine.string.length inLine:prevLine partOfBlock:NO];
		if (prevLine.noteOut) prevLine.noteOut = NO;
		[_changedIndices addIndex:i];
		
		/*
		prevLine = self.lines[i];
		unichar string[line.string.length];
		[prevLine.string getCharacters:string];
		
		bool match = NO;
		int j = (int)prevLine.string.length;
		while (j >= 1) {
			if (string[j] == '[' && string[j-1] == '[') {
				match = YES;
				break;
			}
			j--;
		}
		
		if (match) {
			NSLog(@"[[ starts from %i", j);
			break;
		} else {
			NSLog(@"kill note from %@", line.string);
			[prevLine.noteRanges removeAllIndexes];
			[_changedIndices addIndex:i];
		}
		 */
	}
}


- (NSRange)sceneNumberForChars:(unichar*)string ofLength:(NSUInteger)length
{
    NSUInteger backNumberIndex = NSNotFound;
	int note = 0;
	
    for(NSInteger i = length - 1; i >= 0; i--) {
        char c = string[i];
		
		// Exclude note ranges: [[ Note ]]
		if (c == ' ') continue;
		if (c == ']' && note < 2) { note++; continue; }
		if (c == '[' && note > 0) { note--; continue; }
		
		// Inside a note range
		if (note == 2) continue;
		
        if (backNumberIndex == NSNotFound) {
            if (c == '#') backNumberIndex = i;
            else break;
        } else {
            if (c == '#') {
                return NSMakeRange(i+1, backNumberIndex-i-1);
            }
        }
    }
	
    return NSMakeRange(0, 0);
}

- (NSString *)colorForHeading:(Line *)line
{
	__block NSString *color = @"";
	
	line.colorRange = NSMakeRange(0, 0);
	[line.noteRanges enumerateRangesUsingBlock:^(NSRange range, BOOL * _Nonnull stop) {
		NSString * note = [line.string substringWithRange:range];

		NSRange noteRange = NSMakeRange(NOTE_PATTERN_LENGTH, [note length] - NOTE_PATTERN_LENGTH * 2);
		note =  [note substringWithRange:noteRange];
        
		if ([note localizedCaseInsensitiveContainsString:@COLOR_PATTERN] == true) {
			if (note.length > @COLOR_PATTERN.length + 1) {
				NSRange colorRange = [note rangeOfString:@COLOR_PATTERN options:NSCaseInsensitiveSearch];
				if (colorRange.length) {
					color = [note substringWithRange:NSMakeRange(colorRange.length, [note length] - colorRange.length)];
					color = [color stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
					
					line.colorRange = range;
				}
			}
		}
	}];

	return color;
}
- (NSArray *)storylinesForHeading:(Line *)line {
	__block NSMutableArray *storylines = [NSMutableArray array];
	
	[line.noteRanges enumerateRangesUsingBlock:^(NSRange range, BOOL * _Nonnull stop) {
		NSString * note = [line.string substringWithRange:range];

		NSRange noteRange = NSMakeRange(NOTE_PATTERN_LENGTH, [note length] - NOTE_PATTERN_LENGTH * 2);
		note =  [note substringWithRange:noteRange];
        
		if ([note localizedCaseInsensitiveContainsString:@STORYLINE_PATTERN] == true) {
			// Make sure it is really a storyline block with space & all
			if ([note length] > [@STORYLINE_PATTERN length] + 1) {
				line.storylineRange = range; // Save for editor use
				
				// Only the storylines
				NSRange storylineRange = [note rangeOfString:@STORYLINE_PATTERN options:NSCaseInsensitiveSearch];
			
				NSString *storylineString = [note substringWithRange:NSMakeRange(storylineRange.length, [note length] - storylineRange.length)];
				
				// Check that the user didn't mistype it "storylines"
				if (storylineString.length > 2) {
					NSString *firstChrs = [storylineString.uppercaseString substringToIndex:2];
					if ([firstChrs isEqualToString:@"S "]) storylineString = [storylineString substringFromIndex:2];
				}
				
				NSArray *components = [storylineString componentsSeparatedByString:@","];
				// Make uppercase & trim
				for (NSString* string in components) {
					[storylines addObject:[string.uppercaseString stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet]];
				}
			}
		}
	}];
	
	return storylines;
}

#pragma mark - Data access

- (NSString*)stringAtLine:(NSUInteger)line
{
    if (line >= [self.lines count]) {
        return @"";
    } else {
        Line* l = self.lines[line];
        return l.string;
    }
}

- (LineType)typeAtLine:(NSUInteger)line
{
    if (line >= [self.lines count]) {
        return NSNotFound;
    } else {
        Line* l = self.lines[line];
        return l.type;
    }
}

- (NSUInteger)positionAtLine:(NSUInteger)line
{
    if (line >= [self.lines count]) {
        return NSNotFound;
    } else {
        Line* l = self.lines[line];
        return l.position;
    }
}

- (NSString*)sceneNumberAtLine:(NSUInteger)line
{
    if (line >= self.lines.count) {
        return nil;
    } else {
        Line* l = self.lines[line];
        return l.sceneNumber;
    }
}

- (LineType)lineTypeAt:(NSInteger)index
{
	Line * line = [self lineAtPosition:index];
	
	if (!line) return action;
	else return line.type;
}

#pragma mark - Outline Data

- (NSUInteger)numberOfOutlineItems
{
	[self createOutline];
	return [_outline count];
}

- (OutlineScene*) getOutlineForLine: (Line *) line {
	for (OutlineScene * item in _outline) {
		if (item.line == line) {
			return item;
		}
		else if ([item.scenes count]) {
			for (OutlineScene * subItem in item.scenes) {
				if (subItem.line == line) {
					return subItem;
				}
			}
		}
	}
	return nil;
}
- (NSArray*)outlineItems {
	[self createOutline];
	return self.outline;
}
- (void)createOutline
{
	[_outline removeAllObjects];
	[_storylines removeAllObjects];
	
	NSUInteger result = 0;

	// Get first scene number
	NSUInteger sceneNumber = 1;
	
	if ([self.documentSettings getInt:DocSettingSceneNumberStart] > 0) {
		sceneNumber = [self.documentSettings getInt:DocSettingSceneNumberStart];
	}
	
	// We will store a section depth to adjust depth for scenes that come after a section
	NSUInteger sectionDepth = 0;
	
	OutlineScene *previousScene;
	
	// This is for allowing us to include synopses INSIDE scenes when needed
	OutlineScene *sceneBlock;
	Line *previousLine;
	
	for (Line* line in self.lines) {
		if (line.type == section || line.type == synopse || line.type == heading) {
		
			// Create an outline item
			//OutlineScene *item = [[OutlineScene alloc] init];
			OutlineScene *scene = [OutlineScene withLine:line];
			
			//item.type = line.type;
			//item.omitted = line.omitted;
			//item.line = line;
			//item.storylines = line.storylines;
			
			if (!scene.omitted) scene.string = line.stripInvisible;
			else scene.string = line.stripNotes;
			
			// Add storylines to the storyline bank
			for (NSString* storyline in scene.storylines) {
				if (![_storylines containsObject:storyline]) [_storylines addObject:storyline];
			}
			
			if (scene.type == section) {
				// Save section depth
				sectionDepth = line.sectionDepth;
				scene.sectionDepth = sectionDepth;
			} else {
				scene.sectionDepth = sectionDepth;
			}
			
			if (line.type == heading) {
				// Check if the scene is omitted
				// If the scene is omited, let's not increment scene number for it.
				// However, if the scene has a forced number, we'll maintain it
				if (line.sceneNumberRange.length > 0) {
					scene.sceneNumber = line.sceneNumber;
				}
				else {
					if (!line.omitted) {
						scene.sceneNumber = [NSString stringWithFormat:@"%lu", sceneNumber];
						line.sceneNumber = [NSString stringWithFormat:@"%lu", sceneNumber];
						sceneNumber++;
					} else {
						scene.sceneNumber = @"";
						line.sceneNumber = @"";
					}
				}
				
				// Create an array for character names
				scene.characters = [NSMutableArray array];
			}
			
			if (previousScene) {
				// If this is a synopsis line, it might need to be included in the previous scene length (for moving them around)
				if (scene.type == synopse) {
					if (previousLine.type == heading) {
						// This synopsis belongs into a block, so don't set the length for previous scene
						sceneBlock = previousScene;
					} else {
						// Act normally
						previousScene.length = scene.position - previousScene.position;
					}
				} else {
					if (sceneBlock) {
						// Reset scene block
						sceneBlock.length = scene.position - sceneBlock.position;
						sceneBlock = nil;
					} else {
						previousScene.length = scene.position - previousScene.position;
					}
				}
			}
			
			// Set previous scene to point to the current one
			previousScene = scene;

			result++;
			[_outline addObject:scene];
		}
		
		// Add characters if we are inside a scene
		if (line.type == character && previousScene.type == heading) {
			[previousScene.characters addObject:line.characterName];
		}
		
		// Done. Set the previous line.
		if (line.type != empty) previousLine = line;
	}
	
	OutlineScene *lastScene = _outline.lastObject;
	Line *lastLine = _lines.lastObject;
	lastScene.length = lastLine.position + lastLine.string.length - lastScene.position;
}

- (BOOL)getAndResetChangeInOutline
{
    if (_changeInOutline) {
        _changeInOutline = NO;
        return YES;
    }
    return NO;
}

#pragma mark - Convenience

- (NSInteger)numberOfScenes {
	NSInteger scenes = 0;
	for (Line *line in self.lines) {
		if (line.type == heading) scenes++;
	}
	return scenes;
}
- (NSArray*) scenes {
	NSMutableArray *scenes = [NSMutableArray array];
	for (OutlineScene *scene in self.outline) {
		if (scene.type == heading) [scenes addObject:scene];
	}
	return scenes;
}

- (NSArray*)linesForScene:(OutlineScene*)scene {
	NSMutableArray *lines = [NSMutableArray array];
	
	@try {
		NSRange sceneRange = NSMakeRange(scene.position, scene.length);
		
		for (Line* line in self.lines) {
			if (NSLocationInRange(line.position, sceneRange)) [lines addObject:line];
		}
	}
	@catch (NSException *e) {
		NSLog(@"No lines found");
	}
	return lines;
}

- (Line*)nextLine:(Line*)line {
	NSInteger lineIndex = [self.lines indexOfObject:line];
	
	if (line == self.lines.lastObject || self.lines.count < 2 || lineIndex == NSNotFound) return nil;
	
	return self.lines[lineIndex + 1];
}


#pragma mark - Utility

- (NSString *)description
{
    NSString *result = @"";
    NSUInteger index = 0;
    for (Line *l in self.lines) {
        //For whatever reason, %lu doesn't work with a zero
        if (index == 0) {
            result = [result stringByAppendingString:@"0 "];
        } else {
            result = [result stringByAppendingFormat:@"%lu ", (unsigned long) index];
        }
		
        result = [[result stringByAppendingString:[NSString stringWithFormat:@"%@", l]] stringByAppendingString:@"\n"];
        index++;
    }
    //Cut off the last newline
    result = [result substringToIndex:result.length - 1];
    return result;
}

// This returns a pure string with no comments or invisible elements
- (NSString *)cleanedString {
	NSString * result = @"";
	
	for (Line* line in self.lines) {
		// Skip invisible elements
		if (line.type == section || line.type == synopse || line.omitted || line.isTitlePage) continue;
		
		result = [result stringByAppendingFormat:@"%@\n", line.cleanedString];
	}
	
	return result;
}

- (Line*)lineAtIndex:(NSInteger)index {
	return [self lineAtPosition:index];
}
- (Line*)lineAtPosition:(NSInteger)position {
	for (Line* line in self.lines) {
		if (position >= line.position && position < line.position + line.string.length + 1) return line;
	}
	return nil;
}
- (NSArray*)linesInRange:(NSRange)range {
	NSMutableArray *lines = [NSMutableArray array];
	for (Line* line in self.lines) {
		if ((NSLocationInRange(line.position, range) ||
			NSLocationInRange(range.location, line.textRange) ||
			NSLocationInRange(range.location + range.length, line.textRange)) &&
			NSIntersectionRange(range, line.textRange).length > 0) {
			[lines addObject:line];
		}
	}
	
	return lines;
}

- (OutlineScene*)sceneAtIndex:(NSInteger)index {
	for (OutlineScene *scene in self.outline) {
		if (NSLocationInRange(index, scene.range)) return scene;
	}
	return nil;
}

- (NSArray*)preprocessForPrinting {
	[self createOutline];
	return [self preprocessForPrintingWithLines:self.lines];
}
- (NSArray*)preprocessForPrintingWithLines:(NSArray*)lines {
	if (!lines) {
		NSLog(@"WARNING: No lines issued for preprocessing, using all parsed lines");
		lines = self.lines;
	}
	
	// Get scene number offset from the delegate/document settings
	NSInteger sceneNumber = 1;
	if ([self.documentSettings getInt:DocSettingSceneNumberStart] > 1) {
		sceneNumber = [self.documentSettings getInt:DocSettingSceneNumberStart];
		if (sceneNumber < 1) sceneNumber = 1;
	}
	
	// Printable elements
	NSMutableArray *elements = [NSMutableArray array];
	
	Line *previousLine;
	
	for (Line *line in lines) {
		// Skip over certain elements
		if (line.type == synopse || line.type == section || line.omitted || line.isTitlePage) {
			continue;
		}
		
		// Add scene numbers
		if (line.type == heading) {
			if (line.sceneNumberRange.length > 0) {
				line.sceneNumber = [line.string substringWithRange:line.sceneNumberRange];
			}
			else if (!line.sceneNumber) {
				line.sceneNumber = [NSString stringWithFormat:@"%lu", sceneNumber];
				sceneNumber += 1;
			}
		} else {
			line.sceneNumber = @"";
		}
		
		// Eliminate faux empty lines with only single space (let's use two)
		if ([line.string isEqualToString:@" "]) {
			line.type = empty;
			continue;
		}
		
		// This is a paragraph with a line break, so append the line to the previous one
		// A quick explanation for this practice: We generally skip empty lines and instead
		// calculate margins before elements. This is a legacy of the old Fountain parser,
		// but is actually somewhat sensitive approach. That's why we join the lines into
		// one element.
		
		if (line.isSplitParagraph && [lines indexOfObject:line] > 0 && elements.count > 0) {
			Line *preceedingLine = [elements objectAtIndex:elements.count - 1];

			[preceedingLine joinWithLine:line];
			continue;
		}
		
		// Remove misinterpreted dialogue
		if (line.type == dialogue && line.string.length < 1) {
			line.type = empty;
			previousLine = line;
			continue;
		}
		
		[elements addObject:line];
		
		// If this is dual dialogue character cue,
		// we need to search for the previous one too, just in cae
		if (line.isDualDialogueElement) {
			NSInteger i = elements.count - 2; // Go for previous element
			while (i > 0) {
				Line *preceedingLine = [elements objectAtIndex:i];
				
				if (!(preceedingLine.isDialogueElement || preceedingLine.isDualDialogueElement)) break;
				
				if (preceedingLine.type == character ) {
					preceedingLine.nextElementIsDualDialogue = YES;
					break;
				}
				i--;
			}
		}
		
		previousLine = line;
	}
	
	return elements;
}

#pragma mark - Document settings

- (BeatDocumentSettings*)documentSettings {
	if (self.delegate) return self.delegate.documentSettings;
	else if (self.staticDocumentSettings) return self.staticDocumentSettings;
	else return nil;
}

#pragma mark - Separate title page & content for printing

- (NSDictionary*)scriptForPrinting {
	// NOTE: Use ONLY for static parsing
	return @{ @"title page": self.titlePage, @"script": [self preprocessForPrinting] };
}

#pragma mark - String result for saving the screenplay

- (NSString*)scriptForSaving {
	NSMutableString *string = [NSMutableString string];
	
	Line *previousLine;
	for (Line* line in self.lines) {
		// Ensure we have correct amount of line breaks before elements
		if ((line.type == character || line.type == heading) &&
			previousLine.string.length > 0) {
			[string appendString:@"\n"];
		}
		
		[string appendString:line.string];
		[string appendString:@"\n"];
		
		previousLine = line;
	}
	
	return string;
}

#pragma mark - Testing methods

- (void)startMeasure
{
	_executionTime = [NSDate date];
}
- (NSTimeInterval)getMeasure {
	NSDate *methodFinish = [NSDate date];
	NSTimeInterval executionTime = [methodFinish timeIntervalSinceDate:_executionTime];
	return executionTime;
}
- (void)endMeasure:(NSString*)name
{
	NSDate *methodFinish = [NSDate date];
	NSTimeInterval executionTime = [methodFinish timeIntervalSinceDate:_executionTime];
	NSLog(@"%@ execution time = %f", name, executionTime);
}

@end
/*
 
 Thank you, Hendrik Noeller, for making Beat possible.
 Without your massive original work, any of this had never happened.
 
 */
