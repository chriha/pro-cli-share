#!/usr/bin/env bash

cleanup_share() {
    [ -z "$SHARE_PID" ] && return 0

    printf "${CLEAR_LINE}${YELLOW}Please wait ... cleaning up!${NORMAL}\n"
    disown $SHARE_PID
    kill -9 $SHARE_PID 2>/dev/null
    wait $SHARE_PID 2>/dev/null
    rm -f "$SHARE_LOG"
    docker stop "$SHARE_WS_NAME" > /dev/null 2>&1 && docker rm "$SHARE_WS_NAME" > /dev/null 2>&1
    exit
}

manage_broadcasts() {
    [ ! -f "$SHARE_LOG" ] && return 1

    local SHARE_FILE="$PLUGIN_DIR/app/shares.json"
    local BROADCASTS=$(cat "$SHARE_LOG")

    > $SHARE_LOG

    local JSON=$(cat "$SHARE_FILE" 2> /dev/null)

    if [ ! -f "$SHARE_FILE" ]|| [ -z "$JSON" ]; then
        JSON=$(echo "{ \"self\": { \"user\": \"$SHARE_USER\", \"hostname\": \"$SHARE_HOSTNAME\" }, \"broadcasts\": [] }" | jq -M .)
    else
        JSON=$(echo "$JSON" | jq ".self.user = \"$SHARE_USER\"" | jq -Mc .)
        JSON=$(echo "$JSON" | jq ".self.hostname = \"$SHARE_HOSTNAME\"" | jq -M .)
    fi

    local APP_PORT=$([ ! -f "$WDIR/.env" ] || cat "$WDIR/.env" | grep 'APP_PORT=' | awk '{split($0,a,"="); print a[2]}')

    if [ -f "$PROJECT_CONFIG" ]; then
        JSON=$(echo "$JSON" | jq ".self.project = \"$PROJECT_NAME\"" | jq -Mc .)
        JSON=$(echo "$JSON" | jq ".self.port = \"$APP_PORT\"" | jq -Mc .)
        JSON=$(echo "$JSON" | jq ".self.branch = \"$SHARE_BRANCH\"" | jq -M .)
    fi

    echo "$JSON" > "$SHARE_FILE"

    while read line; do
        JSON_LINE=$(echo "$line" | jq -Mc .)

        [ -z "$JSON_LINE" ] && continue

        local USER=$(echo "$JSON_LINE" | jq -r '.user')
        local HOSTNAME=$(echo "$JSON_LINE" | jq -r '.hostname')

        [ -z "$USER" ] || [ -z "$HOSTNAME" ] && continue
        # no need to add yourself to the broadcasts
        [ "$USER" == "$SHARE_USER" ] && [ "$HOSTNAME" == "$SHARE_HOSTNAME" ] && continue

        USER_KEY=$(echo "$JSON" | jq -r "path( .broadcasts[] | select(.user==\"$USER\") | select(.hostname==\"$HOSTNAME\") )")

        # user not in broadcasts list
        if [ ! -z "$USER_KEY" ]; then
            USER_KEY=$(echo "$USER_KEY" | jq '.[1]')
            # get the users available JSON
            USER_JSON=$(echo "$JSON" | jq -Mc --argjson UKEY "$USER_KEY" '.broadcasts[$UKEY]')
            # merge old and new JSON
            JSON_LINE=$(echo "$USER_JSON $JSON_LINE" | jq -Mc -s add)
            # write the merged JSON to the broadcasts
            JSON=$(echo "$JSON" | jq --argjson UKEY "$USER_KEY" ".broadcasts[\$UKEY] = $JSON_LINE" | jq -M .)
        else
            local PROJECT=$(echo "$JSON_LINE" | jq -r ".project | select (.!=null)")
            local PORT=$(echo "$JSON_LINE" | jq -r ".port | select (.!=null)")
            local BRANCH=$(echo "$JSON_LINE" | jq -r ".branch | select (.!=null)")
            local UPDATED_AT=$(echo "$JSON_LINE" | jq -r ".updated_at | select (.!=null)")
            local IPS=$(echo "$JSON_LINE" | jq -r ".ips")

            JSON_LINE=$(echo "{ \"user\": \"$USER\", \"hostname\": \"$HOSTNAME\", \"project\": \"$PROJECT\", \"port\": \"$PORT\", \"branch\": \"$BRANCH\", \"ips\": $IPS }" | jq -Mc .)

            if [ ! -z "$UPDATED_AT" ]; then
                JSON_LINE=$(echo "$JSON_LINE" | jq -Mc ".updated_at = \"$UPDATED_AT\"")
            fi

            # add user to the broadcasts
            JSON=$(echo "$JSON" | jq -M ".broadcasts += [ $JSON_LINE ]")
        fi
    done <<< "$BROADCASTS"

    # don't brake the JSON file
    [ -z "$JSON" ] && return 0

    echo "$JSON" > "$SHARE_FILE"
}


