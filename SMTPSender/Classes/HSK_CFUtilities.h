/*
 *  HSK_CFUtilities.h
 *  Handshake
 *
 *  Created by Ian Baird on 11/26/08.
 *  Copyright 2008 Skorpiostech, Inc. All rights reserved.
 *
 */

#import <Foundation/Foundation.h>
#import <CFNetwork/CFNetwork.h>

void CFStreamCreatePairWithUNIXSocketPair(CFAllocatorRef alloc, CFReadStreamRef *readStream, CFWriteStreamRef *writeStream);
CFIndex CFWriteStreamWriteFully(CFWriteStreamRef outputStream, const uint8_t* buffer, CFIndex length);
