//
//  SMTPSenderAppDelegate.m
//  SMTPSender
//
//  Created by Ian Baird on 10/28/2008.
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

#import "SMTPSenderAppDelegate.h"
#import "SKPSMTPMessage.h"
#import "NSData+Base64Additions.h"

@implementation SMTPSenderAppDelegate

@synthesize window;
@synthesize textView;

+ (void)initialize {
    NSUserDefaults *userDefaults = [NSUserDefaults standardUserDefaults];
    NSMutableDictionary *defaultsDictionary = [NSMutableDictionary dictionaryWithObjectsAndKeys:@"me@example.com", @"fromEmail",
                                               @"you@example.com", @"toEmail",
                                               @"smtp.example.com", @"relayHost",
                                               @"me@example.com", @"login",
                                               @"SekritSquirrel", @"pass",
                                               [NSNumber numberWithBool:YES], @"requiredAuth",
                                               [NSNumber numberWithBool:YES], @"wantsSecure", nil];
    
    [userDefaults registerDefaults:defaultsDictionary];
}
- (void)applicationDidFinishLaunching:(UIApplication *)application {    
    
    // Override point for customization after app launch    
    //[window addSubview:viewController.view];
    [window makeKeyAndVisible];
}


- (void)dealloc {
    [window release];
    [super dealloc];
}

- (IBAction)sendMessage:(id)sender {
    NSMutableString *logText = [[NSMutableString alloc] init];

    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    
    SKPSMTPMessage *testMsg = [[SKPSMTPMessage alloc] init];
    testMsg.fromEmail = [defaults objectForKey:@"fromEmail"];
    [logText appendFormat:@"From: %@\n", testMsg.fromEmail];
    
    testMsg.toEmail = [defaults objectForKey:@"toEmail"];
    [logText appendFormat:@"To: %@\n", testMsg.toEmail];

    testMsg.relayHost = [defaults objectForKey:@"relayHost"];
    [logText appendFormat:@"Host: %@\n", testMsg.relayHost];
    
    testMsg.requiresAuth = [[defaults objectForKey:@"requiresAuth"] boolValue];
    [logText appendFormat:@"Auth: %@\n", (testMsg.requiresAuth ? @"On" : @"Off")];
    
    if (testMsg.requiresAuth) {
        testMsg.login = [defaults objectForKey:@"login"];
        [logText appendFormat:@"Login: %@\n", testMsg.login];
        
        testMsg.pass = [defaults objectForKey:@"pass"];
        [logText appendFormat:@"Password: %@\n", testMsg.pass];

    }
    
    testMsg.wantsSecure = [[defaults objectForKey:@"wantsSecure"] boolValue]; // smtp.gmail.com doesn't work without TLS!
    [logText appendFormat:@"Secure: %@\n", testMsg.wantsSecure ? @"Yes" : @"No"];

    
    testMsg.subject = @"test message";
    testMsg.bccEmail = @"testbcc@test.com";
    
    // Only do this for self-signed certs!
    // testMsg.validateSSLChain = NO;
    testMsg.delegate = self;
    self.textView.text = logText;
    
    NSDictionary *plainPart = [NSDictionary dictionaryWithObjectsAndKeys:@"text/plain",kSKPSMTPPartContentTypeKey,
                               @"This is a tést messåge.",kSKPSMTPPartMessageKey,@"8bit",kSKPSMTPPartContentTransferEncodingKey,nil];
    
    NSString *vcfPath = [[NSBundle mainBundle] pathForResource:@"test" ofType:@"vcf"];
    NSData *vcfData = [NSData dataWithContentsOfFile:vcfPath];
    
    NSDictionary *vcfPart = [NSDictionary dictionaryWithObjectsAndKeys:@"text/directory;\r\n\tx-unix-mode=0644;\r\n\tname=\"test.vcf\"",kSKPSMTPPartContentTypeKey,
                             @"attachment;\r\n\tfilename=\"test.vcf\"",kSKPSMTPPartContentDispositionKey,[vcfData encodeBase64ForData],kSKPSMTPPartMessageKey,@"base64",kSKPSMTPPartContentTransferEncodingKey,nil];
    
    testMsg.parts = [NSArray arrayWithObjects:plainPart,vcfPart,nil];
    
    [testMsg send];

}
- (void)messageSent:(SKPSMTPMessage *)message
{
    [message release];
    self.textView.text  = @"Yay! Message was sent!";
    //NSLog(@"delegate - message sent");
}

- (void)messageFailed:(SKPSMTPMessage *)message error:(NSError *)error
{
    
    self.textView.text = [NSString stringWithFormat:@"Darn! Error: %@, %@", [error code], [error localizedDescription]];
    [message release];
    
    //NSLog(@"delegate - error(%d): %@", [error code], [error localizedDescription]);
}

@end
