/*
 * Author: Andreas Linde <mail@andreaslinde.de>
 *         Kent Sutherland
 *
 * Copyright (c) 2011 Andreas Linde & Kent Sutherland.
 * All rights reserved.
 *
 * Permission is hereby granted, free of charge, to any person
 * obtaining a copy of this software and associated documentation
 * files (the "Software"), to deal in the Software without
 * restriction, including without limitation the rights to use,
 * copy, modify, merge, publish, distribute, sublicense, and/or sell
 * copies of the Software, and to permit persons to whom the
 * Software is furnished to do so, subject to the following
 * conditions:
 *
 * The above copyright notice and this permission notice shall be
 * included in all copies or substantial portions of the Software.
 *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
 * EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES
 * OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
 * NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT
 * HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY,
 * WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
 * FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR
 * OTHER DEALINGS IN THE SOFTWARE.
 */

#import "CNSCrashReportManager.h"
#import "CNSCrashReportUI.h"
#import <sys/sysctl.h>
#import <CrashReporter/CrashReporter.h>
#import "CNSCrashReportTextFormatter.h"

#define SDK_NAME @"HockeySDK-Mac"
#define SDK_VERSION @"0.5"

#define CRASHREPORT_MAX_CONSOLE_SIZE 50000

@interface CNSCrashReportManager(private)
- (NSString *) applicationName;
- (NSString *) applicationVersionString;
- (NSString *) applicationVersion;

- (void) handleCrashReport;
- (BOOL) hasPendingCrashReport;
- (void)_cleanCrashReports;

- (void) _postXML:(NSString*)xml;
- (void) searchCrashLogFile:(NSString *)path;

- (void) returnToMainApplication;
@end


@implementation CNSCrashReportManager

@synthesize crashReportMechanism = _crashReportMechanism;
@synthesize delegate = _delegate;
@synthesize appIdentifier = _appIdentifier;
@synthesize companyName = _companyName;
@synthesize autoSubmitCrashReport = _autoSubmitCrashReport;

#pragma mark - Init

+ (CNSCrashReportManager *)sharedCrashReportManager {
  static CNSCrashReportManager *crashReportManager = nil;
  
  if (crashReportManager == nil) {
    crashReportManager = [[CNSCrashReportManager alloc] init];
  }
  
  return crashReportManager;
}

- (id) init {
  if ((self = [super init])) {
    _crashReportMechanism = CrashReportMechanismPLCrashReporter;
    _serverResult = CrashReportStatusUnknown;
    _crashReportUI = nil;
    _fileManager = [[NSFileManager alloc] init];
    
    _submissionURL = @"https://rink.hockeyapp.net/";
    
    _crashFile = nil;
    _crashFiles = nil;
    
    self.delegate = nil;
    self.companyName = @"";
    
    NSString *testValue = nil;
    testValue = [[NSUserDefaults standardUserDefaults] stringForKey:kHockeySDKCrashReportActivated];
    if (testValue) {
      _crashReportActivated = [[NSUserDefaults standardUserDefaults] boolForKey:kHockeySDKCrashReportActivated];
    } else {
      _crashReportActivated = YES;
      [[NSUserDefaults standardUserDefaults] setValue:[NSNumber numberWithBool:YES] forKey:kHockeySDKCrashReportActivated];
    }
  }
  return self;
}

- (void)dealloc {
  _delegate = nil;

  [_companyName release]; _companyName = nil;

  [_fileManager release]; _fileManager = nil;

  [_crashFile release]; _crashFile = nil;
  
  [_crashFiles release]; _crashFiles = nil;
  [_crashesDir release]; _crashesDir = nil;
  
  [_crashReportUI release]; _crashReportUI= nil;
  
  [super dealloc];
}


#pragma mark - Private

- (void)_cleanCrashReports {
  NSError *error = NULL;
  
  for (NSUInteger i=0; i < [_crashFiles count]; i++) {		
    [_fileManager removeItemAtPath:[_crashFiles objectAtIndex:i] error:&error];
  }
  [_crashFiles removeAllObjects];
  
  [[NSUserDefaults standardUserDefaults] setObject:nil forKey:kHockeySDKApprovedCrashReports];
  [[NSUserDefaults standardUserDefaults] synchronize];    
}


