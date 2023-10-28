#!/bin/bash

# If $@ is found, run it and bypass the rest of the script
if [ $# -gt 0 ]; then
    exec "$@"
    exit 0
fi

# Helpers
# =========================
if ! type tput >/dev/null 2>&1; then
    tput() {
        return 0
    }
fi
log_info() {
    local CYAN=$(tput setaf 6)
    local NC=$(tput sgr0)
    echo "${CYAN}[INFO   ]${NC} $*" 1>&2
}
log_warning() {
    local YELLOW=$(tput setaf 3)
    local NC=$(tput sgr0)
    echo "${YELLOW}[WARNING]${NC} $*" 1>&2
}
log_error() {
    local RED=$(tput setaf 1)
    local NC=$(tput sgr0)
    echo "${RED}[ERROR  ]${NC} $*" 1>&2
}
log_success() {
    local GREEN=$(tput setaf 2)
    local NC=$(tput sgr0)
    echo "${GREEN}[SUCCESS]${NC} $*" 1>&2
}
log_title() {
    local GREEN=$(tput setaf 2)
    local BOLD=$(tput bold)
    local NC=$(tput sgr0)
    echo 1>&2
    echo "${GREEN}${BOLD}---- $* ----${NC}" 1>&2
}
h_run() {
    local ORANGE=$(tput setaf 3)
    local NC=$(tput sgr0)
    echo "${ORANGE}\$${NC} $*" 1>&2
    eval "$*"
}

# Input validation
# =========================

# Get the list of all arg with `RULE_` prefix
RULES_NAME=$(env | grep RULE_ | cut -d= -f1)

if [ -z "$RULES_NAME" ]; then
    # env var example: <from_ip> <from_port> <to_ip_or_domain> <to_port>
    log_error "No rules found in the env vars!"
    log_error "You must define at least one rule with the RULE_ prefix"
    log_error ""
    log_error "Rule format: <from_ip> <from_port> <to_ip_or_domain> <to_port>"
    log_error ""
    log_error "Full command examples:"
    log_error "podman run -it --rm -e RULE_my_server='0.0.0.0 80 1.2.3.4 8080' -p 80:80 quay.io/thenets/rinetd:latest"
    log_error "podman run -it --rm -e RULE_my_server='0.0.0.0 80 1.2.3.4 8080' --net=host quay.io/thenets/rinetd:latest"

    exit 1
fi

# Validate the rules
# - must be in the format of `<from_ip> <from_port> <to_ip_or_domain> <to_port>`
log_title "Validating rules..."
i=1
for RULE_NAME in $RULES_NAME; do
    RULE=$(eval "echo \$$RULE_NAME")
    RULE=$(echo "$RULE" | tr -s ' ')

    function _allow_deny_rule() {
        _FIRST_WORD=$(echo "$RULE" | cut -d' ' -f1)
        if [ "$_FIRST_WORD" = "allow" -o "$_FIRST_WORD" = "deny" ]; then
            # Must follow the format: [allow|deny] <ip> (octet must be in the range of 0-255 or * or ?)
            #
            # you may specify global allow and deny rules here
            # only ip addresses are matched, hostnames cannot be specified here
            # the wildcards you may use are * and ?
            #
            # allow 192.168.2.*
            # deny 192.168.2.1?

            _FOUND_ERROR=0

            _TEST=$(echo "$RULE" | cut -d' ' -f2 | tr '.' ' ' | wc -w)
            if [ $_TEST -ne 4 ]; then
                _FOUND_ERROR=1
                _ERROR_MSG="IP must have 4 octets"
            fi

            # Replace * and ? with emojis (because I hate to handle * and ? in bash)
            RULE_SANITIZE=$(echo "$RULE" | sed 's/\*/🔥/g')
            RULE_SANITIZE=$(echo "$RULE_SANITIZE" | sed 's/?/💣/g')

            OCTETS=$(echo "$RULE_SANITIZE" | cut -d' ' -f2 | tr '.' ' ')
            for OCTET in $OCTETS; do
                if [ "$OCTET" == "🔥" ]; then
                    continue
                fi
                if [ "$OCTET" == "💣" ]; then
                    continue
                fi

                # Test if the octet is a number
                _TEST=$(echo "$OCTET" | grep -qE '^[0-9]+$')
                if [ $? -ne 0 ]; then
                    _FOUND_ERROR=1
                    _ERROR_MSG="Each octet of the IP must be in the range of 0-255 or * or ?"
                    continue
                fi

                # Test if the octet is in the range of 0-255
                if [ $OCTET -lt 0 -o $OCTET -gt 255 ]; then
                    _FOUND_ERROR=1
                    _ERROR_MSG="Each octet of the IP must be in the range of 0-255 or * or ?"
                    continue
                fi
            done

            if [ $_FOUND_ERROR -ne 0 ]; then
                log_error "#$i: $RULE_NAME='$RULE'"
                log_error ""
                log_error "Rules must be in the format of: [allow|deny] <ip> (octet must be in the range of 0-255 or * or ?)"
                log_error "$_ERROR_MSG"
                log_error ""
                log_error "Examples:"
                log_error "  RULE_allow='allow 192.168.2.*'"
                log_error "  RULE_deny='deny 192.168.2.1?"
                exit 1
            fi

            log_success "#$i: $RULE_NAME = '$RULE' (allow/deny rule)"
            i=$((i+1))
            continue
        fi
    }
    _allow_deny_rule

    function _forward_rule() {
        _TEST=$(echo "$RULE" | grep -qE '^[^ ]+ [0-9]+ [^ ]+ [0-9]+$')
        if [ $? -ne 0 ]; then
            log_error "#$i: $RULE_NAME='$RULE'"
            log_error ""
            log_error "Rules must be in the format of: <from_ip> <from_port> <to_ip_or_domain> <to_port>"
            log_error "Example: RULE_my_server='0.0.0.0 80 1.2.3.4 8080'"
            exit 1
        fi

        # Validate each port range
        FROM_PORT=$(echo "$RULE" | cut -d' ' -f2)
        if [ $FROM_PORT -lt 1 -o $FROM_PORT -gt 65535 ]; then
            log_error "#$i: $RULE_NAME='$RULE'"
            log_error ""
            log_error "<from_port> must be in the range of 1-65535"
            log_error "Example: RULE_my_server='0.0.0.0 80 1.2.3.4 8080'"
            exit 1
        fi
        TO_PORT=$(echo "$RULE" | cut -d' ' -f4)
        if [ $TO_PORT -lt 1 -o $TO_PORT -gt 65535 ]; then
            log_error "#$i: $RULE_NAME='$RULE'"
            log_error ""
            log_error "<to_port> must be in the range of 1-65535"
            log_error "Example: RULE_my_server='0.0.0.0 80 1.2.3.4 8080'"
            exit 1
        fi

        # Validate each IP address
        FROM_IP=$(echo "$RULE" | cut -d' ' -f1)
        echo "$FROM_IP" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'
        if [ $? -ne 0 ]; then
            log_error "#$i: $RULE_NAME='$RULE'"
            log_error ""
            log_error "<from_ip> must be in the format of 'x.x.x.x'"
            log_error "Example: RULE_my_server='0.0.0.0 80 1.2.3.4 8080'"
            exit 1
        fi
        for OCTET in $(echo "$FROM_IP" | tr '.' ' '); do
            if [ $OCTET -lt 0 -o $OCTET -gt 255 ]; then
                log_error "#$i: $RULE_NAME='$RULE'"
                log_error ""
                log_error "Invalid IP: $FROM_IP"
                log_error "Each octet of the <from_ip> must be in the range of 0-255"
                log_error "Example: RULE_my_server='0.0.0.0 80 1.2.3.4 8080'"
                exit 1
            fi
        done

        log_success "#$i: $RULE_NAME = '$RULE'"
        i=$((i+1))
        continue
    }
    _forward_rule

done

# Create the /tmp/rinetd.conf file
log_title "Creating /tmp/rinetd.conf..."
echo "logfile /var/log/rinetd.log" > /tmp/rinetd.conf
echo "logcommon" >> /tmp/rinetd.conf
i=1
for RULE_NAME in $RULES_NAME; do
    RULE=$(eval "echo \$$RULE_NAME")
    RULE=$(echo "$RULE" | tr -s ' ')

    echo "" >> /tmp/rinetd.conf
    echo "# $i: $RULE_NAME" >> /tmp/rinetd.conf
    echo "$RULE" >> /tmp/rinetd.conf
    i=$((i+1))
done
log_info "/tmp/rinetd.conf:"
cat /tmp/rinetd.conf

# Start rinetd
log_title "Starting rinetd..."
h_run "rinetd -f -c /tmp/rinetd.conf"
