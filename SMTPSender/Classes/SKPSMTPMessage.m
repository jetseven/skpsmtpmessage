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

#import "SKPSMTPMessage.h"
#import "NSData+Base64Additions.h"
#import "NSStream+SKPSMTPExtensions.h"

NSString *kSKPSMTPPartContentDispositionKey = @"kSKPSMTPPartContentDispositionKey";
NSString *kSKPSMTPPartContentTypeKey = @"kSKPSMTPPartContentTypeKey";
NSString *kSKPSMTPPartMessageKey = @"kSKPSMTPPartMessageKey";
NSString *kSKPSMTPPartContentTransferEncodingKey = @"kSKPSMTPPartContentTransferEncodingKey";

@interface SKPSMTPMessage ()

@property(nonatomic, retain) NSMutableString *inputString;
@property(nonatomic, retain) NSTimer *connectTimer;

- (void)parseBuffer;
- (void)sendParts;

@end

@implementation SKPSMTPMessage

@synthesize login, pass, relayHost, relayPort, subject, fromEmail, toEmail, parts, requiresAuth, inputString, wantsSecure, delegate, connectTimer;

- (void)dealloc
{
    self.login = nil;
    self.pass = nil;
    self.relayHost = nil;
    self.subject = nil;
    self.fromEmail = nil;
    self.toEmail = nil;
    self.parts = nil;
    self.inputString = nil;
    
    [inputStream release];
    inputStream = nil;
    
    [outputStream release];
    outputStream = nil;
    
    [self.connectTimer invalidate];
    self.connectTimer = nil;
    
    [super dealloc];
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
    
    
    
    [NSStream getStreamsToHostNamed:relayHost port:relayPort inputStream:&inputStream outputStream:&outputStream];
    if ((inputStream != nil) && (outputStream != nil))
    {
        sendState = kSKPSMTPConnecting;
        isSecure = NO;
        
        [inputStream retain];
        [outputStream retain];
        
        [inputStream setDelegate:self];
        [outputStream setDelegate:self];
        
        [inputStream scheduleInRunLoop:[NSRunLoop currentRunLoop]
                               forMode:NSDefaultRunLoopMode];
        [outputStream scheduleInRunLoop:[NSRunLoop currentRunLoop]
                                forMode:NSDefaultRunLoopMode];
        [inputStream open];
        [outputStream open];
        
        self.inputString = [NSMutableString string];
        
        self.connectTimer = [NSTimer scheduledTimerWithTimeInterval:20.0
                                                             target:self
                                                           selector:@selector(connectionLivenessCheck:)
                                                           userInfo:nil 
                                                            repeats:NO];
        
        return YES;
    }
    else
    {
        [delegate messageFailed:self 
                          error:[NSError errorWithDomain:@"SKPSMTPMessageError" 
                                                    code:kSKPSMTPErrorConnectionFailed 
                                                userInfo:[NSDictionary dictionaryWithObject:@"unable to connect to server" 
                                                                                     forKey:NSLocalizedDescriptionKey]]];
        
        return NO;
    }
}

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
                // NSLog(@"Got bytes: %s", buf);
                NSString *tmpStr = [[NSString alloc] initWithBytes:buf length:len encoding:NSUTF8StringEncoding];
                [inputString appendString:tmpStr];
                [tmpStr release];
                
                [self parseBuffer];
            }
            else
            {
                NSLog(@"No buffer!");
            }
            break;
        }
        case NSStreamEventEndEncountered:
        {
            [stream close];
            [stream removeFromRunLoop:[NSRunLoop currentRunLoop]
                              forMode:NSDefaultRunLoopMode];
            [stream release];
            stream = nil; // stream is ivar, so reinit it
            
            if (sendState != kSKPSMTPMessageSent)
            {
                // TODO: Notify the delegate that there was an error encountered in sending the message
                [delegate messageFailed:self 
                                  error:[NSError errorWithDomain:@"SKPSMTPMessageError" 
                                                            code:kSKPSMTPErrorConnectionInterrupted 
                                                        userInfo:[NSDictionary dictionaryWithObject:@"connection was interrupted" 
                                                                                             forKey:NSLocalizedDescriptionKey]]];
            }
            
            break;
        }
    }
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
                        [outputStream write:(const uint8_t *)[ehlo UTF8String] maxLength:[ehlo lengthOfBytesUsingEncoding:NSUTF8StringEncoding]];
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
                        [outputStream write:(const uint8_t *)[startTLS UTF8String] maxLength:[startTLS lengthOfBytesUsingEncoding:NSUTF8StringEncoding]];
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
                                [outputStream write:(const uint8_t *)[authString UTF8String] maxLength:[authString lengthOfBytesUsingEncoding:NSUTF8StringEncoding]];
                            }
                            else if (serverAuthLOGIN)
                            {
                                sendState = kSKPSMTPWaitingLOGINUsernameReply;
                                NSString *authString = @"AUTH LOGIN\r\n";
                                NSLog(@"C: %@", authString);
                                [outputStream write:(const uint8_t *)[authString UTF8String] maxLength:[authString lengthOfBytesUsingEncoding:NSUTF8StringEncoding]];
                            }
                            else
                            {
                                error = [NSError errorWithDomain:@"SKPSMTPMessageError" 
                                                            code:kSKPSMTPErrorUnsupportedLogin
                                                        userInfo:[NSDictionary dictionaryWithObject:@"unsupported login mechanism" 
                                                                                             forKey:NSLocalizedDescriptionKey]];
                                encounteredError = YES;
                            }
                                
                        }
                        else
                        {
                            // Start up send from
                            sendState = kSKPSMTPWaitingFromReply;
                            
                            NSString *mailFrom = [NSString stringWithFormat:@"MAIL FROM:<%@>\r\n", fromEmail];
                            NSLog(@"C: %@", mailFrom);
                            [outputStream write:(const uint8_t *)[mailFrom UTF8String] maxLength:[mailFrom lengthOfBytesUsingEncoding:NSUTF8StringEncoding]];
                        }
                    }
                    break;
                }
                    
                case kSKPSMTPWaitingTLSReply:
                {
                    if ([tmpLine hasPrefix:@"220 "])
                    {
                        // Attempt to use TLSv1
                        if ( [inputStream setProperty:NSStreamSocketSecurityLevelTLSv1 forKey:NSStreamSocketSecurityLevelKey] &&
                            [outputStream setProperty:NSStreamSocketSecurityLevelTLSv1 forKey:NSStreamSocketSecurityLevelKey] )
                        {
                            NSLog(@"Beginning TLSv1...");
                            
                            // restart the connection
                            sendState = kSKPSMTPWaitingEHLOReply;
                            
                            isSecure = YES;
                            
                            NSString *ehlo = [NSString stringWithFormat:@"EHLO %@\r\n", @"localhost"];
                            NSLog(@"C: %@", ehlo);
                            [outputStream write:(const uint8_t *)[ehlo UTF8String] maxLength:[ehlo lengthOfBytesUsingEncoding:NSUTF8StringEncoding]];
                        }
                        else
                        {
                            error = [NSError errorWithDomain:@"SKPSMTPMessageError" 
                                                        code:kSKPSMTPErrorTLSFail
                                                    userInfo:[NSDictionary dictionaryWithObject:@"Unable to start TLS" 
                                                                                         forKey:NSLocalizedDescriptionKey]];
                            encounteredError = YES;
                        }
                    }
                }
                
                case kSKPSMTPWaitingLOGINUsernameReply:
                {
                    if ([tmpLine hasPrefix:@"334 VXNlcm5hbWU6"])
                    {
                        sendState = kSKPSMTPWaitingLOGINPasswordReply;
                        
                        NSString *authString = [NSString stringWithFormat:@"%@\r\n", [[login dataUsingEncoding:NSUTF8StringEncoding] encodeBase64ForData]];
                        NSLog(@"C: %@", authString);
                        [outputStream write:(const uint8_t *)[authString UTF8String] maxLength:[authString lengthOfBytesUsingEncoding:NSUTF8StringEncoding]];
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
                        [outputStream write:(const uint8_t *)[authString UTF8String] maxLength:[authString lengthOfBytesUsingEncoding:NSUTF8StringEncoding]];
                    }
                    break;
                }
                
                case kSKPSMTPWaitingAuthSuccess:
                {
                    if ([tmpLine hasPrefix:@"235 "])
                    {
                        sendState = kSKPSMTPWaitingFromReply;
                        
                        NSString *mailFrom = [NSString stringWithFormat:@"MAIL FROM:<%@>\r\n", fromEmail];
                        NSLog(@"C: %@", mailFrom);
                        [outputStream write:(const uint8_t *)[mailFrom UTF8String] maxLength:[mailFrom lengthOfBytesUsingEncoding:NSUTF8StringEncoding]];
                    }
                    else if ([tmpLine hasPrefix:@"535 "])
                    {
                        error =[NSError errorWithDomain:@"SKPSMTPMessageError" 
                                                   code:kSKPSMTPErrorInvalidUserPass 
                                               userInfo:[NSDictionary dictionaryWithObject:@"login/password invalid" 
                                                                                    forKey:NSLocalizedDescriptionKey]];
                        encounteredError = YES;
                    }
                    break;
                }
                
                case kSKPSMTPWaitingFromReply:
                {
                    if ([tmpLine hasPrefix:@"250 "])
                    {
                        sendState = kSKPSMTPWaitingToReply;
                        
                        NSString *rcptTo = [NSString stringWithFormat:@"RCPT TO:<%@>\r\n", toEmail];
                        NSLog(@"C: %@", rcptTo);
                        [outputStream write:(const uint8_t *)[rcptTo UTF8String] maxLength:[rcptTo lengthOfBytesUsingEncoding:NSUTF8StringEncoding]];
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
                        [outputStream write:(const uint8_t *)[dataString UTF8String] maxLength:[dataString lengthOfBytesUsingEncoding:NSUTF8StringEncoding]];
                    }
                    else if ([tmpLine hasPrefix:@"530 "])
                    {
                        error =[NSError errorWithDomain:@"SKPSMTPMessageError" 
                                                   code:kSKPSMTPErrorNoRelay 
                                               userInfo:[NSDictionary dictionaryWithObject:@"relay rejected - server probably requires auth" 
                                                                                    forKey:NSLocalizedDescriptionKey]];
                        encounteredError = YES;
                    }
                    break;
                }
                case kSKPSMTPWaitingForEnterMail:
                {
                    if ([tmpLine hasPrefix:@"354 "])
                    {
                        sendState = kSKPSMTPWaitingSendSuccess;
                        
                        [self sendParts];
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
                        [outputStream write:(const uint8_t *)[quitString UTF8String] maxLength:[quitString lengthOfBytesUsingEncoding:NSUTF8StringEncoding]];
                    }
                    else if ([tmpLine hasPrefix:@"550 "])
                    {
                        error =[NSError errorWithDomain:@"SKPSMTPMessageError" 
                                                   code:kSKPSMTPErrorInvalidMessage 
                                               userInfo:[NSDictionary dictionaryWithObject:@"error sending message" 
                                                                                    forKey:NSLocalizedDescriptionKey]];
                        encounteredError = YES;
                    }
                }
                case kSKPSMTPWaitingQuitReply:
                {
                    if ([tmpLine hasPrefix:@"221 "])
                    {
                        sendState = kSKPSMTPMessageSent;
                        
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
        [delegate messageSent:self];
    }
    else if (encounteredError)
    {
        [delegate messageFailed:self error:error];
    }
}

