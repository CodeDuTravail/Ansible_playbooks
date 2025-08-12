#!/bin/bash
#
# /home/pi/scripts/ufw_set_n_check_ex.sh
# Purpose: Monitor open ports and configure UFW rules accordingly
# Optimized version with better error handling and crontab management
#
# Crontab entry: 0 1 * * * ~/$USER/scripts/ufw_set_n_check_ex.sh
#
# -------------------------------------------------------------------------------

set -euo pipefail  # Exit on error, undefined vars, pipe failures

# Configuration
readonly SCRIPT_NAME="$(basename "$0")"
readonly DATE=$(date +%Y_%m_%d)

readonly DEST_MAIL="YOUR_MAIL@DOMAIN.COM"
readonly UFW_CONF_PATH="/etc/ufw/monitor"

readonly UFW_CONF_FILE="$UFW_CONF_PATH/ufw_ports.conf"
readonly UFW_CONF_CHECK="$UFW_CONF_PATH/ufw_ports.check"
readonly UFW_CONF_DIFF="$UFW_CONF_PATH/ufw_ports.log"
readonly UFW_LAST_LOG="$UFW_CONF_PATH/ufw_ports_last.log"
readonly CRON_COMMENT="# UFW PORTS CONF CHECK"
readonly CRON_JOB="0 1 * * * $(realpath "$0" 2>/dev/null || echo "$0")"

# Logging function
log_message() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $*"
}

# Error handling
error_exit() {
    log_message "ERROR: $1" >&2
    exit "${2:-1}"
}

# Check if running as root (required for UFW operations)
check_root() {
    if [[ $EUID -ne 0 ]]; then
        error_exit "This script must be run as root for UFW operations"
    fi
}

# Detect system type
detect_system() {
    if [[ -f /etc/debian_version ]]; then
        echo "debian"
    elif [[ -f /etc/redhat-release ]]; then
        echo "rhel"
    else
        echo "unknown"
    fi
}

# Get listening ports - improved command
get_listening_ports() {
    local system_type="$1"
    
    case "$system_type" in
        "debian"|"rhel")
            # Use ss (modern replacement for netstat) if available, fallback to netstat
            if command -v ss >/dev/null 2>&1; then
                ss -tlnH | awk '{print $4}' | sed 's/.*://' | sort -un
            else
                netstat -tlnH 2>/dev/null | awk '{print $4}' | sed 's/.*://' | sort -un
            fi
            ;;
        *)
            error_exit "Unsupported system type: $system_type"
            ;;
    esac
}

# Create directory if it doesn't exist
ensure_directory() {
    local dir="$1"
    if [[ ! -d "$dir" ]]; then
        log_message "Creating directory: $dir"
        mkdir -p "$dir" || error_exit "Failed to create directory: $dir"
        chmod 755 "$dir"
    fi
}

# Add crontab entry safely (prevents duplicates)
add_crontab_entry() {
    local temp_cron
    temp_cron=$(mktemp)
    
    # Get current crontab, ignore error if no crontab exists
    crontab -l 2>/dev/null > "$temp_cron" || true
    
    # Check if our job already exists
    if ! grep -Fq "$CRON_JOB" "$temp_cron"; then
        log_message "Adding crontab entry"
        {
            echo "$CRON_COMMENT"
            echo "$CRON_JOB"
        } >> "$temp_cron"
        
        crontab "$temp_cron" || error_exit "Failed to update crontab"
        log_message "Crontab entry added successfully"
    else
        log_message "Crontab entry already exists, skipping"
    fi
    
    rm -f "$temp_cron"
}

# Configure UFW rules for ports
configure_ufw_rules() {
    local ports=("$@")
    
    log_message "Configuring UFW rules for ${#ports[@]} ports"
    
    for port in "${ports[@]}"; do
        if [[ "$port" =~ ^[0-9]+$ ]] && [[ "$port" -gt 0 ]] && [[ "$port" -lt 65536 ]]; then
            log_message "Adding UFW rule: allow $port"
            if ! ufw allow "$port" >/dev/null 2>&1; then
                log_message "WARNING: Failed to add UFW rule for port $port"
            fi
        else
            log_message "WARNING: Invalid port number: $port"
        fi
    done
}

