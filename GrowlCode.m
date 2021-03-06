/*
 Copyright (c) The Growl Project, 2004-2005
 Copyright (c) Ben Willmore, 2006-2009
 All rights reserved.
 
 
 Redistribution and use in source and binary forms, with or without modification,
 are permitted provided that the following conditions are met:
 
 
 1. Redistributions of source code must retain the above copyright
 notice, this list of conditions and the following disclaimer.
 2. Redistributions in binary form must reproduce the above copyright
 notice, this list of conditions and the following disclaimer in the
 documentation and/or other materials provided with the distribution.
 3. Neither the name of Growl nor the names of its contributors
 may be used to endorse or promote products derived from this software
 without specific prior written permission.
 
 
 THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND 
 ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WAR
 RANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. I
 N NO EVENT SHALL THE COPYRIGHT OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, IN
 DIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT 
 NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, O
 R PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILIT
 Y, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERW
 ISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE P
 OSSIBILITY OF SUCH DAMAGE.
 
 */

//
//  GrowlCode.m
//  GrowlCode
//

#import "GrowlCode.h"
#import <Growl/Growl.h>
#import <objc/objc-runtime.h>

static int CodeVersion;
static NSString* operationStarted = @"OperationStarted";
static NSString* operationCanceled = @"OperationCanceled";
static NSString* buildSucceeded = @"Build Succeeded";
static NSString* buildFailed = @"Build Failed";
static NSString* cleanComplete = @"Clean Complete";
static NSString* disassemblyComplete = @"Disassembly Complete";
static NSString* compilationSucceeded = @"Compilation Succeeded";
static NSString* compilationFailed = @"Compilation Failed";
static NSString* preprocessingComplete = @"Preprocessing Complete";

static NSMutableDictionary* buildStatuses = nil;

BOOL PerformSwizzle(Class c, SEL orig, SEL new);

BOOL PerformSwizzle(Class c, SEL orig, SEL new)
{
    Method origMethod = class_getInstanceMethod(c, orig);
    Method newMethod = class_getInstanceMethod(c, new);
    if(class_addMethod(c, orig, method_getImplementation(newMethod), method_getTypeEncoding(newMethod)))
        class_replaceMethod(c, new, method_getImplementation(origMethod), method_getTypeEncoding(origMethod));
    else
		method_exchangeImplementations(origMethod, newMethod);
	return YES;
}

@implementation GrowlCode
+ (NSBundle *) bundle {
	return [NSBundle bundleForClass:self];
}

+ (NSString *) bundleVersion {
	return [[[GrowlCode bundle] infoDictionary] objectForKey:(NSString *)kCFBundleVersionKey];
}

+ (void) load
{
	NSString *growlPath = [[[GrowlCode bundle] privateFrameworksPath] stringByAppendingPathComponent:@"Growl.framework"];
	NSBundle *growlBundle = [NSBundle bundleWithPath:growlPath];
	
	if (!(growlBundle && [growlBundle load])) {
		NSLog(@"GrowlCode: Could not load Growl.framework, disabled");
		return;
	}
	// Register ourselves as a Growl delegate
	[GrowlApplicationBridge setGrowlDelegate:self];
		
	Class class = NSClassFromString(@"PBXAppDelegate");
	SEL origSel = @selector(_buildOperationDidStop:);
	SEL newSel = @selector(gcBuildOperationDidStop:);
	if (!PerformSwizzle(class, origSel, newSel)) {
		NSLog(@"GrowlCode: Swizzle failed, disabled: %@ %@ %@",class,NSStringFromSelector(origSel),NSStringFromSelector(newSel));
		return;
	}
		
	//class-dump /Developer/Library/PrivateFrameworks/DevToolsCore.framework/DevToolsCore 
	class = NSClassFromString(@"XCBuildOperation");
	origSel = @selector(initWithProject:buildAction:configurationName:activeArchitecture:overridingProperties:buildables:);
	newSel = @selector(gcInitWithProject:buildAction:configurationName:activeArchitecture:overridingProperties:buildables:);
	if (!PerformSwizzle(class, origSel, newSel)) {
		NSLog(@"GrowlCode: Swizzle failed, disabled: %@ %@ %@",class,NSStringFromSelector(origSel),NSStringFromSelector(newSel));
		return;
	}
	
	class = NSClassFromString(@"XCBuildOperation");
	origSel = @selector(cancel);
	newSel = @selector(gcCancel);
	if (!PerformSwizzle(class, origSel, newSel)) {
		NSLog(@"GrowlCode: Swizzle failed, disabled: %@ %@ %@",class,NSStringFromSelector(origSel),NSStringFromSelector(newSel));
		return;
	}
	
	CodeVersion = [[[[NSBundle mainBundle] infoDictionary] objectForKey:(NSString *)kCFBundleVersionKey] intValue];
  NSLog(@"GrowlCode loaded");
}

