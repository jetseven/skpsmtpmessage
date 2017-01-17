Pod::Spec.new do |s|
  s.name     = 'skpsmtpmessage'
  s.version  = '0.0.1'
  s.license  = 'Public Domain'
  s.platform = :ios
  s.summary      = 'Quick SMTP client code for the iPhone.'
  s.homepage     = 'https://github.com/erichsu/skpsmtpmessage'
  s.author       = 'jetseven'
  s.source       = { :git => "https://github.com/erichsu/skpsmtpmessage.git" }

  s.source_files = 'SMTPLibrary/*.{h,m}'
 # s.requires_arc = false
  s.ios.deployment_target = '5.1'
  s.ios.frameworks = 'CFNetwork'

end

