//
//  SKPSMTPMessage.m
//
//  Created by Ian Baird on 10/28/08.
//
//  Copyright (c) 2008 Skorpiostech, Inc. All rights reserved.
//
//  Permission is hereby granted, free of charge, to any person
//  obtaining a copy of this software and associated documentation
//  files (the "Software"), to deal in the Software without
//  restriction, including without limitation the rights to use,
//  copy, modify, merge, publish, distribute, sublicense, and/or sell
//  copies of the Software, and to permit persons to whom the
//  Software is furnished to do so, subject to the following
//  conditions:
//
//  The above copyright notice and this permission notice shall be
//  included in all copies or substantial portions of the Software.
//
//  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
//  EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES
//  OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
//  NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT
//  HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY,
//  WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
//  FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR
//  OTHER DEALINGS IN THE SOFTWARE.
//

#import <Foundation/Foundation.h>
#import "SKPSMTPMessage.h"
#import "NSData+Base64Additions.h"
#import "NSStream+SKPSMTPExtensions.h"
#import "HSK_CFUtilities.h"

NSString *kSKPSMTPPartContentDispositionKey = @"kSKPSMTPPartContentDispositionKey";
NSString *kSKPSMTPPartContentTypeKey = @"kSKPSMTPPartContentTypeKey";
NSString *kSKPSMTPPartMessageKey = @"kSKPSMTPPartMessageKey";
NSString *kSKPSMTPPartContentTransferEncodingKey = @"kSKPSMTPPartContentTransferEncodingKey";

#define SHORT_LIVENESS_TIMEOUT 20.0
#define LONG_LIVENESS_TIMEOUT 60.0

@interface SKPSMTPMessage ()

@property(nonatomic, retain) NSMutableString *inputString;
@property(retain) NSTimer *connectTimer;
@property(retain) NSTimer *watchdogTimer;

- (void)parseBuffer;
- (BOOL)sendParts;
- (void)cleanUpStreams;
- (void)startShortWatchdog;
- (void)stopWatchdog;
- (NSString *)formatAnAddress:(NSString *)address;
- (NSString *)formatAddresses:(NSString *)addresses;

@end

@implementation SKPSMTPMessage

@synthesize login, pass, relayHost, relayPorts, subject, fromEmail, toEmail, parts, requiresAuth, inputString, wantsSecure, \
            delegate, connectTimer, connectTimeout, watchdogTimer, validateSSLChain;
@synthesize ccEmail;
@synthesize bccEmail;

#pragma mark -
#pragma mark Memory & Lifecycle

- (id)init
{
    static NSArray *defaultPorts = nil;
    
    if (!defaultPorts)
    {
        defaultPorts = [[NSArray alloc] initWithObjects:[NSNumber numberWithShort:25], [NSNumber numberWithShort:465], [NSNumber numberWithShort:587], nil];
    }
    
    if ((self = [super init]))
    {
        // Setup the default ports
        self.relayPorts = defaultPorts;
        
        // setup a default timeout (8 seconds)
        connectTimeout = 8.0; 
        
        // by default, validate the SSL chain
        validateSSLChain = YES;
    }
    
    return self;
}

- (void)dealloc
{
    NSLog(@"dealloc %@", self);
    self.login = nil;
    self.pass = nil;
    self.relayHost = nil;
    self.relayPorts = nil;
    self.subject = nil;
    self.fromEmail = nil;
    self.toEmail = nil;
	self.ccEmail = nil;
	self.bccEmail = nil;
    self.parts = nil;
    self.inputString = nil;
    
    [inputStream release];
    inputStream = nil;
    
    [outputStream release];
    outputStream = nil;
    
    [self.connectTimer invalidate];
    self.connectTimer = nil;
    
    [self stopWatchdog];
    
    [super dealloc];
}

- (id)copyWithZone:(NSZone *)zone
{
    SKPSMTPMessage *smtpMessageCopy = [[[self class] allocWithZone:zone] init];
    smtpMessageCopy.delegate = self.delegate;
    smtpMessageCopy.fromEmail = self.fromEmail;
    smtpMessageCopy.login = self.login;
    smtpMessageCopy.parts = [[self.parts copy] autorelease];
    smtpMessageCopy.pass = self.pass;
    smtpMessageCopy.relayHost = self.relayHost;
    smtpMessageCopy.requiresAuth = self.requiresAuth;
    smtpMessageCopy.subject = self.subject;
    smtpMessageCopy.toEmail = self.toEmail;
    smtpMessageCopy.wantsSecure = self.wantsSecure;
    smtpMessageCopy.validateSSLChain = self.validateSSLChain;
    smtpMessageCopy.ccEmail = self.ccEmail;
    smtpMessageCopy.bccEmail = self.bccEmail;
    
    return smtpMessageCopy;
}