#pragma mark GrowlApplicationBridge delegate methods

+ (NSString *) applicationNameForGrowl {
	return @"GrowlCode";
}

+ (NSData *) applicationIconDataForGrowl {
	NSWorkspace *ws = [NSWorkspace sharedWorkspace];
	NSImage 	*icon = nil;
	if (!(icon = [ws iconForFile: [ws fullPathForApplication: @"Xcode"]]))
		return [[NSImage imageNamed:@"NSApplicationIcon"] TIFFRepresentation];
	else
		return [icon TIFFRepresentation]; 
}

+ (NSDictionary *) registrationDictionaryForGrowl {
	NSBundle *bundle = [GrowlCode bundle];
	NSArray *array = [[NSArray alloc] initWithObjects:
					  NSLocalizedStringFromTableInBundle(buildSucceeded, nil, bundle, @""),
					  NSLocalizedStringFromTableInBundle(buildFailed, nil, bundle, @""),
					  NSLocalizedStringFromTableInBundle(cleanComplete, nil, bundle, @""),
					  NSLocalizedStringFromTableInBundle(disassemblyComplete, nil, bundle, @""),
					  NSLocalizedStringFromTableInBundle(compilationSucceeded, nil, bundle, @""),
					  NSLocalizedStringFromTableInBundle(compilationFailed, nil, bundle, @""),
					  NSLocalizedStringFromTableInBundle(preprocessingComplete, nil, bundle, @""),
					  nil];
	NSDictionary *dict = [NSDictionary dictionaryWithObjectsAndKeys:
						  array, GROWL_NOTIFICATIONS_DEFAULT,
						  array, GROWL_NOTIFICATIONS_ALL,
						  nil];
	[array release];
	
	return dict;
}

@end

@implementation NSObject (GrowlCodePatch)

- (id)gcInitWithProject:(id)project buildAction:(id)buildAction configurationName:(id)configName
	 activeArchitecture:(id)arch overridingProperties:(id)override buildables:(id)buildables
{
	if (!buildStatuses)
		buildStatuses = [[NSMutableDictionary dictionaryWithCapacity:0] retain];
	
	[buildStatuses setObject:operationStarted forKey:[NSNumber numberWithInt:(long)self]];
	
	return [self gcInitWithProject:project buildAction:buildAction configurationName:configName 
				activeArchitecture:(id)arch
			  overridingProperties:override buildables:buildables];
}

-(void)gcCancel
{
	[buildStatuses setObject:operationCanceled forKey:[NSNumber numberWithInt:(long)self]];
	[self gcCancel];
}

