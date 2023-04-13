#!/bin/bash

# Usage: ./prod.sh [--ipa /path/to/ipa] [--port <port number>]

# Check if Zenity, jq, Python 2, Figlet, and wkhtmltopdf are installed
if ! which zenity > /dev/null || ! which jq > /dev/null || ! which python2 > /dev/null || ! which figlet > /dev/null || ! which wkhtmltopdf > /dev/null; then
  echo "Error: Zenity or jq or Figlet or wkhtmltopdf is not installed."
  echo "Installing Zenity, jq, Figlet, and wkhtmltopdf"
  # install Zenity, jq, Figlet, and wkhtmltopdf
  sudo apt update && sudo apt install -y zenity jq python2 figlet wkhtmltopdf
fi

# Display signature
tput setaf 1
figlet "iLPT"
tput setaf 2


# Default port number
PORT=8085
echo "Booting......"
fuser -k $PORT/tcp >/dev/null 2>&1
tput setaf 4

while [[ $# -gt 0 ]]
do
    key="$1"

    case $key in
        -a|--ipa)
        IPA_PATH="$2"
        shift
        shift
        ;;
        -p|--port)
        PORT="$2"
        shift
        shift
        ;;
        *)
        shift
        ;;
    esac
done

if [[ -z $IPA_PATH ]]; then
    zenity --info --text="Please select the IPA file." --title="Select IPA" 2>/dev/null
    IPA_PATH=$(zenity --file-selection --title="Select IPA" --file-filter="IPA files | *.ipa" 2>/dev/null)
    if [[ -z $IPA_PATH ]]; then
        zenity --error --text="No IPA file selected. Exiting." --title="Error" 2>/dev/null
        exit 1
    fi
fi

# Use the $IPA_PATH variable in your code to access the IPA file
echo "IPA file path: $IPA_PATH"


#Config file
CONFIG_FILE="$HOME/.mobsec.conf"

if [ -f "$CONFIG_FILE" ]; then
    source "$CONFIG_FILE"
fi

# Open a file dialog to select the MobSF installation directory
if [ -z "$MOBSF_DIR" ]; then
    zenity --info --text="Please select the MOBSF folder." --title="Select Mobsf folder" 2>/dev/null
    MOBSF_DIR=$(zenity --file-selection --directory --title="Select MobSF Installation Directory")

    if [ -z "$MOBSF_DIR" ]; then
        echo "Error: No directory selected."
        exit 1
    else
        echo "MOBSF_DIR=\"$MOBSF_DIR\"" > "$CONFIG_FILE"
    fi
fi


# Create report folder with the same name as the IPA file
IPA_BASENAME=$(basename "$IPA_PATH")
FOLDER_NAME="$(dirname "$IPA_PATH")/${IPA_BASENAME%.*}_report"
mkdir "$FOLDER_NAME"


# Check if the selected directory contains the mobsf script
if [ ! -f "$MOBSF_DIR/run.sh" ]; then
    echo "Error: Selected directory does not contain the MobSF script."
    exit 1
fi

# Use the selected directory in your code to execute the MobSF script
echo "Selected MobSF installation directory: $MOBSF_DIR"
 tput sgr0

 
# Start MobSF in the background
echo "Starting MobSF on port $PORT..."
cd $MOBSF_DIR
./run.sh 127.0.0.1:$PORT >> $FOLDER_NAME/Mobsf.log 2>&1 &
sleep 10
echo "MobSF started."


# Get API key from MobSF web interface
echo "Getting API key..."

API_KEY=$(curl --silent http://localhost:$PORT/api_docs | grep -oP "REST API Key:\s*<strong><code>\K\S+(?=<\/code>)")
if [ -z "$API_KEY" ]
then
    echo "Error: Failed to get API key from MobSF web interface."
    exit 1
fi
echo "API key: $API_KEY"
export MOBSF_API_KEY=$API_KEY


# Upload IPA file
RESPONSE=$(curl -s -F "file=@$IPA_PATH" http://localhost:$PORT/api/v1/upload -H "Authorization:$API_KEY")
HASH=$(echo "$RESPONSE" | jq -r '.hash')
FILE_NAME=$(echo "$RESPONSE" | jq -r '.file_name')

# Analyze IPA file
echo "Analyzing IPA file..."
RESPONSE=$(curl -s -X POST --url http://localhost:$PORT/api/v1/scan --data "scan_type=ipa&file_name=$FILE_NAME&hash=$HASH" -H "Authorization:$API_KEY")
JOB_ID=$(echo "$RESPONSE" | jq -r '.job_id')

# Check if the scan was started successfully
if [ -z "$JOB_ID" ]
then
    echo "Error: Scan failed. Please check the uploaded file and try again."
    exit 1
fi
 

# Wait for the scan to complete
echo "Waiting for scan to complete..."
STATUS="queued"
while [ "$STATUS" != "completed" ]
do
    sleep 10
    RESPONSE=$(curl -s -X POST --url http://localhost:$PORT/api/v1/scorecard --data "hash=$HASH" -H "Authorization:$API_KEY")
    SECURITY_SCORE=$(echo "$RESPONSE" | jq -r '.security_score')
    if [ "$SECURITY_SCORE" != "null" ]; then
        echo "Scan complete."
        
        curl -s -o "$FOLDER_NAME/appsec_report.pdf" -X POST --url http://localhost:$PORT/api/v1/download_pdf --data "hash=$HASH" -H "Authorization:$API_KEY"
        
        echo "Report downloaded to $FOLDER_NAME/appsec_report.pdf."
        # Open folder in file manager
        xdg-open "$FOLDER_NAME"
        break
    fi
    STATUS=$(echo "$RESPONSE" | jq -r '.scan_details.status')
done


# Stop MobSF
echo "Scans Completed."

tput setaf 3