#pragma mark -
#pragma mark Connection Timers

- (void)startShortWatchdog
{
    NSLog(@"*** starting short watchdog ***");
    self.watchdogTimer = [NSTimer scheduledTimerWithTimeInterval:SHORT_LIVENESS_TIMEOUT target:self selector:@selector(connectionWatchdog:) userInfo:nil repeats:NO];
}

- (void)startLongWatchdog
{
    NSLog(@"*** starting long watchdog ***");
    self.watchdogTimer = [NSTimer scheduledTimerWithTimeInterval:LONG_LIVENESS_TIMEOUT target:self selector:@selector(connectionWatchdog:) userInfo:nil repeats:NO];
}

- (void)stopWatchdog
{
    NSLog(@"*** stopping watchdog ***");
    [self.watchdogTimer invalidate];
    self.watchdogTimer = nil;
}


#pragma mark Watchdog Callback

- (void)connectionWatchdog:(NSTimer *)aTimer
{
    [self cleanUpStreams];
    
    // No hard error if we're wating on a reply
    if (sendState != kSKPSMTPWaitingQuitReply)
    {
        NSError *error = [NSError errorWithDomain:@"SKPSMTPMessageError" 
                                             code:kSKPSMPTErrorConnectionTimeout 
                                         userInfo:[NSDictionary dictionaryWithObjectsAndKeys:NSLocalizedString(@"Timeout sending message.", @"server timeout fail error description"),NSLocalizedDescriptionKey,
                                                   NSLocalizedString(@"Try sending your message again later.", @"server generic error recovery"),NSLocalizedRecoverySuggestionErrorKey,nil]];
        [delegate messageFailed:self error:error];
    }
    else
    {
        [delegate messageSent:self];
    }
}

#pragma mark -
#pragma mark Connection Handling

- (BOOL)preflightCheckWithError:(NSError **)error {
    
    CFHostRef host = CFHostCreateWithName(NULL, (CFStringRef)self.relayHost);
    CFStreamError streamError;
    
    if (!CFHostStartInfoResolution(host, kCFHostAddresses, &streamError)) {
        NSString *errorDomainName;
        switch (streamError.domain) {
            case kCFStreamErrorDomainCustom:
                errorDomainName = @"kCFStreamErrorDomainCustom";
                break;
            case kCFStreamErrorDomainPOSIX:
                errorDomainName = @"kCFStreamErrorDomainPOSIX";
                break;
            case kCFStreamErrorDomainMacOSStatus:
                errorDomainName = @"kCFStreamErrorDomainMacOSStatus";
                break;
            default:
                errorDomainName = [NSString stringWithFormat:@"Generic CFStream Error Domain %ld", streamError.domain];
                break;
        }
        if (error)
            *error = [NSError errorWithDomain:errorDomainName
                                         code:streamError.error
                                     userInfo:[NSDictionary dictionaryWithObjectsAndKeys:@"Error resolving address.", NSLocalizedDescriptionKey,
                                               @"Check your SMTP Host name", NSLocalizedRecoverySuggestionErrorKey, nil]];
        CFRelease(host);
        return NO;
    }
    Boolean hasBeenResolved;
    CFHostGetAddressing(host, &hasBeenResolved);
    if (!hasBeenResolved) {
        if(error)
            *error = [NSError errorWithDomain:@"SKPSMTPMessageError" code:kSKPSMTPErrorNonExistentDomain userInfo:
                      [NSDictionary dictionaryWithObjectsAndKeys:@"Error resolving host.", NSLocalizedDescriptionKey,
                       @"Check your SMTP Host name", NSLocalizedRecoverySuggestionErrorKey, nil]];
        CFRelease(host);
        return NO;
    }
    
    CFRelease(host);
    return YES;
}


