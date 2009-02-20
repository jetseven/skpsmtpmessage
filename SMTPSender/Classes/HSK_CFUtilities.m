//
//  HSK_CFUtilities.m
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

#include "HSK_CFUtilities.h"

#include <sys/types.h>
#include <sys/socket.h>

void CFStreamCreatePairWithUNIXSocketPair(CFAllocatorRef alloc, CFReadStreamRef *readStream, CFWriteStreamRef *writeStream)
{
    int sockpair[2];
    int success = socketpair(AF_UNIX, SOCK_STREAM, 0, sockpair);
    if (success < 0)
    {
        [NSException raise:@"HSK_CFUtilitiesErrorDomain" format:@"Unable to create socket pair, errno: %d", errno];
    }
    
    CFStreamCreatePairWithSocket(NULL, sockpair[0], readStream, NULL);
    CFReadStreamSetProperty(*readStream, kCFStreamPropertyShouldCloseNativeSocket, kCFBooleanTrue);
    CFStreamCreatePairWithSocket(NULL, sockpair[1], NULL, writeStream);    
    CFWriteStreamSetProperty(*writeStream, kCFStreamPropertyShouldCloseNativeSocket, kCFBooleanTrue);
}

CFIndex CFWriteStreamWriteFully(CFWriteStreamRef outputStream, const uint8_t* buffer, CFIndex length)
{
    CFIndex bufferOffset = 0;
    CFIndex bytesWritten;
        
    while (bufferOffset < length)
    {
        if (CFWriteStreamCanAcceptBytes(outputStream))
        {
            bytesWritten = CFWriteStreamWrite(outputStream, &(buffer[bufferOffset]), length - bufferOffset);
            if (bytesWritten < 0)
            {
                // Bail!                
                return bytesWritten;
            }
            bufferOffset += bytesWritten;
        }
        else if (CFWriteStreamGetStatus(outputStream) == kCFStreamStatusError)
        {
            return -1;
        }
        else
        {
            // Pump the runloop
            CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.0, true);
        }
    }
    
    return bufferOffset;
}
