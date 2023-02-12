#!/bin/bash
require_package () {
    # $1 is package command
    # $2 is package name
    # Check if $1 is installed
    if ! command -v $1 &> /dev/null
    then
        # If not, install $2
        require_superuser
        # Detect package manager
        if command -v apt &> /dev/null
        then 
            # Install using apt
            sudo apt install -y $2
        elif command -v pacman &> /dev/null
        then
            # Install using pacman
            sudo pacman -S $2
        elif command -v dnf &> /dev/null
        then
            # Install using dnf
            sudo dnf install $2
        elif command -v yum &> /dev/null
        then
            # Install using yum
            sudo yum install $2
        elif command -v zypper &> /dev/null
        then
            # Install using zypper
            sudo zypper install $2
        elif command -v nix &> /dev/null
        then
            #  Install using nix
            sudo nix-env -i $2
        else
            echo "No package manager found"
            exit 1
        fi
    fi 
}

require_superuser () {
    # Check if user is root
    if [ "$EUID" -ne 0 ]
    then
        # prompt for sudo password
        sudo -v
        # keep-alive: update existing sudo time stamp if set, otherwise do nothing.
        while true; do sudo -n true; sleep 60; kill -0 "$$" || exit; done 2>/dev/null &
    fi
}

# Check that required packages are installed
require_package "curl" "curl"
require_package "jq" "jq"
RECAF_STORE="$HOME/.local/share/recaf"
# check if '$RECAF_VERSION' is set
RECAF_VERSION=$1
if [ -z "$RECAF_VERSION" ]; then
    # If not, set it to '3'
    RECAF_VERSION='3'
fi
RECAF_LATEST="$RECAF_STORE/latest$RECAF_VERSION"
# Create directory if it doesn't exist
mkdir -p $RECAF_STORE
# Create latest file if it doesn't exist, if it didnt exist write '0' to it
if test -f "$RECAF_LATEST"; then
    echo ""
else
    touch $RECAF_LATEST
    echo "0" > $RECAF_LATEST
fi
# Check if sufficent java version is present (REQUIRED_JAVA or higher)
check_java () {
    JAVA_VERSION=$($1 -version 2>&1 | grep -oP 'version "?(1\.)?\K\d+')
    # Check if version is REQUIRED_JAVA or higher
    if [ "$JAVA_VERSION" -ge "$REQUIRED_JAVA" ]; then
        # If so, return path
        echo $1
    else
        # Else, return nothing
        echo ""
    fi
}

get_all_java_installs () {
    # Get all java installs
    JAVA_INSTALLS=$(find /usr/lib/jvm -name java | grep -v jre)
    # Check if any java installs are present
    if [ -z "$JAVA_INSTALLS" ]; then
        # If not, return nothing
        echo ""
    else
        # Else, return all java installs
        echo $JAVA_INSTALLS
    fi
}

find_java () {
    # Iterate over all java installs and find first one that is 11 or higher
    for JAVA_INSTALL in $(get_all_java_installs); do
        RESULT=$(check_java $JAVA_INSTALL)
        if [ -n "$RESULT" ]; then
            JAVA_PATH=$RESULT
            break
        fi
    done
    # If no java REQUIRED_JAVA or higher was found, use default java
    if [ -z "$JAVA_PATH" ]; then
        JAVA_PATH="java"
        RESULT=$(check_java $JAVA_PATH)
        if [ -z "$RESULT" ]; then
            echo "No Java $JAVA_PATH or higher found"
            exit 1
        fi
    fi
}

# First find newest 3x-snapshort
GITHUB_BASE_URL='https://github.com/Col-E'
GITHUB_API_BASE_URL='https://api.github.com/repos/Col-E'
GITHUB_PER_PAGE="100"
build_recaf () {
    # $1 is branch
    # $2 is build command
    # $3 is where output is stored
    require_package "git" "git"
    JAVA_PATH=$(find_java)
    # first get latest commit hash on branch
    LATEST_COMMIT=$(curl -s $GITHUB_API_BASE_URL/$GITHUB_REPO/commits/$1 | jq -r '.sha')
    # compare with latest commit hash stored locally
    LATEST_LOCAL=$(cat $RECAF_LATEST)
    # if different, build
    if [ "$LATEST_COMMIT" != "$LATEST_LOCAL" ]; then
        # Build
        # Create tmp dir
        cd /tmp
        mkdir recaf
        cd recaf
        # Clone repo
        git clone $GITHUB_BASE_URL/$GITHUB_REPO.git
        # Checkout branch
        cd $GITHUB_REPO
        git checkout $1
        # Build
        $2
        # Move to store
        mv $3 $RECAF_STORE/recaf$RECAF_VERSION.jar
        # Remove repo
        cd ..
        rm -rf $GITHUB_REPO
        # Remove tmp dir
        cd ..
        rm -rf recaf
        # Update latest
        echo $LATEST_COMMIT > $RECAF_LATEST
    fi
}