-(void)gcBuildOperationDidStop:(NSNotification *)theNotification
{
	NSNumber* buildOperationAsNumber = [NSNumber numberWithInt:(long)[theNotification object]];
	NSString* buildStatus = [buildStatuses objectForKey:buildOperationAsNumber];
	
	if ([buildStatus isEqual:operationCanceled]) {
		[buildStatuses removeObjectForKey:buildOperationAsNumber];
		[self gcBuildOperationDidStop:theNotification];
		return;
	}
	
	id object = [theNotification object];
	NSString* buildAction = [(NSObject*)object buildAction];
	
	NSString* projectName = [[object project] name];
	NSString* configurationName = [object configurationName];
	
    // growl notification strings
	NSBundle* bundle = [GrowlCode bundle];	
	NSString* growlName = nil;
	NSString* extraInfo = nil;
	
	int errors = -1;
	int warnings = -1;
	NSString* errorString = nil;
	NSString* warningString = nil;
	if ([object isKindOfClass:NSClassFromString(@"XCTargetBuildOperation")] ||
		[object isKindOfClass:NSClassFromString(@"XCCompileFileBuildOperation")]) {
		errors = [[theNotification object] totalNumberOfErrors];
		warnings = [[theNotification object] totalNumberOfWarnings];
		errorString = (errors==1) ? NSLocalizedStringFromTableInBundle(@"error", nil, bundle, @"") : 
		NSLocalizedStringFromTableInBundle(@"errors", nil, bundle, @""); 
		warningString = (warnings==1) ? NSLocalizedStringFromTableInBundle(@"warning", nil, bundle, @"") : 
		NSLocalizedStringFromTableInBundle(@"warnings", nil, bundle, @"");
	}
	
	if ([object isKindOfClass:NSClassFromString(@"XCTargetBuildOperation")]) {
		if ([buildAction isEqual:@"build"]) {
			growlName = (errors==0) ? NSLocalizedStringFromTableInBundle(buildSucceeded, nil, bundle, @"") :
			NSLocalizedStringFromTableInBundle(buildFailed, nil, bundle, @"");
			extraInfo = (errors==0) ? [NSString stringWithFormat:@"%d %@", warnings, warningString] :
			[NSString stringWithFormat:@"%d %@, %d %@", errors, errorString, warnings, warningString];
		}
		else if ([buildAction isEqual:@"clean"])
			growlName = NSLocalizedStringFromTableInBundle(cleanComplete, nil, bundle, @"");
	}
	
	else if ([object isKindOfClass:NSClassFromString(@"XCDisassembleFileBuildOperation")])
		growlName = NSLocalizedStringFromTableInBundle(disassemblyComplete, nil, bundle, @"");
	
	else if ([object isKindOfClass:NSClassFromString(@"XCCompileFileBuildOperation")]) {
		growlName = (errors==0) ? NSLocalizedStringFromTableInBundle(compilationSucceeded, nil, bundle, @"") :
		NSLocalizedStringFromTableInBundle(compilationFailed, nil, bundle, @"");
		extraInfo = (errors==0) ? [NSString stringWithFormat:@"%d %@", warnings, warningString] :
		[NSString stringWithFormat:@"%d %@, %d %@", errors, errorString, warnings, warningString];
	}
	
	else if ([object isKindOfClass:NSClassFromString(@"XCPreprocessFileBuildOperation")])
		growlName = NSLocalizedStringFromTableInBundle(preprocessingComplete, nil, bundle, @"");
	
	if (growlName) {
	    NSString* configString = [[@" (" stringByAppendingString:configurationName] stringByAppendingString:@")"];
		NSString* description = [projectName stringByAppendingString:configString];
		if (extraInfo)
			description = [[description stringByAppendingString:@"\n"] stringByAppendingString:extraInfo];
		
		NSString* iconName = nil;
		if (errors > 0) {
			iconName = @"failed";
		} else {
			iconName = (warnings==0) ? @"passed" : @"warning";
		}

		NSData* iconData = [NSData dataWithContentsOfFile:[bundle pathForResource:iconName ofType:@"png"]];
		
		[GrowlApplicationBridge notifyWithTitle:growlName
									description:description
							   notificationName:growlName
									   iconData:iconData
									   priority:0
									   isSticky:NO
								   clickContext:nil];
		
	}
    [buildStatuses removeObjectForKey:buildOperationAsNumber];
	
	[self gcBuildOperationDidStop:theNotification];
}

@end
