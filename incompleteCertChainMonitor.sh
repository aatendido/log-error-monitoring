#!/bin/bash
# Author: Alvin Atendido (alvin_atendido@manulife.com)
# Main function: When installed and ran in a host, it will search for given error string/s in files within given a directory/ies recursively and output only new lines to a log file (old lines found are stored in another log file)
# Additional function: Purge error lines found when source file is not existent (so that they can be reported again) and purge old log files
# Data captured by the script: hostName, fileTimestamp, fileName, errorString, lineNumber, logEntry, countOfLogs

# Define constants etc.
hostName=$(hostname) # name of this host
scriptDir=$(dirname "$(realpath "$0")") # directory where this script is located
scriptName=$(basename "$0") # name of this script
scriptLogDir="$scriptDir/Logs"; mkdir -p "$scriptLogDir"  # directory to contain logs created by this script, create it (if not created yet)
errorsFoundLogFile="$scriptLogDir/${scriptName}.results.log."$(date +"%Y%m%d%H%M%S"); > "$errorsFoundLogFile" # file to contain errors found in per run, made empty
errorsFoundLastRunLogFile="$scriptLogDir/${scriptName}.lastrunresults.log"; > "$errorsFoundLastRunLogFile" # file to contain errors found in last run, made empty
allErrorsFoundLogFile="$scriptLogDir/${scriptName}.allresults.log" # file to contain all errors found in all runs
os="|" # output line separator, should match the file separator defined in split_by field of the New Relic Flex integration .yaml file
logDaysRetention=7
searchDirs=( # directories to search (recursively) for errors
    "/tech/Logs" # "/tech/admin/monitoring/incompleteCertChainMonitor/testDir" 
)
searchStrings=( # error message strings to search for (can use wildcard character i.e. "*") in searchDirs
    "PKIX path building failed.*unable to find valid certification path to requested target" # "PKIX"
)

# Function to search for strings in files in a given directory
searchInFiles() {
    local dir=$1
    declare -i count=0
    declare logEntry=""
    declare lastErrorLine=""

    for searchString in "${searchStrings[@]}"; do
        while IFS= read -r fileName; do
            errorsInFile=""
            count=0
            lastErrorLine=""
            while IFS= read -r line; do
                lineNumber=$(echo "$line" | cut -d: -f2) 
                logEntry=$(sed "${lineNumber}q;d" "$fileName")
                
                # Check if the error "signature" is absent in history of errors, output this if so
                signature="${fileName}${os}${searchString}${os}${lineNumber}" # unique id of an error
                if [ "$firstRun" = true ] || ! grep -q "$signature" "$allErrorsFoundLogFile"; then
                    count=$((count + 1))
                    fileTimestamp=$(stat -c %y "$fileName")
                    output="${fileTimestamp}${os}${fileName}${os}${searchString}${os}${lineNumber}${os}${logEntry}"
                    errorsInFile+="$output\n"
                fi
            done < <(grep -Hn "$searchString" "$fileName") # returns lines found with given search string with a line number

            if [ -n "$errorsInFile" ]; then

                while IFS= read -r errorLine; do
                    if [ "$firstRun" = true ]; then
                        echo "${hostName}${os}${errorLine}${os}${count}" >> "$allErrorsFoundLogFile" # write only to history, not to errors found file
                    else
                        echo "${hostName}${os}${errorLine}${os}${count}" >> "$allErrorsFoundLogFile"
                        echo "${hostName}${os}${errorLine}${os}${count}" >> "$errorsFoundLogFile" # write to errors found file (wll be sent to New Relic)
                    fi
                done <<< "$(printf "%b\n" "$errorsInFile")" #done <<< "$errorsInFile" # note to self: this does not work
            fi
        
        done < <(find "$dir" -type f -newermt "$startTime" ! -newermt "$endTime") # returns all files with last modified time within a time window
       
    done
}

# Prune allErrorsFoundLogFile
pruneallErrorsFoundLogFile() {
    local tempFile=$(mktemp)
    chmod 766 "$tempFile"
    while IFS= read -r line; do
        fileTimestamp=$(awk -F "$os" '{printf $2}' <<< "$line") # fileTimestamp=$(echo "$line" | cut -d"$os" -f2) # note to self: this does not work
        fileName=$(awk -F "$os" '{printf $3}' <<< "$line") # fileName=$(echo "$line" | cut -d"$os" -f3) # note to self: this does not work
        
        if [[ -f "$fileName" ]]; then
            echo "$line" >> "$tempFile"
        fi
    done < "$allErrorsFoundLogFile"
    
    mv "$tempFile" "$allErrorsFoundLogFile" # note to self: create BEFORE (and possibly also AFTER) file of all errors before editing $allErrorsFoundLogFile
}

pruneLogDir() {
    find "$scriptLogDir" -type f -name "*.results.log.*" -not -newermt +"$logDaysRetention days ago" -exec rm -f {} \; # note to self: improve the search pattern based on the pattern constants in errorsFoundLogFile
    #find "$scriptLogDir" -type f -name "*.results.log.*" -mmin +70 -exec rm -f {} \; # note to self: improve the search pattern based on the pattern constants in errorsFoundLogFile
}

# MAIN

# Check if the number of minutes argument is provided
if [ "$#" -ne 1 ]; then
    echo "Usage: $scriptName <minutes> where minutes is the number of minutes ago to search from (up to current time)"
    exit 1
fi

# Get the start time and end time (the scope) using the number of minutes passed as argument
minutes=$1
startTime=$(date -d "-$minutes minutes" +"%Y-%m-%d %H:%M:%S %Z")
endTime=$(date +"%Y-%m-%d %H:%M:%S %Z")

# Check if allErrorsFoundLogFile exists or not (if not, this is the first run, thus do not output to stdout (New Relic Flex will not send to New Relic server))
if [ ! -e "$allErrorsFoundLogFile" ]; then
    touch "$allErrorsFoundLogFile"
    chmod 766 "$allErrorsFoundLogFile"
    firstRun=true
else
    firstRun=false
fi

# Iterate over searchDirs and search for strings
for dir in "${searchDirs[@]}"; do
    searchInFiles "$dir"
done

# Copy all errors found (for all error string to search for all search directories) into the last run log file 
cp "$errorsFoundLogFile" "$errorsFoundLastRunLogFile"

# Prune all results log (to maintain size and so that new errors will be reported)
pruneallErrorsFoundLogFile

# Prune the log directory itself of files older than 30 days
pruneLogDir

# THE END :-)
