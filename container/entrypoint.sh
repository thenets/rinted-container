#!/bin/bash

# If $@ is found, run it and bypass the rest of the script
if [ $# -gt 0 ]; then
    exec "$@"
    exit 0
fi

# Helpers
# =========================
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

    # Sanitize the rule, removing multiple spaces
    RULE=$(echo "$RULE" | tr -s ' ')

    _TEST=$(echo "$RULE" | grep -qE '^[^ ]+ [0-9]+ [^ ]+ [0-9]+$')
    if [ $? -ne 0 ]; then
        log_error "Invalid rule: $RULE_NAME='$RULE'"
        log_error "Rules must be in the format of: <from_ip> <from_port> <to_ip_or_domain> <to_port>"
        log_error "Example: RULE_my_server='0.0.0.0 80 1.2.3.4 8080'"
        exit 1
    fi

    # Validate each port range
    FROM_PORT=$(echo "$RULE" | cut -d' ' -f2)
    if [ $FROM_PORT -lt 1 -o $FROM_PORT -gt 65535 ]; then
        log_error "Invalid rule: $RULE_NAME='$RULE'"
        log_error "<from_port> must be in the range of 1-65535"
        log_error "Example: RULE_my_server='0.0.0.0 80 1.2.3.4 8080'"
        exit 1
    fi
    TO_PORT=$(echo "$RULE" | cut -d' ' -f4)
    if [ $TO_PORT -lt 1 -o $TO_PORT -gt 65535 ]; then
        log_error "Invalid rule: $RULE_NAME='$RULE'"
        log_error "<to_port> must be in the range of 1-65535"
        log_error "Example: RULE_my_server='0.0.0.0 80 1.2.3.4 8080'"
        exit 1
    fi

    # Validate each IP address
    FROM_IP=$(echo "$RULE" | cut -d' ' -f1)
    echo "$FROM_IP" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'
    if [ $? -ne 0 ]; then
        log_error "Invalid rule: $RULE_NAME='$RULE'"
        log_error "<from_ip> must be in the format of 'x.x.x.x'"
        log_error "Example: RULE_my_server='0.0.0.0 80 1.2.3.4 8080'"
        exit 1
    fi
    for OCTET in $(echo "$FROM_IP" | tr '.' ' '); do
        if [ $OCTET -lt 0 -o $OCTET -gt 255 ]; then
            log_error "Invalid rule: $RULE_NAME='$RULE'"
            log_error "Invalid IP: $FROM_IP"
            log_error "Each octet of the <from_ip> must be in the range of 0-255"
            log_error "Example: RULE_my_server='0.0.0.0 80 1.2.3.4 8080'"
            exit 1
        fi
    done

    # Print the rule
    log_success "#$i: $RULE_NAME = '$RULE'"

    i=$((i+1))
done

# Create the /tmp/rinetd.conf file
log_title "Creating /tmp/rinetd.conf..."
echo "logfile /var/log/rinetd.log" > /tmp/rinetd.conf
i=1
for RULE_NAME in $RULES_NAME; do
    RULE=$(eval "echo \$$RULE_NAME")

    # Sanitize the rule, removing multiple spaces
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
