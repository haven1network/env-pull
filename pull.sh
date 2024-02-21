# Function to extract a unique list of repositories inside .env.pull
parse_repository_names() {
    sed -n 's/.*\${{\([^}]*\)}}.*/\1/p' "$PULL_ENV_FILENAME" | awk -F '.' '{print $1}' | sort -u
}

# Function to fetch a file from Haven1's GitHub repository
pull_remote_environment() {
    REPOSITORY_NAME=$1
    CHOSEN_IDENTITY=$2

    REPOSITORY_URL="https://github.com/haven1network/${REPOSITORY_NAME}.git"
    if [ -n "$CHOSEN_IDENTITY" ]; then
        REPOSITORY_URL="git@github.com:haven1network/${REPOSITORY_NAME}.git"
    fi

    mkdir "${TEMP_DIR}/${REPOSITORY_NAME}"

    # Initializing a new git repository
    git -C "${TEMP_DIR}/${REPOSITORY_NAME}" init &> /dev/null
    git -C "${TEMP_DIR}/${REPOSITORY_NAME}" config core.sparseCheckout true
    git -C "${TEMP_DIR}/${REPOSITORY_NAME}" config core.sshCommand "ssh -i $CHOSEN_IDENTITY -F /dev/null"
    git -C "${TEMP_DIR}/${REPOSITORY_NAME}" remote add -f origin "${REPOSITORY_URL}" &> /dev/null

    echo "${TARGET_ENV_FILENAME}" > "${TEMP_DIR}/${REPOSITORY_NAME}/.git/info/sparse-checkout"
    git -C "${TEMP_DIR}/${REPOSITORY_NAME}" pull origin main &> /dev/null

    # Checking if the file was successfully pulled
    if [ ! -f "${TEMP_DIR}/${REPOSITORY_NAME}/${TARGET_ENV_FILENAME}" ]; then
        echo "Error: Something went wrong, make sure the file  ${REPOSITORY_NAME}/${TARGET_ENV_FILENAME} exists and that your git account has access and retry."
        exit 0
    fi
}

# Function to map local env key to remote env values
map_pull_remote_array() {
    REMOTE_ARRAY_REF=$1[@]
    PULL_ARRAY_REF=$2[@]

    REMOTE_ARRAY=("${!REMOTE_ARRAY_REF}")
    PULL_ARRAY=("${!PULL_ARRAY_REF}")

    for PULL_ITEM in "${PULL_ARRAY[@]}"; do
        for REMOTE_ITEM in "${REMOTE_ARRAY[@]}"; do
            REMOTE_KEY="${REMOTE_ITEM%%=*}"
            REMOTE_VALUE="${REMOTE_ITEM#*=}"
            RESULT=$(echo "$PULL_ITEM" | sed "s/\${{$REMOTE_KEY}}/$REMOTE_VALUE/g")
        done
        echo "$RESULT"
    done
}

# Function to update or append variables in the .env file
update_local_environment() {
    REMOTE_KEY="$1"
    REMOTE_VALUE="$2"
    FOUND=false

    while IFS= read -r line || [[ -n "$line" ]]; do
        # TRIMMED_LINE=$(trim_string "$line")
        LOCAL_KEY=$(echo "$line" | cut -d "=" -f1)
        
        if [[ "$LOCAL_KEY" == "$REMOTE_KEY" ]]; then
            # Variable exists, update its value
            echo "$REMOTE_KEY=$REMOTE_VALUE"
            FOUND=true
        else
            echo "$line"
        fi
    done < "$TARGET_ENV_FILENAME"

    if ! $FOUND; then
        # Variable does not exist, append it
        echo "$REMOTE_KEY=$REMOTE_VALUE"
    fi
}

# Check if the required arguments are provided
if [ "$#" -ne 1 ]; then
    echo "Usage: $0 {staging|development}"
    exit 1
fi

# Validate environment argument and construct file path
ENVIRONMENT=$1
if [ "${ENVIRONMENT}" == "staging" ]; then
    TARGET_ENV_FILENAME=".env.staging"