- (NSString *) consoleContent {
  // get the console log
  NSError* error = nil;
  NSMutableString *content = [[NSMutableString alloc] initWithString:@""];
  
  NSEnumerator *theEnum = [[[NSString stringWithContentsOfFile:@"/private/var/log/system.log" encoding:NSUTF8StringEncoding error:&error] componentsSeparatedByString: @"\n"] objectEnumerator];
  NSString* currentObject;
  NSMutableArray* applicationStrings = [NSMutableArray array];
  
  NSString* searchString = [[self applicationName] stringByAppendingString:@"["];
  while ( (currentObject = [theEnum nextObject]) ) {
    if ([currentObject rangeOfString:searchString].location != NSNotFound)
      [applicationStrings addObject: currentObject];
  }
  
  NSInteger i;
  for(i = ((NSInteger)[applicationStrings count])-1; (i>=0 && i>((NSInteger)[applicationStrings count])-100); i--) {
    [content appendString:[applicationStrings objectAtIndex:i]];
    [content appendString:@"\n"];
  }
  
  // Now limit the content to CRASHREPORTSENDER_MAX_CONSOLE_SIZE (default: 50kByte)
  if ([content length] > CRASHREPORT_MAX_CONSOLE_SIZE) {
    content = (NSMutableString *)[content substringWithRange:NSMakeRange([content length]-CRASHREPORT_MAX_CONSOLE_SIZE-1, CRASHREPORT_MAX_CONSOLE_SIZE)]; 
  }
  
  return [content autorelease];
}


- (NSString *) modelVersion {
  NSString * modelString  = nil;
  int        modelInfo[2] = { CTL_HW, HW_MODEL };
  size_t     modelSize;
  
  if (sysctl(modelInfo,
             2,
             NULL,
             &modelSize,
             NULL, 0) == 0) {
    void * modelData = malloc(modelSize);
    
    if (modelData) {
      if (sysctl(modelInfo,
                 2,
                 modelData,
                 &modelSize,
                 NULL, 0) == 0) {
        modelString = [NSString stringWithUTF8String:modelData];
      }
      
      free(modelData);
    }
  }
  
  return modelString;
}

- (void) returnToMainApplication {
  if ( self.delegate != nil && [self.delegate respondsToSelector:@selector(showMainApplicationWindow)])
    [self.delegate showMainApplicationWindow];
}

- (void) startManager {
  BOOL returnToApp = NO;
  
  if ([self hasPendingCrashReport]) {
    NSError* error = nil;
    NSString *crashReport = nil;
    if (_crashReportMechanism == CrashReportMechanismPLCrashReporter) {
      _crashFile = [_crashFiles lastObject];
      NSData *crashData = [NSData dataWithContentsOfFile: _crashFile];
      PLCrashReport *report = [[[PLCrashReport alloc] initWithData:crashData error:&error] autorelease];
      crashReport = [CNSCrashReportTextFormatter stringValueForCrashReport:report withTextFormat:PLCrashReportTextFormatiOS];
    } else {
      NSString *crashLogs = [NSString stringWithContentsOfFile:_crashFile encoding:NSUTF8StringEncoding error:&error];
      if (!error) {
        crashReport = [[crashLogs componentsSeparatedByString: @"**********\n\n"] lastObject];
      }
    }

    if (crashReport && !error) {        
      NSString* description = @"";
    
      if (_delegate && [_delegate respondsToSelector:@selector(crashReportDescription)]) {
        description = [_delegate crashReportDescription];
      }

      if (self.autoSubmitCrashReport) {
        [self sendReportCrash:crashReport crashNotes:description];
      } else {
        _crashReportUI = [[CNSCrashReportUI alloc] initWithManager:self crashReport:crashReport companyName:_companyName applicationName:[self applicationName]];
        
        [_crashReportUI askCrashReportDetails];
      }
    } else {
      returnToApp = YES;
    }
  } else {
    returnToApp = YES;
  }
  
  if (returnToApp)
    [self returnToMainApplication];
}