- (BOOL)send
{
    NSAssert(sendState == kSKPSMTPIdle, @"Message has already been sent!");
    
    if (requiresAuth)
    {
        NSAssert(login, @"auth requires login");
        NSAssert(pass, @"auth requires pass");
    }
    
    NSAssert(relayHost, @"send requires relayHost");
    NSAssert(subject, @"send requires subject");
    NSAssert(fromEmail, @"send requires fromEmail");
    NSAssert(toEmail, @"send requires toEmail");
    NSAssert(parts, @"send requires parts");
    
    NSError *error = nil;
    if (![self preflightCheckWithError:&error]) {
        [delegate messageFailed:self error:error];
        return NO;
    }
    
    if (![relayPorts count])
    {
        dispatch_async(dispatch_get_main_queue(), ^{
            [delegate messageFailed:self 
                              error:[NSError errorWithDomain:@"SKPSMTPMessageError" 
                                                        code:kSKPSMTPErrorConnectionFailed 
                                                    userInfo:[NSDictionary dictionaryWithObjectsAndKeys:NSLocalizedString(@"Unable to connect to the server.", @"server connection fail error description"),NSLocalizedDescriptionKey,
                                                              NSLocalizedString(@"Try sending your message again later.", @"server generic error recovery"),NSLocalizedRecoverySuggestionErrorKey,nil]]];

        });
        
        return NO;
    }
    
    // Grab the next relay port
    short relayPort = [[relayPorts objectAtIndex:0] shortValue];
    
    // Pop this off the head of the queue.
    self.relayPorts = ([relayPorts count] > 1) ? [relayPorts subarrayWithRange:NSMakeRange(1, [relayPorts count] - 1)] : [NSArray array];
    
    NSLog(@"C: Attempting to connect to server at: %@:%d", relayHost, relayPort);
    
    
    self.connectTimer = [NSTimer timerWithTimeInterval:connectTimeout target:self selector:@selector(connectionConnectedCheck:) userInfo:nil repeats:NO];
    [[NSRunLoop mainRunLoop] addTimer:self.connectTimer forMode:NSDefaultRunLoopMode];

    [NSStream getStreamsToHostNamed:relayHost port:relayPort inputStream:&inputStream outputStream:&outputStream];
    if ((inputStream != nil) && (outputStream != nil))
    {
        sendState = kSKPSMTPConnecting;
        isSecure = NO;
        
        [inputStream retain];
        [outputStream retain];
        
        [inputStream setDelegate:self];
        [outputStream setDelegate:self];
        
        [inputStream scheduleInRunLoop:[NSRunLoop mainRunLoop] forMode:NSDefaultRunLoopMode];
        [outputStream scheduleInRunLoop:[NSRunLoop mainRunLoop] forMode:NSDefaultRunLoopMode];
        [inputStream open];
        [outputStream open];
        
        self.inputString = [NSMutableString string];
        
        
        
        return YES;
    }
    else
    {
        [self.connectTimer invalidate];
        self.connectTimer = nil;
        
        [delegate messageFailed:self 
                          error:[NSError errorWithDomain:@"SKPSMTPMessageError" 
                                                    code:kSKPSMTPErrorConnectionFailed 
                                                userInfo:[NSDictionary dictionaryWithObjectsAndKeys:NSLocalizedString(@"Unable to connect to the server.", @"server connection fail error description"),NSLocalizedDescriptionKey,
                                                          NSLocalizedString(@"Try sending your message again later.", @"server generic error recovery"),NSLocalizedRecoverySuggestionErrorKey,nil]]];
        
        return NO;
    }
}

#pragma mark -
#pragma mark <NSStreamDelegate>

- (void)stream:(NSStream *)stream handleEvent:(NSStreamEvent)eventCode 
{
    switch(eventCode) 
    {
        case NSStreamEventHasBytesAvailable:
        {
            uint8_t buf[1024];
            memset(buf, 0, sizeof(uint8_t) * 1024);
            unsigned int len = 0;
            len = [(NSInputStream *)stream read:buf maxLength:1024];
            if(len) 
            {
                NSString *tmpStr = [[NSString alloc] initWithBytes:buf length:len encoding:NSUTF8StringEncoding];
                [inputString appendString:tmpStr];
                [tmpStr release];
                
                [self parseBuffer];
            }
            break;
        }
        case NSStreamEventEndEncountered:
        {
            [self stopWatchdog];
            [stream close];
            [stream removeFromRunLoop:[NSRunLoop currentRunLoop]
                              forMode:NSDefaultRunLoopMode];
            [stream release];
            stream = nil; // stream is ivar, so reinit it
            
            if (sendState != kSKPSMTPMessageSent)
            {
                [delegate messageFailed:self 
                                  error:[NSError errorWithDomain:@"SKPSMTPMessageError" 
                                                            code:kSKPSMTPErrorConnectionInterrupted 
                                                        userInfo:[NSDictionary dictionaryWithObjectsAndKeys:NSLocalizedString(@"The connection to the server was interrupted.", @"server connection interrupted error description"),NSLocalizedDescriptionKey,
                                                                  NSLocalizedString(@"Try sending your message again later.", @"server generic error recovery"),NSLocalizedRecoverySuggestionErrorKey,nil]]];

            }
            
            break;
        }
    }
}
            

- (NSString *)formatAnAddress:(NSString *)address {
	NSString		*formattedAddress;
	NSCharacterSet	*whitespaceCharSet = [NSCharacterSet whitespaceCharacterSet];

	if (([address rangeOfString:@"<"].location == NSNotFound) && ([address rangeOfString:@">"].location == NSNotFound)) {
		formattedAddress = [NSString stringWithFormat:@"RCPT TO:<%@>\r\n", [address stringByTrimmingCharactersInSet:whitespaceCharSet]];									
	}
	else {
		formattedAddress = [NSString stringWithFormat:@"RCPT TO:%@\r\n", [address stringByTrimmingCharactersInSet:whitespaceCharSet]];																		
	}
	
	return(formattedAddress);
}