elif [ "${ENVIRONMENT}" == "development" ]; then
    TARGET_ENV_FILENAME=".env.development"
else
    echo "Error: Invalid environment. Please specify either 'staging' or 'development'."
    exit 1
fi

# Check if .env.pull file existed
PULL_ENV_FILENAME=".env.pull"
if [ ! -f "$PULL_ENV_FILENAME" ]; then
    echo "Error: The file $PULL_ENV_FILENAME does not exists"
    exit 1
fi

# Initial temporary directory setup
TEMP_DIR=$(mktemp -d)

# Find identity to pull remote data and check if SSH config exists
ssh_config="$HOME/.ssh/config"
if [ -f "$ssh_config" ]; then
    echo "Checking SSH identities from $ssh_config"

    # Extract identity files associated with github.com from SSH config
    identities=($(awk '/github.com$/{p=1;next}/^Hostname /{p=0} p && /^ +IdentityFile/{gsub("^ +", "", $0); print $2}' "$ssh_config"))

    if [ "${#identities[@]}" -gt 0 ]; then
        echo "SSH identities found for github.com:"
        echo "0. Do not use any SSH identity (use HTTPS)"

        for ((i=0; i<"${#identities[@]}"; i++)); do
            echo "$((i+1)). ${identities[$i]}"
        done

        read -p "Choose an SSH identity (0-${#identities[@]}): " choice
        if [ "$choice" -eq 0 ]; then
            CHOSEN_IDENTITY=""
        else
            CHOSEN_IDENTITY="${identities[$((choice-1))]}"
        fi

        echo "Using $CHOSEN_IDENTITY for git clone.\n"
    else
        echo "No SSH identities found for github.com in $ssh_config. Using HTTPS for git clone.\n"
        CHOSEN_IDENTITY=""
    fi
else
    echo "SSH config file $ssh_config not found. Using HTTPS for git clone.\n"
    CHOSEN_IDENTITY=""
fi

# Extract repository names from .env.pull file
REPOSITORY_NAMES=$(parse_repository_names)
REPOSITORY_COUNT=$(echo "$REPOSITORY_NAMES" | wc -l)
echo "Found $REPOSITORY_COUNT repositories:\n${REPOSITORY_NAMES}\n"

# Extract pull array data from .env.pull file
PULL_ARRAY=()
while IFS= read -r line; do
    # trimmed=$(trim_string_brackets "$line")
    trimmed="$(echo -e "$line" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
    if [ -n "$trimmed" ] && [[ "$trimmed" != "#"* ]]; then
        PULL_ARRAY+=("$line")
    fi
done < "$PULL_ENV_FILENAME"
echo "Pull array:\n${PULL_ARRAY[@]}\n"

# Extract remote array data from respective repositories
REMOTE_ARRAY=()
while IFS= read -r REPOSITORY_NAME; do
    echo "Downloading $REPOSITORY_NAME's .env.$ENVIRONMENT\n"
    pull_remote_environment "$REPOSITORY_NAME" "$CHOSEN_IDENTITY"

    while IFS= read -r line; do
        trimmed="$(echo "$line" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
        if [ -n "$trimmed" ] && [[ "$trimmed" != "#"* ]]; then
            REMOTE_ARRAY+=("$REPOSITORY_NAME.$trimmed")
        fi
    done < "${TEMP_DIR}/${REPOSITORY_NAME}/${TARGET_ENV_FILENAME}"
done <<< "$REPOSITORY_NAMES"

# Create array mapping between local env key and remote env value
ARRAY_MAPPING=$(map_pull_remote_array REMOTE_ARRAY PULL_ARRAY)

# Create local env files if not yet existed
if [ ! -f "$TARGET_ENV_FILENAME" ]; then
    touch "$TARGET_ENV_FILENAME"
fi

for item in "${ARRAY_MAPPING[@]}"; do
    # Extract variable name and value from each item
    var="${item%%=*}"
    value="${item#*=}"
    update_local_environment "$var" "$value" > "$TARGET_ENV_FILENAME"
done

# Cleanup
rm -rf "$TEMP_DIR"