#pragma mark - Mac OS X based

- (void) searchCrashLogFile:(NSString *)path {  
  NSError* error;
  NSMutableArray* filesWithModificationDate = [NSMutableArray array];
  NSArray* crashLogFiles = [_fileManager contentsOfDirectoryAtPath:path error:&error];
  NSEnumerator* filesEnumerator = [crashLogFiles objectEnumerator];
  NSString* crashFile;
  while((crashFile = [filesEnumerator nextObject])) {
    NSString* crashLogPath = [path stringByAppendingPathComponent:crashFile];
    NSDate* modDate = [[_fileManager attributesOfItemAtPath:crashLogPath error:&error] fileModificationDate];
    [filesWithModificationDate addObject:[NSDictionary dictionaryWithObjectsAndKeys:crashFile,@"name",crashLogPath,@"path",modDate,@"modDate",nil]];
  }
  
  NSSortDescriptor* dateSortDescriptor = [[[NSSortDescriptor alloc] initWithKey:@"modDate" ascending:YES] autorelease];
  NSArray* sortedFiles = [filesWithModificationDate sortedArrayUsingDescriptors:[NSArray arrayWithObject:dateSortDescriptor]];
  
  NSPredicate* filterPredicate = [NSPredicate predicateWithFormat:@"name BEGINSWITH %@", [self applicationName]];
  NSArray* filteredFiles = [sortedFiles filteredArrayUsingPredicate:filterPredicate];
  
  _crashFile = [[[filteredFiles valueForKeyPath:@"path"] lastObject] copy];
}

#pragma mark - setter

- (void)storeLastCrashDate:(NSDate *) date {
  [[NSUserDefaults standardUserDefaults] setValue:date forKey:@"CrashReportSender.lastCrashDate"];
  [[NSUserDefaults standardUserDefaults] synchronize];
}

- (NSDate *)loadLastCrashDate {
  NSDate *date = [[NSUserDefaults standardUserDefaults] valueForKey:@"CrashReportSender.lastCrashDate"];
  return date ?: [NSDate distantPast];
}

- (void)storeAppVersion:(NSString *) version {
  [[NSUserDefaults standardUserDefaults] setValue:version forKey:@"CrashReportSender.appVersion"];
  [[NSUserDefaults standardUserDefaults] synchronize];
}

- (NSString *)loadAppVersion {
  NSString *appVersion = [[NSUserDefaults standardUserDefaults] valueForKey:@"CrashReportSender.appVersion"];
  return appVersion ?: nil;
}

#pragma mark - PLCrashReporter based

#pragma mark - GetCrashData