- (NSString *)formatAddresses:(NSString *)addresses {
	NSCharacterSet	*splitSet = [NSCharacterSet characterSetWithCharactersInString:@";,"];
	NSMutableString	*multipleRcptTo = [NSMutableString string];
	
	if ((addresses != nil) && (![addresses isEqualToString:@""])) {
		if( [addresses rangeOfString:@";"].location != NSNotFound || [addresses rangeOfString:@","].location != NSNotFound ) {
			NSArray *addressParts = [addresses componentsSeparatedByCharactersInSet:splitSet];
						
			for( NSString *address in addressParts ) {
				[multipleRcptTo appendString:[self formatAnAddress:address]];
			}
		}
		else {
			[multipleRcptTo appendString:[self formatAnAddress:addresses]];
		}		
	}
	
	return(multipleRcptTo);
}

            
- (void)parseBuffer
{
    // Pull out the next line
    NSScanner *scanner = [NSScanner scannerWithString:inputString];
    NSString *tmpLine = nil;
    
    NSError *error = nil;
    BOOL encounteredError = NO;
    BOOL messageSent = NO;
    
    while (![scanner isAtEnd])
    {
        BOOL foundLine = [scanner scanUpToCharactersFromSet:[NSCharacterSet newlineCharacterSet]
                                                 intoString:&tmpLine];
        if (foundLine)
        {
            [self stopWatchdog];
            
            NSLog(@"S: %@", tmpLine);
            switch (sendState)
            {
                case kSKPSMTPConnecting:
                {
                    if ([tmpLine hasPrefix:@"220 "])
                    {
                        
                        sendState = kSKPSMTPWaitingEHLOReply;
                        
                        NSString *ehlo = [NSString stringWithFormat:@"EHLO %@\r\n", @"localhost"];
                        NSLog(@"C: %@", ehlo);
                        if (CFWriteStreamWriteFully((CFWriteStreamRef)outputStream, (const uint8_t *)[ehlo UTF8String], [ehlo lengthOfBytesUsingEncoding:NSUTF8StringEncoding]) < 0)
                        {
                            error =  [outputStream streamError];
                            encounteredError = YES;
                        }
                        else
                        {
                            [self startShortWatchdog];
                        }
                    }
                    break;
                }
                case kSKPSMTPWaitingEHLOReply:
                {
                    // Test auth login options
                    if ([tmpLine hasPrefix:@"250-AUTH"])
                    {
                        NSRange testRange;
                        testRange = [tmpLine rangeOfString:@"CRAM-MD5"];
                        if (testRange.location != NSNotFound)
                        {
                            serverAuthCRAMMD5 = YES;
                        }
                        
                        testRange = [tmpLine rangeOfString:@"PLAIN"];
                        if (testRange.location != NSNotFound)
                        {
                            serverAuthPLAIN = YES;
                        }
                        
                        testRange = [tmpLine rangeOfString:@"LOGIN"];
                        if (testRange.location != NSNotFound)
                        {
                            serverAuthLOGIN = YES;
                        }
                        
                        testRange = [tmpLine rangeOfString:@"DIGEST-MD5"];
                        if (testRange.location != NSNotFound)
                        {
                            serverAuthDIGESTMD5 = YES;
                        }
                    }
                    else if ([tmpLine hasPrefix:@"250-8BITMIME"])
                    {
                        server8bitMessages = YES;
                    }
                    else if ([tmpLine hasPrefix:@"250-STARTTLS"] && !isSecure && wantsSecure)
                    {
                        // if we're not already using TLS, start it up
                        sendState = kSKPSMTPWaitingTLSReply;
                        
                        NSString *startTLS = @"STARTTLS\r\n";
                        NSLog(@"C: %@", startTLS);
                        if (CFWriteStreamWriteFully((CFWriteStreamRef)outputStream, (const uint8_t *)[startTLS UTF8String], [startTLS lengthOfBytesUsingEncoding:NSUTF8StringEncoding]) < 0)
                        {
                            error =  [outputStream streamError];
                            encounteredError = YES;
                        }
                        else
                        {
                            [self startShortWatchdog];
                        }
                    }
                    else if ([tmpLine hasPrefix:@"250 "])
                    {
                        if (self.requiresAuth)
                        {
                            // Start up auth
                            if (serverAuthPLAIN)
                            {
                                sendState = kSKPSMTPWaitingAuthSuccess;
                                NSString *loginString = [NSString stringWithFormat:@"\000%@\000%@", login, pass];
                                NSString *authString = [NSString stringWithFormat:@"AUTH PLAIN %@\r\n", [[loginString dataUsingEncoding:NSUTF8StringEncoding] encodeBase64ForData]];
                                NSLog(@"C: %@", authString);
                                if (CFWriteStreamWriteFully((CFWriteStreamRef)outputStream, (const uint8_t *)[authString UTF8String], [authString lengthOfBytesUsingEncoding:NSUTF8StringEncoding]) < 0)
                                {
                                    error =  [outputStream streamError];
                                    encounteredError = YES;
                                }
                                else
                                {
                                    [self startShortWatchdog];
                                }
                            }
                            else if (serverAuthLOGIN)
                            {
                                sendState = kSKPSMTPWaitingLOGINUsernameReply;
                                NSString *authString = @"AUTH LOGIN\r\n";
                                NSLog(@"C: %@", authString);
                                if (CFWriteStreamWriteFully((CFWriteStreamRef)outputStream, (const uint8_t *)[authString UTF8String], [authString lengthOfBytesUsingEncoding:NSUTF8StringEncoding]) < 0)
                                {
                                    error =  [outputStream streamError];
                                    encounteredError = YES;
                                }
                                else
                                {
                                    [self startShortWatchdog];
                                }
                            }
                            else
                            {
                                error = [NSError errorWithDomain:@"SKPSMTPMessageError" 
                                                            code:kSKPSMTPErrorUnsupportedLogin
                                                        userInfo:[NSDictionary dictionaryWithObjectsAndKeys:NSLocalizedString(@"Unsupported login mechanism.", @"server unsupported login fail error description"),NSLocalizedDescriptionKey,
                                                                  NSLocalizedString(@"Your server's security setup is not supported, please contact your system administrator or use a supported email account like MobileMe.", @"server security fail error recovery"),NSLocalizedRecoverySuggestionErrorKey,nil]];
                                         
                                encounteredError = YES;
                            }
                                
                        }
                        else
                        {
                            // Start up send from
                            sendState = kSKPSMTPWaitingFromReply;
                            
                            NSString *mailFrom = [NSString stringWithFormat:@"MAIL FROM:<%@>\r\n", fromEmail];
                            NSLog(@"C: %@", mailFrom);
                            if (CFWriteStreamWriteFully((CFWriteStreamRef)outputStream, (const uint8_t *)[mailFrom UTF8String], [mailFrom lengthOfBytesUsingEncoding:NSUTF8StringEncoding]) < 0)
                            {
                                error =  [outputStream streamError];
                                encounteredError = YES;
                            }
                            else
                            {
                                [self startShortWatchdog];
                            }
                        }
                    }
                    break;
                }
                    
                case kSKPSMTPWaitingTLSReply:
                {
                    if ([tmpLine hasPrefix:@"220 "])
                    {
                        
                        // Attempt to use TLSv1
                        CFMutableDictionaryRef sslOptions = CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
                        
                        CFDictionarySetValue(sslOptions, kCFStreamSSLLevel, kCFStreamSocketSecurityLevelTLSv1);
                        
                        if (!self.validateSSLChain)
                        {
                            // Don't validate SSL certs. This is terrible, please complain loudly to your BOFH.
                            NSLog(@"WARNING: Will not validate SSL chain!!!");
                            
                            CFDictionarySetValue(sslOptions, kCFStreamSSLValidatesCertificateChain, kCFBooleanFalse);
                            CFDictionarySetValue(sslOptions, kCFStreamSSLAllowsExpiredCertificates, kCFBooleanTrue);
                            CFDictionarySetValue(sslOptions, kCFStreamSSLAllowsExpiredRoots, kCFBooleanTrue);
                            CFDictionarySetValue(sslOptions, kCFStreamSSLAllowsAnyRoot, kCFBooleanTrue);
                        }
                        
                        NSLog(@"Beginning TLSv1...");
                        
                        CFReadStreamSetProperty((CFReadStreamRef)inputStream, kCFStreamPropertySSLSettings, sslOptions);
                        CFWriteStreamSetProperty((CFWriteStreamRef)outputStream, kCFStreamPropertySSLSettings, sslOptions);
                        
                        CFRelease(sslOptions);
                        
                        // restart the connection
                        sendState = kSKPSMTPWaitingEHLOReply;
                        isSecure = YES;
                        
                        NSString *ehlo = [NSString stringWithFormat:@"EHLO %@\r\n", @"localhost"];
                        NSLog(@"C: %@", ehlo);
                        
                        if (CFWriteStreamWriteFully((CFWriteStreamRef)outputStream, (const uint8_t *)[ehlo UTF8String], [ehlo lengthOfBytesUsingEncoding:NSUTF8StringEncoding]) < 0)
                        {
                            error =  [outputStream streamError];
                            encounteredError = YES;
                        }
                        else
                        {
                            [self startShortWatchdog];
                        }
                        
                        /*
                        else
                        {
                            error = [NSError errorWithDomain:@"SKPSMTPMessageError" 
                                                        code:kSKPSMTPErrorTLSFail
                                                    userInfo:[NSDictionary dictionaryWithObject:@"Unable to start TLS" 
                                                                                         forKey:NSLocalizedDescriptionKey]];
                            encounteredError = YES;
                        }
                        */
                    }
                }
                
                case kSKPSMTPWaitingLOGINUsernameReply:
                {
                    if ([tmpLine hasPrefix:@"334 VXNlcm5hbWU6"])
                    {
                        sendState = kSKPSMTPWaitingLOGINPasswordReply;
                        
                        NSString *authString = [NSString stringWithFormat:@"%@\r\n", [[login dataUsingEncoding:NSUTF8StringEncoding] encodeBase64ForData]];
                        NSLog(@"C: %@", authString);
                        if (CFWriteStreamWriteFully((CFWriteStreamRef)outputStream, (const uint8_t *)[authString UTF8String], [authString lengthOfBytesUsingEncoding:NSUTF8StringEncoding]) < 0)
                        {
                            error =  [outputStream streamError];
                            encounteredError = YES;
                        }
                        else
                        {
                            [self startShortWatchdog];
                        }
                    }
                    break;
                }
                    
                case kSKPSMTPWaitingLOGINPasswordReply:
                {
                    if ([tmpLine hasPrefix:@"334 UGFzc3dvcmQ6"])
                    {
                        sendState = kSKPSMTPWaitingAuthSuccess;
                        
                        NSString *authString = [NSString stringWithFormat:@"%@\r\n", [[pass dataUsingEncoding:NSUTF8StringEncoding] encodeBase64ForData]];
                        NSLog(@"C: %@", authString);
                        if (CFWriteStreamWriteFully((CFWriteStreamRef)outputStream, (const uint8_t *)[authString UTF8String], [authString lengthOfBytesUsingEncoding:NSUTF8StringEncoding]) < 0)
                        {
                            error =  [outputStream streamError];
                            encounteredError = YES;
                        }
                        else
                        {
                            [self startShortWatchdog];
                        }
                    }
                    break;
                }
                
                case kSKPSMTPWaitingAuthSuccess:
                {
                    if ([tmpLine hasPrefix:@"235 "])
                    {
                        sendState = kSKPSMTPWaitingFromReply;
                        
                        NSString *mailFrom = server8bitMessages ? [NSString stringWithFormat:@"MAIL FROM:<%@> BODY=8BITMIME\r\n", fromEmail] : [NSString stringWithFormat:@"MAIL FROM:<%@>\r\n", fromEmail];
                        NSLog(@"C: %@", mailFrom);
                        if (CFWriteStreamWriteFully((CFWriteStreamRef)outputStream, (const uint8_t *)[mailFrom cStringUsingEncoding:NSASCIIStringEncoding], [mailFrom lengthOfBytesUsingEncoding:NSASCIIStringEncoding]) < 0)
                        {
                            error =  [outputStream streamError];
                            encounteredError = YES;
                        }
                        else
                        {
                            [self startShortWatchdog];
                        }
                    }
                    else if ([tmpLine hasPrefix:@"535 "])
                    {
                        error =[NSError errorWithDomain:@"SKPSMTPMessageError" 
                                                   code:kSKPSMTPErrorInvalidUserPass 
                                               userInfo:[NSDictionary dictionaryWithObjectsAndKeys:NSLocalizedString(@"Invalid username or password.", @"server login fail error description"),NSLocalizedDescriptionKey,
                                                         NSLocalizedString(@"Go to Email Preferences in the application and re-enter your username and password.", @"server login error recovery"),NSLocalizedRecoverySuggestionErrorKey,nil]];
                        encounteredError = YES;
                    }
                    break;
                }
                
                case kSKPSMTPWaitingFromReply:
                {
					// toc 2009-02-18 begin changes per mdesaro issue 18 - http://code.google.com/p/skpsmtpmessage/issues/detail?id=18
					// toc 2009-02-18 begin changes to support cc & bcc
					
                    if ([tmpLine hasPrefix:@"250 "]) {
                        sendState = kSKPSMTPWaitingToReply;
                        
						NSMutableString	*multipleRcptTo = [NSMutableString string];
						[multipleRcptTo appendString:[self formatAddresses:toEmail]];
						[multipleRcptTo appendString:[self formatAddresses:ccEmail]];
						[multipleRcptTo appendString:[self formatAddresses:bccEmail]];
																		
                        NSLog(@"C: %@", multipleRcptTo);
                        if (CFWriteStreamWriteFully((CFWriteStreamRef)outputStream, (const uint8_t *)[multipleRcptTo UTF8String], [multipleRcptTo lengthOfBytesUsingEncoding:NSUTF8StringEncoding]) < 0)
                        {
                            error =  [outputStream streamError];
                            encounteredError = YES;
                        }
                        else
                        {
                            [self startShortWatchdog];
                        }
                    }
                    break;
                }
                case kSKPSMTPWaitingToReply:
                {
                    if ([tmpLine hasPrefix:@"250 "])
                    {
                        sendState = kSKPSMTPWaitingForEnterMail;
                        
                        NSString *dataString = @"DATA\r\n";
                        NSLog(@"C: %@", dataString);
                        if (CFWriteStreamWriteFully((CFWriteStreamRef)outputStream, (const uint8_t *)[dataString UTF8String], [dataString lengthOfBytesUsingEncoding:NSUTF8StringEncoding]) < 0)
                        {
                            error =  [outputStream streamError];
                            encounteredError = YES;
                        }
                        else
                        {
                            [self startShortWatchdog];
                        }
                    }
                    else if ([tmpLine hasPrefix:@"530 "])
                    {
                        error =[NSError errorWithDomain:@"SKPSMTPMessageError" 
                                                   code:kSKPSMTPErrorNoRelay 
                                               userInfo:[NSDictionary dictionaryWithObjectsAndKeys:NSLocalizedString(@"Relay rejected.", @"server relay fail error description"),NSLocalizedDescriptionKey,
                                                        NSLocalizedString(@"Your server probably requires a username and password.", @"server relay fail error recovery"),NSLocalizedRecoverySuggestionErrorKey,nil]];
                        encounteredError = YES;
                    }
                    else if ([tmpLine hasPrefix:@"550 "])
                    {
                        error =[NSError errorWithDomain:@"SKPSMTPMessageError" 
                                                   code:kSKPSMTPErrorInvalidMessage 
                                               userInfo:[NSDictionary dictionaryWithObjectsAndKeys:NSLocalizedString(@"To address rejected.", @"server to address fail error description"),NSLocalizedDescriptionKey,
                                                         NSLocalizedString(@"Please re-enter the To: address.", @"server to address fail error recovery"),NSLocalizedRecoverySuggestionErrorKey,nil]];
                        encounteredError = YES;
                    }
                    break;
                }
                case kSKPSMTPWaitingForEnterMail:
                {
                    if ([tmpLine hasPrefix:@"354 "])
                    {
                        sendState = kSKPSMTPWaitingSendSuccess;
                        
                        if (![self sendParts])
                        {
                            error =  [outputStream streamError];
                            encounteredError = YES;
                        }
                    }
                    break;
                }
                case kSKPSMTPWaitingSendSuccess:
                {
                    if ([tmpLine hasPrefix:@"250 "])
                    {
                        sendState = kSKPSMTPWaitingQuitReply;
                        
                        NSString *quitString = @"QUIT\r\n";
                        NSLog(@"C: %@", quitString);
                        if (CFWriteStreamWriteFully((CFWriteStreamRef)outputStream, (const uint8_t *)[quitString UTF8String], [quitString lengthOfBytesUsingEncoding:NSUTF8StringEncoding]) < 0)
                        {
                            error =  [outputStream streamError];
                            encounteredError = YES;
                        }
                        else
                        {
                            [self startShortWatchdog];
                        }
                    }
                    else if ([tmpLine hasPrefix:@"550 "])
                    {
                        error =[NSError errorWithDomain:@"SKPSMTPMessageError" 
                                                   code:kSKPSMTPErrorInvalidMessage 
                                               userInfo:[NSDictionary dictionaryWithObjectsAndKeys:NSLocalizedString(@"Failed to logout.", @"server logout fail error description"),NSLocalizedDescriptionKey,
                                                         NSLocalizedString(@"Try sending your message again later.", @"server generic error recovery"),NSLocalizedRecoverySuggestionErrorKey,nil]];
                        encounteredError = YES;
                    }
                }
                case kSKPSMTPWaitingQuitReply:
                {
                    if ([tmpLine hasPrefix:@"221 "])
                    {
                        sendState = kSKPSMTPMessageSent;
                        
                        messageSent = YES;
                    }
                }
            }
            
        }
        else
        {
            break;
        }
    }
    self.inputString = [[[inputString substringFromIndex:[scanner scanLocation]] mutableCopy] autorelease];
    
    if (messageSent)
    {
        [self cleanUpStreams];
        
        [delegate messageSent:self];
    }
    else if (encounteredError)
    {
        [self cleanUpStreams];
        
        [delegate messageFailed:self error:error];
    }
}

