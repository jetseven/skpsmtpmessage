Thanks to the guys at Avatron for submitting the static library code.

To use this in your app, either (a is recommended):

a) Include the following files in your project:

SKPSMTPMessage.*
NSStream+SKPSMTPExtensions.*

OR

b) Build the libsmtpmessage.a library and include that.
   *** NOTE: You must add the following flag to your app's link flags in order to link to the NSStream+SKPSMTPExtension category. Your app WILL NOT
   WORK IF YOU DO NOT.
   
   Your Target -> Get Info -> Build -> All Configurations -> Other Link Flags: "-ObjC"
   
   Setting this flag will have the side effect of making your app bigger.
   
   See: http://developer.apple.com/qa/qa2006/qa1490.html


- Ian Baird

