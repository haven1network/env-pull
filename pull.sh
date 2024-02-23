# Function to extract a unique list of repositories inside .env.pull
parse_repository_names() {
    echo $(grep -o '\${{[^}]*}}' $PULL_ENV_FILENAME | awk '{gsub(/[${}]/,""); split($0,a,"."); print a[1]}' | sort -u)
}

# Function to fetch a file from Haven1's GitHub repository
pull_remote_environment() {
    REPOSITORY_NAME=$1
    CHOSEN_IDENTITY=$2

    ENVIRONMENT="$DEFAULT_ENVIRONMENT"
    for REPO in "${REPO_ENVS[@]}"; do
        if [ "$REPO" = "$REPOSITORY_NAME" ]; then
            ENVIRONMENT="$DEFAULT_OPPOSITE_ENVIRONMENT"
            break
        fi
    done
    ENV_FILENAME=".env.$ENVIRONMENT"

    echo "Downloading $REPOSITORY_NAME's $ENV_FILENAME to $TARGET_ENV_FILENAME"

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

    echo "$ENV_FILENAME" > "${TEMP_DIR}/${REPOSITORY_NAME}/.git/info/sparse-checkout"
    git -C "${TEMP_DIR}/${REPOSITORY_NAME}" pull origin main &> /dev/null 

    # Checking if the file was successfully pulled
    if [ ! -f "${TEMP_DIR}/${REPOSITORY_NAME}/${ENV_FILENAME}" ]; then
        echo "Error: Something went wrong, make sure the file ${REPOSITORY_NAME}/${ENV_FILENAME} exists and that your git account has access and retry."
        exit 0
    else
        mv ${TEMP_DIR}/${REPOSITORY_NAME}/${ENV_FILENAME} ${TEMP_DIR}/${REPOSITORY_NAME}/${TARGET_ENV_FILENAME}
    fi
}

# Function to map local env key to remote env values
map_pull_remote_array() {
    REMOTE_ARRAY_REF=$1[@]
    PULL_ARRAY_REF=$2[@]

    REMOTE_ARRAY=("${!REMOTE_ARRAY_REF}")
    PULL_ARRAY=("${!PULL_ARRAY_REF}")

    for PULL_ITEM in "${PULL_ARRAY[@]}"; do
        RESULT="$PULL_ITEM"
        for REMOTE_ITEM in "${REMOTE_ARRAY[@]}"; do
            REMOTE_KEY="${REMOTE_ITEM%%=*}"
            REMOTE_VALUE="${REMOTE_ITEM#*=}"
            if [[ $RESULT == *"\${{$REMOTE_KEY}}"* ]]; then
                RESULT=$(echo "$RESULT" | sed "s/\${{$REMOTE_KEY}}/$REMOTE_VALUE/g")
            fi
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
if [ "$#" -lt 1 ]; then
    echo "Usage 1: {staging|development}"
    echo "Usage 2: {staging|development} {reponame1,reponame2..}"
    echo "The first argument is what .env to pull from all repos (e.g. development) and the second (optional) argument is the list of repos that want the opposite environment (e.g. staging)"
    exit 1
fi

DEFAULT_ENVIRONMENT=$1
REPO_ENVS=()
if [ "$#" -gt 1 ]; then
    # Input string
    input_string="$2"

    # Set the Internal Field Separator (IFS) to comma
    IFS=',' read -r -a REPO_ENVS <<< "$input_string"

    # Remove leading and trailing spaces from array elements
    for ((i=0; i<${#REPO_OPPOSITE_ENVS[@]}; i++)); do
        REPO_ENVS[$i]=$(echo "${REPO_ENVS[$i]}" | tr -d ' ')
    done
fi

# Validate environment argument and construct file path
if [ "${DEFAULT_ENVIRONMENT}" == "staging" ]; then
    DEFAULT_OPPOSITE_ENVIRONMENT="development"
    TARGET_ENV_FILENAME=".env.staging"
elif [ "${DEFAULT_ENVIRONMENT}" == "development" ]; then
    DEFAULT_OPPOSITE_ENVIRONMENT="staging"
    TARGET_ENV_FILENAME=".env.development"
else
    echo "Error: Invalid environment. Please specify either 'staging' or 'development'."
    exit 1
fi

if [ ${#REPO_ENVS[@]} -gt 0 ]; then
    TARGET_ENV_FILENAME=".env.local"
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
        echo "0. Use HTTPS"

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

# Extract pull array data from .env.pull file
PULL_ARRAY=()
while IFS= read -r line || [[ -n "$line" ]]; do
    trimmed="${line#"${line%%[![:space:]]*}"}"
    if [[ -n "$trimmed" && "$trimmed" != \#* ]]; then
        PULL_ARRAY+=("$line")
    fi
done < "$PULL_ENV_FILENAME"
echo "Extracted ${#PULL_ARRAY[@]} lines from $PULL_ENV_FILENAME"

# Extract repository names from .env.pull file
REPOSITORY_NAMES=($(parse_repository_names))
echo "Found ${#REPOSITORY_NAMES[@]} repositories: ${REPOSITORY_NAMES[@]}"

# Extract remote array data from respective repositories
REMOTE_ARRAY=()
for REPOSITORY_NAME in "${REPOSITORY_NAMES[@]}"; do
    echo ""
    pull_remote_environment "$REPOSITORY_NAME" "$CHOSEN_IDENTITY"

    echo "Extracting data from ${TEMP_DIR}/${REPOSITORY_NAME}/${TARGET_ENV_FILENAME}..."
    while IFS= read -r line; do
        trimmed="${line#"${line%%[![:space:]]*}"}"
        if [[ -n "$trimmed" && "$trimmed" != \#* ]]; then
            REMOTE_ARRAY+=("$REPOSITORY_NAME.$trimmed")
        fi
    done < "${TEMP_DIR}/${REPOSITORY_NAME}/${TARGET_ENV_FILENAME}"
done
echo ""
echo "Extracted ${#REMOTE_ARRAY[@]} lines from ${#REPOSITORY_NAMES[@]} repositories"

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
echo "Updated $TARGET_ENV_FILENAME"

# Cleanup
rm -rf "$TEMP_DIR"