# Send email notification
send_notification() {
    local subject="$1"
    local body="$2"
    
    if command -v msmtp >/dev/null 2>&1; then
        {
            printf "Subject: %s - %s\n\n" "$(uname -n)" "$subject"
            printf "Port monitoring report from %s\n\n" "$(uname -n)"
            printf "Generated on: %s\n\n" "$(date)"
            printf "%s\n" "$body"
        } | msmtp -a default "$DEST_MAIL" 2>/dev/null || log_message "WARNING: Failed to send email"
    else
        log_message "WARNING: msmtp not found, email notification skipped"
    fi
}

# Main execution
main() {
    log_message "Starting UFW port monitoring script"
    
    check_root
    
    local system_type
    system_type=$(detect_system)
    log_message "Detected system: $system_type"
    
    ensure_directory "$UFW_CONF_PATH"
    
    # Get current listening ports
    local ports
    readarray -t ports < <(get_listening_ports "$system_type")
    
    if [[ ${#ports[@]} -eq 0 ]]; then
        error_exit "No listening ports found"
    fi
    
    log_message "Found ${#ports[@]} listening ports"
    
    # Initialize if config file doesn't exist
    if [[ ! -f "$UFW_CONF_FILE" ]]; then
        log_message "Initializing UFW configuration"
        
        {
            echo "UFW PORTS"
            printf '%s\n' "${ports[@]}"
        } > "$UFW_CONF_FILE"
        
        configure_ufw_rules "${ports[@]}"
        
        log_message "UFW status:"
        ufw status numbered
        
        add_crontab_entry
        
        # Send initial configuration email
        local initial_config
        initial_config=$(cat "$UFW_CONF_FILE")
        local ufw_status
        ufw_status=$(ufw status numbered 2>/dev/null || echo "UFW status unavailable")
        
        local email_body
        email_body=$(cat <<EOF
Initial UFW port configuration has been set up on $(uname -n).

DETECTED LISTENING PORTS:
$initial_config

UFW RULES CONFIGURED:
$ufw_status

Total ports configured: ${#ports[@]}

This is an automated notification from the UFW port monitoring system.
The system will now monitor for port changes and notify you of any modifications.

Script location: $0
Configuration path: $UFW_CONF_PATH
EOF
)
        
        send_notification "Initial UFW Configuration Complete" "$email_body"
        
        log_message "Initialization complete, notification sent"
        return 0
    fi
    
    # Backup previous diff if it exists
    [[ -f "$UFW_CONF_DIFF" ]] && mv "$UFW_CONF_DIFF" "$UFW_LAST_LOG"
    
    # Create current port check file
    {
        echo "OPEN PORTS CHECK"
        printf '%s\n' "${ports[@]}"
    } > "$UFW_CONF_CHECK"
    
    # Compare configurations
    log_message "Comparing port configurations"
    diff -y --width=40 "$UFW_CONF_FILE" "$UFW_CONF_CHECK" > "$UFW_CONF_DIFF" || true
    
    # Check if we need to send notification
    if [[ -f "$UFW_LAST_LOG" ]] && ! diff -q "$UFW_LAST_LOG" "$UFW_CONF_DIFF" >/dev/null 2>&1; then
        if grep -E '[<>|]' "$UFW_CONF_DIFF" >/dev/null 2>&1; then
            log_message "Port changes detected, sending notification"
            local diff_content
            diff_content=$(cat "$UFW_CONF_DIFF")
            send_notification "WARNING: Port configuration changed" "$diff_content"
        else
            log_message "No significant port changes detected"
        fi
    elif [[ ! -f "$UFW_LAST_LOG" ]]; then
        log_message "First run comparison, no notification sent"
    else
        log_message "No changes since last run"
    fi
    
    log_message "UFW port monitoring script completed"
}

# Execute main function
main "$@"