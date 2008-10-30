/*
 *  Base64Transcoder.h
 *  Base64Test
 *
 *  Created by Jonathan Wight on Tue Mar 18 2003.
 *  Copyright (c) 2003 Toxic Software. All rights reserved.
 *
 */



#include <UIKit/UIKit.h>

extern size_t EstimateBas64EncodedDataSize(size_t inDataSize);
extern size_t EstimateBas64DecodedDataSize(size_t inDataSize);

extern bool Base64EncodeData(const void *inInputData, size_t inInputDataSize, char *outOutputData, size_t *ioOutputDataSize);
extern bool Base64DecodeData(const void *inInputData, size_t inInputDataSize, void *ioOutputData, size_t *ioOutputDataSize);