- (BOOL)sendParts
{
    NSMutableString *message = [[NSMutableString alloc] init];
    static NSString *separatorString = @"--SKPSMTPMessage--Separator--Delimiter\r\n";
    
	CFUUIDRef	uuidRef   = CFUUIDCreate(kCFAllocatorDefault);
	NSString	*uuid     = (NSString *)CFUUIDCreateString(kCFAllocatorDefault, uuidRef);
	CFRelease(uuidRef);
    
    NSDate *now = [[NSDate alloc] init];
	NSDateFormatter	*dateFormatter = [[NSDateFormatter alloc] init];
	
	[dateFormatter setDateFormat:@"EEE, dd MMM yyyy HH:mm:ss Z"];
	
	[message appendFormat:@"Date: %@\r\n", [dateFormatter stringFromDate:now]];
	[message appendFormat:@"Message-id: <%@@%@>\r\n", [(NSString *)uuid stringByReplacingOccurrencesOfString:@"-" withString:@""], self.relayHost];
	
    [now release];
    [dateFormatter release];
    [uuid release];
    
    [message appendFormat:@"From:%@\r\n", fromEmail];
	
    
	if ((self.toEmail != nil) && (![self.toEmail isEqualToString:@""])) 
    {
		[message appendFormat:@"To:%@\r\n", self.toEmail];		
	}

	if ((self.ccEmail != nil) && (![self.ccEmail isEqualToString:@""])) 
    {
		[message appendFormat:@"Cc:%@\r\n", self.ccEmail];		
	}
    
    [message appendString:@"Content-Type: multipart/mixed; boundary=SKPSMTPMessage--Separator--Delimiter\r\n"];
    [message appendString:@"Mime-Version: 1.0 (SKPSMTPMessage 1.0)\r\n"];
    [message appendFormat:@"Subject:%@\r\n\r\n",subject];
    [message appendString:separatorString];
    
    NSData *messageData = [message dataUsingEncoding:NSUTF8StringEncoding allowLossyConversion:YES];
    [message release];
    
    NSLog(@"C: %s", [messageData bytes]);
    if (CFWriteStreamWriteFully((CFWriteStreamRef)outputStream, (const uint8_t *)[messageData bytes], [messageData length]) < 0)
    {
        return NO;
    }
    
    message = [[NSMutableString alloc] init];
    
    for (NSDictionary *part in parts)
    {
        if ([part objectForKey:kSKPSMTPPartContentDispositionKey])
        {
            [message appendFormat:@"Content-Disposition: %@\r\n", [part objectForKey:kSKPSMTPPartContentDispositionKey]];
        }
        [message appendFormat:@"Content-Type: %@\r\n", [part objectForKey:kSKPSMTPPartContentTypeKey]];
        [message appendFormat:@"Content-Transfer-Encoding: %@\r\n\r\n", [part objectForKey:kSKPSMTPPartContentTransferEncodingKey]];
        [message appendString:[part objectForKey:kSKPSMTPPartMessageKey]];
        [message appendString:@"\r\n"];
        [message appendString:separatorString];
    }
    
    [message appendString:@"\r\n.\r\n"];
    
    NSLog(@"C: %@", message);
    if (CFWriteStreamWriteFully((CFWriteStreamRef)outputStream, (const uint8_t *)[message UTF8String], [message lengthOfBytesUsingEncoding:NSUTF8StringEncoding]) < 0)
    {
        [message release];
        return NO;
    }
    [self startLongWatchdog];
    [message release];
    return YES;
}

- (void)connectionConnectedCheck:(NSTimer *)aTimer
{
    if (sendState == kSKPSMTPConnecting)
    {
        [inputStream close];
        [inputStream removeFromRunLoop:[NSRunLoop currentRunLoop]
                               forMode:NSDefaultRunLoopMode];
        [inputStream release];
        inputStream = nil;
        
        [outputStream close];
        [outputStream removeFromRunLoop:[NSRunLoop currentRunLoop]
                                forMode:NSDefaultRunLoopMode];
        [outputStream release];
        outputStream = nil;
        
        // Try the next port - if we don't have another one to try, this will fail
        sendState = kSKPSMTPIdle;
        [self send];
    }
    
    self.connectTimer = nil;
}


- (void)cleanUpStreams
{
    [inputStream close];
    [inputStream removeFromRunLoop:[NSRunLoop currentRunLoop]
                           forMode:NSDefaultRunLoopMode];
    [inputStream release];
    inputStream = nil;
    
    [outputStream close];
    [outputStream removeFromRunLoop:[NSRunLoop currentRunLoop]
                            forMode:NSDefaultRunLoopMode];
    [outputStream release];
    outputStream = nil;
}

@end
