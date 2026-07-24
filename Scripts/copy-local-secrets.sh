#!/bin/sh

source_path="$SRCROOT/Config/LocalSecrets.xcconfig"
destination_path="$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH/LocalSecrets.xcconfig"

if [ -f "$source_path" ]; then
	/bin/cp "$source_path" "$destination_path"
else
	: > "$destination_path"
fi
