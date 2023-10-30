#!/bin/bash
# must be used like ". wormhole.sh" or "source wormhole.sh" to affect the current shell

while true; do
	NAV_FILE=".fastnav-wormhole"

    #cleanup if dirty
    if test -f $NAV_FILE
    then
        echo "$NAV_FILE left over! Cleaning up!"
        rm $NAV_FILE
    fi

    # main program execution, should be in PATH
    wormhole

    TARGET_PATH=$(cat $NAV_FILE)
    rm $NAV_FILE

    if test -z "$TARGET_PATH"
    then
        echo "Target Path is empty! Exiting.."
        break
    fi

    if test -d $TARGET_PATH
    then
        cd $TARGET_PATH
        break
   
    elif test -f $TARGET_PATH
    then
        #TODO: open file with default app, maybe via xdg-open
        # in that case we could remove the break here and go back into wormhole
        # after we're done with the file
        echo "File opening not implemented in bash"
        break
    else
        echo "Invalid file path!"
        break
    fi
done