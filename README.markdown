# About skpsmtpmessage

A quick SMTP client for iOS. Fork of [skpsmtpmessage](http://code.google.com/p/skpsmtpmessage/), by Ian Baird.

To use this in your app, add the files in the SMTPLibrary directory to your project.

The Demo folder contains an Xcode project which will build a sample iPhone app.

Note: If you choose to build these files as a static library, you must add the following flag to your app's link flags in order to link to the NSStream+SKPSMTPExtension category. You will get an runtime exception (selector not recognized) if you forget. 
   
   Your Target -> Get Info -> Build -> All Configurations -> Other Link Flags: "-ObjC"
   
   See: http://developer.apple.com/qa/qa2006/qa1490.html


- Steve Brokaw

