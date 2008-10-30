#!/bin/sh

echo "Refreshing source from Handshake..."

cp -fv ../Handshake/Classes/SKPSMTPMessage.h Classes/ 
cp -fv ../Handshake/Classes/SKPSMTPMessage.m Classes/
cp -fv ../Handshake/Classes/NSStream+SKPSMTPExtensions.h Classes/
cp -fv ../Handshake/Classes/NSStream+SKPSMTPExtensions.m Classes/