- (BOOL) hasPendingCrashReport {
  if (!_crashReportActivated) return NO;
  
  if (_crashReportMechanism == CrashReportMechanismPLCrashReporter) {
    
    _crashFiles = [[NSMutableArray alloc] init];
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES);
    _crashesDir = [[NSString stringWithFormat:@"%@", [[paths objectAtIndex:0] stringByAppendingPathComponent:@"/crashes/"]] retain];
    
    if (![_fileManager fileExistsAtPath:_crashesDir]) {
      NSDictionary *attributes = [NSDictionary dictionaryWithObject: [NSNumber numberWithUnsignedLong: 0755] forKey: NSFilePosixPermissions];
      NSError *theError = NULL;
      
      [_fileManager createDirectoryAtPath:_crashesDir withIntermediateDirectories: YES attributes: attributes error: &theError];
    }
    
    PLCrashReporter *crashReporter = [PLCrashReporter sharedReporter];
    NSError *error = NULL;
    
    // Check if we previously crashed
    if ([crashReporter hasPendingCrashReport]) {
      [self handleCrashReport];
    }
    
    // Enable the Crash Reporter
    if (![crashReporter enableCrashReporterAndReturnError: &error])
      NSLog(@"Warning: Could not enable crash reporter: %@", error);
    
    if ([_crashFiles count] == 0 && [_fileManager fileExistsAtPath: _crashesDir]) {
      NSString *file = nil;
      NSError *error = NULL;
      
      NSDirectoryEnumerator *dirEnum = [_fileManager enumeratorAtPath: _crashesDir];
      
      while ((file = [dirEnum nextObject])) {
        NSDictionary *fileAttributes = [_fileManager attributesOfItemAtPath:[_crashesDir stringByAppendingPathComponent:file] error:&error];
        if ([[fileAttributes objectForKey:NSFileSize] intValue] > 0 && ![file isEqualToString:@".DS_Store"]) {
          [_crashFiles addObject:[_crashesDir stringByAppendingPathComponent: file]];
        }
      }
    }
    
    if ([_crashFiles count] > 0) {
      return YES;
    } else
      return NO;
  } else {
    BOOL returnValue = NO;
    
    NSString *appVersion = [self loadAppVersion];
    NSDate *lastCrashDate = [self loadLastCrashDate];
    
    if (!appVersion || ![appVersion isEqualToString:[self applicationVersion]] || [lastCrashDate isEqualToDate:[NSDate distantPast]]) {
      [self storeAppVersion:[self applicationVersion]];
      [self storeLastCrashDate:[NSDate date]];
      return NO;
    }
    
    NSArray* libraryDirectories = NSSearchPathForDirectoriesInDomains(NSLibraryDirectory, NSUserDomainMask, TRUE);
    // Snow Leopard is having the log files in another location
    [self searchCrashLogFile:[[libraryDirectories lastObject] stringByAppendingPathComponent:@"Logs/DiagnosticReports"]];
    if (_crashFile == nil) {
      [self searchCrashLogFile:[[libraryDirectories lastObject] stringByAppendingPathComponent:@"Logs/CrashReporter"]];
      if (_crashFile == nil) {
        NSString *sandboxFolder = [NSString stringWithFormat:@"/Containers/%@/Data/Library", [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleIdentifier"]];
        if ([[libraryDirectories lastObject] rangeOfString:sandboxFolder].location != NSNotFound) {
          NSString *libFolderName = [[libraryDirectories lastObject] stringByReplacingOccurrencesOfString:sandboxFolder withString:@""];
          [self searchCrashLogFile:[libFolderName stringByAppendingPathComponent:@"Logs/DiagnosticReports"]];
        }
      }
    }
    
    if (_crashFile) {
      NSError* error;
      
      NSDate *crashLogModificationDate = [[_fileManager attributesOfItemAtPath:_crashFile error:&error] fileModificationDate];
      unsigned long long crashLogFileSize = [[_fileManager attributesOfItemAtPath:_crashFile error:&error] fileSize];
      if ([crashLogModificationDate compare: lastCrashDate] == NSOrderedDescending && crashLogFileSize > 0) {
        [self storeLastCrashDate:crashLogModificationDate];
        returnValue = YES;
      }
    }
    
    return returnValue;
  }
}


#pragma mark - CNSCrashReportManagerDelegate

- (void) cancelReport {
  [self _cleanCrashReports];
  [self returnToMainApplication];
}


- (void) sendReportCrash:(NSString*)crashReport crashNotes:(NSString *)crashNotes {
  NSString *userid = @"";
  NSString *contact = @"";
  
  if ([self delegate] != nil && [[self delegate] respondsToSelector:@selector(crashReportUserID)]) {
    userid = [[self delegate] crashReportUserID] ?: @"";
  }
  
  if ([self delegate] != nil && [[self delegate] respondsToSelector:@selector(crashReportContact)]) {
    contact = [[self delegate] crashReportContact] ?: @"";
  }
  
  SInt32 versionMajor, versionMinor, versionBugFix;
  if (Gestalt(gestaltSystemVersionMajor, &versionMajor) != noErr) versionMajor = 0;
  if (Gestalt(gestaltSystemVersionMinor, &versionMinor) != noErr)  versionMinor= 0;
  if (Gestalt(gestaltSystemVersionBugFix, &versionBugFix) != noErr) versionBugFix = 0;
  
  NSString* xml = [NSString stringWithFormat:@"<crash><applicationname>%s</applicationname><bundleidentifier>%s</bundleidentifier><systemversion>%@</systemversion><senderversion>%@</senderversion><version>%@</version><platform>%@</platform><userid>%@</userid><contact>%@</contact><description><![CDATA[%@]]></description><log><![CDATA[%@]]></log></crash>",
                   [[self applicationName] UTF8String],
                   [[[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleIdentifier"] UTF8String],
                   [NSString stringWithFormat:@"%i.%i.%i", versionMajor, versionMinor, versionBugFix],
                   [self applicationVersion],
                   [self applicationVersion],
                   [self modelVersion],
                   userid,
                   contact,
                   crashNotes,
                   crashReport
                   ];

    
  [self returnToMainApplication];
  
  [self _postXML:[NSString stringWithFormat:@"<crashes>%@</crashes>", xml]];
}


#pragma mark - Networking

- (void)_postXML:(NSString*)xml {
  NSMutableURLRequest *request = nil;
  NSString *boundary = @"----FOO";
  
  request = [NSMutableURLRequest requestWithURL:
             [NSURL URLWithString:[NSString stringWithFormat:@"%@api/2/apps/%@/crashes?sdk=%@&sdk_version=%@",
                                   _submissionURL,
                                   [self.appIdentifier stringByAddingPercentEscapesUsingEncoding:NSUTF8StringEncoding],
                                   SDK_NAME,
                                   SDK_VERSION
                                   ]
              ]];
  
  [request setValue:@"Quincy/Mac" forHTTPHeaderField:@"User-Agent"];
  [request setValue:@"gzip" forHTTPHeaderField:@"Accept-Encoding"];
  [request setTimeoutInterval: 15];
  [request setHTTPMethod:@"POST"];
  NSString *contentType = [NSString stringWithFormat:@"multipart/form-data; boundary=%@", boundary];
  [request setValue:contentType forHTTPHeaderField:@"Content-type"];
  
  NSMutableData *postBody =  [NSMutableData data];  
  [postBody appendData:[[NSString stringWithFormat:@"--%@\r\n", boundary] dataUsingEncoding:NSUTF8StringEncoding]];
  if (self.appIdentifier) {
    [postBody appendData:[@"Content-Disposition: form-data; name=\"xml\"; filename=\"crash.xml\"\r\n" dataUsingEncoding:NSUTF8StringEncoding]];
    [postBody appendData:[[NSString stringWithFormat:@"Content-Type: text/xml\r\n\r\n"] dataUsingEncoding:NSUTF8StringEncoding]];
  } else {
    [postBody appendData:[@"Content-Disposition: form-data; name=\"xmlstring\"\r\n\r\n" dataUsingEncoding:NSUTF8StringEncoding]];
  }
  [postBody appendData:[xml dataUsingEncoding:NSUTF8StringEncoding]];
  [postBody appendData:[[NSString stringWithFormat:@"\r\n--%@--\r\n", boundary] dataUsingEncoding:NSUTF8StringEncoding]];
  [request setHTTPBody:postBody];
  
  _serverResult = CrashReportStatusUnknown;
  _statusCode = 200;
  
  NSHTTPURLResponse *response = nil;
  NSError *error = nil;
  
  NSData *responseData = nil;
  responseData = [NSURLConnection sendSynchronousRequest:request returningResponse:&response error:&error];
  _statusCode = [response statusCode];
  
  if (_statusCode >= 200 && _statusCode < 400 && responseData != nil && [responseData length] > 0) {
    [self _cleanCrashReports];

    NSXMLParser *parser = [[NSXMLParser alloc] initWithData:responseData];
    // Set self as the delegate of the parser so that it will receive the parser delegate methods callbacks.
    [parser setDelegate:self];
    // Depending on the XML document you're parsing, you may want to enable these features of NSXMLParser.
    [parser setShouldProcessNamespaces:NO];
    [parser setShouldReportNamespacePrefixes:NO];
    [parser setShouldResolveExternalEntities:NO];
    
    [parser parse];
    
    [parser release];
  }
}


#pragma mark - NSXMLParser

- (void)parser:(NSXMLParser *)parser didStartElement:(NSString *)elementName namespaceURI:(NSString *)namespaceURI qualifiedName:(NSString *)qName attributes:(NSDictionary *)attributeDict {
  if (qName) {
    elementName = qName;
  }
  
  if ([elementName isEqualToString:@"result"]) {
    _contentOfProperty = [NSMutableString string];
  }
}

- (void)parser:(NSXMLParser *)parser didEndElement:(NSString *)elementName namespaceURI:(NSString *)namespaceURI qualifiedName:(NSString *)qName {
  if (qName) {
    elementName = qName;
  }
  
  if ([elementName isEqualToString:@"result"]) {
    if ([_contentOfProperty intValue] > _serverResult) {
      _serverResult = [_contentOfProperty intValue];
    }
  }
}


- (void)parser:(NSXMLParser *)parser foundCharacters:(NSString *)string {
  if (_contentOfProperty) {
    // If the current element is one whose content we care about, append 'string'
    // to the property that holds the content of the current element.
    if (string != nil) {
      [_contentOfProperty appendString:string];
    }
  }
}


#pragma mark - GetterSetter

- (NSString *) applicationName {
  NSString *applicationName = [[[NSBundle mainBundle] localizedInfoDictionary] valueForKey: @"CFBundleExecutable"];
  
  if (!applicationName)
    applicationName = [[[NSBundle mainBundle] infoDictionary] valueForKey: @"CFBundleExecutable"];
  
  return applicationName;
}


- (NSString*) applicationVersionString {
  NSString* string = [[[NSBundle mainBundle] localizedInfoDictionary] valueForKey: @"CFBundleShortVersionString"];
  
  if (!string)
    string = [[[NSBundle mainBundle] infoDictionary] valueForKey: @"CFBundleShortVersionString"];
  
  return string;
}

- (NSString *) applicationVersion {
  NSString* string = [[[NSBundle mainBundle] localizedInfoDictionary] valueForKey: @"CFBundleVersion"];
  
  if (!string)
    string = [[[NSBundle mainBundle] infoDictionary] valueForKey: @"CFBundleVersion"];
  
  return string;
}


#pragma mark - PLCrashReporter

//
// Called to handle a pending crash report.
//
- (void) handleCrashReport {
  PLCrashReporter *crashReporter = [PLCrashReporter sharedReporter];
  NSError *error = NULL;
	
  // check if the next call ran successfully the last time
  if (_analyzerStarted == 0) {
    // mark the start of the routine
    _analyzerStarted = 1;
    [[NSUserDefaults standardUserDefaults] setValue:[NSNumber numberWithInt:_analyzerStarted] forKey:kHockeySDKAnalyzerStarted];
    [[NSUserDefaults standardUserDefaults] synchronize];
    
    // Try loading the crash report
    NSData *crashData = [[NSData alloc] initWithData:[crashReporter loadPendingCrashReportDataAndReturnError: &error]];
    
    NSString *cacheFilename = [NSString stringWithFormat: @"%.0f", [NSDate timeIntervalSinceReferenceDate]];
    
    if (crashData == nil) {
      NSLog(@"Could not load crash report: %@", error);
    } else {
      [crashData writeToFile:[_crashesDir stringByAppendingPathComponent: cacheFilename] atomically:YES];
    }
  }
	
  // Purge the report
  // mark the end of the routine
  _analyzerStarted = 0;
  [[NSUserDefaults standardUserDefaults] setValue:[NSNumber numberWithInt:_analyzerStarted] forKey:kHockeySDKAnalyzerStarted];
  [[NSUserDefaults standardUserDefaults] synchronize];
  
  [crashReporter purgePendingCrashReport];
  return;
}

@end