download_recaf () {
    echo "Downloading Recaf $1"
    # $1 is tag name, if latest, use .[0].id
    # Get latest version stored locally
    LATEST_LOCAL=$(cat $RECAF_LATEST)
    if [ "$1" = "latest" ]; then
        # Load all releases using the GitHub API
        RELEASES=$(curl -s $GITHUB_API_BASE_URL/$GITHUB_REPO/releases)
        # Compare with .[0].id
        LATEST_REMOTE=$(echo $RELEASES | jq -r '.[0].id')
        # If different, download latest
        if [ "$LATEST_LOCAL" != "$LATEST_REMOTE" ]; then
            # Get asset download url
            LATEST_URL=$(echo $RELEASES | jq -r '.[0].assets[0].browser_download_url')
            # Download latest 
            curl -L $LATEST_URL -o $RECAF_STORE/recaf$RECAF_VERSION.jar
            # Update latest
            echo $LATEST_REMOTE > $RECAF_LATEST
        fi
    else 
        # go through the pages, compare .[n].tag_name with $1
        # if same, download .[n].assets[0].browser_download_url
        # if not, go to next page, if page does not contain 30 entires, stop
        if [ "$LATEST_LOCAL" != "$1" ]; then
            PAGE=0
            while true; do
                # Load all releases using the GitHub API
                RELEASES=$(curl -s $GITHUB_API_BASE_URL/$GITHUB_REPO/releases\?page=$PAGE\&per_page=$GITHUB_PER_PAGE)
                # Get number of releases
                RELEASES_COUNT=$(echo $RELEASES | jq -r 'length')
                # iterate over all releases
                for (( i=0; i<$RELEASES_COUNT; i++ )); do
                    # Get tag name
                    TAG_NAME=$(echo $RELEASES | jq -r ".[$i].tag_name")
                    # Compare with $1
                    if [ "$TAG_NAME" = "$1" ]; then
                        # Get asset download url
                        LATEST_URL=$(echo $RELEASES | jq -r ".[$i].assets[0].browser_download_url")
                        # Download latest 
                        curl -L $LATEST_URL -o $RECAF_STORE/recaf$RECAF_VERSION.jar
                        # Update latest
                        echo $TAG_NAME > $RECAF_LATEST
                        # Stop
                        break 2
                    fi
                done
                # If page does not contain 30 entries, stop
                if [ "$RELEASES_COUNT" -lt "$GITHUB_PER_PAGE" ]; then
                    break
                fi
                # Go to next page
                PAGE=$((PAGE+1))
            done
        fi
    fi

    find_java

}

if [ $1 == "--list" ]; then
    echo 'Retrieving all tags...'
    GITHUB_REPO='Recaf'
    LIST="1 2 3 3dev 2dev"
    # retrieve all tags
    PAGE=0
    while true; do
        TAGS=$(curl -s $GITHUB_API_BASE_URL/$GITHUB_REPO/tags\?page=$PAGE\&per_page=$GITHUB_PER_PAGE)
        TAGS_COUNT=$(echo $TAGS | jq -r 'length')
        for (( i=0; i<$TAGS_COUNT; i++ )); do
            TAG_NAME=$(echo $TAGS | jq -r ".[$i].name")
            LIST="$LIST $TAG_NAME"
        done
        if [ "$TAGS_COUNT" -lt "$GITHUB_PER_PAGE" ]; then
            break
        fi
        PAGE=$((PAGE+1))
    done
    # sort list
    LIST=$(echo $LIST | tr ' ' ' ' | tr ' ' ' ')
    echo $LIST
    exit 0
fi

if [ $1 == "--help" ]; then
    echo "Usage $0 [--list|--help]|[version]"
    echo ' version - Version of Recaf to download'
    echo ' --list - List all available versions'
    echo ' --help - Show this help message'
    echo 'Version can be one of the following:'
    echo '1 - Latest 1.x release'
    echo '2 - Latest 2.x release'
    echo '3 - Latest 3.x release'
    echo '3dev - Build latest 3.x development build'
    echo '2dev - Build latest 2.x development build'
    echo '<tag> - Download a specific release'
    exit 0
fi

# decide repo based on version
GITHUB_REPO='Recaf'
REQUIRED_JAVA='11'
if [ "$RECAF_VERSION" = "3" ]; then
    GITHUB_REPO='recaf-3x-issues' # Might have to change this when 3x is released
    download_recaf 'latest'
elif [ "$RECAF_VERSION" = "2" ]; then
    download_recaf 'latest'
elif [ "$RECAF_VERSION" = "3dev" ]; then
    build_recaf 'dev3' './gradlew shadowJar' 'recaf-ui/build/libs/recaf*-jar-with-dependencies.jar'
elif [ "$RECAF_VERSION" = "2dev" ]; then
    build_recaf 'master' './mvnw clean package' 'target/recaf*-jar-with-dependencies.jar'
elif [ "$RECAF_VERSION" = "1" ]; then 
    download_recaf '1.15.10'
else
    download_recaf $RECAF_VERSION
fi
# if there is a filed ending in '*-patched.jar', move that to $RECAF_STORE/recaf$RECAF_VERSION.jar, cause 1x pacthes the jar
if [ -f "$RECAF_STORE/*-patched.jar" ]; then
    mv $RECAF_STORE/*-patched.jar $RECAF_STORE/recaf$RECAF_VERSION.jar
fi

# Run recaf in a new terminal
/bin/bash -c "cd $RECAF_STORE && $JAVA_PATH -jar recaf$RECAF_VERSION.jar"