#!/bin/bash

# buildstaticlib.sh
# SMTPSender static lib
#
# Build SMTPSender as a static library/header package.


dst_root=$1

if [ -z "$dst_root" ] || ! [ -d "$dst_root" ] ; then
	echo
	echo "Usage: $0 PATH"
	echo "where PATH is the destination directory for the build package"
	echo
	exit 1
fi

echo
echo "Updating to the latest revision ..."

# Do an svn update to make sure we have the latest version
if ! svn up ; then
	exit 1
fi

# Find the library version (as the most recent changed svn revision)
revision=`svn info | grep -e "Last Changed Rev:" | sed -e s/[^0-9]//g`

if [[ $dst_root =~ /$ ]] ; then
	dst="$dst_root$revision"
else
	dst="$dst_root/$revision"
fi

if [ -e "$dst" ] ; then
	echo
	echo "Destination already exists: $dst"
	echo
	exit 1
fi

project="smtpsender"
target=libsmtpmessage
productname="libsmtpmessage"
product="$productname.a"
config="Release"
device="iphoneos"
sim="iphonesimulator"
sdkvers="2.0"
devicesdk="$device$sdkvers"
simsdk="$sim$sdkvers"

echo
echo "Building $project version $revision at: $dst ..."

# Clean the targets
if ! xcodebuild -project "$project.xcodeproj" -target "$target" -configuration "$config" -sdk "$devicesdk" clean ; then
	exit 1
fi
if ! xcodebuild -project "$project.xcodeproj" -target "$target" -configuration "$config" -sdk "$simsdk" clean ; then
	exit 1
fi

# Build the targets
if ! xcodebuild -project "$project.xcodeproj" -target "$target" -configuration "$config" -sdk "$devicesdk" build ; then
	exit 1
fi
if ! xcodebuild -project "$project.xcodeproj" -target "$target" -configuration "$config" -sdk "$simsdk" build ; then
	exit 1
fi

devicedir="build/$config-$device"
simdir="build/$config-$sim"

# Package the library
echo
echo "Packaging library ..."

if ! mkdir "$dst" ; then
	exit 1
fi
if ! lipo "$devicedir/$product" "$simdir/$product" -create -output "$dst/$product" ; then
	exit 1
fi
if ! sed -e s/'$(REVISION)'/"$revision"/g "Classes/SKPSMTPMessage.h" > "$dst/SKPSMTPMessage.h" ; then
	exit 1
fi


echo
echo "Done"
echo

exit 0