if [ "$1" == "share" ]; then
    if ! ( socat -h > /dev/null 2>&1 ); then
        printf "${RED}socat is not installed!${NORMAL} Please install 'socat' and try again.\n" && exit
    fi

    if [ -f "$PROJECT_CONFIG" ] && ! ( is_service_running web >/dev/null ); then
        read -p "${YELLOW}Application is not running.${NORMAL} Start it now? [y|n] " -n 1 -r

        if [[ $REPLY =~ ^[Yy]$ ]]; then
            echo && project up
        fi
    fi

    SHARE_PORT=3080
    SHARE_SERVER_PORT=3081
    SHARE_LOG=$(mktemp)

    # trap CTRL+C to clean up and exit the script; 2 is SIGINT
    trap 'cleanup_share' 2

    printf "${BOLD}Broadcasts are logged to:${NORMAL} ${SHARE_LOG}\n"

    # start listening
    ( socat -u udp-recv:$SHARE_PORT file:"$SHARE_LOG" ) &
    SHARE_PID=$!

    SHARE_WS_NAME="${PROJECT_NAME}_share"
    PLUGIN_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

    SHARE_CONTAINER=$(docker run -d -v "$PLUGIN_DIR/app":/usr/app --name "$SHARE_WS_NAME" -w /usr/app -p $SHARE_SERVER_PORT:80 php:7.2-cli php -S 0.0.0.0:80)
    #printf "Container ID: ${SHARE_CONTAINER}\n"
    printf "${BOLD}Webinterface:${NORMAL} http://localhost:${SHARE_SERVER_PORT}\n"
    printf "Press Ctrl-C to quit.\n"

    SHARE_USER=$(whoami)
    SHARE_HOSTNAME=$(hostname)
    SHARE_IPS=$(ifconfig | grep 'inet 19' | awk '{print $2}')
    SHARE_DATA=$(echo "{ \"user\": \"$SHARE_USER\", \"hostname\": \"$SHARE_HOSTNAME\" }" | jq -M .)

    if [ -f "$PROJECT_CONFIG" ]; then
        SHARE_DATA=$(echo "$SHARE_DATA" | jq -M ".project = \"$PROJECT_NAME\"")
        SHARE_APP_PORT=$([ ! -f "$WDIR/.env" ] || cat "$WDIR/.env" | grep 'APP_PORT=' | awk '{split($0,a,"="); print a[2]}')
        SHARE_DATA=$(echo "$SHARE_DATA" | jq -M ".port = \"$SHARE_APP_PORT\"")
    fi

    SHARE_BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null)

    if [ ! -z "$SHARE_BRANCH" ]; then
        SHARE_DATA=$(echo "$SHARE_DATA" | jq -M ".branch = \"$SHARE_BRANCH\"")
    fi

    while true; do
        # only broadcast if we're in a project
        if [ -f "$PROJECT_CONFIG" ]; then
            SHARE_DATA=$(echo "$SHARE_DATA" | jq -Mc ".updated_at = \"$(date +%s)\"")
            SHARE_BROADCAST_IPS=()
            SHARE_DATA=$(echo "$SHARE_DATA" | jq -Mc ".ips = []")

            for IP in $SHARE_IPS; do
                SHARE_DATA=$(echo "$SHARE_DATA" | jq -Mc ".ips += [ \"$IP\" ]")
                SHARE_IFCONFIG=$(ifconfig | grep "inet ${IP}")
                SHARE_BROADCAST_IPS+=($(echo ${SHARE_IFCONFIG##*broadcast }))
            done

            for i in "${SHARE_BROADCAST_IPS[@]}"; do
                echo "$SHARE_DATA" | socat - udp-datagram:$i:$SHARE_PORT,broadcast
            done
        fi

        manage_broadcasts
        sleep 5
    done

    exit
fi