- (void)sendParts
{
    NSMutableString *message = [[NSMutableString alloc] init];
    static NSString *separatorString = @"--SKPSMTPMessage--Separator--Delimiter\r\n";
    
    [message appendFormat:@"From:%@\r\n", fromEmail];
    [message appendFormat:@"To:%@\r\n", toEmail];
    [message appendString:@"Content-Type: multipart/mixed; boundary=SKPSMTPMessage--Separator--Delimiter\r\n"];
    [message appendString:@"Mime-Version: 1.0 (SKPSMTPMessage 1.0)\r\n"];
    [message appendFormat:@"Subject:%@\r\n\r\n",subject];
    [message appendString:separatorString];
    
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
    [outputStream write:(const uint8_t *)[message UTF8String] maxLength:[message lengthOfBytesUsingEncoding:NSUTF8StringEncoding]];
    [message release];
}

- (void)connectionLivenessCheck:(NSTimer *)aTimer
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
        
        
        [delegate messageFailed:self 
                          error:[NSError errorWithDomain:@"SKPSMTPMessageError" 
                                                    code:kSKPSMTPErrorConnectionFailed 
                                                userInfo:[NSDictionary dictionaryWithObject:@"unable to connect to server" 
                                                                                     forKey:NSLocalizedDescriptionKey]]];
    }
    
    self.connectTimer = nil;
}

@end
